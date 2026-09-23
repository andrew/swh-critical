require_relative "clone_checks"
require_relative "known"

module SwhCritical
  class ContentCoverage
    def initialize(store, http, output, swhid: "swhid")
      @store, @http, @output, @swhid = store, http, output, swhid
      @git = CloneChecks.new(store, output, swhid: swhid)
    end

    def run(urls, offline: false)
      evidence = urls.map do |url|
        relative = "content-evidence/#{Digest::SHA256.hexdigest(url)}.json.gz"
        path = File.join(@store.path, relative)
        unless File.exist?(path)
          raise Error, "Content evidence not cached: #{url}" if offline
          clone = @store.get("clone_check:#{url}")
          raise Error, "No completed clone baseline: #{url}" unless clone && clone["status"] == "complete"

          @git.log("START contents #{url}")
          data = collect(clone)
          @store.guard.check!
          FileUtils.mkdir_p(File.dirname(path))
          Zlib::GzipWriter.open(path) { |gzip| gzip.write(JSON.generate(data)) }
        end
        JSON.parse(Zlib::GzipReader.open(path, &:read)).merge("evidence_file" => relative)
      end
      ids = evidence.flat_map { |row| row.fetch("directories") + row.fetch("contents") }.uniq
      @store.guard.check!
      @store.db.transaction do
        ids.each { |id| @store.db.execute("INSERT OR IGNORE INTO objects(swhid) VALUES (?)", [id]) }
      end
      statuses = @store.db.execute("SELECT swhid, status FROM objects").to_h { |row| row.values_at("swhid", "status") }
      pending = ids.select { |id| %w[pending unknown].include?(statuses.fetch(id)) }
      begin
        Known.new(@store, @http, @output).check(pending)
      ensure
        report(evidence)
      end
    end

    def collect(clone)
      @git.with_repository(clone.fetch("url")) do |repository|
        head = clone.fetch("revision_swhid").delete_prefix("swh:1:rev:")
        raise Error, "Clone is shallow" unless @git.command("git", "-C", repository, "rev-parse", "--is-shallow-repository").strip == "false"
        raise Error, "Unsupported object format" unless @git.command("git", "-C", repository, "rev-parse", "--show-object-format").strip == "sha1"

        reachable = @git.command("git", "-C", repository, "rev-list", "--objects", "--no-object-names", head).lines.map(&:strip).to_h { |sha| [sha, true] }
        objects = @git.command("git", "-C", repository, "cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype)")
        directories, contents = [], []
        objects.each_line do |line|
          sha, type = line.split
          raise Error, "Invalid Git object identifier" unless sha.match?(/\A[0-9a-f]{40}\z/)
          next unless reachable.key?(sha)

          directories << "swh:1:dir:#{sha}" if type == "tree"
          contents << "swh:1:cnt:#{sha}" if type == "blob"
        end
        trees = @git.command("git", "-C", repository, "log", head, "--format=%H %T").lines.to_h { |line| line.split }
        files = @git.command("git", "-C", repository, "ls-tree", "-r", "-z", "--full-tree", head).split("\0").map do |record|
          attributes, path = record.split("\t", 2)
          mode, type, sha = attributes.split
          { "path" => path, "mode" => mode, "type" => type, "object" => sha, "swhid" => type == "blob" ? "swh:1:cnt:#{sha}" : nil }
        end
        { "url" => clone.fetch("url"), "observed_at" => Time.now.utc.iso8601, "scope" => "saved_head_ancestry",
          "saved_head" => head, "head_tree" => "swh:1:dir:#{trees.fetch(head)}", "revision_trees" => trees,
          "directories" => directories.sort, "contents" => contents.sort, "head_files" => files,
          "snapshot_swhid" => @git.identifier("snapshot", repository, "snp"),
          "revision_swhid" => @git.identifier("revision", repository, "rev"), "tool_version" => @git.command(@swhid, "version").strip }
      end
    end

    def report(evidence)
      @store.guard.check!
      statuses = @store.db.execute("SELECT swhid, status FROM objects").to_h { |row| row.values_at("swhid", "status") }
      rows = evidence.map do |row|
        files = row.fetch("head_files").map { |file| file.merge("status" => file["swhid"] ? statuses.fetch(file["swhid"]) : "not_checked") }
        row.slice("url", "observed_at", "scope", "saved_head", "head_tree", "evidence_file").merge(
          "head_tree_status" => statuses.fetch(row.fetch("head_tree")),
          "directories" => row.fetch("directories").map { |id| statuses.fetch(id) }.tally,
          "contents" => row.fetch("contents").map { |id| statuses.fetch(id) }.tally,
          "head_files" => files, "head_file_statuses" => files.map { |file| file["status"] }.tally,
          "present_root_trees" => row.fetch("revision_trees").select { |_, tree| statuses["swh:1:dir:#{tree}"] == "present" })
      end
      directory = File.join(@store.path, "out")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "content_coverage.json"), JSON.pretty_generate(rows) + "\n")
      rows.each { |row| @git.log("RESULT contents #{row['url']} head_tree=#{row['head_tree_status']} files=#{JSON.generate(row['head_file_statuses'])}") }
    end
  end
end
