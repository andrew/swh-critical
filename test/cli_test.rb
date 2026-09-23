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
