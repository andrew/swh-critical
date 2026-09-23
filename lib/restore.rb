require_relative "origin_contents"
require "tmpdir"

module SwhCritical
  class Restore
    def initialize(store, http, output)
      @store, @http, @output = store, http, output
      @objects = SwhObjects.new(http)
      @files, @bytes, @directories = [], 0, 0
    end

    def run(registry:, name:, version: nil)
      @manifest = { "started_at" => Time.now.utc.iso8601, "registry" => registry, "package" => name, "status" => "incomplete" }
      package_url = "#{Http::PACKAGES}/registries/#{URI.encode_www_form_component(registry)}/packages/#{URI.encode_www_form_component(name)}"
      package = metadata(package_url)
      raise Error, "Package name differs from requested name" unless package["name"] == name
      version ||= package["latest_release_number"]
      raise Error, "Package has no selected version" unless version.is_a?(String) && !version.empty?

      release = metadata("#{package_url}/versions/#{URI.encode_www_form_component(version)}")
      raise Error, "Package version differs from requested version" unless release["number"] == version
      @manifest.merge!("version" => version, "purl" => release["purl"], "repository_url" => package["repository_url"],
        "download_url" => release["download_url"], "package_metadata" => package, "version_metadata" => release)
      @output.puts "PACKAGE #{release['purl']} repository=#{package['repository_url']}"
      revision = release.dig("metadata", "gitHead")
      if revision.is_a?(String) && revision.match?(/\A[0-9a-f]{40}\z/)
        id = "swh:1:rev:#{revision}"
        result = @http.request(:post, "#{Http::SWH}/known/", body: [id])
        @manifest["package_git_revision"] = { "swhid" => id, "result" => result.dig("body", id), "evidence" => result.slice("url", "fetched_at", "cache_file") }
        @output.puts "PACKAGE REVISION #{id} known=#{result.dig('body', id, 'known').inspect}"
      end
      resolver = OriginContents.new(@store, @http, @output)
      origin = resolver.package_origin("registry" => registry, "name" => name)
      raise Error, "No package-origin mapping for #{registry}" unless origin
      visit = Origins.new(@store, @http, @output).lookup(origin)
      @manifest.merge!("origin" => origin, "visit_check" => visit)
      raise Error, "No package snapshot found: #{visit['status']}" unless %w[full partial].include?(visit["status"])

      snapshot = @objects.snapshot(visit.fetch("visit").fetch("snapshot"))
      names = [version, "v#{version}", "releases/#{version}", "releases/v#{version}", "refs/tags/#{version}", "refs/tags/v#{version}"]
      matches = names.filter_map { |branch| [branch, @objects.resolve(snapshot.fetch("branches"), branch)] if snapshot["branches"].key?(branch) }
      raise Error, "Version not uniquely matched in snapshot" unless matches.size == 1 && matches.first.last
      branch, target = matches.first
      directory, chain = resolver.directory_target(target)
      raise Error, "Release has no directory target" unless directory
      @manifest.merge!("snapshot_swhid" => "swh:1:snp:#{snapshot['id']}", "snapshot_complete" => snapshot["complete"],
        "branch" => branch, "object_chain" => chain, "directory_swhid" => "swh:1:dir:#{directory}")
      @output.puts "ARCHIVE #{origin} #{branch} swh:1:dir:#{directory}"
      @output.flush
      destination = File.join(@store.path, "restored")
      Dir.mktmpdir("restore-", @store.path) do |temporary|
        @staging = temporary
        source = File.join(temporary, "source")
        restore_directory(directory, source)
        raise Error, "Restored directory hash mismatch" unless local_tree(source) == directory
        if File.exist?(destination) || File.symlink?(destination)
          raise Error, "Existing restored directory differs; use a new investigation directory" unless File.directory?(destination) && !File.symlink?(destination) && local_tree(destination) == directory
        else
          @store.guard.check!
          File.rename(source, destination)
        end
      end
      @manifest.merge!("status" => "complete", "completed_at" => Time.now.utc.iso8601, "destination" => "restored",
        "files" => @files, "file_count" => @files.size, "bytes" => @bytes, "directories" => @directories)
      @output.puts "VERIFIED #{@files.size} files, #{@bytes} bytes; #{@manifest['directory_swhid']}"
      @output.puts "RESTORED #{destination}"
    ensure
      if @manifest
        @store.guard.check!
        FileUtils.mkdir_p(File.join(@store.path, "out"))
        File.write(File.join(@store.path, "out/recovery.json"), JSON.pretty_generate(@manifest) + "\n")
      end
    end

    def metadata(url)
      response = @http.request(:get, url)
      raise Error, "Package metadata not found" unless response["status"] == 200 && response["body"].is_a?(Hash)
      (@manifest["metadata_evidence"] ||= []) << response.slice("url", "fetched_at", "cache_file")
      response.fetch("body")
    end

    def restore_directory(id, path, depth = 0)
      @directories += 1
      raise Error, "Directory recovery limit reached" if @directories > 1000 || depth > 32
      @store.guard.check!
      entries = @objects.get("directory", id)
      raise Error, "Invalid archived directory" unless entries.is_a?(Array)
      names = entries.map { |entry| entry["name"] }
      unless names.uniq.size == names.size && names.all? { |name| name.is_a?(String) && !name.empty? && !%w[. .. .git].include?(name) && !name.match?(/[\x00\/\\]/) }
        raise Error, "Unsafe or duplicate archived filename"
      end
      FileUtils.mkdir_p(path)
      entries.each do |entry|
        target = entry.fetch("target")
        raise Error, "Invalid archived object identifier" unless target.match?(/\A[0-9a-f]{40}\z/)
        file = File.join(path, entry.fetch("name"))
        mode = entry.fetch("perms")
        if entry["type"] == "dir" && mode == 0o040000
          restore_directory(target, file, depth + 1)
        elsif entry["type"] == "file" && [0o100644, 0o100755, 0o120000].include?(mode)
          raise Error, "File recovery limit reached" if @files.size >= 10_000
          response = @http.request(:get, "#{Http::SWH}/content/sha1_git:#{target}/raw/", raw: true)
          bytes = response.fetch("body").unpack1("m0")
          raise Error, "Downloaded content hash mismatch" unless object_hash("blob", bytes) == target
          @bytes += bytes.bytesize
          raise Error, "Recovery exceeds 100 MiB" if @bytes > 100 * 1024**2
          @store.guard.check!
          if mode == 0o120000
            raise Error, "Unsafe archived symlink" if bytes.start_with?("/") || bytes.include?("\0")
            link = File.expand_path(bytes, path)
            raise Error, "Symlink escapes restored source" unless link.start_with?(File.join(@staging, "source") + "/")
            File.symlink(bytes, file)
          else
            File.binwrite(file, bytes)
            File.chmod(mode & 0o777, file)
          end
          @files << { "path" => file.delete_prefix(File.join(@staging, "source") + "/"), "swhid" => "swh:1:cnt:#{target}",
            "bytes" => bytes.bytesize, "mode" => mode.to_s(8), "evidence" => response.slice("url", "fetched_at", "cache_file") }
        else
          raise Error, "Unsupported archived entry type or mode"
        end
      end
    end

    def object_hash(type, bytes)
      Digest::SHA1.hexdigest("#{type} #{bytes.bytesize}\0".b + bytes.b)
    end

    def local_tree(path)
      entries = Dir.children(path).map do |name|
        file = File.join(path, name)
        stat = File.lstat(file)
        if stat.symlink?
          [name, "120000", object_hash("blob", File.readlink(file))]
        elsif stat.directory?
          [name, "40000", local_tree(file)]
        elsif stat.file?
          raise Error, "Local file exceeds size limit" if stat.size > Http::MAX_RESPONSE_BYTES
          [name, (stat.mode & 0o111).zero? ? "100644" : "100755", object_hash("blob", File.binread(file))]
        else
          raise Error, "Unsupported local file type"
        end
      end
      raw = entries.sort_by { |name, mode, _| (name + (mode == "40000" ? "/" : "")).b }.map do |name, mode, sha|
        "#{mode} #{name}\0".b + [sha].pack("H*")
      end.join.b
      object_hash("tree", raw)
    end
  end
end
