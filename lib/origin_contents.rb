require_relative "swh_objects"
require_relative "origins"
require "set"

module SwhCritical
  class OriginContents
    def initialize(store, http, output)
      @store, @http, @output = store, http, output
      @objects = SwhObjects.new(http)
    end

    def run(urls)
      urls.each do |url|
        next if @store.get("origin_contents:#{url}")&.fetch("status", nil) == "complete"

        evidence_file = "content-evidence/#{Digest::SHA256.hexdigest(url)}.json.gz"
        local = JSON.parse(Zlib::GzipReader.open(File.join(@store.path, evidence_file), &:read))
        packages = @store.db.execute(<<~SQL, [url])
          SELECT p.registry, p.name, v.version FROM packages p
          LEFT JOIN package_releases v ON p.registry = v.registry AND p.purl = v.purl
          WHERE p.repository_url = ?
        SQL
        data = { "url" => url, "checked_at" => Time.now.utc.iso8601, "evidence_file" => evidence_file, "origins" => [] }
        begin
          packages.each do |package|
            origin = package_origin(package)
            next unless origin

            visit = Origins.new(@store, @http, @output).lookup(origin)
            entry = { "url" => origin, "version" => package["version"], "visit_check" => visit, "targets" => [] }
            data["origins"] << entry
            next unless %w[full partial].include?(visit["status"])

            snapshot = @objects.snapshot(visit.fetch("visit").fetch("snapshot"))
            branches = snapshot.fetch("branches")
            head = @objects.resolve(branches, "HEAD")
            targets = branches.select { |_, branch| branch && %w[release revision directory].include?(branch["target_type"]) }.to_a
            version = package["version"]
            targets.sort_by! { |name, branch| [version && [version, "v#{version}"].include?(name.split("/").last) ? 0 : 1, branch == head ? 0 : 1, name] }
            targets.uniq! { |_, branch| branch }
            entry.merge!("snapshot_complete" => snapshot["complete"], "target_count" => targets.size, "targets_limited" => targets.size > 3)
            targets.first(3).each do |name, branch|
              target = { "branch" => name, "target" => branch }
              directory, chain = directory_target(branch)
              target["object_chain"] = chain
              if directory
                tree = walk(directory)
                files = tree.fetch("files")
                identifiers = files.map { |file| file["target"] }.to_set
                head_matches = local.fetch("head_files").select { |file| file["type"] == "blob" && identifiers.include?(file["object"]) }
                target.merge!("directory" => directory, "walk_complete" => tree["complete"], "directories_checked" => tree["directories"].size,
                  "file_count" => files.size, "head_files_matched" => head_matches.map { |file| file["path"] },
                  "historical_contents_matched" => (identifiers & local.fetch("contents").map { |id| id.delete_prefix("swh:1:cnt:") }.to_set).size,
                  "matching_git_roots" => local.fetch("revision_trees").select { |_, id| tree["directories"].include?(id) },
                  "files" => files)
              end
              entry["targets"] << target
              @output.puts "[#{Time.now.utc.iso8601}] RESULT origin-contents #{origin} #{name} head_files=#{target.fetch('head_files_matched', []).size}"
              @output.flush
            end
          end
          data["status"] = data["origins"].any? { |origin| origin.dig("visit_check", "status") == "unknown" } ? "incomplete" : "complete"
        ensure
          @store.set("origin_contents:#{url}", data)
          report
        end
      end
      report
    end

    def package_origin(package)
      name = package.fetch("name")
      case package["registry"]
      when "cran.r-project.org" then "https://cran.r-project.org/package=#{name}"
      when "hackage.haskell.org" then "https://hackage.haskell.org/package/#{name}"
      when "npmjs.org" then "https://www.npmjs.com/package/#{name}"
      end
    end

    def directory_target(branch)
      type, id = branch.values_at("target_type", "target")
      chain = []
      5.times do
        chain << { "type" => type, "id" => id }
        return [id, chain] if type == "directory"
        return [nil, chain] unless %w[release revision].include?(type)

        object = @objects.get(type, id)
        if type == "revision"
          type, id = "directory", object.fetch("directory")
        else
          type, id = object.values_at("target_type", "target")
        end
      end
      [nil, chain]
    end

    def walk(root)
      queue, directories, files = [[root, ""]], [], []
      until queue.empty? || directories.size >= 100
        id, prefix = queue.shift
        directories << id
        entries = @objects.get("directory", id)
        raise Error, "Invalid directory response" unless entries.is_a?(Array)

        entries.each do |entry|
          path = prefix + entry.fetch("name")
          if entry["type"] == "dir"
            queue << [entry.fetch("target"), path + "/"]
          elsif entry["type"] == "file"
            files << entry.slice("target", "perms", "status").merge("path" => path)
          end
        end
      end
      { "directories" => directories, "files" => files, "complete" => queue.empty? }
    end

    def report
      @store.guard.check!
      rows = @store.db.execute("SELECT value FROM metadata WHERE key LIKE 'origin_contents:%' ORDER BY key").map { |row| JSON.parse(row["value"]) }
      directory = File.join(@store.path, "out")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "origin_contents.json"), JSON.pretty_generate(rows) + "\n")
    end
  end
end
