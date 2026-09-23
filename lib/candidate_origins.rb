require_relative "http"

module SwhCritical
  class CandidateOrigins
    def initialize(store, http, output)
      @store, @http, @output = store, http, output
    end

    def run(urls)
      urls.each do |url|
        next if @store.get("origin_candidates:#{url}")&.fetch("status", nil) == "complete"

        aliases = @store.db.execute("SELECT url FROM aliases WHERE repository_url = ?", [url]).map { |row| row["url"] }
        packages = @store.db.execute("SELECT registry, name, purl FROM packages WHERE repository_url = ?", [url])
        patterns = ([url] + aliases).map { |candidate| URI(candidate).path.split("/").last.delete_suffix(".git") }
        patterns = (patterns + packages.map { |package| package["name"] }).uniq
        data = { "url" => url, "checked_at" => Time.now.utc.iso8601, "packages" => packages, "searches" => [] }
        begin
          patterns.each do |pattern|
            search = { "pattern" => pattern, "pages" => [], "matches" => [] }
            data["searches"] << search
            next_url = "#{Http::SWH}/origin/search/#{URI.encode_www_form_component(pattern)}/?limit=1000&use_ql=false"
            seen = []
            3.times do
              raise Error, "Origin search pagination loop" if seen.include?(next_url)
              seen << next_url
              response = @http.request(:get, next_url)
              raise Error, "Invalid origin search response" unless response["status"] == 200 && response["body"].is_a?(Array)

              search["pages"] << response.slice("url", "fetched_at", "cache_file")
              search["matches"].concat(response.fetch("body"))
              next_url = Http.next_url(response)
              break unless next_url
            end
            search["complete"] = next_url.nil?
          end
          data["status"] = data["searches"].all? { |search| search["complete"] } ? "complete" : "incomplete"
        ensure
          @store.set("origin_candidates:#{url}", data)
          report
        end
        @output.puts "[#{Time.now.utc.iso8601}] RESULT origin-candidates #{url} status=#{data['status']} matches=#{data['searches'].sum { |search| search['matches'].size }}"
        @output.flush
      end
      report
    end

    def report
      @store.guard.check!
      rows = @store.db.execute("SELECT value FROM metadata WHERE key LIKE 'origin_candidates:%' ORDER BY key").map { |row| JSON.parse(row["value"]) }
      directory = File.join(@store.path, "out")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "origin_candidates.json"), JSON.pretty_generate(rows) + "\n")
    end
  end
end
