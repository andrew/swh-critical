require_relative "http"

module SwhCritical
  class Known
    MAX_IDENTIFIERS = 1_000

    def initialize(store, http, output)
      @store, @http, @output = store, http, output
      @db = store.db
    end

    def run(limit: 1000)
      identifiers = @db.execute("SELECT swhid FROM objects WHERE status IN ('pending', 'unknown') ORDER BY swhid LIMIT ?", [limit]).map { |row| row["swhid"] }
      @output.puts "[#{Time.now.utc.iso8601}] START known selected=#{identifiers.size} batch_size=#{MAX_IDENTIFIERS}"
      checked = 0
      identifiers.each_slice(MAX_IDENTIFIERS) do |batch|
        @store.guard.check!
        response = @http.request(:post, "#{Http::SWH}/known/", body: batch)
        results = response.fetch("body")
        @db.transaction do
          batch.each do |swhid|
            entry = results.is_a?(Hash) && response["status"] == 200 ? results[swhid] : nil
            value = entry.is_a?(Hash) ? entry["known"] : nil
            status = value == true ? "present" : (value == false ? "missing" : "unknown")
            evidence = response.slice("url", "cache_file", "fetched_at").merge("result" => entry)
            @db.execute("UPDATE objects SET status = ?, checked_at = ?, evidence = ?, error = ? WHERE swhid = ?",
              [status, response["fetched_at"], JSON.generate(evidence), status == "unknown" ? "Invalid known response" : nil, swhid])
          end
        end
        checked += batch.size
        @output.puts "[#{Time.now.utc.iso8601}] RESULT known checked=#{checked}/#{identifiers.size} batch=#{batch.size}"
        @output.flush
      end
      @output.puts "[#{Time.now.utc.iso8601}] END known checked=#{checked}/#{identifiers.size}"
    end
  end
end
