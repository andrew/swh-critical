require "zlib"
require "digest"
require_relative "heads"

module SwhCritical
  class Tags
    def initialize(store, output, offline: false)
      @store, @output, @offline = store, output, offline
      @db = store.db
      @git = Heads.new(store, output)
    end

    def run(limit: 100)
      seed_versions
      rows = @db.execute(<<~SQL, [limit])
        SELECT r.url FROM repositories r
        WHERE EXISTS (
          SELECT 1 FROM packages p JOIN package_releases v ON v.registry = p.registry AND v.purl = p.purl
          WHERE p.repository_url = r.url AND v.match_status IN ('unchecked', 'unknown')
        )
        ORDER BY EXISTS (SELECT 1 FROM objects o WHERE o.swhid = r.head_swhid AND o.status = 'missing') DESC,
          (r.host = 'github.com') DESC, r.url LIMIT ?
      SQL
      log("START tags selected=#{rows.size}")
      rows.each_with_index do |row, index|
        @store.guard.check!
        repository = row.fetch("url")
        packages = @db.execute(<<~SQL, [repository])
          SELECT p.registry, p.purl, p.name, v.version FROM packages p
          JOIN package_releases v ON v.registry = p.registry AND v.purl = p.purl
          WHERE p.repository_url = ? AND v.match_status IN ('unchecked', 'unknown')
        SQL
        begin
          refs, evidence = scan(repository)
          @db.transaction { packages.each { |package| match(package, refs, evidence) } }
          counts = packages.map { |p| @db.get_first_value("SELECT match_status FROM package_releases WHERE registry = ? AND purl = ?", p.values_at("registry", "purl")) }.tally
          log("RESULT tags run=#{index + 1}/#{rows.size} #{repository} #{JSON.generate(counts)}")
        rescue Error => error
          raise if error.is_a?(DiskSpaceError)
          @db.transaction do
            packages.each do |package|
              @db.execute("UPDATE package_releases SET match_status = 'unknown', match_data = ? WHERE registry = ? AND purl = ?",
                [JSON.generate("error" => error.message, "checked_at" => Time.now.utc.iso8601), package["registry"], package["purl"]])
            end
          end
          log("RESULT tags run=#{index + 1}/#{rows.size} #{repository}: #{error.message}")
        end
      end
      log("END tags repositories=#{rows.size}")
    end

    def seed_versions
      return if @store.get("release_versions_seeded")

      wanted = @db.execute("SELECT registry, purl, fetched_at FROM packages").to_h { |r| [r.values_at("registry", "purl"), r["fetched_at"]] }
      Dir.glob(File.join(@store.path, "cache", "*.json.gz")).each do |file|
        response = JSON.parse(Zlib::GzipReader.open(file, &:read))
        uri = URI(response.fetch("url"))
        path = uri.path.match(%r{\A/api/v1/registries/([^/]+)/packages\z})
        next unless uri.host == "packages.ecosyste.ms" && path && response["body"].is_a?(Array)

        registry = URI.decode_www_form_component(path[1])
        @store.guard.check!
        @db.transaction do
          response["body"].each do |package|
            next unless wanted[[registry, package["purl"]]] == response["fetched_at"]

            version = package["latest_release_number"].to_s.strip
            @db.execute("INSERT OR IGNORE INTO package_releases(registry, purl, version, match_status, metadata_evidence) VALUES (?, ?, ?, ?, ?)",
              [registry, package["purl"], version.empty? ? nil : version, version.empty? ? "no_version" : "unchecked",
                JSON.generate(response.slice("url", "fetched_at", "cache_file"))])
          end
        end
      end
      @db.execute("INSERT OR IGNORE INTO package_releases(registry, purl, match_status) SELECT registry, purl, 'metadata_unavailable' FROM packages")
      @store.set("release_versions_seeded", true)
    end

    def scan(repository)
      cached = @db.get_first_row("SELECT * FROM tag_scans WHERE repository_url = ?", [repository])
      if cached
        raw = Zlib::GzipReader.open(File.join(@store.path, cached["evidence_file"]), &:read)
        return [parse(raw), cached]
      end
      raise Error, "No cached tag refs" if @offline

      raw = @git.command(repository, refs: ["refs/tags/*"], maximum_bytes: 2 * 1024**2)
      refs = parse(raw)
      relative = "git-tags/#{Digest::SHA256.hexdigest(repository)}.txt.gz"
      @store.guard.check!
      FileUtils.mkdir_p(File.join(@store.path, "git-tags"))
      Zlib::GzipWriter.open(File.join(@store.path, relative)) { |gzip| gzip.write(raw) }
      observed = Time.now.utc.iso8601
      @db.execute("INSERT INTO tag_scans VALUES (?, ?, ?)", [repository, observed, relative])
      [refs, { "repository_url" => repository, "observed_at" => observed, "evidence_file" => relative }]
    end

    def parse(raw)
      refs = {}
      raw.each_line do |line|
        match = line.chomp.match(/\A([0-9a-f]{40})\trefs\/tags\/(\S+)\z/)
        raise Error, "Unsupported or invalid tag refs" if !match && line.include?("\trefs/tags/")
        next unless match
        raise Error, "Duplicate tag ref" if refs.key?(match[2])
        refs[match[2]] = match[1]
      end
      raise Error, "Unsupported or invalid tag refs" if !raw.empty? && refs.empty?
      refs.each_key do |name|
        raise Error, "Peeled tag without tag object" if name.end_with?("^{}") && !refs.key?(name.delete_suffix("^{}"))
      end
      refs
    end

    def match(package, refs, evidence)
      name, version = package.values_at("name", "version")
      short = name.split(/[\/:]/).last
      qualified = ["#{name}@#{version}", "#{short}@#{version}", "#{short}-#{version}", "#{short}/#{version}", "#{short}/v#{version}"].uniq
      candidates = qualified.select { |tag| refs.key?(tag) }
      method = "package_qualified"
      if candidates.empty?
        candidates = [version, "v#{version}"].uniq.select { |tag| refs.key?(tag) }
        method = "version_only"
      end
      status = candidates.empty? ? "unmatched" : (candidates.size == 1 ? "matched" : "ambiguous")
      data = evidence.merge("matching" => method, "candidate_tags" => candidates, "checked_at" => Time.now.utc.iso8601)
      tag = target = release = nil
      if status == "matched"
        tag = candidates.first
        target_hash = refs["#{tag}^{}"] || refs[tag]
        target = "swh:1:rev:#{target_hash}"
        release = "swh:1:rel:#{refs[tag]}" if refs.key?("#{tag}^{}")
        data.merge!("tag_object" => refs[tag], "target_object" => target_hash, "target_type" => "unverified")
        [target, release].compact.each { |id| @db.execute("INSERT OR IGNORE INTO objects(swhid) VALUES (?)", [id]) }
      end
      @db.execute("UPDATE package_releases SET match_status = ?, tag_name = ?, target_swhid = ?, release_swhid = ?, match_data = ? WHERE registry = ? AND purl = ?",
        [status, tag, target, release, JSON.generate(data), package["registry"], package["purl"]])
    end

    def log(message)
      @output.puts "[#{Time.now.utc.iso8601}] #{message.gsub(/[\r\n\t]+/, ' ')}"
      @output.flush
    end
  end
end
