require "csv"
require "digest"
require_relative "store"
require_relative "repository_url"

module SwhCritical
  class Recovery
    COLUMNS = %w[registry purl repository_url evidence_url evidence_file reason].freeze

    def initialize(store, output)
      @store, @output = store, output
      @db = store.db
    end

    def run(path)
      rows = CSV.read(path, headers: true)
      raise Error, "Recovery CSV requires #{COLUMNS.join(', ')}" unless (COLUMNS - Array(rows.headers)).empty?

      seen = []
      mappings = rows.map do |row|
        raise Error, "Recovery fields must be nonblank" unless COLUMNS.all? { |key| !row[key].to_s.strip.empty? }
        key = [row["registry"], row["purl"]]
        raise Error, "Duplicate recovery: #{key.join(' ')}" if seen.include?(key)
        seen << key
        package = @db.get_first_row("SELECT repository_url FROM packages WHERE registry = ? AND purl = ?", key)
        raise Error, "Package outside cohort: #{key.join(' ')}" unless package
        url = RepositoryUrl.key(row["repository_url"])
        raise Error, "Invalid repository URL: #{row['repository_url']}" unless url
        if package["repository_url"] && package["repository_url"] != url
          raise Error, "Recovery would replace an existing repository: #{key.join(' ')}"
        end
        evidence_url = URI(row["evidence_url"])
        unless %w[http https].include?(evidence_url.scheme) && evidence_url.host && !evidence_url.userinfo
          raise Error, "Invalid evidence URL"
        end
        file = File.expand_path(row["evidence_file"], @store.path)
        raise Error, "Evidence must be inside the investigation directory" unless file.start_with?("#{@store.path}/")
        raise Error, "Missing evidence file: #{row['evidence_file']}" unless File.file?(file)
        row.to_h.merge("repository_url" => url, "source_repository_url" => row["repository_url"], "evidence_sha256" => Digest::SHA256.file(file).hexdigest,
          "skip" => !package["repository_url"].nil?)
      end

      applied = 0
      @store.guard.check!
      @db.transaction do
        mappings.each do |row|
          next if row["skip"]

          url = row.fetch("repository_url")
          @db.execute("INSERT OR IGNORE INTO repositories(url, host) VALUES (?, ?)", [url, URI(url).host])
          (RepositoryUrl.variants(row["source_repository_url"]) + RepositoryUrl.variants(url)).uniq.each do |candidate|
            @db.execute("INSERT OR IGNORE INTO aliases VALUES (?, ?, ?)", [url, candidate, "recovery"])
            if @db.changes.positive?
              @db.execute("UPDATE repositories SET coverage = 'unchecked', origin_data = NULL WHERE url = ? AND coverage != 'snapshot_found'", [url])
            end
          end
          @db.execute("UPDATE packages SET repository_url = ? WHERE registry = ? AND purl = ?",
            [url, row["registry"], row["purl"]])
          evidence = row.reject { |key, _| key == "skip" }.merge("recovered_at" => Time.now.utc.iso8601)
          @db.execute("INSERT INTO repository_recoveries(registry, purl, evidence) VALUES (?, ?, ?)",
            [row["registry"], row["purl"], JSON.generate(evidence)])
          applied += 1
        end
      end
      remaining = @db.get_first_value("SELECT COUNT(*) FROM packages WHERE repository_url IS NULL")
      @output.puts "Recovered #{applied} package repository URLs; #{mappings.size - applied} already mapped; #{remaining} still missing"
    rescue CSV::MalformedCSVError, URI::InvalidURIError => error
      raise Error, error.message
    end
  end
end
