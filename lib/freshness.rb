require_relative "origins"

module SwhCritical
  class Freshness
    def initialize(store, output)
      @store, @output = store, output
      @http = Http.new(store, offline: true)
      @origins = Origins.new(store, @http, output)
    end

    def run
      @as_of = Time.now.utc
      packages = @store.db.execute("SELECT repository_url, registry, COUNT(*) AS count FROM packages WHERE repository_url IS NOT NULL GROUP BY repository_url, registry").group_by { |row| row["repository_url"] }
      aliases = @store.db.execute("SELECT repository_url, url FROM aliases ORDER BY url").group_by { |row| row["repository_url"] }
      rows = @store.db.execute(<<~SQL).map do |row|
        SELECT r.*, o.status AS object_status FROM repositories r
        LEFT JOIN objects o ON o.swhid = r.head_swhid ORDER BY r.url
      SQL
        candidates = aliases.fetch(row["url"], []).map { |entry| entry["url"] }
        saved = JSON.parse(row["origin_data"] || "{}")
        checked = saved.fetch("observations", []).map { |entry| entry.fetch("origin") }.uniq & candidates
        observations = checked.map { |origin| lookup(origin) }
        latest_attempt = latest(observations.filter_map { |entry| entry["latest_attempt"] })
        latest_snapshot = latest(observations.filter_map { |entry| entry["latest_snapshot"] })
        head = JSON.parse(row["head_data"] || "{}")
        {
          "url" => row["url"], "forge" => row["host"], "coverage" => row["coverage"],
          "registries" => packages.fetch(row["url"], []).to_h { |entry| [entry["registry"], entry["count"]] },
          "local_git_status" => row["head_status"], "local_git_error" => head["error"],
          "local_git_observed_at" => head["observed_at"],
          "head_object_status" => row["head_status"] == "observed" ? (row["object_status"] || "pending") : row["head_status"],
          "candidate_aliases" => candidates.size, "checked_aliases" => checked.size,
          "untried_aliases" => candidates - checked,
          "all_aliases_checked" => candidates.any? && candidates.size == checked.size,
          "checked_aliases_complete" => observations.any? && observations.all? { |entry| entry["latest_complete"] },
          "latest_attempt" => latest_attempt, "latest_snapshot" => latest_snapshot,
          "attempt_snapshot_gap_days" => latest_attempt && latest_snapshot && days_between(latest_attempt["date"], latest_snapshot["date"]),
          "observations" => observations
        }
      end
      missing = rows.select { |row| row["local_git_status"] == "observed" && row["head_object_status"] == "missing" }
      summary = {
        "reported_at" => @as_of.iso8601, "source" => "cached origin visit pages for previously checked aliases",
        "scope" => "Latest dates cover checked aliases only. Untried aliases and uncached pages remain unresolved. Ages are days since visits, not commit ingestion lag.",
        "all" => summarize(rows), "missing_heads" => summarize(missing),
        "by_forge" => grouped(rows), "missing_heads_by_forge" => grouped(missing),
        "by_registry" => registries(rows), "missing_heads_by_registry" => registries(missing)
      }
      @store.guard.check!
      directory = File.join(@store.path, "out")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "freshness.json"), JSON.pretty_generate({ "reported_at" => @as_of.iso8601, "repositories" => rows }) + "\n")
      File.write(File.join(directory, "freshness_summary.json"), JSON.pretty_generate(summary) + "\n")
      @output.puts JSON.pretty_generate(summary.slice("reported_at", "all", "missing_heads"))
    end

    def lookup(origin)
      encoded = URI.encode_www_form_component(origin).gsub("+", "%20")
      url = "#{Http::SWH}/origin/#{encoded}/visits/?per_page=100"
      data = { "origin" => origin, "latest_attempt" => nil, "latest_snapshot" => nil,
        "latest_complete" => false, "pagination_complete" => false, "pages" => [] }
      seen = []
      previous_date = nil
      Origins::MAX_PAGES.times do
        raise Error, "Visit pagination loop" if seen.include?(url)

        seen << url
        response = @http.request(:get, url)
        evidence = response.slice("url", "fetched_at", "cache_file", "status")
        data["pages"] << evidence
        if response["status"] == 404
          raise Error, "Origin disappeared during pagination" if seen.size > 1

          return data.merge("status" => "not_found", "latest_complete" => true, "pagination_complete" => true)
        end
        visits = response.fetch("body")
        raise Error, "Invalid visits response" unless visits.is_a?(Array)

        visits.each do |visit|
          @origins.validate_visit(visit, origin)
          date = Time.iso8601(visit.fetch("date"))
          raise Error, "Visits are not in descending date order" if previous_date && date > previous_date

          previous_date = date
        end
        data["latest_attempt"] ||= dated(visits.first, evidence) if visits.any?
        snapshot = visits.find { |visit| %w[full partial].include?(visit["status"]) && visit["snapshot"] }
        data["latest_snapshot"] ||= dated(snapshot, evidence) if snapshot
        url = Http.next_url(response)
        data["next_url"] = url
        data["pagination_complete"] = url.nil?
        if data["latest_snapshot"] || url.nil?
          status = data["latest_snapshot"] ? "snapshot_found" : (data["latest_attempt"] ? "no_snapshot" : "no_visits")
          return data.merge("status" => status, "latest_complete" => true)
        end
      end
      data.merge("status" => "incomplete", "error" => "Visit page limit reached")
    rescue Error, ArgumentError => error
      data.merge("status" => "incomplete", "error" => error.message)
    end

    def dated(visit, evidence)
      visit.merge("evidence" => evidence, "age_days" => days_between(@as_of.iso8601, visit.fetch("date")))
    end

    def days_between(newer, older)
      ((Time.iso8601(newer) - Time.iso8601(older)) / 86_400).round(2)
    end

    def latest(visits)
      visits.max_by { |visit| [Time.iso8601(visit.fetch("date")), visit.fetch("visit")] }
    end

    def distribution(values)
      sorted = values.sort
      middle = sorted.size / 2
      median = sorted.empty? ? nil : (sorted[(sorted.size - 1) / 2] + sorted[middle]) / 2.0
      { "n" => sorted.size, "min" => sorted.first, "median" => median&.round(2), "max" => sorted.last }
    end

    def summarize(rows)
      complete = rows.select { |row| row["checked_aliases_complete"] }
      attempts = complete.filter_map { |row| row["latest_attempt"] }
      snapshots = complete.filter_map { |row| row["latest_snapshot"] }
      dates = rows.flat_map { |row| row["observations"].flat_map { |entry| entry["pages"].map { |page| page["fetched_at"] } } }.compact
      {
        "repositories" => rows.size, "packages" => rows.sum { |row| row["registries"].values.sum },
        "with_checked_aliases" => rows.count { |row| row["checked_aliases"].positive? },
        "checked_aliases_complete" => complete.size,
        "all_aliases_checked" => rows.count { |row| row["all_aliases_checked"] },
        "with_incomplete_lookups" => rows.count { |row| row["observations"].any? { |entry| !entry["latest_complete"] } },
        "with_unread_visit_pages" => rows.count { |row| row["observations"].any? { |entry| !entry["pagination_complete"] } },
        "local_git_status" => rows.map { |row| row["local_git_status"] }.tally,
        "local_git_errors" => rows.count { |row| row["local_git_error"] },
        "head_object_status" => rows.map { |row| row["head_object_status"] }.tally,
        "latest_attempt_status" => attempts.map { |visit| visit["status"] }.tally,
        "latest_snapshot_status" => snapshots.map { |visit| visit["status"] }.tally,
        "latest_attempt_age_days" => distribution(attempts.map { |visit| visit["age_days"] }),
        "latest_snapshot_age_days" => distribution(snapshots.map { |visit| visit["age_days"] }),
        "attempt_snapshot_gap_days" => distribution(complete.filter_map { |row| row["attempt_snapshot_gap_days"] }),
        "latest_attempt_after_snapshot" => complete.count { |row| row["attempt_snapshot_gap_days"].to_f.positive? },
        "evidence_fetched_at" => { "first" => dates.min, "last" => dates.max }
      }
    end

    def grouped(rows)
      rows.group_by { |row| row["forge"] }.transform_values { |group| summarize(group) }
    end

    def registries(rows)
      rows.flat_map { |row| row["registries"].keys }.uniq.sort.to_h do |registry|
        members = rows.select { |row| row["registries"].key?(registry) }
        summary = summarize(members)
        summary["packages"] = members.sum { |row| row["registries"].fetch(registry) }
        [registry, summary]
      end
    end
  end
end
