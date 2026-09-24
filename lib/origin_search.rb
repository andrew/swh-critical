require_relative "origins"
require_relative "repository_url"

module SwhCritical
  class OriginSearch
    def initialize(store, http, output)
      @store, @http, @output = store, http, output
    end

    def run(limit: 100)
      clones = @store.db.execute("SELECT value FROM metadata WHERE key LIKE 'clone_check:%' ORDER BY key").map { |row| JSON.parse(row["value"]) }
      clones.select! do |row|
        saved = @store.get("origin_search:#{row['url']}")
        row["status"] == "complete" && !(saved && saved["status"] == "complete" && visits_complete?(saved))
      end
      clones.first(limit).each_with_index do |clone, index|
        url = clone.fetch("url")
        uri = URI(url)
        pattern = "#{uri.host}#{uri.path}"
        next_url = "#{Http::SWH}/origin/search/#{URI.encode_www_form_component(pattern)}/?limit=1000&use_ql=false"
        data = { "url" => url, "searched_at" => Time.now.utc.iso8601, "matches" => [], "pages" => [] }
        begin
          3.times do
            response = @http.request(:get, next_url)
            raise Error, "Invalid origin search response" unless response["status"] == 200 && response["body"].is_a?(Array)

            data["pages"] << response.slice("url", "cache_file", "fetched_at")
            response["body"].each do |entry|
              raise Error, "Invalid origin search result" unless entry.is_a?(Hash) && entry["url"].is_a?(String)

              origin = entry.fetch("url")
              normalized = RepositoryUrl.normalize(origin)
              target = RepositoryUrl.normalize(url)
              relation = if normalized && normalized.downcase == target.downcase
                if uri.host == "github.com" || normalized == target
                  "same_repository_url"
                else
                  "case_variant_candidate"
                end
              elsif URI(origin).host == "pkg.go.dev" && URI(origin).path.sub(%r{\A/}, "").downcase == pattern.downcase
                "package_registry_reference"
              else
                "substring_match"
              end
              match = entry.merge("relation" => relation)
              match["visit_check"] = Origins.new(@store, @http, @output).lookup(origin) unless relation == "substring_match"
              data["matches"] << match
            end
            next_url = Http.next_url(response)
            break unless next_url
          end
          data["status"] = next_url || !visits_complete?(data) ? "incomplete" : "complete"
        rescue RateLimited, DiskSpaceError
          raise
        rescue Error => error
          data.merge!("status" => "error", "error" => error.message)
        end
        @store.set("origin_search:#{url}", data)
        @output.puts "[#{Time.now.utc.iso8601}] RESULT origin-search run=#{index + 1}/#{[clones.size, limit].min} #{url} status=#{data['status']} matches=#{data['matches'].size}"
        @output.flush
        report
      end
      report
    end

    def visits_complete?(data)
      data.fetch("matches").none? { |match| match.dig("visit_check", "status") == "unknown" }
    end

    def report
      @store.guard.check!
      rows = @store.db.execute("SELECT value FROM metadata WHERE key LIKE 'origin_search:%' ORDER BY key").map { |row| JSON.parse(row["value"]) }
      directory = File.join(@store.path, "out")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "origin_search.json"), JSON.pretty_generate(rows) + "\n")
    end
  end
end
