require "bundler/setup"
require "test/unit"
require "webmock/test_unit"
require "tmpdir"
require "stringio"
require_relative "../lib/cli"

class RestoreTest < Test::Unit::TestCase
  SWH = SwhCritical::Http::SWH
  PACKAGE = "#{SwhCritical::Http::PACKAGES}/registries/npmjs.org/packages/recovery-example"

  def setup
    @directory = Dir.mktmpdir("swh-restore-test-")
    @out, @err = StringIO.new, StringIO.new
    @original_token = ENV.delete("SWH_API_TOKEN")
    WebMock.disable_net_connect!
  end

  def teardown
    @original_token.nil? ? ENV.delete("SWH_API_TOKEN") : ENV["SWH_API_TOKEN"] = @original_token
    FileUtils.remove_entry(@directory)
  end

  def cli(*args)
    SwhCritical::CLI.run(["restore", "--registry", "npmjs.org", "--package", "recovery-example", "--data", @directory,
      "--min-free-gib", "0", *args], out: @out, err: @err, env_file: File.join(@directory, ".env"))
  end

  def json(body)
    { status: 200, body: JSON.generate(body), headers: { "Content-Type" => "application/json" } }
  end

  def git_hash(type, bytes)
    value, error, status = Open3.capture3("git", "hash-object", "-t", type, "--stdin", stdin_data: bytes)
    assert status.success?, error
    value.strip
  end

  def directory(entries)
    raw = entries.sort_by { |entry| entry[:name] + (entry[:type] == "dir" ? "/" : "") }.map do |entry|
      "#{entry[:perms].to_s(8)} #{entry[:name]}\0".b + [entry[:target]].pack("H*")
    end.join.b
    id = git_hash("tree", raw)
    stub_request(:get, "#{SWH}/directory/#{id}/").to_return(json(entries))
    id
  end

  def fixture
    @bytes = "\x00\xff\n".b
    @blob = git_hash("blob", @bytes)
    @script = "#!/bin/sh\nprintf recovered\n"
    script_id = git_hash("blob", @script)
    link_id = git_hash("blob", "bin/run")
    { @blob => @bytes, script_id => @script, link_id => "bin/run" }.each do |id, bytes|
      stub_request(:get, "#{SWH}/content/sha1_git:#{id}/raw/")
        .with(headers: { "Accept" => "*/*" })
        .to_return(status: 200, body: bytes, headers: { "Content-Type" => "application/octet-stream" })
    end
    bin = directory([{ name: "run", type: "file", target: script_id, perms: 0o100755 }])
    @entries = [
      { name: "bin", type: "dir", target: bin, perms: 0o040000 },
      { name: "bin.c", type: "file", target: @blob, perms: 0o100644 },
      { name: "binary", type: "file", target: @blob, perms: 0o100644 },
      { name: "link", type: "file", target: link_id, perms: 0o120000 }
    ]
    @root = directory(@entries)
    snapshot, release = %w[b c].map { |char| char * 40 }
    stub_request(:get, PACKAGE).to_return(json({ name: "recovery-example", latest_release_number: "1.0", repository_url: "https://github.com/unavailable/source" }))
    stub_request(:get, "#{PACKAGE}/versions/1.0").to_return(json({ number: "1.0", purl: "pkg:npm/recovery-example@1.0", metadata: { gitHead: "e" * 40 } }))
    stub_request(:post, "#{SWH}/known/").with(body: JSON.generate(["swh:1:rev:#{'e' * 40}"]))
      .to_return(json({ "swh:1:rev:#{'e' * 40}" => { known: false } }))
    origin = "https://www.npmjs.com/package/recovery-example"
    stub_request(:get, "#{SWH}/origin/#{URI.encode_www_form_component(origin)}/visits/?per_page=100")
      .to_return(json([{ origin: origin, visit: 1, date: "2026-09-01T12:00:00Z", type: "npm", status: "full", snapshot: snapshot }]))
    stub_request(:get, "#{SWH}/snapshot/#{snapshot}/?branches_count=1000")
      .to_return(json({ branches: { "releases/1.0" => { target_type: "release", target: release } }, next_branch: nil }))
    stub_request(:get, "#{SWH}/release/#{release}/").to_return(json({ target_type: "directory", target: @root }))
  end

  def test_restores_from_metadata_without_repository_access_and_replays_offline
    fixture
    bin = File.join(@directory, "no-git")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "git"), "#!/bin/sh\nexit 99\n")
    File.chmod(0o755, File.join(bin, "git"))
    old_path, ENV["PATH"] = ENV["PATH"], "#{bin}:#{ENV['PATH']}"
    assert_equal 0, cli, @err.string
    restored = File.join(@directory, "restored")
    assert_equal @bytes, File.binread(File.join(restored, "binary"))
    assert_equal 0o755, File.stat(File.join(restored, "bin/run")).mode & 0o777
    assert_equal "bin/run", File.readlink(File.join(restored, "link"))
    report = JSON.parse(File.read(File.join(@directory, "out/recovery.json")))
    assert_equal "swh:1:dir:#{@root}", report["directory_swhid"]
    assert_equal 4, report["file_count"]
    assert_equal false, report.dig("package_git_revision", "result", "known")
    assert_equal "complete", report["status"]
    assert_equal 0, cli("--offline"), @err.string
    assert_requested(:get, "#{SWH}/content/sha1_git:#{@blob}/raw/", times: 1)
    assert_empty Dir.glob(File.join(@directory, "restore-*"))
  ensure
    ENV["PATH"] = old_path if old_path
  end

  def test_rejects_corrupt_file_bytes_without_publishing_source
    fixture
    stub_request(:get, "#{SWH}/content/sha1_git:#{@blob}/raw/")
      .to_return(status: 200, body: "corrupt", headers: { "Content-Type" => "application/octet-stream" })
    assert_equal 1, cli
    assert_include @err.string, "Downloaded content hash mismatch"
    assert_false File.exist?(File.join(@directory, "restored"))
    assert_empty Dir.glob(File.join(@directory, "restore-*"))
  end

  def chained_symlink_fixture(target)
    fixture
    nested_link = git_hash("blob", "../safe")
    outer_link = git_hash("blob", target)
    { nested_link => "../safe", outer_link => target }.each do |id, bytes|
      stub_request(:get, "#{SWH}/content/sha1_git:#{id}/raw/").to_return(
        status: 200, body: bytes, headers: { "Content-Type" => "application/octet-stream" })
    end
    safe = directory([{ name: "run", type: "file", target: @blob, perms: 0o100644 }])
    nested = directory([{ name: "link", type: "file", target: nested_link, perms: 0o120000 }])
    root = directory([
      { name: "escape", type: "file", target: outer_link, perms: 0o120000 },
      { name: "nested", type: "dir", target: nested, perms: 0o040000 },
      { name: "safe", type: "dir", target: safe, perms: 0o040000 }
    ])
    stub_request(:get, "#{SWH}/release/#{'c' * 40}/").to_return(json({ target_type: "directory", target: root }))
  end

  def test_rejects_chained_symlinks_that_escape_restored_source
    chained_symlink_fixture("nested/link/../../outside")
    outside = File.join(@directory, "outside")
    File.write(outside, "outside restored tree")
    assert_equal 1, cli, @err.string
    assert_include @err.string, "Symlink escapes restored source"
    assert_false File.exist?(File.join(@directory, "restored"))
    assert_equal "outside restored tree", File.read(outside)
    assert_equal "incomplete", JSON.parse(File.read(File.join(@directory, "out/recovery.json")))["status"]
    assert_empty Dir.glob(File.join(@directory, "restore-*"))
  end

  def test_restores_safe_forward_symlink_chains_and_replays_offline
    chained_symlink_fixture("nested/link/run")
    assert_equal 0, cli, @err.string
    assert_equal @bytes, File.binread(File.join(@directory, "restored/escape"))
    assert_equal 0, cli("--offline"), @err.string
  end

  def test_restores_safe_dangling_symlink_chains
    chained_symlink_fixture("nested/link/missing")
    assert_equal 0, cli, @err.string
    assert_true File.symlink?(File.join(@directory, "restored/escape"))
    assert_false File.exist?(File.join(@directory, "restored/escape"))
  end

  def test_rejects_symlink_cycles_without_publishing_source
    chained_symlink_fixture("escape")
    assert_equal 1, cli, @err.string
    assert_include @err.string, "Symlink resolution limit reached"
    assert_false File.exist?(File.join(@directory, "restored"))
    assert_empty Dir.glob(File.join(@directory, "restore-*"))
  end

  def test_rejects_archived_path_traversal
    fixture
    stub_request(:get, "#{SWH}/directory/#{@root}/").to_return(json([@entries[1].merge(name: "../escape")]))
    assert_equal 1, cli
    assert_include @err.string, "Unsafe or duplicate archived filename"
    assert_false File.exist?(File.join(@directory, "escape"))
    assert_false File.exist?(File.join(@directory, "restored"))
  end

  def test_rejects_changed_directory_structure_and_preserves_existing_output
    fixture
    assert_equal 0, cli, @err.string
    File.binwrite(File.join(@directory, "restored/binary"), "local change")
    assert_equal 1, cli("--offline")
    assert_include @err.string, "Existing restored directory differs"
    assert_equal "local change", File.binread(File.join(@directory, "restored/binary"))
  end
end
