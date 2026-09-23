require_relative "swh_objects"
require_relative "clone_checks"

module SwhCritical
  class PackageContents
    def initialize(store, http, output, swhid: "swhid")
      @store, @output = store, output
      @objects = SwhObjects.new(http)
      @git = CloneChecks.new(store, output, swhid: swhid)
    end

    def run(limit: 100, offline: false)
      statuses = @store.db.execute("SELECT swhid, status FROM objects").to_h { |row| row.values_at("swhid", "status") }
      clones = @store.db.execute("SELECT value FROM metadata WHERE key LIKE 'clone_check:%' ORDER BY key").map { |row| JSON.parse(row["value"]) }
      processed = 0
      clones.each do |clone|
        url = clone.fetch("url")
        next unless clone["status"] == "complete"
        next if @store.get("package_contents:#{url}")&.fetch("status", nil) == "complete"

        origins = @store.get("origin_search:#{url}")&.fetch("matches", []) || []
        origins = origins.select { |entry| entry["relation"] == "package_registry_reference" && %w[full partial].include?(entry.dig("visit_check", "status")) }
        next if origins.empty?

        evidence = JSON.parse(Zlib::GzipReader.open(File.join(@store.path, clone.fetch("evidence_file")), &:read))
        revisions = evidence.fetch("revisions").lines.map(&:strip)
        next unless revisions.all? { |sha| statuses["swh:1:rev:#{sha}"] == "missing" }
        break if processed >= limit

        data = { "url" => url, "checked_at" => Time.now.utc.iso8601, "origins" => [] }
        begin
          path = File.join(@store.path, "tree-evidence", "#{Digest::SHA256.hexdigest(url)}.json.gz")
          if File.exist?(path)
            trees = JSON.parse(Zlib::GzipReader.open(path, &:read))
          else
            raise Error, "Tree evidence not cached: #{url}" if offline

            trees = collect(clone, revisions)
            @store.guard.check!
            FileUtils.mkdir_p(File.dirname(path))
            Zlib::GzipWriter.open(path) { |gzip| gzip.write(JSON.generate(trees)) }
          end
          data["saved_head"] = trees.fetch("head")
          data["saved_head_tree"] = trees.fetch("by_revision").fetch(data["saved_head"])
          origins.each do |origin|
            visit = origin.fetch("visit_check").fetch("visit")
            snapshot = @objects.snapshot(visit.fetch("snapshot"))
            branches = snapshot.fetch("branches")
            head = @objects.resolve(branches, "HEAD")
            releases = branches.select { |_, branch| branch && branch["target_type"] == "release" }.to_a
            releases.sort_by! { |_, branch| branch == head ? 0 : 1 }
            result = { "url" => origin.fetch("url"), "visit" => visit, "snapshot_complete" => snapshot["complete"],
              "release_count" => releases.size, "releases_limited" => releases.size > 50, "releases" => [] }
            data["origins"] << result
            releases.first(50).each do |name, branch|
              release = @objects.get("release", branch.fetch("target"))
              entry = { "branch" => name, "release_swhid" => "swh:1:rel:#{branch['target']}", "synthetic" => release["synthetic"], "target_type" => release["target_type"] }
              if release["target_type"] == "directory"
                directories = directory_chain(release.fetch("target"), trees.fetch("by_revision").values)
                matches = trees.fetch("by_revision").select { |_, tree| directories.include?(tree) }
                entry.merge!("directory_chain" => directories, "matching_git_revisions" => matches.keys,
                  "saved_head_tree_matches" => directories.include?(data["saved_head_tree"]))
              end
              result["releases"] << entry
            end
          end
          data["status"] = "complete"
        ensure
          @store.set("package_contents:#{url}", data)
          report
        end
        processed += 1
        @git.log("RESULT package-contents #{url} matching_releases=#{data['origins'].sum { |o| o['releases'].count { |r| r.fetch('matching_git_revisions', []).any? } }}")
      end
      report
    end

    def collect(clone, revisions)
      @git.with_repository(clone.fetch("url")) do |repository|
        head = clone.fetch("revision_swhid").delete_prefix("swh:1:rev:")
        raw = @git.command("git", "-C", repository, "log", "--all", head, "--format=%H %T")
        trees = raw.lines.to_h { |line| line.split }
        raise Error, "Fresh clone lacks saved commits" unless revisions.all? { |sha| trees.key?(sha) }

        { "observed_at" => Time.now.utc.iso8601, "head" => head, "by_revision" => trees.slice(*revisions),
          "snapshot_swhid" => @git.identifier("snapshot", repository, "snp"), "revision_swhid" => @git.identifier("revision", repository, "rev") }
      end
    end

    def directory_chain(id, trees)
      directories = []
      6.times do
        directories << id
        break if trees.include?(id)

        entries = @objects.get("directory", id)
        raise Error, "Invalid directory response" unless entries.is_a?(Array)
        break unless entries.size == 1 && entries.first["type"] == "dir"

        id = entries.first.fetch("target")
      end
      directories
    end

    def report
      @store.guard.check!
      rows = @store.db.execute("SELECT value FROM metadata WHERE key LIKE 'package_contents:%' ORDER BY key").map { |row| JSON.parse(row["value"]) }
      directory = File.join(@store.path, "out")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "package_contents.json"), JSON.pretty_generate(rows) + "\n")
    end
  end
end
