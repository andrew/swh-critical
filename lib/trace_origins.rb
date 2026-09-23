require_relative "swh_objects"
require_relative "repository_url"
require_relative "history_coverage"

module SwhCritical
  class TraceOrigins
    CANDIDATE_LIMIT = 12

    def initialize(store, http, output)
      @store, @http, @output = store, http, output
      @objects = SwhObjects.new(http)
    end

    def run(urls)
      urls.each_with_index do |url, index|
        next if @store.get("trace:#{url}")&.fetch("status", nil) == "complete"

        history = @store.get("history_coverage:#{url}")
        raise Error, "No completed history analysis for #{url}" unless history && history["status"] == "complete"

        graph_data = JSON.parse(Zlib::GzipReader.open(File.join(@store.path, history.fetch("evidence_file")), &:read))
        graph = graph_data.fetch("commits")
        first_parent = []
        sha = graph_data.fetch("head")
        while sha
          first_parent << sha
          sha = graph.fetch(sha).fetch("parents").first
        end
        data = { "url" => url, "checked_at" => Time.now.utc.iso8601, "nearest_present_revision" => history["nearest_present_revision"], "candidates" => [] }
        begin
          name = URI(url).path.split("/").last
          search_url = "#{Http::SWH}/origin/search/#{URI.encode_www_form_component(name)}/?limit=1000&use_ql=false"
          search = @http.request(:get, search_url)
          raise Error, "Invalid origin search" unless search["status"] == 200 && search["body"].is_a?(Array)

          data["search"] = search.slice("url", "fetched_at", "cache_file")
          data["search_complete"] = Http.next_url(search).nil?
          existing = @store.get("origin_search:#{url}")&.fetch("matches", []) || []
          candidates = (existing + search["body"]).uniq { |entry| entry["url"] }.select do |entry|
            normalized = RepositoryUrl.normalize(entry["url"])
            normalized && URI(normalized).host != "pkg.go.dev" &&
              URI(normalized).path.split("/").last.downcase == name.downcase && entry["snapshot_id"]
          end
          aliases = @store.db.execute("SELECT url FROM aliases WHERE repository_url = ?", [url]).map { |row| row["url"].downcase }
          candidates.sort_by! { |entry| [aliases.include?(entry["url"].downcase) ? 0 : 1, -(Time.iso8601(entry["last_visit_date"]).to_f rescue 0)] }
          data["candidate_count"] = candidates.size
          candidates.first(CANDIDATE_LIMIT).each do |candidate|
            match = candidate.slice("url", "snapshot_id", "last_visit_date")
            begin
              snapshot = @objects.snapshot(candidate.fetch("snapshot_id"))
              targets = snapshot["branches"].values.compact.select { |branch| branch["target_type"] == "revision" }.map { |branch| branch["target"] }.uniq
              shared = targets.select { |target| graph.key?(target) }
              nearest = first_parent.find { |commit| shared.include?(commit) }
              boundary = history["nearest_present_revision"]&.delete_prefix("swh:1:rev:")
              match.merge!("status" => "complete", "snapshot_complete" => snapshot["complete"], "snapshot_pages" => snapshot["pages"],
                "direct_revision_targets" => targets.size, "shared_revision_targets" => shared,
                "archived_boundary_is_branch_tip" => shared.include?(boundary),
                "closest_shared_first_parent" => nearest, "distance_from_saved_head" => nearest && first_parent.index(nearest))
            rescue RateLimited, DiskSpaceError
              raise
            rescue Error => error
              match.merge!("status" => "error", "error" => error.message)
            end
            data["candidates"] << match
          end
          data["status"] = data["candidates"].any? { |c| c["status"] == "error" } ? "incomplete" : "complete"
          data["candidates_limited"] = candidates.size > CANDIDATE_LIMIT
        ensure
          @store.set("trace:#{url}", data)
          report
        end
        @output.puts "[#{Time.now.utc.iso8601}] RESULT trace run=#{index + 1}/#{urls.size} #{url} candidates=#{data['candidates'].size} boundary_matches=#{data['candidates'].count { |c| c['archived_boundary_is_branch_tip'] }}"
        @output.flush
      end
      report
    end

    def report
      @store.guard.check!
      rows = @store.db.execute("SELECT value FROM metadata WHERE key LIKE 'trace:%' ORDER BY key").map { |row| JSON.parse(row["value"]) }
      directory = File.join(@store.path, "out")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "origin_traces.json"), JSON.pretty_generate(rows) + "\n")
    end
  end
end
