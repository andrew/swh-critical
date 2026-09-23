require_relative "http"
require_relative "release_gaps"

module SwhCritical
  class Origins
    MAX_ORIGINS = 8
    MAX_PAGES = 3

    def initialize(store, http, output)
      @store, @http, @output = store, http, output
      @db = store.db
    end

    def run(limit: 100, missing_heads: false, missing_releases: false)
      @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @run_id = "#{Time.now.utc.strftime('%Y%m%dT%H%M%S%6N')}-#{Process.pid}"
      @counts = Hash.new(0)
      @db.execute("SELECT coverage, COUNT(*) AS count FROM repositories GROUP BY coverage").each { |row| @counts[row["coverage"]] = row["count"] }
      @total = @counts.values.sum
      scope = if missing_heads
        "AND head_status = 'observed' AND head_swhid IN (SELECT swhid FROM objects WHERE status = 'missing')"
      else
        ""
      end
      rows = if missing_releases
        ReleaseGaps.rows(@db).select { |row| row["archive_status"] == "unresolved" }.first(limit)
      else
        @db.execute("SELECT url, coverage FROM repositories WHERE coverage IN ('unchecked', 'unknown') #{scope} ORDER BY url LIMIT ?", [limit])
      end
      @selected = rows.size
      @processed = 0
      scope_name = missing_releases ? "missing_releases_without_evidence" : (missing_heads ? "missing_heads" : "all")
      log("START", "data=#{@store.path} scope=#{scope_name} selected=#{@selected} #{summary}")
      rows.each do |row|
        @store.guard.check!
        repository = row.fetch("url")
        @current_repository = repository
        candidates = @db.execute("SELECT url FROM aliases WHERE repository_url = ? ORDER BY CASE source WHEN 'package' THEN 0 ELSE 1 END, url", [repository]).map { |r| r["url"] }
        observations = []
        candidates.first(MAX_ORIGINS).each do |origin|
          observation = lookup(origin)
          observations << observation
          break if %w[full partial].include?(observation["status"])
        end
        covered = observations.select { |entry| %w[full partial].include?(entry["status"]) }
        status = if covered.any?
          "snapshot_found"
        elsif candidates.empty? || candidates.size > MAX_ORIGINS || observations.any? { |entry| entry["status"] == "unknown" }
          "unknown"
        elsif observations.any? { |entry| entry["status"] == "no_snapshot" }
          "no_snapshot"
        else
          "origin_not_found"
        end
        reasons = []
        reasons << "alias limit: checked #{observations.size}/#{candidates.size} URLs" if covered.empty? && candidates.size > MAX_ORIGINS
        reasons << "no candidate URLs" if candidates.empty?
        observations.each do |observation|
          reason = observation["error"]
          reason ||= "incomplete origin lookup" if observation["status"] == "unknown"
          reasons << "#{observation['origin']}: #{reason}" if reason
        end
        data = { "checked_at" => Time.now.utc.iso8601, "candidates" => candidates, "observations" => observations, "incomplete_reasons" => reasons }
        @db.execute("UPDATE repositories SET coverage = ?, origin_data = ? WHERE url = ?", [status, JSON.generate(data), repository])
        @counts[row.fetch("coverage")] -= 1
        @counts[status] += 1
        @processed += 1
        checked = @total - @counts["unchecked"]
        percentage = @total.zero? ? 100.0 : 100.0 * checked / @total
        message = "checked=#{checked}/#{@total} (#{format('%.1f', percentage)}%) run=#{@processed}/#{@selected} #{status} #{repository}"
        message += " | #{reasons.join('; ')}" unless reasons.empty?
        log("RESULT", message)
        log("PROGRESS", summary) if (@processed % 25).zero?
      end
      log("END", "batch finished #{summary}")
    rescue RateLimited => error
      log("PAUSED", "#{error.message} current=#{@current_repository} #{summary}")
      raise
    rescue Error, Interrupt => error
      log(error.is_a?(Interrupt) ? "INTERRUPTED" : "ERROR", "#{error.message} current=#{@current_repository} #{summary}") if @counts
      raise
    end

    def summary
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started
      "checked=#{@total - @counts['unchecked']}/#{@total} snapshots=#{@counts['snapshot_found']} " \
        "no_snapshot=#{@counts['no_snapshot']} origin_not_found=#{@counts['origin_not_found']} " \
        "unknown=#{@counts['unknown']} remaining=#{@counts['unchecked']} elapsed=#{format('%.1f', elapsed)}s"
    end

    def log(event, message)
      @output.puts "[#{Time.now.utc.iso8601}] [#{@run_id}] #{event} #{message.gsub(/[\r\n\t]+/, ' ')}"
      @output.flush
    end

    def lookup(origin)
      encoded = URI.encode_www_form_component(origin).gsub("+", "%20")
      url = "#{Http::SWH}/origin/#{encoded}/visits/?per_page=100"
      evidence = []
      registered = false
      seen = []
      MAX_PAGES.times do
        raise Error, "Visit pagination loop" if seen.include?(url)
        seen << url
        response = @http.request(:get, url)
        evidence << response.slice("url", "fetched_at", "cache_file", "status")
        if response["status"] == 404
          return { "origin" => origin, "status" => registered ? "unknown" : "not_found", "evidence" => evidence }
        end
        visits = response.fetch("body")
        raise Error, "Invalid visits response" unless visits.is_a?(Array)
        registered = true
        visits.each do |visit|
          validate_visit(visit, origin)
          next unless %w[full partial].include?(visit["status"]) && visit["snapshot"]

          return { "origin" => origin, "status" => visit["status"], "visit" => visit, "evidence" => evidence }
        end
        url = Http.next_url(response)
        return { "origin" => origin, "status" => "no_snapshot", "evidence" => evidence } unless url
      end
      { "origin" => origin, "status" => "unknown", "error" => "Visit page limit reached", "evidence" => evidence }
    rescue RateLimited, DiskSpaceError
      raise
    rescue Error, ArgumentError => error
      { "origin" => origin, "status" => "unknown", "error" => error.message, "evidence" => evidence }
    end

    def validate_visit(visit, origin)
      unless visit.is_a?(Hash) && visit["origin"] == origin && visit["visit"].is_a?(Integer) && visit["visit"].positive? &&
          visit["date"].is_a?(String) && visit["type"].is_a?(String) &&
          %w[created ongoing full partial not_found failed].include?(visit["status"]) &&
          (visit["snapshot"].nil? || visit["snapshot"].is_a?(String) && visit["snapshot"].match?(/\A[0-9a-f]{40}\z/))
        raise Error, "Invalid visit record"
      end
      raise Error, "Full visit has no snapshot" if visit["status"] == "full" && visit["snapshot"].nil?
      Time.iso8601(visit.fetch("date"))
    end
  end
end
