require_relative "http"
require_relative "repository_url"

module SwhCritical
  class Collector
    def initialize(store, http, output)
      @store, @http, @output = store, http, output
      @db = store.db
    end

    def run(registries: [], per_page: 100, pages_per_registry: nil)
      discover
      selected = @db.execute("SELECT * FROM registries ORDER BY name")
      unless registries.empty?
        missing = registries - selected.map { |row| row["name"] }
        raise Error, "Unknown registries: #{missing.join(', ')}" unless missing.empty?
        selected = selected.select { |row| registries.include?(row["name"]) }
      end
      selected.each do |registry|
        next if registry["status"] == "complete"

        collect_registry(registry, per_page, pages_per_registry)
      end
    end

    def discover
      return if @store.get("registries_complete")

      url = @store.get("registries_next") || "#{Http::PACKAGES}/registries?per_page=100&page=1"
      seen = []
      while url
        raise Error, "Registry pagination loop" if seen.include?(url)
        seen << url
        response = @http.request(:get, url)
        rows = response.fetch("body")
        raise Error, "Invalid registry response" unless response["status"] == 200 && rows.is_a?(Array)
        next_url = Http.next_url(response)
        @store.guard.check!
        @db.transaction do
          rows.each do |row|
            raise Error, "Registry missing name" unless row.is_a?(Hash) && row["name"].is_a?(String)
            @db.execute("INSERT OR IGNORE INTO registries(name, ecosystem) VALUES (?, ?)", [row["name"], row["ecosystem"]])
          end
          @store.set("registries_next", next_url)
          @store.set("registries_complete", true) unless next_url
        end
        url = next_url
      end
      @output.puts "Discovered #{@db.get_first_value('SELECT COUNT(*) FROM registries')} registries"
    end

    def collect_registry(registry, per_page, page_limit)
      name = registry.fetch("name")
      encoded = URI.encode_www_form_component(name).gsub("+", "%20")
      url = registry["next_url"] || "#{Http::PACKAGES}/registries/#{encoded}/packages?critical=true&per_page=#{per_page}&sort=name&order=asc&page=1"
      pages = 0
      seen = []
      while url && (!page_limit || pages < page_limit)
        raise Error, "Package pagination loop" if seen.include?(url)
        seen << url
        begin
          response = @http.request(:get, url)
        rescue ResponseTooLarge
          smaller_url = smaller_page(url)
          raise unless smaller_url

          @store.guard.check!
          @db.execute("UPDATE registries SET next_url = ?, status = 'partial', error = NULL WHERE name = ?", [smaller_url, name])
          @output.puts "#{name}: response too large; retrying #{smaller_url}"
          url = smaller_url
          next
        end
        rows = response.fetch("body")
        raise Error, "Invalid package response for #{name}" unless response["status"] == 200 && rows.is_a?(Array)
        next_url = Http.next_url(response)
        @store.guard.check!
        @db.transaction do
          rows.each { |row| import(row, registry, response.fetch("fetched_at")) }
          @db.execute("UPDATE registries SET next_url = ?, status = ?, error = NULL WHERE name = ?",
            [next_url, next_url ? "partial" : "complete", name])
        end
        pages += 1
        url = next_url
      end
      count = @db.get_first_value("SELECT COUNT(*) FROM packages WHERE registry = ?", [name])
      @output.puts "#{name}: #{count} packages (#{url ? 'partial' : 'complete'})"
    rescue RateLimited, DiskSpaceError
      raise
    rescue Error => error
      @db.execute("UPDATE registries SET status = 'error', error = ? WHERE name = ?", [error.message, name])
      @output.puts "#{name}: #{error.message}"
    end

    def smaller_page(url)
      uri = URI(url)
      params = URI.decode_www_form(uri.query.to_s).to_h
      size = Integer(params.fetch("per_page"), 10)
      page = Integer(params.fetch("page", "1"), 10)
      raise Error, "Invalid package pagination" unless (1..100).cover?(size) && page.positive?
      return if size == 1

      offset = (page - 1) * size
      size /= 2
      # Round down to overlap earlier records rather than skip any.
      params["page"] = (offset / size + 1).to_s
      params["per_page"] = size.to_s
      uri.query = URI.encode_www_form(params)
      uri.to_s
    rescue ArgumentError, KeyError, URI::InvalidURIError
      raise Error, "Invalid package pagination"
    end

    def import(package, registry, fetched_at)
      unless package.is_a?(Hash) && package["purl"].is_a?(String) && package["name"].is_a?(String) && package["critical"] == true
        raise Error, "Invalid critical package record"
      end
      original = package["repository_url"]
      repository = RepositoryUrl.key(original)
      if repository
        @db.execute("INSERT OR IGNORE INTO repositories(url, host) VALUES (?, ?)", [repository, URI(repository).host])
        metadata = package["repo_metadata"].is_a?(Hash) ? package["repo_metadata"] : {}
        aliases = { original => "package", repository => "normalized" }
        %w[clone_url html_url].each { |key| aliases[metadata[key]] = "repo_metadata.#{key}" if metadata[key] }
        Array(metadata["previous_names"]).each do |name|
          next unless name.is_a?(String)
          alias_url = name.include?("://") ? name : "https://#{URI(repository).host}/#{name}"
          aliases[alias_url] = "repo_metadata.previous_names"
        end
        aliases.each do |value, source|
          RepositoryUrl.variants(value).each do |url|
            @db.execute("INSERT OR IGNORE INTO aliases VALUES (?, ?, ?)", [repository, url, source])
            if @db.changes.positive?
              @db.execute("UPDATE repositories SET coverage = 'unchecked', origin_data = NULL WHERE url = ?", [repository])
            end
          end
        end
      end
      @db.execute(<<~SQL, [package["purl"], registry["name"], package["name"], package["ecosystem"] || registry["ecosystem"], original, repository, fetched_at])
        INSERT INTO packages VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(registry, purl) DO NOTHING
      SQL
      if @db.changes.positive?
        version = package["latest_release_number"].to_s.strip
        @db.execute("INSERT OR IGNORE INTO package_releases(registry, purl, version, match_status, metadata_evidence) VALUES (?, ?, ?, ?, ?)",
          [registry["name"], package["purl"], version.empty? ? nil : version, version.empty? ? "no_version" : "unchecked", JSON.generate("fetched_at" => fetched_at)])
      end
    end
  end
end
