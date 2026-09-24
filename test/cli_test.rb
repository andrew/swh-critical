require "bundler/setup"
require "test/unit"
require "webmock/test_unit"
require "tmpdir"
require "stringio"
require_relative "../lib/cli"

class CliTest < Test::Unit::TestCase
  PACKAGES = SwhCritical::Http::PACKAGES
  SWH = SwhCritical::Http::SWH
  REPO = "https://github.com/Example/Library"
  SHA = "a" * 40
  SWHID = "swh:1:rev:#{SHA}"

  def setup
    @directory = Dir.mktmpdir("swh-critical-test-")
    @out, @err = StringIO.new, StringIO.new
    @original_token = ENV.delete("SWH_API_TOKEN")
    WebMock.disable_net_connect!
  end

  def teardown
    @original_token.nil? ? ENV.delete("SWH_API_TOKEN") : ENV["SWH_API_TOKEN"] = @original_token
    FileUtils.remove_entry(@directory)
  end

  def cli(*args)
    SwhCritical::CLI.run([*args, "--data", @directory, "--min-free-gib", "0"], out: @out, err: @err, env_file: File.join(@directory, ".env"))
  end

  def response(body, status: 200, link: nil)
    { status: status, body: JSON.generate(body), headers: { "Content-Type" => "application/json", "Link" => link }.compact }
  end

  def packages_url(registry, page: 1, per_page: 100)
    "#{PACKAGES}/registries/#{registry}/packages?critical=true&per_page=#{per_page}&sort=name&order=asc&page=#{page}"
  end

  def package(name, url = REPO)
    { "name" => name, "purl" => "pkg:gem/#{name}", "critical" => true, "repository_url" => url, "ecosystem" => "rubygems" }
  end

  def seed(packages = [package("example")])
    stub_request(:get, "#{PACKAGES}/registries?per_page=100&page=1").to_return(response([{ name: "rubygems.org", ecosystem: "rubygems" }]))
    stub_request(:get, packages_url("rubygems.org")).to_return(response(packages))
    assert_equal 0, cli("collect"), @err.string
  end

  def query(sql)
    db = SQLite3::Database.new(File.join(@directory, "investigation.sqlite3"))
    db.results_as_hash = true
    db.execute(sql)
  ensure
    db&.close
  end

  def test_discovers_all_registry_pages_and_resumes_package_pages
    registry_next = "#{PACKAGES}/registries?per_page=100&page=2"
    stub_request(:get, "#{PACKAGES}/registries?per_page=100&page=1").to_return(response([{ name: "rubygems.org" }], link: "<#{registry_next}>; rel=\"next\""))
    stub_request(:get, registry_next).to_return(response([{ name: "gem.coop" }]))
    package_next = packages_url("rubygems.org", page: 2)
    stub_request(:get, packages_url("rubygems.org")).to_return(response([package("alpha")], link: "<#{package_next}>; rel=\"next\""))
    stub_request(:get, package_next).to_return(response([package("beta", REPO.downcase + ".git")]))
    stub_request(:get, packages_url("gem.coop")).to_return(response([package("no-source", nil)]))

    assert_equal 0, cli("collect", "--pages-per-registry", "1")
    assert_equal ["complete", "partial"], query("SELECT status FROM registries ORDER BY name").map { |r| r["status"] }
    assert_equal 0, cli("report")
    assert_equal false, JSON.parse(File.read(File.join(@directory, "out/summary.json")))["cohort_complete"]
    assert_equal 0, cli("collect")
    assert_equal 3, query("SELECT * FROM packages").size
    assert_equal 1, query("SELECT * FROM repositories").size
    assert_equal REPO, query("SELECT original_url FROM packages WHERE name = 'alpha'").first["original_url"]
    assert_equal 0, cli("collect", "--offline")
    assert_requested(:get, packages_url("rubygems.org"), times: 1)
    assert_equal 0, cli("report")
    summary = JSON.parse(File.read(File.join(@directory, "out/summary.json")))
    assert_equal true, summary["cohort_complete"]
    assert_equal 1, summary["packages_without_repository"]
  end

  def test_case_sensitive_hosts_are_not_merged_and_missing_urls_are_retained
    seed([package("upper", "https://forge.example/Owner/Repo"), package("lower", "https://forge.example/Owner/repo"), package("none", nil)])
    assert_equal 2, query("SELECT * FROM repositories").size
    assert_equal 3, query("SELECT * FROM packages").size
  end

  def test_science_collection_resumes_and_reports_matches_without_changing_cohort
    seed([package("example"), package("alias", "https://github.com/Old/Project"),
      package("research-without-url", nil), package("dependency", "https://github.com/deps/library"),
      package("same-repo-other-package", "https://github.com/deps/library"),
      package("unmatched", "https://forge.example/Owner/Repo")])
    fake_git("#{SHA}\tHEAD\n") { assert_equal 0, cli("heads") }
    stub_request(:post, "#{SWH}/known/").to_return(response({ SWHID => { known: false } }))
    assert_equal 0, cli("known")
    science_data = File.join(@directory, "science")
    invoke = ->(*args) { SwhCritical::CLI.run([*args, "--data", science_data, "--min-free-gib", "0"], out: @out, err: @err, env_file: File.join(@directory, ".env")) }
    first = "#{SwhCritical::Http::SCIENCE}/projects/search_seeds?per_page=100&page=1"
    second = first.sub("&page=1", "&page=2")
    dependencies = "#{SwhCritical::Http::SCIENCE}/packages?per_page=1000&page=1"
    projects = [
      { project_id: 1, repository_url: REPO + ".git", science_score: 50, packages: [{ purl: "pkg:gem/example@1.0" }], seeds: [] },
      { project_id: 2, repository_url: "https://github.com/New/Project", science_score: 40, packages: [], seeds: [
        { type: "repository_url", source: "repository.previous_names", value: "https://github.com/Old/Project.git" },
        { type: "repository_url", source: "citation_cff.repository-code", value: "https://forge.example/Owner/Repo" }] }
    ]
    stub_request(:get, first).with { |r| !r.headers.key?("Authorization") }.to_return(response(projects, link: "<#{second}>; rel=\"next\""))
    stub_request(:get, second).to_return(response([{ project_id: 3, repository_url: "https://research.example/project", science_score: 80,
      packages: [{ purl: "pkg:gem/research-without-url" }], seeds: [] }]))
    stub_request(:get, dependencies).with { |r| !r.headers.key?("Authorization") }.to_return(response([
      { id: 10, purl: "pkg:gem/dependency", scientific_projects_count: 200 },
      { id: 11, purl: "pkg:gem/example", scientific_projects_count: 100 },
      { id: 12, purl: "pkg:gem/unrelated", repository_url: "https://forge.example/Owner/Repo", scientific_projects_count: 50 }
    ]))
    ENV["SWH_API_TOKEN"] = "science-must-not-receive-token"
    before = query("SELECT * FROM packages")
    assert_equal 0, invoke.call("science", "--limit", "1", "--per-page", "1000"), @err.string
    assert_equal 0, invoke.call("science-report", "--cohort", @directory), @err.string
    summary_path = File.join(science_data, "out/science_summary.json")
    partial = JSON.parse(File.read(summary_path))
    assert_equal false, partial["science_collection_complete"]
    assert_equal 2, partial.dig("groups", "projects", "packages")
    assert_equal 2, partial.dig("groups", "dependencies", "packages")
    assert_equal 3, partial.dig("not_matched_yet", "packages")
    assert_equal 1, partial.dig("not_matched_yet", "repositories")
    assert_equal 1, partial.dig("all", "latest_release_tag_matching", "no_repository")
    assert_equal 0, invoke.call("science"), @err.string
    assert_equal 0, invoke.call("science", "--offline"), @err.string
    assert_equal 0, invoke.call("science-report", "--cohort", @directory, "--offline"), @err.string
    summary = JSON.parse(File.read(summary_path))
    assert_equal true, summary["science_collection_complete"]
    assert_equal 3, summary.dig("groups", "projects", "packages")
    assert_equal 2, summary.dig("groups", "projects", "repositories")
    assert_equal 1, summary.dig("groups", "projects", "packages_without_repository")
    assert_equal({ "missing" => 2 }, summary.dig("groups", "projects", "current_commit_coverage"))
    assert_equal 2, summary.dig("not_matched", "packages")
    assert_equal 1, summary.dig("not_matched", "repositories")
    assert_equal before, query("SELECT * FROM packages")
    matches = CSV.read(File.join(science_data, "out/science_matches.csv"), headers: true)
    assert_equal %w[purl repository_url], matches.select { |r| r["purl"] == "pkg:gem/example" && r["category"] == "projects" }.map { |r| r["method"] }.sort
    assert_equal ["repository_alias"], matches.select { |r| r["purl"] == "pkg:gem/alias" }.map { |r| r["method"] }
    assert_not_include matches.map { |r| r["purl"] }, "pkg:gem/unmatched"
    assert_requested(:get, first, times: 1)
    assert_requested(:get, second, times: 1)
    assert_requested(:get, dependencies, times: 1)
  end

  def test_science_rate_limits_resume_from_last_saved_page
    first = "#{SwhCritical::Http::SCIENCE}/projects/search_seeds?per_page=100&page=1"
    second = first.sub("&page=1", "&page=2")
    stub_request(:get, first).to_return(response([{ project_id: 1, repository_url: REPO, packages: [], seeds: [] }], link: "<#{second}>; rel=\"next\""))
    stub_request(:get, second).to_return(status: 429, headers: { "Retry-After" => "60" })
    assert_equal 75, cli("science")
    assert_equal 1, query("SELECT COUNT(*) AS count FROM science_records").first["count"]
    assert_equal second, JSON.parse(query("SELECT value FROM metadata WHERE key = 'science:projects'").first["value"])["next_url"]
    assert_equal 75, cli("science")
    assert_requested(:get, first, times: 1)
    assert_requested(:get, second, times: 1)
  end

  def test_science_rejects_mutating_pagination_endpoints
    first = "#{SwhCritical::Http::SCIENCE}/projects/search_seeds?per_page=100&page=1"
    stub_request(:get, first).to_return(response([{ project_id: 1 }], link: "<#{SwhCritical::Http::SCIENCE}/projects/lookup?url=https://example.org/repo>; rel=\"next\""))
    assert_equal 1, cli("science")
    assert_include @err.string, "Invalid pagination link"
    assert_equal [], query("SELECT * FROM science_records")
    assert_not_requested(:get, %r{science.ecosyste.ms/api/v1/projects/lookup})
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    assert_raise(SwhCritical::Error) { SwhCritical::Http.new(store).request(:get, "#{SwhCritical::Http::SCIENCE}/projects/lookup?url=example") }
  ensure
    store&.close
  end

  def test_science_invalid_records_leave_page_incomplete
    first = "#{SwhCritical::Http::SCIENCE}/projects/search_seeds?per_page=100&page=1"
    stub_request(:get, first).to_return(response([{ project_id: 1 }, { repository_url: REPO }]))
    assert_equal 1, cli("science")
    assert_include @err.string, "no integer ID"
    assert_empty query("SELECT * FROM science_records")
    assert_empty query("SELECT * FROM science_pages")
  end

  def record_http_delays
    delays = []
    SwhCritical::Http.define_method(:sleep) { |seconds| delays << seconds }
    yield delays
  ensure
    SwhCritical::Http.remove_method(:sleep)
  end

  def test_science_timeouts_retry_with_delays_and_save_only_successful_responses
    projects = "#{SwhCritical::Http::SCIENCE}/projects/search_seeds?per_page=100&page=1"
    dependencies = "#{SwhCritical::Http::SCIENCE}/packages?per_page=100&page=1"
    stub_request(:get, projects).to_raise(Net::OpenTimeout).then.to_raise(Net::ReadTimeout).then.to_return(response([{ project_id: 1, repository_url: REPO }]))
    stub_request(:get, dependencies).to_return(response([]))
    record_http_delays do |delays|
      assert_equal 0, cli("science"), @err.string
      assert_equal [5, 15], delays.select { |delay| delay >= 1 }
    end
    assert_include @err.string, "retry=1/3 delay=5s"
    assert_include @err.string, "retry=2/3 delay=15s"
    assert_requested(:get, projects, times: 3)
    assert_equal 1, query("SELECT * FROM science_records").size
    assert_equal 0, cli("science", "--offline")
    assert_equal 2, Dir.glob(File.join(@directory, "cache/*.gz")).size
  end

  def test_exhausted_timeout_retries_preserve_science_resume_position
    first = "#{SwhCritical::Http::SCIENCE}/projects/search_seeds?per_page=100&page=1"
    second = first.sub("&page=1", "&page=2")
    stub_request(:get, first).to_return(response([{ project_id: 1 }], link: "<#{second}>; rel=\"next\""))
    stub_request(:get, second).to_raise(Net::ReadTimeout)
    record_http_delays do |delays|
      assert_equal 1, cli("science")
      assert_equal [5, 15, 30], delays.select { |delay| delay >= 1 }
    end
    assert_requested(:get, second, times: 4)
    assert_equal 1, query("SELECT * FROM science_records").size
    assert_equal second, JSON.parse(query("SELECT value FROM metadata WHERE key = 'science:projects'").first["value"])["next_url"]
    assert_equal 1, Dir.glob(File.join(@directory, "cache/*.gz")).size
  end

  def test_known_post_timeout_retries_the_same_read_only_batch
    seed
    fake_git("#{SHA}\tHEAD\n") { assert_equal 0, cli("heads") }
    request = stub_request(:post, "#{SWH}/known/").with(body: [SWHID].to_json)
      .to_raise(Net::ReadTimeout).then.to_return(response({ SWHID => { known: true } }))
    record_http_delays do |delays|
      assert_equal 0, cli("known"), @err.string
      assert_equal [5], delays.select { |delay| delay >= 1 }
    end
    assert_requested(request, times: 2)
    assert_equal "present", query("SELECT status FROM objects").first["status"]
  end

  def recovery_csv(rows)
    File.write(File.join(@directory, "upstream.json"), JSON.generate(repository: REPO))
    path = File.join(@directory, "recoveries.csv")
    CSV.open(path, "w") do |csv|
      csv << SwhCritical::Recovery::COLUMNS
      rows.each do |name, url|
        csv << ["rubygems.org", "pkg:gem/#{name}", url, "https://rubygems.org/api/v1/gems/#{name}.json",
          "upstream.json", "Upstream source_code_uri"]
      end
    end
    path
  end

  def test_recovery_preserves_original_and_reuses_existing_repository
    seed([package("existing"), package("missing", "UNKNOWN"), package("new", nil)])
    path = recovery_csv([["missing", REPO], ["new", "https://github.com/Another/Project"]])
    assert_equal 0, cli("recover", "--mappings", path, "--offline"), @err.string
    assert_equal 2, query("SELECT * FROM repositories").size
    missing = query("SELECT * FROM packages WHERE name = 'missing'").first
    assert_equal "UNKNOWN", missing["original_url"]
    assert_equal REPO.downcase, missing["repository_url"]
    evidence = JSON.parse(query("SELECT evidence FROM repository_recoveries WHERE purl = 'pkg:gem/missing'").first["evidence"])
    assert_equal Digest::SHA256.file(File.join(@directory, "upstream.json")).hexdigest, evidence["evidence_sha256"]
    assert_equal "upstream.json", evidence["evidence_file"]
    aliases = query("SELECT url FROM aliases WHERE repository_url = 'https://github.com/another/project'").map { |row| row["url"] }
    assert_include aliases, "https://github.com/Another/Project"
    assert_include aliases, "https://github.com/another/project"
    assert_equal "unchecked", query("SELECT head_status FROM repositories WHERE url = 'https://github.com/another/project'").first["head_status"]
    assert_equal 0, cli("recover", "--mappings", path, "--offline"), @err.string
    assert_equal 2, query("SELECT * FROM repository_recoveries").size
    assert_equal 0, cli("report")
    summary = JSON.parse(File.read(File.join(@directory, "out/summary.json")))
    assert_equal 0, summary["packages_without_repository"]
    assert_equal 2, summary["packages_with_recovered_repository"]
    assert_equal 2, CSV.read(File.join(@directory, "out/repository_recoveries.csv"), headers: true).size
  end

  def test_recovery_rejects_conflicts_before_applying_any_rows
    seed([package("missing", nil), package("existing")])
    path = recovery_csv([["missing", REPO], ["existing", "https://github.com/wrong/project"]])
    assert_equal 1, cli("recover", "--mappings", path), @err.string
    assert_include @err.string, "would replace an existing repository"
    assert_nil query("SELECT repository_url FROM packages WHERE name = 'missing'").first["repository_url"]
    assert_empty query("SELECT * FROM repository_recoveries")
  end

  def test_recovery_requires_evidence_and_a_package_in_the_cohort
    seed([package("missing", nil)])
    path = recovery_csv([["outside", REPO]])
    assert_equal 1, cli("recover", "--mappings", path)
    assert_include @err.string, "Package outside cohort"
    path = recovery_csv([["missing", REPO]])
    File.unlink(File.join(@directory, "upstream.json"))
    assert_equal 1, cli("recover", "--mappings", path)
    assert_include @err.string, "Missing evidence file"
    assert_nil query("SELECT repository_url FROM packages").first["repository_url"]
    assert_empty query("SELECT * FROM repository_recoveries")
  end

  def test_registry_filter_collects_only_selected_registries
    registries = %w[gem.coop pypi.org rubygems.org]
    stub_request(:get, "#{PACKAGES}/registries?per_page=100&page=1").to_return(response(registries.map { |name| { name: name } }))
    %w[gem.coop rubygems.org].each do |name|
      stub_request(:get, packages_url(name, per_page: 3)).to_return(response([package("example")]))
    end

    assert_equal 0, cli("collect", "--registry", "rubygems.org", "--registry", "gem.coop", "--per-page", "3", "--pages-per-registry", "1"), @err.string
    assert_equal %w[gem.coop rubygems.org], query("SELECT registry FROM packages ORDER BY registry").map { |row| row["registry"] }
    assert_equal "unchecked", query("SELECT status FROM registries WHERE name = 'pypi.org'").first["status"]
    assert_not_requested(:get, /registries\/pypi.org\/packages/)
    assert_equal 0, cli("collect", "--registry", "gem.coop", "--offline")
  end

  def oversized_response
    record = package("large")
    record["description"] = "x" * SwhCritical::Http::MAX_RESPONSE_BYTES
    response([record])
  end

  def test_large_page_reduces_size_without_skipping_records_and_resumes
    stub_request(:get, "#{PACKAGES}/registries?per_page=100&page=1").to_return(response([{ name: "rubygems.org" }]))
    first = packages_url("rubygems.org", per_page: 5)
    large = packages_url("rubygems.org", page: 2, per_page: 5)
    smaller = packages_url("rubygems.org", page: 3, per_page: 2)
    following = packages_url("rubygems.org", page: 4, per_page: 2)
    stub_request(:get, first).to_return(response(%w[a b c d e].map { |name| package(name) }, link: "<#{large}>; rel=\"next\""))
    stub_request(:get, large).to_return(oversized_response)
    stub_request(:get, smaller).to_return(response(%w[e f].map { |name| package(name) }, link: "<#{following}>; rel=\"next\""))
    stub_request(:get, following).to_return(response([package("g")]))

    assert_equal 0, cli("collect", "--per-page", "5", "--pages-per-registry", "1")
    assert_equal 0, cli("collect", "--pages-per-registry", "1")
    assert_equal %w[a b c d e f], query("SELECT name FROM packages ORDER BY name").map { |row| row["name"] }
    registry = query("SELECT * FROM registries").first
    assert_equal "partial", registry["status"]
    assert_equal following, registry["next_url"]
    assert_equal 0, cli("collect")
    assert_equal %w[a b c d e f g], query("SELECT name FROM packages ORDER BY name").map { |row| row["name"] }
    assert_equal "complete", query("SELECT status FROM registries").first["status"]
    assert_requested(:get, large, times: 1)
    cached_urls = Dir[File.join(@directory, "cache/*.gz")].map { |path| JSON.parse(Zlib::GzipReader.open(path, &:read))["url"] }
    assert_not_include cached_urls, large
  end

  def test_one_oversized_package_remains_an_error_without_unbounded_retries
    stub_request(:get, "#{PACKAGES}/registries?per_page=100&page=1").to_return(response([{ name: "rubygems.org" }]))
    oversized = oversized_response
    [5, 2, 1].each do |size|
      stub_request(:get, packages_url("rubygems.org", per_page: size)).to_return(oversized)
    end

    assert_equal 1, cli("collect", "--per-page", "5")
    registry = query("SELECT * FROM registries").first
    assert_equal "error", registry["status"]
    assert_include registry["error"], "Response exceeds"
    assert_equal URI.decode_www_form(URI(packages_url("rubygems.org", per_page: 1)).query).to_h,
      URI.decode_www_form(URI(registry["next_url"]).query).to_h
    assert_empty query("SELECT * FROM packages")
    [5, 2, 1].each { |size| assert_requested(:get, packages_url("rubygems.org", per_page: size), times: 1) }
  end

  def visit(origin, status: "full", snapshot: "b" * 40)
    { origin: origin, visit: 1, status: status, snapshot: snapshot, date: "2026-09-01T12:00:00Z", type: "git" }
  end

  def stub_origins
    query("SELECT url FROM aliases").each do |row|
      stub_request(:get, "#{SWH}/origin/#{URI.encode_www_form_component(row['url'])}/visits/?per_page=100").to_return(response({ error: "not found" }, status: 404))
    end
  end

  def test_origin_coverage_finds_an_older_partial_snapshot_after_a_failed_visit
    seed
    stub_origins
    url = "#{SWH}/origin/#{URI.encode_www_form_component(REPO)}/visits/?per_page=100"
    next_url = url + "&last_visit=2"
    stub_request(:get, url).to_return(response([visit(REPO, status: "failed", snapshot: nil)], link: "<#{next_url}>; rel=\"next\""))
    stub_request(:get, next_url).to_return(response([visit(REPO, status: "partial")]))
    assert_equal 0, cli("origins")
    row = query("SELECT * FROM repositories").first
    assert_equal "snapshot_found", row["coverage"]
    observations = JSON.parse(row["origin_data"])["observations"]
    assert_equal "partial", observations.find { |o| o["origin"] == REPO }["status"]
    assert_equal 2, observations.find { |o| o["origin"] == REPO }["evidence"].size
  end

  def test_http_errors_are_unknown_and_not_missing
    seed
    stub_origins
    stub_request(:get, "#{SWH}/origin/#{URI.encode_www_form_component(REPO)}/visits/?per_page=100").to_return(status: 503)
    assert_equal 0, cli("origins")
    assert_equal "unknown", query("SELECT coverage FROM repositories").first["coverage"]
    assert_match(/RESULT .* unknown .*HTTP 503/, @out.string)
  end

  def test_origin_registered_without_snapshot_is_distinct_from_not_found
    seed
    stub_origins
    stub_request(:get, "#{SWH}/origin/#{URI.encode_www_form_component(REPO)}/visits/?per_page=100").to_return(response([]))
    assert_equal 0, cli("origins")
    assert_equal "no_snapshot", query("SELECT coverage FROM repositories").first["coverage"]
  end

  def fake_git(output)
    directory = File.join(@directory, "bin")
    FileUtils.mkdir_p(directory)
    path = File.join(directory, "git")
    File.write(path, "#!#{RbConfig.ruby}\nFile.write(#{File.join(@directory, 'git-args.json').inspect}, ARGV.inspect)\nvalue = #{output.inspect}\nSTDOUT.write(value.is_a?(Hash) ? value.fetch(ARGV[-2]) : value)\n")
    File.chmod(0o755, path)
    old = ENV["PATH"]
    ENV["PATH"] = "#{directory}:#{old}"
    yield
  ensure
    ENV["PATH"] = old
  end

  def test_heads_feed_deduplicated_batches_and_reports_without_clones
    seed([package("one"), package("two", "https://github.com/example/other")])
    fake_git("ref: refs/heads/main\tHEAD\n#{SHA}\tHEAD\n") do
      assert_equal 0, cli("heads")
    end
    assert_equal 2, query("SELECT * FROM repositories WHERE head_status = 'observed'").size
    assert_equal 1, query("SELECT * FROM objects").size
    assert_include File.read(File.join(@directory, "git-args.json")), '"ls-remote"'
    request = stub_request(:post, "#{SWH}/known/").with(body: JSON.generate([SWHID])).to_return(response({ SWHID => { known: false } }))
    assert_equal 0, cli("known")
    assert_requested request, times: 1
    assert_equal 0, cli("report")
    summary = JSON.parse(File.read(File.join(@directory, "out/summary.json")))
    assert_equal({ "missing" => 2 }, summary["current_commit_coverage"])
    assert_equal({ "missing" => 1 }, summary["distinct_objects"])
    assert_empty Dir.glob(File.join(@directory, "**/.git"))
  end

  def test_tags_match_collected_versions_and_share_known_batches_with_heads
    seed([
      package("annotated").merge("latest_release_number" => "1.2.0"),
      package("lightweight").merge("latest_release_number" => "2.0.0"),
      package("ambiguous").merge("latest_release_number" => "3.0.0"),
      package("unmatched").merge("latest_release_number" => "9.0.0"),
      package("no-version")
    ])
    fake_git("#{SHA}\tHEAD\n") { assert_equal 0, cli("heads") }
    annotation, lightweight = "b" * 40, "c" * 40
    refs = "#{annotation}\trefs/tags/v1.2.0\n#{SHA}\trefs/tags/v1.2.0^{}\n#{lightweight}\trefs/tags/lightweight@2.0.0\n#{SHA}\trefs/tags/2.0.0\n#{SHA}\trefs/tags/3.0.0\n#{lightweight}\trefs/tags/v3.0.0\n"
    fake_git(refs) { assert_equal 0, cli("tags"), @err.string }
    assert_include File.read(File.join(@directory, "git-args.json")), '"refs/tags/*"'
    assert_equal({ "ambiguous" => 1, "matched" => 2, "no_version" => 1, "unmatched" => 1 }, query("SELECT match_status, COUNT(*) AS count FROM package_releases GROUP BY match_status").to_h { |r| r.values_at("match_status", "count") })
    light = query("SELECT * FROM package_releases WHERE purl = 'pkg:gem/lightweight'").first
    assert_equal "lightweight@2.0.0", light["tag_name"]
    assert_nil light["release_swhid"]
    assert_equal 3, query("SELECT * FROM objects").size
    release_id = "swh:1:rel:#{annotation}"
    light_id = "swh:1:rev:#{lightweight}"
    request = stub_request(:post, "#{SWH}/known/").with(body: [SWHID, release_id, light_id].to_json)
      .to_return(response({ SWHID => { known: true }, release_id => { known: false }, light_id => { known: false } }))
    assert_equal 0, cli("known")
    assert_requested request, times: 1
    assert_equal 0, cli("report")
    summary = JSON.parse(File.read(File.join(@directory, "out/summary.json")))
    assert_equal({ "present" => 1 }, summary["current_commit_coverage"])
    assert_equal({ "missing" => 1 }, summary["annotated_release_coverage"])
    assert_equal({ "present" => 1, "revision_not_found" => 1 }, summary["tag_target_revision_coverage"])
    assert_equal 5, CSV.read(File.join(@directory, "out/release_tags.csv"), headers: true).size
    assert_equal 0, cli("tags", "--offline")
  end

  def test_tags_seed_existing_cohort_from_cached_collection_and_report_unknowns
    seed([package("one").merge("latest_release_number" => "1.0"), package("two").merge("latest_release_number" => "2.0")])
    db = SQLite3::Database.new(File.join(@directory, "investigation.sqlite3"))
    db.execute("DELETE FROM package_releases")
    db.close
    assert_equal 0, cli("tags", "--offline")
    assert_equal 2, query("SELECT * FROM package_releases WHERE match_status = 'unknown'").size
    fake_git("#{SHA}\trefs/tags/v1.0\n") { assert_equal 0, cli("tags") }
    assert_equal 1, query("SELECT * FROM package_releases WHERE match_status = 'matched'").size
    assert_equal 1, query("SELECT * FROM package_releases WHERE match_status = 'unmatched'").size
    assert_equal 1, query("SELECT * FROM tag_scans").size
    assert_not_nil JSON.parse(query("SELECT metadata_evidence FROM package_releases LIMIT 1").first["metadata_evidence"])["cache_file"]
  end

  def test_malformed_or_sha256_tag_refs_are_unknown_instead_of_unmatched
    seed([package("one").merge("latest_release_number" => "1.0")])
    fake_git("#{SHA}\trefs/tags/other\n#{'d' * 64}\trefs/tags/v1.0\n") { assert_equal 0, cli("tags") }
    assert_equal "unknown", query("SELECT match_status FROM package_releases").first["match_status"]
    assert_empty query("SELECT * FROM objects")
    assert_empty query("SELECT * FROM tag_scans")
  end

  def test_origin_followup_checks_only_confirmed_missing_heads
    names = %w[a-present b-missing c-unknown d-pending e-unreadable f-unchecked]
    urls = names.to_h { |name| [name, "https://github.com/example/#{name}"] }
    seed(names.map { |name| package(name, urls.fetch(name)) })
    stub_origins
    assert_equal 0, cli("origins", "--missing-heads")
    assert_not_requested(:get, /archive.softwareheritage.org/)

    replies = names.first(4).each_with_index.to_h { |name, index| [urls.fetch(name), "#{(index + 1).to_s.rjust(40, '0')}\tHEAD\n"] }
    replies[urls.fetch("e-unreadable")] = ""
    fake_git(replies) { assert_equal 0, cli("heads", "--limit", "5") }
    identifiers = (1..3).map { |index| "swh:1:rev:#{index.to_s.rjust(40, '0')}" }
    stub_request(:post, "#{SWH}/known/").with(body: identifiers.to_json).to_return(response({
      identifiers[0] => { known: true }, identifiers[1] => { known: false }, identifiers[2] => { known: "invalid" }
    }))
    assert_equal 0, cli("known", "--limit", "3")
    missing_url = "#{SWH}/origin/#{URI.encode_www_form_component(urls.fetch('b-missing'))}/visits/?per_page=100"
    stub_request(:get, missing_url).to_return(response([visit(urls.fetch("b-missing"))]))
    assert_equal 0, cli("origins", "--missing-heads")
    assert_requested(:get, missing_url, times: 1)
    (names - ["b-missing"]).each do |name|
      assert_not_requested(:get, "#{SWH}/origin/#{URI.encode_www_form_component(urls.fetch(name))}/visits/?per_page=100")
    end
    assert_equal [urls.fetch("b-missing")], query("SELECT url FROM repositories WHERE coverage != 'unchecked'").map { |row| row["url"] }
    assert_equal 0, cli("report")
    summary = JSON.parse(File.read(File.join(@directory, "out/summary.json")))
    assert_equal({ "snapshot_found" => 1 }, summary["missing_heads_repository_coverage"])
    assert_equal 5, summary["repository_coverage"]["unchecked"]
    assert_equal 0, cli("origins", "--missing-heads", "--offline")
    assert_requested(:get, missing_url, times: 1)
  end

  def test_origin_check_stops_after_first_snapshot
    record = package("example")
    record["repo_metadata"] = { "previous_names" => %w[Example/Old1 Example/Old2 Example/Old3 Example/Old4] }
    seed([record])
    url = "#{SWH}/origin/#{URI.encode_www_form_component(REPO)}/visits/?per_page=100"
    stub_request(:get, url).to_return(response([visit(REPO, status: "partial")]))
    assert_equal 0, cli("origins")
    row = query("SELECT coverage, origin_data FROM repositories").first
    data = JSON.parse(row["origin_data"])
    assert_equal "snapshot_found", row["coverage"]
    assert_equal 1, data["observations"].size
    assert_empty data["incomplete_reasons"]
    assert_not_include @out.string, "alias limit"
  end

  def test_clones_capture_identifiers_and_history_then_remove_temporary_repositories
    real_git, status = Open3.capture2("which", "git")
    assert status.success?
    real_git = real_git.strip
    source = File.join(@directory, "source")
    environment = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" }
    git = lambda do |*args|
      stdout, stderr, result = Open3.capture3(environment, real_git, *args)
      assert result.success?, stderr
      stdout.strip
    end
    git.call("init", "--initial-branch=main", source)
    File.write(File.join(source, "source\tname.txt"), "fixture source contents\n")
    git.call("-C", source, "add", ".")
    2.times { |index| git.call("-C", source, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.org", "commit", "--allow-empty", "-m", "Commit #{index}") }
    git.call("-C", source, "tag", "v1.0")
    sha = git.call("-C", source, "rev-parse", "HEAD")
    git.call("-C", source, "update-ref", "refs/heads/HEAD", "HEAD~1")
    stdout, stderr, status = Open3.capture3(environment, real_git, "-C", source, "rev-parse", "HEAD")
    assert status.success?
    assert_equal sha, stdout.strip
    assert_include stderr, "refname 'HEAD' is ambiguous"
    url = "https://github.com/clone-fixtures/#{File.basename(@directory)}"
    seed([package("clone-fixture", url).merge("latest_release_number" => "1.0")])
    fake_git("#{sha}\tHEAD\n") { assert_equal 0, cli("heads") }
    fake_git("#{sha}\trefs/tags/v1.0\n") { assert_equal 0, cli("tags") }
    stub_request(:post, "#{SWH}/known/").to_return(response({ "swh:1:rev:#{sha}" => { known: false } }))
    assert_equal 0, cli("known")
    stub_origins
    assert_equal 0, cli("origins", "--missing-releases")

    bin = File.join(@directory, "clone-bin")
    FileUtils.mkdir_p(bin)
    failure = File.join(@directory, "fail-clone")
    File.write(failure, "yes")
    File.write(File.join(bin, "git"), <<~RUBY)
      #!#{RbConfig.ruby}
      args = ARGV.dup
      if args.include?("clone")
        if File.exist?(#{failure.inspect})
          Dir.mkdir(args.last)
          File.write(File.join(args.last, "partial"), "partial clone")
          warn "fixture clone failure"
          exit 1
        end
        args[-2] = #{source.inspect}
      end
      exec(#{real_git.inspect}, *args)
    RUBY
    tool = File.join(bin, "swhid")
    File.write(tool, <<~RUBY)
      #!#{RbConfig.ruby}
      require "open3"
      abort "Expected --format raw" unless ARGV.first == "version" || ARGV[1, 2] == ["--format", "raw"]
      case ARGV.first
      when "version" then puts "swhid fixture"
      when "snapshot" then puts "swh:1:snp:#{'b' * 40}"
      when "revision"
        sha, status = Open3.capture2(#{real_git.inspect}, "-C", ARGV.last, "rev-parse", "HEAD")
        abort unless status.success?
        puts "swh:1:rev:" + sha.strip
      else abort "Unexpected command"
      end
    RUBY
    File.chmod(0o755, tool, File.join(bin, "git"))
    previous_path = ENV["PATH"]
    ENV["PATH"] = "#{bin}:#{previous_path}"
    assert_equal 0, cli("clones", "--swhid", tool), @err.string
    failed = JSON.parse(query("SELECT value FROM metadata WHERE key LIKE 'clone_check:%'").first["value"])
    assert_equal "error", failed["status"]
    assert_equal false, failed["cloned"]
    assert_include failed["error"], "fixture clone failure"
    assert_empty Dir.children(File.join(@directory, "clone-tmp"))
    FileUtils.rm_f(failure)
    assert_equal 0, cli("clones", "--swhid", tool), @err.string
    result = JSON.parse(query("SELECT value FROM metadata WHERE key LIKE 'clone_check:%'").first["value"])
    assert_equal "complete", result["status"]
    assert_equal true, result["cloned"]
    assert_equal "swh:1:snp:#{'b' * 40}", result["snapshot_swhid"]
    assert_equal "swh:1:rev:#{sha}", result["revision_swhid"]
    assert_equal 2, result["commit_count"]
    assert_empty Dir.children(File.join(@directory, "clone-tmp"))
    evidence = JSON.parse(Zlib::GzipReader.open(File.join(@directory, result["evidence_file"]), &:read))
    assert_include evidence["refs"], "refs/heads/main"
    assert_include evidence["refs"], "refs/heads/HEAD"
    assert_include evidence["refs"], "refs/tags/v1.0"
    assert_equal 2, evidence["revisions"].lines.size
    assert_equal 1, CSV.read(File.join(@directory, "out/clone_checks.csv"), headers: true).size
    File.write(failure, "should not clone again")
    assert_equal 0, cli("clones", "--swhid", tool)
    assert_equal result, JSON.parse(query("SELECT value FROM metadata WHERE key LIKE 'clone_check:%'").first["value"])
    FileUtils.rm_f(failure)
    history = evidence.fetch("revisions").lines.map(&:strip)
    older = history.find { |commit| commit != sha }
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    store.db.execute("INSERT INTO objects(swhid, status) VALUES (?, 'present')", ["swh:1:rev:#{older}"])
    store.close
    assert_equal 0, cli("history"), @err.string
    coverage = JSON.parse(File.read(File.join(@directory, "out/history_coverage.json"))).first
    assert_equal "complete", coverage["status"]
    assert_equal "continuous_older_first_parent_history", coverage["pattern"]
    assert_equal 1, coverage["missing_tip_commits"]
    assert_equal "swh:1:rev:#{older}", coverage["nearest_present_revision"]
    assert_equal 0, coverage["present_to_missing_parent_edges"]
    assert_equal 2, coverage["branches"].size
    assert_empty Dir.children(File.join(@directory, "clone-tmp"))
    File.write(failure, "should not clone again")
    assert_equal 0, cli("history", "--offline"), @err.string
    assert_equal [coverage], JSON.parse(File.read(File.join(@directory, "out/history_coverage.json")))
    FileUtils.rm_f(failure)
    input = File.join(@directory, "repositories.txt")
    File.write(input, "#{url}\n")
    blob = git.call("-C", source, "rev-parse", "#{sha}:source\tname.txt")
    File.write(File.join(source, "new-after-baseline.txt"), "new upstream content\n")
    git.call("-C", source, "add", ".")
    git.call("-C", source, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.org", "commit", "-m", "After baseline")
    batches = []
    stub_request(:post, "#{SWH}/known/").to_return do |request|
      ids = JSON.parse(request.body)
      batches << ids
      response(ids.to_h { |id| [id, { known: id == "swh:1:cnt:#{blob}" }] })
    end
    assert_equal 0, cli("contents", "--repositories", input, "--swhid", tool), @err.string
    content = JSON.parse(File.read(File.join(@directory, "out/content_coverage.json"))).first
    assert_equal "missing", content["head_tree_status"]
    assert_equal({ "present" => 1 }, content["head_file_statuses"])
    assert_equal "source\tname.txt", content["head_files"].first["path"]
    assert_equal ["swh:1:cnt:#{blob}"], batches.flatten.grep(/:cnt:/)
    assert_equal "missing", query("SELECT status FROM objects WHERE swhid = 'swh:1:rev:#{sha}'").first["status"]
    assert_empty Dir.children(File.join(@directory, "clone-tmp"))
    File.write(failure, "should not clone again")
    assert_equal 0, cli("contents", "--repositories", input, "--offline"), @err.string
    assert_equal 1, batches.size
  ensure
    ENV["PATH"] = previous_path if previous_path
  end

  def test_history_distinguishes_gaps_merges_and_unrelated_archived_branches
    seed
    a, b, c, d, e, f = (1..6).map { |n| n.to_s(16).rjust(40, "0") }
    graph = { a => [], b => [a], c => [b], d => [a], e => [c, d], f => [] }.to_h do |sha, parents|
      [sha, { "parents" => parents, "committed_at" => "2026-01-0#{sha.to_i(16)}T12:00:00Z" }]
    end
    clone = { "url" => REPO, "status" => "complete", "revision_swhid" => "swh:1:rev:#{e}", "evidence_file" => "clone-evidence/fixture.json.gz" }
    FileUtils.mkdir_p(File.join(@directory, "clone-evidence"))
    FileUtils.mkdir_p(File.join(@directory, "history-evidence"))
    Zlib::GzipWriter.open(File.join(@directory, clone["evidence_file"])) do |gzip|
      gzip.write(JSON.generate("revisions" => graph.keys.join("\n") + "\n", "refs" => "#{e} refs/heads/main\n#{f} refs/heads/other\n"))
    end
    Zlib::GzipWriter.open(File.join(@directory, "history-evidence/#{Digest::SHA256.hexdigest(REPO)}.json.gz")) do |gzip|
      gzip.write(JSON.generate("head" => e, "current_head" => e, "commits" => graph))
    end
    scenarios = [
      [%w[present present present present missing present], "continuous_older_first_parent_history", 4, 1, 0],
      [%w[present missing present missing missing present], "gaps_in_first_parent_history", 2, 1, 1],
      [%w[missing missing missing present missing missing], "merged_history_only", 1, 0, 1],
      [%w[missing missing missing missing missing present], "outside_head_ancestry_only", 0, 1, 0],
      [%w[present unknown missing missing missing missing], "incomplete", 1, 0, 0]
    ]
    scenarios.each do |statuses, pattern, in_head, outside, holes|
      store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
      begin
        store.set("clone_check:#{REPO}", clone)
        store.db.execute("DELETE FROM metadata WHERE key = ?", ["history_coverage:#{REPO}"])
        graph.keys.zip(statuses).each do |sha, status|
          store.db.execute("INSERT OR REPLACE INTO objects(swhid, status) VALUES (?, ?)", ["swh:1:rev:#{sha}", status])
        end
      ensure
        store.close
      end
      assert_equal 0, cli("history", "--offline"), @err.string
      result = JSON.parse(File.read(File.join(@directory, "out/history_coverage.json"))).first
      assert_equal pattern, result["pattern"]
      assert_equal in_head, result["present_in_head_ancestry"]
      assert_equal outside, result["present_outside_head_ancestry"]
      assert_equal holes, result["present_to_missing_parent_edges"]
      assert_equal 2.0, result["commit_date_gap_days"] if pattern == "continuous_older_first_parent_history"
    end
  end

  def test_history_refreshes_cached_analysis_after_known_checks_finish
    seed
    parent, head = %w[a b].map { |char| char * 40 }
    graph = {
      parent => { "parents" => [], "committed_at" => "2026-01-01T12:00:00Z" },
      head => { "parents" => [parent], "committed_at" => "2026-01-02T12:00:00Z" }
    }
    clone = { "url" => REPO, "status" => "complete", "revision_swhid" => "swh:1:rev:#{head}",
      "evidence_file" => "clone-evidence/fixture.json.gz" }
    FileUtils.mkdir_p(File.join(@directory, "clone-evidence"))
    FileUtils.mkdir_p(File.join(@directory, "history-evidence"))
    Zlib::GzipWriter.open(File.join(@directory, clone["evidence_file"])) do |gzip|
      gzip.write(JSON.generate("revisions" => "#{head}\n#{parent}\n", "refs" => "#{head} refs/heads/main\n"))
    end
    Zlib::GzipWriter.open(File.join(@directory, "history-evidence/#{Digest::SHA256.hexdigest(REPO)}.json.gz")) do |gzip|
      gzip.write(JSON.generate("head" => head, "current_head" => head, "commits" => graph))
    end
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    store.set("clone_check:#{REPO}", clone)
    store.db.execute("INSERT INTO objects(swhid, status) VALUES (?, 'present')", ["swh:1:rev:#{parent}"])
    store.db.execute("INSERT INTO objects(swhid) VALUES (?)", ["swh:1:rev:#{head}"])
    store.close
    assert_equal 0, cli("history", "--offline"), @err.string
    first = JSON.parse(File.read(File.join(@directory, "out/history_coverage.json"))).first
    assert_equal "incomplete", first["pattern"]
    assert_equal 1, first["first_parent_present"]
    stub_request(:post, "#{SWH}/known/").with(body: JSON.generate(["swh:1:rev:#{head}"]))
      .to_return(response({ "swh:1:rev:#{head}" => { known: true } }))
    assert_equal 0, cli("known"), @err.string
    assert_equal 0, cli("history", "--offline"), @err.string
    second = JSON.parse(File.read(File.join(@directory, "out/history_coverage.json"))).first
    assert_equal "head_present", second["pattern"]
    assert_equal 2, second["first_parent_present"]
    assert_equal "swh:1:rev:#{head}", second["nearest_present_revision"]
    assert_equal 0.0, second["commit_date_gap_days"]
    assert_equal 0, cli("history", "--offline"), @err.string
    assert_equal [second], JSON.parse(File.read(File.join(@directory, "out/history_coverage.json")))

    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    store.set("history_coverage:#{REPO}", first.reject { |key, _| key == "known_fingerprint" })
    store.close
    assert_equal 0, cli("history", "--offline"), @err.string
    refreshed = JSON.parse(File.read(File.join(@directory, "out/history_coverage.json"))).first
    assert_equal "head_present", refreshed["pattern"]
    assert_equal 2, refreshed["first_parent_present"]
  end

  def test_trace_matches_archived_boundaries_through_paginated_snapshots
    seed
    head = "b" * 40
    snapshot = "c" * 40
    fork = "https://github.com/fork/Library"
    graph_file = "trace-fixture.json.gz"
    Zlib::GzipWriter.open(File.join(@directory, graph_file)) do |gzip|
      gzip.write(JSON.generate("head" => head, "commits" => { head => { "parents" => [SHA] }, SHA => { "parents" => [] } }))
    end
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    store.set("history_coverage:#{REPO}", { "status" => "complete", "evidence_file" => graph_file, "nearest_present_revision" => SWHID })
    store.close
    input = File.join(@directory, "trace-repositories.txt")
    File.write(input, "#{REPO}\n")
    stub_request(:get, "#{SWH}/origin/search/Library/?limit=1000&use_ql=false")
      .to_return(response([{ url: fork, snapshot_id: snapshot, last_visit_date: "2026-01-02T00:00:00Z" }]))
    stub_request(:get, "#{SWH}/snapshot/#{snapshot}/?branches_count=1000")
      .to_return(response({ branches: { "HEAD" => { target_type: "alias", target: "refs/heads/main" } }, next_branch: "refs/heads/main" }))
    stub_request(:get, "#{SWH}/snapshot/#{snapshot}/?branches_count=1000&branches_from=refs%2Fheads%2Fmain")
      .to_return(response({ branches: { "refs/heads/main" => { target_type: "revision", target: SHA } }, next_branch: nil }))
    assert_equal 0, cli("trace", "--repositories", input), @err.string
    rows = JSON.parse(File.read(File.join(@directory, "out/origin_traces.json")))
    candidate = rows.first.fetch("candidates").first
    assert_equal true, candidate["archived_boundary_is_branch_tip"]
    assert_equal [SHA], candidate["shared_revision_targets"]
    assert_equal 1, candidate["distance_from_saved_head"]
    assert_equal true, candidate["snapshot_complete"]
    assert_equal 2, candidate["snapshot_pages"].size
    assert_equal 0, cli("trace", "--repositories", input, "--offline")
    assert_requested(:get, "#{SWH}/origin/search/Library/?limit=1000&use_ql=false", times: 1)
  end

  def test_package_contents_matches_wrapped_source_without_claiming_git_history
    seed
    head, snapshot, release, wrapper, old_tree, head_tree = %w[b c d e f 1].map { |char| char * 40 }
    origin = "https://pkg.go.dev/github.com/Example/Library"
    file = "package-clone.json.gz"
    Zlib::GzipWriter.open(File.join(@directory, file)) { |gzip| gzip.write(JSON.generate("revisions" => "#{head}\n#{SHA}\n")) }
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    store.set("clone_check:#{REPO}", { "url" => REPO, "status" => "complete", "evidence_file" => file })
    store.set("origin_search:#{REPO}", { "matches" => [{ "url" => origin, "relation" => "package_registry_reference",
      "visit_check" => { "status" => "full", "visit" => { "snapshot" => snapshot } } }] })
    [head, SHA].each { |sha| store.db.execute("INSERT INTO objects(swhid, status) VALUES (?, 'missing')", ["swh:1:rev:#{sha}"]) }
    store.close
    FileUtils.mkdir_p(File.join(@directory, "tree-evidence"))
    path = File.join(@directory, "tree-evidence", "#{Digest::SHA256.hexdigest(REPO)}.json.gz")
    Zlib::GzipWriter.open(path) { |gzip| gzip.write(JSON.generate("head" => head, "by_revision" => { head => head_tree, SHA => old_tree })) }
    stub_request(:get, "#{SWH}/snapshot/#{snapshot}/?branches_count=1000").to_return(response({ branches: {
      "HEAD" => { target_type: "alias", target: "releases/v1.0" },
      "releases/v1.0" => { target_type: "release", target: release } }, next_branch: nil }))
    stub_request(:get, "#{SWH}/release/#{release}/").to_return(response({ synthetic: true, target_type: "directory", target: wrapper }))
    stub_request(:get, "#{SWH}/directory/#{wrapper}/").to_return(response([{ name: "module@v1.0", type: "dir", target: old_tree }]))

    assert_equal 0, cli("package-contents"), @err.string
    data = JSON.parse(File.read(File.join(@directory, "out/package_contents.json"))).first
    assert_equal "complete", data["status"]
    archived = data.fetch("origins").first.fetch("releases").first
    assert_equal [wrapper, old_tree], archived["directory_chain"]
    assert_equal [SHA], archived["matching_git_revisions"]
    assert_equal false, archived["saved_head_tree_matches"]
    assert_equal ["missing"], query("SELECT DISTINCT status FROM objects").map { |row| row["status"] }
    assert_equal 0, cli("package-contents", "--offline"), @err.string
    assert_requested(:get, "#{SWH}/release/#{release}/", times: 1)
  end

  def test_origin_contents_follows_release_and_revision_targets_to_source_files
    seed([package("example").merge("latest_release_number" => "2.0")])
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    store.db.execute("UPDATE packages SET registry = 'npmjs.org'")
    store.db.execute("UPDATE package_releases SET registry = 'npmjs.org'")
    store.close
    snapshot, release, revision, wrapper, tree, blob, old_tree = %w[b c d e f 1 2].map { |char| char * 40 }
    url = REPO.downcase
    input = File.join(@directory, "repositories.txt")
    File.write(input, "#{url}\n")
    FileUtils.mkdir_p(File.join(@directory, "content-evidence"))
    evidence = File.join(@directory, "content-evidence", "#{Digest::SHA256.hexdigest(url)}.json.gz")
    Zlib::GzipWriter.open(evidence) do |gzip|
      gzip.write(JSON.generate("contents" => ["swh:1:cnt:#{blob}"], "revision_trees" => { SHA => tree },
        "head_files" => [{ "path" => "index.js", "type" => "blob", "object" => blob }]))
    end
    origin = "https://www.npmjs.com/package/example"
    stub_request(:get, "#{SWH}/origin/#{URI.encode_www_form_component(origin)}/visits/?per_page=100")
      .to_return(response([visit(origin)]))
    stub_request(:get, "#{SWH}/snapshot/#{snapshot}/?branches_count=1000").to_return(response({ branches: {
      "HEAD" => { target_type: "alias", target: "releases/2.0" },
      "releases/2.0" => { target_type: "release", target: release },
      "releases/1.0" => { target_type: "revision", target: revision } }, next_branch: nil }))
    stub_request(:get, "#{SWH}/release/#{release}/").to_return(response({ target_type: "directory", target: wrapper }))
    stub_request(:get, "#{SWH}/revision/#{revision}/").to_return(response({ directory: old_tree }))
    stub_request(:get, "#{SWH}/directory/#{wrapper}/").to_return(response([{ name: "package", type: "dir", target: tree }]))
    [tree, old_tree].each do |id|
      stub_request(:get, "#{SWH}/directory/#{id}/").to_return(response([{ name: "index.js", type: "file", target: blob, perms: 33188 }]))
    end
    assert_equal 0, cli("origin-contents", "--repositories", input), @err.string
    result = JSON.parse(File.read(File.join(@directory, "out/origin_contents.json"))).first
    targets = result.fetch("origins").first.fetch("targets")
    assert_equal "complete", result["status"]
    assert_equal "releases/2.0", targets.first["branch"]
    assert_equal ["index.js"], targets.first["head_files_matched"]
    assert_equal({ SHA => tree }, targets.first["matching_git_roots"])
    assert_equal "revision", targets.last["object_chain"].first["type"]
    assert_equal true, targets.last["walk_complete"]
    assert_equal 0, cli("origin-contents", "--repositories", input, "--offline"), @err.string
    assert_requested(:get, "#{SWH}/directory/#{tree}/", times: 1)
  end

  def test_origin_candidates_search_package_and_former_names_without_changing_coverage
    seed([package("library-package")])
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    store.db.execute("INSERT INTO aliases VALUES (?, ?, ?)", [REPO.downcase, "https://github.com/Former/OldName.git", "repo_metadata.previous_names"])
    store.close
    input = File.join(@directory, "repositories.txt")
    File.write(input, "#{REPO.downcase}\n")
    %w[library OldName library-package].each do |pattern|
      stub_request(:get, "#{SWH}/origin/search/#{pattern}/?limit=1000&use_ql=false")
        .to_return(response([{ url: "https://registry.example/#{pattern}", snapshot_id: SHA }]))
    end
    stub_request(:get, "#{SWH}/origin/search/Library/?limit=1000&use_ql=false").to_return(response([]))
    assert_equal 0, cli("origin-candidates", "--repositories", input), @err.string
    row = JSON.parse(File.read(File.join(@directory, "out/origin_candidates.json"))).first
    assert_equal "complete", row["status"]
    assert_include row["searches"].map { |search| search["pattern"] }, "OldName"
    assert_include row["searches"].map { |search| search["pattern"] }, "library-package"
    assert_equal "unchecked", query("SELECT coverage FROM repositories").first["coverage"]
    assert_equal 0, cli("origin-candidates", "--repositories", input, "--offline"), @err.string
    assert_requested(:get, "#{SWH}/origin/search/OldName/?limit=1000&use_ql=false", times: 1)
  end

  def test_origin_search_checks_case_variants_and_registry_references_without_merging_substrings
    seed
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    store.set("clone_check:#{REPO}", { "url" => REPO, "status" => "complete" })
    store.close
    variant = "https://github.com/EXAMPLE/Library.git"
    registry = "https://pkg.go.dev/github.com/Example/Library"
    unrelated = "#{REPO}-extra"
    search = "#{SWH}/origin/search/#{URI.encode_www_form_component('github.com/Example/Library')}/?limit=1000&use_ql=false"
    stub_request(:get, search).to_return(response([{ url: variant }, { url: registry }, { url: unrelated }]))
    [variant, registry].each do |origin|
      stub_request(:get, "#{SWH}/origin/#{URI.encode_www_form_component(origin)}/visits/?per_page=100")
        .to_return(response([visit(origin)]))
    end
    assert_equal 0, cli("origin-search"), @err.string
    results = JSON.parse(File.read(File.join(@directory, "out/origin_search.json")))
    assert_equal "complete", results.first["status"]
    matches = results.first["matches"]
    assert_equal %w[same_repository_url package_registry_reference substring_match], matches.map { |r| r["relation"] }
    assert_equal "full", matches[0].dig("visit_check", "status")
    assert_equal "full", matches[1].dig("visit_check", "status")
    assert_nil matches[2]["visit_check"]
    assert_equal "unchecked", query("SELECT coverage FROM repositories").first["coverage"]
    assert_equal 0, cli("origin-search", "--offline"), @err.string
    assert_requested(:get, search, times: 1)
  end

  def test_origin_search_retries_unknown_visits_including_previously_completed_searches
    seed
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    store.set("clone_check:#{REPO}", { "url" => REPO, "status" => "complete" })
    store.close
    search = "#{SWH}/origin/search/#{URI.encode_www_form_component('github.com/Example/Library')}/?limit=1000&use_ql=false"
    visits = "#{SWH}/origin/#{URI.encode_www_form_component(REPO)}/visits/?per_page=100"
    stub_request(:get, search).to_return(response([{ url: REPO }]))
    stub_request(:get, visits).to_return({ status: 503 }, { status: 503 }, response([visit(REPO)]))
    2.times do
      assert_equal 0, cli("origin-search"), @err.string
      result = JSON.parse(File.read(File.join(@directory, "out/origin_search.json"))).first
      assert_equal "incomplete", result["status"]
      assert_equal "unknown", result["matches"].first.dig("visit_check", "status")
    end
    assert_requested(:get, visits, times: 2)
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    saved = store.get("origin_search:#{REPO}")
    store.set("origin_search:#{REPO}", saved.merge("status" => "complete"))
    store.close
    assert_equal 0, cli("origin-search"), @err.string
    result = JSON.parse(File.read(File.join(@directory, "out/origin_search.json"))).first
    assert_equal "complete", result["status"]
    assert_equal "full", result["matches"].first.dig("visit_check", "status")
    assert_requested(:get, visits, times: 3)
    assert_requested(:get, search, times: 1)
    assert_equal 0, cli("origin-search", "--offline"), @err.string
    assert_equal [result], JSON.parse(File.read(File.join(@directory, "out/origin_search.json")))
  end

  def test_clone_known_batches_saved_history_and_resumes_without_rechecking_objects
    seed
    revisions = (1..1001).map { |n| n.to_s(16).rjust(40, "0") }
    snapshots = %w[b c].map { |char| "swh:1:snp:#{char * 40}" }
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    begin
      FileUtils.mkdir_p(File.join(@directory, "clone-evidence"))
      [revisions, [revisions.last]].each_with_index do |history, index|
        url = "https://github.com/example/history-#{index}"
        file = "clone-evidence/#{index}.json.gz"
        Zlib::GzipWriter.open(File.join(@directory, file)) do |gzip|
          gzip.write(JSON.generate("revisions" => history.join("\n") + "\n"))
        end
        store.set("clone_check:#{url}", { "url" => url, "status" => "complete", "snapshot_swhid" => snapshots[index], "evidence_file" => file })
      end
      store.db.execute("INSERT INTO objects(swhid, status) VALUES (?, 'missing')", ["swh:1:rev:#{revisions.last}"])
      store.db.execute("INSERT INTO objects(swhid) VALUES (?)", [SWHID])
    ensure
      store.close
    end
    batches = []
    present = "swh:1:rev:#{revisions.first}"
    stub_request(:post, "#{SWH}/known/").to_return do |request|
      ids = JSON.parse(request.body)
      batches << ids
      response(ids.to_h { |id| [id, { known: id == present }] })
    end
    assert_equal 0, cli("clone-known", "--limit", "1001"), @err.string
    assert_equal [1000, 1], batches.map(&:size)
    assert_equal snapshots, batches.first.first(2)
    rows = CSV.read(File.join(@directory, "out/clone_known.csv"), headers: true)
    assert_equal "found", rows[0]["archive_evidence"]
    assert_equal "false", rows[0]["checks_complete"]
    assert_equal "none_in_checked_objects", rows[1]["archive_evidence"]
    assert_equal "true", rows[1]["checks_complete"]
    assert_equal 0, cli("clone-known"), @err.string
    assert_equal [1000, 1, 1], batches.map(&:size)
    assert_equal 1002, batches.flatten.uniq.size
    assert_not_include batches.flatten, SWHID
    assert_not_include batches.flatten, "swh:1:rev:#{revisions.last}"
    summary = JSON.parse(File.read(File.join(@directory, "out/clone_known_summary.json")))
    assert_equal 2, summary["repositories_checks_complete"]
    assert_equal({ "missing" => 2 }, summary["snapshots"])
    assert_equal({ "present" => 1, "missing" => 1000 }, summary["revisions"])
    assert_equal 0, cli("clone-known", "--offline"), @err.string
    assert_equal 3, batches.size
  end

  def test_release_gap_origins_skip_existing_evidence_and_report_the_whole_group
    names = %w[a-snapshot b-no-origin c-head-present d-target-present e-release-present f-needs-origin g-pending]
    urls = names.to_h { |name| [name, "https://github.com/example/#{name}"] }
    records = names.map { |name| package(name, urls.fetch(name)).merge("latest_release_number" => "1.0") }
    records << package("shared-release", urls.fetch("f-needs-origin")).merge("latest_release_number" => "1.0")
    seed(records)
    stub_origins
    origin_url = ->(name) { "#{SWH}/origin/#{URI.encode_www_form_component(urls.fetch(name))}/visits/?per_page=100" }
    stub_request(:get, origin_url.call("a-snapshot")).to_return(response([visit(urls.fetch("a-snapshot"))]))
    assert_equal 0, cli("origins", "--limit", "2")

    heads, tags, known = {}, {}, {}
    names.each_with_index do |name, index|
      head = format("%040x", index + 1)
      target = format("%040x", index + 20)
      annotation = format("%040x", index + 40)
      heads[urls.fetch(name)] = "#{head}\tHEAD\n"
      known["swh:1:rev:#{head}"] = { known: name == "c-head-present" }
      if name == "g-pending"
        tags[urls.fetch(name)] = "#{target}\trefs/tags/v1.0\n"
      else
        tags[urls.fetch(name)] = "#{annotation}\trefs/tags/v1.0\n#{target}\trefs/tags/v1.0^{}\n"
        known["swh:1:rev:#{target}"] = { known: name == "d-target-present" }
        known["swh:1:rel:#{annotation}"] = { known: name == "e-release-present" }
      end
    end
    fake_git(heads) { assert_equal 0, cli("heads") }
    fake_git(tags) { assert_equal 0, cli("tags") }
    stub_request(:post, "#{SWH}/known/").to_return(response(known))
    assert_equal 0, cli("known")
    assert_equal 0, cli("report")
    summary_path = File.join(@directory, "out/summary.json")
    initial = JSON.parse(File.read(summary_path)).fetch("release_gap_repositories")
    assert_equal 6, initial["repositories"]
    assert_equal({ "archived_evidence_found" => 4, "no_snapshot_at_checked_origins" => 1, "unresolved" => 1 }, initial["archive_status"])

    stub_request(:get, origin_url.call("f-needs-origin")).to_return(response([visit(urls.fetch("f-needs-origin"), status: "partial")]))
    assert_equal 0, cli("origins", "--missing-releases"), @err.string
    assert_include @out.string, "scope=missing_releases_without_evidence selected=1"
    assert_requested(:get, origin_url.call("f-needs-origin"), times: 1)
    %w[c-head-present d-target-present e-release-present g-pending].each do |name|
      assert_not_requested(:get, origin_url.call(name))
    end
    assert_equal 0, cli("origins", "--missing-releases", "--offline")
    assert_requested(:get, origin_url.call("f-needs-origin"), times: 1)
    assert_equal 0, cli("report")
    result = JSON.parse(File.read(summary_path)).fetch("release_gap_repositories")
    assert_equal 6, result["repositories"]
    assert_equal({ "archived_evidence_found" => 5, "no_snapshot_at_checked_origins" => 1 }, result["archive_status"])
    assert_equal 5, result["missing_tag_target_revision"]
    assert_equal 5, result["missing_annotated_release"]
    rows = CSV.read(File.join(@directory, "out/release_gap_repositories.csv"), headers: true)
    assert_equal 6, rows.size
    assert_equal ["snapshot"], JSON.parse(rows.find { |r| r["url"] == urls.fetch("f-needs-origin") }["archive_evidence"])
    assert_equal 1, cli("origins", "--missing-releases", "--missing-heads")
    assert_equal 1, cli("heads", "--missing-releases")
  end

  def test_batches_split_at_a_thousand_and_resume_after_rate_limit
    seed
    db = SQLite3::Database.new(File.join(@directory, "investigation.sqlite3"))
    db.transaction do
      1001.times { |index| db.execute("INSERT INTO objects(swhid) VALUES (?)", ["swh:1:rev:#{(index + 1).to_s(16).rjust(40, '0')}"]) }
    end
    db.close
    sizes = []
    stub_request(:post, "#{SWH}/known/").to_return do |request|
      ids = JSON.parse(request.body)
      sizes << ids.size
      ids.size == 1000 ? response(ids.to_h { |id| [id, { known: true }] }) : response({}, status: 429).merge(headers: { "Retry-After" => "120" })
    end
    assert_equal 75, cli("known", "--limit", "1001")
    assert_equal [1000, 1], sizes
    assert_equal 1000, query("SELECT * FROM objects WHERE status = 'present'").size
    assert_equal 1, query("SELECT * FROM objects WHERE status = 'pending'").size
    assert_equal 75, cli("known")
    assert_equal [1000, 1], sizes
  end

  def test_invalid_known_values_remain_unknown
    seed
    fake_git("#{SHA}\tHEAD\n") { assert_equal 0, cli("heads") }
    stub_request(:post, "#{SWH}/known/").to_return(response({ SWHID => { known: "false" } }))
    assert_equal 0, cli("known")
    assert_equal "unknown", query("SELECT status FROM objects").first["status"]
  end

  def test_dotenv_token_is_sent_only_to_swh_and_not_written_to_evidence
    File.write(File.join(@directory, ".env"), "SWH_API_TOKEN=dotenv-test-token\n")
    seed
    assert_not_requested(:get, /packages.ecosyste.ms/) { |request| request.headers.key?("Authorization") }
    fake_git("#{SHA}\tHEAD\n") { assert_equal 0, cli("heads") }
    request = stub_request(:post, "#{SWH}/known/").with(headers: { "Authorization" => "Bearer dotenv-test-token" }).to_return(response({ SWHID => { known: true } }))
    assert_equal 0, cli("known")
    assert_requested request
    assert_equal "present", query("SELECT status FROM objects").first["status"]
    evidence = Dir[File.join(@directory, "cache/*.gz")].map { |path| Zlib::GzipReader.open(path, &:read) }.join
    assert_not_include evidence, "dotenv-test-token"
    assert_not_include query("SELECT evidence FROM objects").first["evidence"], "dotenv-test-token"
    assert_not_include @out.string + @err.string, "dotenv-test-token"
  end

  def test_existing_token_takes_precedence_over_dotenv
    File.write(File.join(@directory, ".env"), "SWH_API_TOKEN=dotenv-test-token\n")
    ENV["SWH_API_TOKEN"] = "environment-test-token"
    seed
    fake_git("#{SHA}\tHEAD\n") { assert_equal 0, cli("heads") }
    request = stub_request(:post, "#{SWH}/known/").with(headers: { "Authorization" => "Bearer environment-test-token" }).to_return(response({ SWHID => { known: true } }))
    assert_equal 0, cli("known")
    assert_requested request
  end

  def test_blank_dotenv_token_sends_no_authorization_header
    File.write(File.join(@directory, ".env"), "SWH_API_TOKEN=\n")
    seed
    fake_git("#{SHA}\tHEAD\n") { assert_equal 0, cli("heads") }
    stub_request(:post, "#{SWH}/known/").to_return(response({ SWHID => { known: false } }))
    assert_equal 0, cli("known")
    assert_not_requested(:post, "#{SWH}/known/") { |request| request.headers.key?("Authorization") }
  end

  def test_authenticated_requests_have_a_separate_persistent_cooldown
    seed
    fake_git("#{SHA}\tHEAD\n") { assert_equal 0, cli("heads") }
    anonymous = stub_request(:post, "#{SWH}/known/").with { |request| !request.headers.key?("Authorization") }.to_return(status: 429, headers: { "Retry-After" => "120" })
    assert_equal 75, cli("known")

    File.write(File.join(@directory, ".env"), "SWH_API_TOKEN=dotenv-test-token\n")
    authenticated = stub_request(:post, "#{SWH}/known/").with(headers: { "Authorization" => "Bearer dotenv-test-token" }).to_return(status: 429, headers: { "Retry-After" => "120" })
    assert_equal 75, cli("known")
    assert_equal 75, cli("known")
    assert_requested anonymous, times: 1
    assert_requested authenticated, times: 1
    assert_equal "pending", query("SELECT status FROM objects").first["status"]
    assert_not_include query("SELECT * FROM metadata").to_json, "dotenv-test-token"
  end

  def test_exhausted_visit_pages_remain_unknown
    seed
    stub_origins
    url = "#{SWH}/origin/#{URI.encode_www_form_component(REPO)}/visits/?per_page=100"
    3.times do |index|
      current = index.zero? ? url : "#{url}&last_visit=#{index}"
      following = "#{url}&last_visit=#{index + 1}"
      stub_request(:get, current).to_return(response([visit(REPO, status: "failed", snapshot: nil)], link: "<#{following}>; rel=\"next\""))
    end
    assert_equal 0, cli("origins")
    assert_equal "unknown", query("SELECT coverage FROM repositories").first["coverage"]
  end

  def test_all_aliases_missing_and_offline_replay
    seed
    stub_origins
    assert_equal 0, cli("origins")
    assert_equal "origin_not_found", query("SELECT coverage FROM repositories").first["coverage"]
    assert_equal 0, cli("origins", "--offline")
    assert_equal 0, cli("report", "--offline")
  end

  def test_origin_logs_show_global_progress_across_runs
    seed([package("one"), package("two", "https://github.com/Example/Other")])
    stub_origins
    @out.truncate(0)
    @out.rewind
    assert_equal 0, cli("origins", "--limit", "1")
    assert_match(/\[\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\] \[.+\] START .*selected=1 checked=0\/2/, @out.string)
    assert_include @out.string, "RESULT checked=1/2 (50.0%) run=1/1 origin_not_found"
    assert_match(/END batch finished checked=1\/2 .*origin_not_found=1 unknown=0 remaining=1/, @out.string)

    @out.truncate(0)
    @out.rewind
    assert_equal 0, cli("origins")
    assert_match(/START .*selected=1 checked=1\/2/, @out.string)
    assert_include @out.string, "RESULT checked=2/2 (100.0%) run=1/1"
    assert_match(/END batch finished checked=2\/2 .*origin_not_found=2 unknown=0 remaining=0/, @out.string)
  end

  def test_alias_limit_is_explained_in_logs_and_saved_evidence
    record = package("example")
    record["repo_metadata"] = { "previous_names" => %w[Example/Old1 Example/Old2 Example/Old3 Example/Old4] }
    seed([record])
    stub_origins
    assert_equal 0, cli("origins")
    data = JSON.parse(query("SELECT origin_data FROM repositories").first["origin_data"])
    reason = "alias limit: checked 8/#{data['candidates'].size} URLs"
    assert_include @out.string, reason
    assert_include data["incomplete_reasons"], reason
    assert_match(/END batch finished checked=1\/1 .*unknown=1 remaining=0/, @out.string)
    assert_equal 8, data["observations"].size
    assert_equal 0, cli("origins")
    row = query("SELECT coverage, origin_data FROM repositories").first
    resumed = JSON.parse(row["origin_data"])
    assert_equal "origin_not_found", row["coverage"]
    assert_equal resumed["candidates"].sort, resumed["observations"].map { |entry| entry["origin"] }.sort
    assert_equal data["observations"], resumed["observations"].first(8)
    assert_empty resumed["incomplete_reasons"]
  end

  def seed_origin_aliases
    record = package("example").merge("latest_release_number" => "1.0")
    record["repo_metadata"] = { "previous_names" => %w[Example/Old1 Example/Old2 Example/Old3 Example/Old4] }
    seed([record])
    stub_origins
    query("SELECT url FROM aliases ORDER BY CASE source WHEN 'package' THEN 0 ELSE 1 END, url").map { |row| row["url"] }
  end

  def test_missing_head_origins_resume_to_a_snapshot_beyond_the_alias_limit
    aliases = seed_origin_aliases
    fake_git("#{SHA}\tHEAD\n") { assert_equal 0, cli("heads") }
    stub_request(:post, "#{SWH}/known/").to_return(response({ SWHID => { known: false } }))
    assert_equal 0, cli("known")
    ninth = "#{SWH}/origin/#{URI.encode_www_form_component(aliases.fetch(8))}/visits/?per_page=100"
    stub_request(:get, ninth).to_return(response([visit(aliases.fetch(8))]))
    assert_equal 0, cli("origins", "--missing-heads")
    assert_equal "unknown", query("SELECT coverage FROM repositories").first["coverage"]
    assert_not_requested(:get, ninth)
    assert_equal 0, cli("origins", "--missing-heads")
    row = query("SELECT coverage, origin_data FROM repositories").first
    observations = JSON.parse(row["origin_data"]).fetch("observations")
    assert_equal "snapshot_found", row["coverage"]
    assert_equal 9, observations.size
    assert_equal "full", observations.last["status"]
    assert_requested(:get, ninth, times: 1)
    assert_equal 0, cli("report")
    assert_equal({ "snapshot_found" => 1 }, JSON.parse(File.read(File.join(@directory, "out/summary.json")))["missing_heads_repository_coverage"])
  end

  def test_origin_resumption_checks_new_aliases_before_retrying_unknowns
    aliases = seed_origin_aliases
    failed = "#{SWH}/origin/#{URI.encode_www_form_component(aliases.first)}/visits/?per_page=100"
    stub_request(:get, failed).to_return({ status: 503 }, { status: 503 }, response({ error: "not found" }, status: 404))
    stub_request(:get, "#{SWH}/origin/#{URI.encode_www_form_component(aliases.last)}/visits/?per_page=100").to_return(response([]))
    assert_equal 0, cli("origins")
    assert_equal 0, cli("origins")
    row = query("SELECT coverage, origin_data FROM repositories").first
    data = JSON.parse(row["origin_data"])
    assert_equal "unknown", row["coverage"]
    assert_equal aliases.sort, data["observations"].map { |entry| entry["origin"] }.sort
    assert_equal aliases.first, data["observations"].last["origin"]
    assert_equal "unknown", data["observations"].last["status"]
    assert_equal "no_snapshot", data["observations"].find { |entry| entry["origin"] == aliases.last }["status"]
    assert_not_include data["incomplete_reasons"].join, "alias limit"
    assert_equal 0, cli("origins")
    assert_equal "no_snapshot", query("SELECT coverage FROM repositories").first["coverage"]
    assert_requested(:get, failed, times: 3)
  end

  def test_origin_resumption_rotates_unknown_aliases
    aliases = seed_origin_aliases
    aliases.each do |origin|
      stub_request(:get, "#{SWH}/origin/#{URI.encode_www_form_component(origin)}/visits/?per_page=100").to_return(status: 503)
    end
    3.times { assert_equal 0, cli("origins") }
    assert_equal "unknown", query("SELECT coverage FROM repositories").first["coverage"]
    aliases.each do |origin|
      assert_requested(:get, "#{SWH}/origin/#{URI.encode_www_form_component(origin)}/visits/?per_page=100", at_least_times: 2)
    end
  end

  def test_origin_resumption_saves_alias_progress_before_rate_limit
    aliases = seed_origin_aliases
    limited = "#{SWH}/origin/#{URI.encode_www_form_component(aliases.fetch(3))}/visits/?per_page=100"
    stub_request(:get, limited).to_return(status: 429, headers: { "Retry-After" => "120" })
    assert_equal 75, cli("origins")
    row = query("SELECT coverage, origin_data FROM repositories").first
    assert_equal "unknown", row["coverage"]
    observations = JSON.parse(row["origin_data"]).fetch("observations")
    assert_equal aliases.first(3), observations.map { |entry| entry["origin"] }
    assert_equal 75, cli("origins")
    assert_requested(:get, limited, times: 1)
    assert_equal observations, JSON.parse(query("SELECT origin_data FROM repositories").first["origin_data"]).fetch("observations")
  end

  def test_release_gap_origins_resume_saved_aliases
    seed_origin_aliases
    fake_git("#{SHA}\trefs/tags/v1.0\n") { assert_equal 0, cli("tags") }
    stub_request(:post, "#{SWH}/known/").to_return(response({ SWHID => { known: false } }))
    assert_equal 0, cli("known")
    assert_equal 0, cli("origins", "--missing-releases")
    assert_equal "unknown", query("SELECT coverage FROM repositories").first["coverage"]
    assert_equal 0, cli("origins", "--missing-releases")
    assert_equal "origin_not_found", query("SELECT coverage FROM repositories").first["coverage"]
  end

  def test_origin_resumption_saves_alias_progress_before_interrupt
    aliases = seed_origin_aliases
    interrupted = "#{SWH}/origin/#{URI.encode_www_form_component(aliases.fetch(2))}/visits/?per_page=100"
    stub_request(:get, interrupted).to_raise(Interrupt).then.to_return(response([visit(aliases.fetch(2))]))
    assert_equal 130, cli("origins")
    observations = JSON.parse(query("SELECT origin_data FROM repositories").first["origin_data"]).fetch("observations")
    assert_equal aliases.first(2), observations.map { |entry| entry["origin"] }
    assert_equal 0, cli("origins")
    row = query("SELECT coverage, origin_data FROM repositories").first
    assert_equal "snapshot_found", row["coverage"]
    assert_equal observations, JSON.parse(row["origin_data"]).fetch("observations").first(2)
    assert_requested(:get, interrupted, times: 2)
  end

  def test_rate_limit_logs_pause_without_reporting_completion
    seed
    stub_origins
    stub_request(:get, "#{SWH}/origin/#{URI.encode_www_form_component(REPO)}/visits/?per_page=100").to_return(status: 429, headers: { "Retry-After" => "120" })
    assert_equal 75, cli("origins")
    assert_match(/PAUSED .*retry after .*current=https:\/\/github.com\/example\/library checked=0\/1/, @out.string)
    assert_not_include @out.string, "END batch finished"
    assert_match(/\[\d{4}-\d\d-\d\dT.*Z\] Paused:/, @err.string)
  end

  def test_invalid_json_does_not_create_a_negative_cache
    stub_request(:get, "#{PACKAGES}/registries?per_page=100&page=1").to_return(status: 200, body: "<html>challenge</html>", headers: { "Content-Type" => "text/html" })
    assert_equal 1, cli("collect")
    assert_include @err.string, "Expected JSON"
    assert_empty Dir.glob(File.join(@directory, "cache/*.gz"))
  end

  def test_pagination_cannot_leave_the_endpoint
    seed_response = response([{ name: "rubygems.org" }], link: '<https://another.example/api/v1/registries?page=2>; rel="next"')
    stub_request(:get, "#{PACKAGES}/registries?per_page=100&page=1").to_return(seed_response)
    assert_equal 1, cli("collect")
    assert_include @err.string, "Invalid pagination link"
    assert_not_requested(:get, /another.example/)
  end

  def test_disk_guard_stops_before_database_or_network_requests
    assert_equal 1, SwhCritical::CLI.run(["collect", "--data", @directory, "--min-free-gib", "1000000"], out: @out, err: @err, env_file: File.join(@directory, ".env"))
    assert_include @err.string, "Disk guard"
    assert_false File.exist?(File.join(@directory, "investigation.sqlite3"))
    assert_not_requested(:any, /https:/)
  end

  def test_archival_requests_are_rejected
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    assert_raise(SwhCritical::Error) { SwhCritical::Http.new(store).request(:post, "#{SWH}/origin/save/git/url/", body: {}) }
    assert_not_requested(:any, /https:/)
  ensure
    store&.close
  end
end
