require "bundler/setup"
require "test/unit"
require "webmock/test_unit"
require "tmpdir"
require "stringio"
require_relative "../lib/cli"

class ExtrinsicMetadataTest < Test::Unit::TestCase
  SWH = SwhCritical::Http::SWH
  TARGET = "swh:1:dir:#{'a' * 40}"
  OTHER = "swh:1:rel:#{'b' * 40}"
  AUTHORITY = { "type" => "forge", "url" => "https://www.npmjs.com/" }

  def setup
    @directory = Dir.mktmpdir("swh-metadata-test-")
    @targets = File.join(@directory, "targets.txt")
    File.write(@targets, "#{TARGET}\n")
    @out, @err = StringIO.new, StringIO.new
    @token = ENV.delete("SWH_API_TOKEN")
    WebMock.disable_net_connect!
  end

  def teardown
    @token.nil? ? ENV.delete("SWH_API_TOKEN") : ENV["SWH_API_TOKEN"] = @token
    FileUtils.remove_entry(@directory)
  end

  def cli(*args)
    SwhCritical::CLI.run(["extrinsic-metadata", "--data", @directory, "--targets", @targets,
      "--min-free-gib", "0", *args], out: @out, err: @err, env_file: File.join(@directory, ".env"))
  end

  def response(body, status: 200, link: nil)
    { status: status, body: JSON.generate(body), headers: { "Content-Type" => "application/json", "Link" => link }.compact }
  end

  def authorities_url(target = TARGET)
    "#{SWH}/raw-extrinsic-metadata/swhid/#{target}/authorities/"
  end

  def list_url
    "#{SWH}/raw-extrinsic-metadata/swhid/#{TARGET}/?#{URI.encode_www_form(authority: 'forge https://www.npmjs.com/', limit: 10)}"
  end

  def record(id = "c" * 40)
    { "target" => TARGET, "authority" => AUTHORITY, "discovery_date" => "2026-09-01T12:00:00Z",
      "fetcher" => { "name" => "swh.loader.package.npm.loader.NpmLoader", "version" => "test" },
      "format" => "replicate-npm-package-json", "origin" => "https://www.npmjs.com/package/example",
      "metadata_url" => "#{SWH}/raw-extrinsic-metadata/get/#{id}/?filename=metadata" }
  end

  def fixture
    stub_request(:get, authorities_url).to_return(response([AUTHORITY]))
    stub_request(:get, list_url).to_return(response([record]))
    stub_request(:get, record["metadata_url"]).to_return(status: 200,
      body: '{"name":"example","version":"1.2.3","repository":{"url":"https://github.com/example/library"}}',
      headers: { "Content-Type" => "application/octet-stream" })
  end

  def report
    JSON.parse(File.read(File.join(@directory, "out/extrinsic_metadata.json"))).fetch("targets")
  end

  def test_cli_reads_authorities_paginated_records_and_payloads_and_replays_offline
    fixture
    ENV["SWH_API_TOKEN"] = "metadata-test-token"
    next_url = list_url + "&page_token=next"
    second = record("d" * 40).merge("format" => "example-xml")
    stub_request(:get, list_url).to_return(response([record], link: "<#{next_url}>; rel=\"next\""))
    stub_request(:get, next_url).to_return(response([second]))
    stub_request(:get, second["metadata_url"]).with(headers: { "Accept" => "*/*", "Authorization" => "Bearer metadata-test-token" })
      .to_return(status: 200, body: "<metadata/>\n", headers: { "Content-Type" => "application/octet-stream" })
    assert_equal 0, cli, @err.string
    result = report.first
    authority = result.fetch("authorities").first
    assert_equal "complete", result["status"]
    assert_equal 1, result["authorities_found"]
    assert_equal true, authority["complete"]
    assert_equal 2, authority["pages"].size
    assert_equal "example", authority.dig("records", 0, "payload", "json", "name")
    assert_equal "1.2.3", authority.dig("records", 0, "payload", "json", "version")
    assert_equal "base64", authority.dig("records", 1, "payload", "encoding")
    assert_equal Digest::SHA256.hexdigest("<metadata/>\n"), authority.dig("records", 1, "payload", "sha256")
    assert_equal "2026-09-01T12:00:00Z", authority.dig("records", 0, "discovery_date")
    raw = authority.dig("records", 1, "payload", "evidence")
    cached = JSON.parse(Zlib::GzipReader.open(File.join(@directory, "cache", raw["cache_file"]), &:read))
    assert_equal "<metadata/>\n", cached.fetch("body").unpack1("m0")
    assert_not_nil raw["fetched_at"]
    WebMock.reset!
    assert_equal 0, cli("--offline"), @err.string
    assert_equal result, report.first
    assert_not_requested(:any, /https:/)
  end

  def test_empty_authorities_are_distinct_from_404_and_limit_preserves_unchecked_targets
    File.write(@targets, "#{TARGET}\n#{OTHER}\n")
    stub_request(:get, authorities_url).to_return(response([]))
    stub_request(:get, authorities_url(OTHER)).to_return(response({ error: "not found" }, status: 404))
    assert_equal 0, cli("--limit", "1")
    assert_equal %w[complete unchecked], report.map { |row| row["status"] }
    assert_equal 0, report.first["authorities_found"]
    assert_equal 0, cli
    assert_equal %w[complete incomplete], report.map { |row| row["status"] }
    assert_include report.last["error"], "HTTP 404"
    assert_equal 404, report.last.dig("authorities_evidence", "status")
    assert_requested(:get, authorities_url, times: 1)
  end

  def test_missing_payload_retries_without_repeating_cached_lists
    fixture
    stub_request(:get, record["metadata_url"]).to_return(status: 503).then.to_return(
      status: 200, body: '{"name":"example"}', headers: { "Content-Type" => "application/octet-stream" })
    assert_equal 0, cli
    assert_equal "incomplete", report.first["status"]
    assert_include report.first.dig("authorities", 0, "error"), "HTTP 503"
    assert_nil report.first.dig("authorities", 0, "records", 0, "payload")
    assert_equal 0, cli
    assert_equal "complete", report.first["status"]
    assert_requested(:get, authorities_url, times: 1)
    assert_requested(:get, list_url, times: 1)
    assert_requested(:get, record["metadata_url"], times: 2)
  end

  def test_rate_limit_saves_partial_evidence_and_resumes_after_cooldown
    fixture
    stub_request(:get, record["metadata_url"]).to_return(status: 429, headers: { "Retry-After" => "60" }).then.to_return(
      status: 200, body: '{}', headers: { "Content-Type" => "application/octet-stream" })
    assert_equal 75, cli
    assert_equal "incomplete", report.first["status"]
    assert_equal 1, report.first.dig("authorities", 0, "records").size
    assert_include report.first["error"], "retry after"
    assert_equal 75, cli
    assert_requested(:get, record["metadata_url"], times: 1)
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    store.set("cooldown:archive.softwareheritage.org", "2000-01-01T00:00:00Z")
    store.close
    assert_equal 0, cli
    assert_equal "complete", report.first["status"]
    assert_requested(:get, authorities_url, times: 1)
    assert_requested(:get, list_url, times: 1)
  end

  def test_page_limit_remains_incomplete
    stub_request(:get, authorities_url).to_return(response([AUTHORITY]))
    pages = [list_url, list_url + "&page_token=1", list_url + "&page_token=2", list_url + "&page_token=3"]
    pages.first(3).each_with_index do |url, index|
      stub_request(:get, url).to_return(response([], link: "<#{pages[index + 1]}>; rel=\"next\""))
    end
    assert_equal 0, cli
    assert_equal "incomplete", report.first["status"]
    assert_equal "Metadata page limit reached", report.first.dig("authorities", 0, "error")
    assert_equal pages.last, report.first.dig("authorities", 0, "next_url")
    assert_not_requested(:get, pages.last)
  end

  def test_rejects_pagination_that_changes_authority
    stub_request(:get, authorities_url).to_return(response([AUTHORITY]))
    other = "#{SWH}/raw-extrinsic-metadata/swhid/#{TARGET}/?authority=forge+https%3A%2F%2Fother.example%2F&page_token=1"
    stub_request(:get, list_url).to_return(response([], link: "<#{other}>; rel=\"next\""))
    assert_equal 0, cli
    assert_equal "incomplete", report.first["status"]
    assert_equal "Metadata pagination changed authority", report.first.dig("authorities", 0, "error")
    assert_not_requested(:get, other)
  end

  def test_rejects_external_payload_links
    fixture
    stub_request(:get, list_url).to_return(response([record.merge("metadata_url" => "https://other.example/metadata")]))
    assert_equal 0, cli
    assert_equal "incomplete", report.first["status"]
    assert_equal "Invalid metadata payload URL", report.first.dig("authorities", 0, "error")
    assert_not_requested(:any, /other.example/)
    assert_not_requested(:post, /https:/)
  end

  def test_rejects_records_for_another_target
    fixture
    stub_request(:get, list_url).to_return(response([record.merge("target" => OTHER)]))
    assert_equal 0, cli
    assert_equal "incomplete", report.first["status"]
    assert_equal "Invalid metadata record", report.first.dig("authorities", 0, "error")
    assert_not_requested(:get, record["metadata_url"])
  end

  def test_malformed_payload_url_is_reported_as_incomplete
    fixture
    stub_request(:get, list_url).to_return(response([record.merge("metadata_url" => "https://archive.softwareheritage.org/has space")]))
    assert_equal 0, cli
    assert_equal "incomplete", report.first["status"]
    assert_not_empty report.first.dig("authorities", 0, "error")
    assert_not_requested(:get, record["metadata_url"])
  end

  def test_offline_cache_miss_does_not_become_an_empty_authority_result
    assert_equal 0, cli("--offline")
    assert_equal "incomplete", report.first["status"]
    assert_include report.first["error"], "Not cached:"
    assert_nil report.first["authorities_found"]
    assert_not_requested(:any, /https:/)
  end

  def test_authority_limit_is_explicit
    authorities = 11.times.map { |index| { "type" => "registry", "url" => "https://registry.example/#{index}" } }
    stub_request(:get, authorities_url).to_return(response(authorities))
    authorities.first(10).each do |authority|
      query = URI.encode_www_form(authority: "registry #{authority['url']}", limit: 10)
      stub_request(:get, "#{SWH}/raw-extrinsic-metadata/swhid/#{TARGET}/?#{query}").to_return(response([]))
    end
    assert_equal 0, cli
    assert_equal "incomplete", report.first["status"]
    assert_equal "Authority limit reached", report.first["error"]
    assert_equal 11, report.first["authorities_found"]
    assert_equal 10, report.first["authorities"].size
  end

  def test_rejects_invalid_targets_before_any_requests
    File.write(@targets, "#{TARGET}\nswh:1:ori:#{'d' * 40}\n")
    assert_equal 1, cli("--limit", "1")
    assert_include @err.string, "Expected core SWHIDs"
    assert_not_requested(:any, /https:/)
  end

  def test_allowlist_rejects_metadata_writes_and_unrelated_raw_paths
    store = SwhCritical::Store.new(@directory, minimum_bytes: 0)
    http = SwhCritical::Http.new(store)
    assert_raise(SwhCritical::Error) { http.request(:post, authorities_url, body: {}) }
    assert_raise(SwhCritical::Error) { http.request(:get, authorities_url, raw: true) }
    assert_raise(SwhCritical::Error) { http.request(:get, "#{SWH}/raw-extrinsic-metadata/save/") }
    assert_not_requested(:any, /https:/)
  ensure
    store&.close
  end
end
