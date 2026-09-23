require "csv"
require_relative "http"
require_relative "repository_url"

module SwhCritical
  class Science
    SOURCES = { "projects" => "projects/search_seeds", "dependencies" => "packages" }.freeze

    def initialize(store, http, output)
      @store, @http, @output = store, http, output
      @db = store.db
      @db.execute_batch <<~SQL
        CREATE TABLE IF NOT EXISTS science_records (
          source TEXT NOT NULL, id INTEGER NOT NULL, data TEXT NOT NULL, evidence TEXT NOT NULL,
          PRIMARY KEY(source, id)
        );
        CREATE TABLE IF NOT EXISTS science_pages (
          source TEXT NOT NULL, url TEXT NOT NULL, PRIMARY KEY(source, url)
        );
      SQL
    end

    def run(per_page: 100, limit: nil)
      SOURCES.each do |source, path|
        key = "science:#{source}"
        state = @store.get(key) || {
          "status" => "partial", "pages" => 0, "started_at" => Time.now.utc.iso8601,
          "next_url" => "#{Http::SCIENCE}/#{path}?per_page=#{source == 'projects' ? [per_page, 100].min : per_page}&page=1"
        }
        next if state["status"] == "complete"

        log("START science source=#{source} pages_saved=#{state['pages']}")
        processed = 0
        while state["next_url"] && (!limit || processed < limit)
          response = @http.request(:get, state.fetch("next_url"))
          rows = response["body"]
          raise Error, "Invalid science #{source} page" unless response["status"] == 200 && rows.is_a?(Array)
          rows.each do |row|
            id = row.is_a?(Hash) && row[source == "projects" ? "project_id" : "id"]
            raise Error, "Science #{source} record has no integer ID" unless id.is_a?(Integer) && id.positive?
          end
          next_url = Http.next_url(response)
          if next_url && @db.get_first_value("SELECT 1 FROM science_pages WHERE source = ? AND url = ?", [source, next_url])
            raise Error, "Science pagination cycle"
          end
          evidence = JSON.generate(response.slice("url", "fetched_at", "cache_file"))
          @store.guard.check!
          @db.transaction do
            rows.each do |row|
              id = row[source == "projects" ? "project_id" : "id"]
              @db.execute("INSERT INTO science_records VALUES (?, ?, ?, ?) ON CONFLICT(source, id) DO UPDATE SET data = excluded.data, evidence = excluded.evidence",
                [source, id, JSON.generate(compact_record(source, row)), evidence])
            end
            @db.execute("INSERT INTO science_pages VALUES (?, ?)", [source, response.fetch("url")])
            state.merge!("next_url" => next_url, "pages" => state["pages"] + 1,
              "status" => next_url ? "partial" : "complete", "updated_at" => response["fetched_at"])
            @store.set(key, state)
          end
          processed += 1
          count = @db.get_first_value("SELECT COUNT(*) FROM science_records WHERE source = ?", [source])
          log("RESULT science source=#{source} pages=#{state['pages']} records=#{count} status=#{state['status']}")
        end
      end
    end

    def compact_record(source, row)
      return row.slice("purl", "repository_url", "registry", "scientific_projects_count", "repository_science_score") if source == "dependencies"

      row.slice("repository_url", "science_score", "updated_at", "last_synced_at").merge(
        "packages" => Array(row["packages"]).filter_map { |p| p.slice("purl", "registry") if p.is_a?(Hash) },
        "aliases" => Array(row["seeds"]).filter_map do |seed|
          seed["value"] if seed.is_a?(Hash) && seed["type"] == "repository_url" && seed["source"] == "repository.previous_names"
        end
      )
    end

    def package_key(value)
      return unless value.is_a?(String) && value.start_with?("pkg:")

      base, qualifiers = value.split("#", 2).first.split("?", 2)
      base = base.sub(/@[^\/]*\z/, "")
      qualifiers ? "#{base}?#{qualifiers}" : base
    end

    def report(cohort_path)
      @store.guard.check!
      cohort = SQLite3::Database.new(File.join(File.expand_path(cohort_path), "investigation.sqlite3"), readonly: true)
      cohort.results_as_hash = true
      cohort.busy_timeout = 5000
      captured_at = Time.now.utc.iso8601
      cohort.transaction do
        @packages = cohort.execute("SELECT * FROM packages")
        @repositories = cohort.execute(<<~SQL).to_h { |row| [row["url"], row] }
          SELECT r.*, CASE WHEN r.head_status = 'observed' THEN COALESCE(o.status, 'pending')
            ELSE r.head_status END AS current_commit_coverage
          FROM repositories r LEFT JOIN objects o ON o.swhid = r.head_swhid
        SQL
        @releases = cohort.execute(<<~SQL).to_h { |row| [row.values_at("registry", "purl"), row] }
          SELECT v.*, t.status AS target_status, a.status AS release_status FROM package_releases v
          LEFT JOIN objects t ON t.swhid = v.target_swhid LEFT JOIN objects a ON a.swhid = v.release_swhid
        SQL
      end
      cohort.close
      cohort = nil
      by_purl = @packages.group_by { |p| package_key(p["purl"]) }
      by_url = @packages.reject { |p| p["repository_url"].nil? }.group_by { |p| p["repository_url"] }
      matches = []
      @db.execute("SELECT * FROM science_records ORDER BY source, id") do |record|
        data = JSON.parse(record["data"])
        candidates = []
        purls = record["source"] == "projects" ? data.fetch("packages").map { |p| p["purl"] } : [data["purl"]]
        purls.compact.uniq.each do |purl|
          key = package_key(purl)
          candidates.concat(by_purl.fetch(key, []).map { |p| [p, "purl", key] }) if key
        end
        if record["source"] == "projects"
          [[data["repository_url"], "repository_url"], *data.fetch("aliases").map { |url| [url, "repository_alias"] }].each do |url, method|
            normalized = RepositoryUrl.key(url)
            candidates.concat(by_url.fetch(normalized, []).map { |p| [p, method, url] }) if normalized
          end
        end
        candidates.uniq.each do |package, method, value|
          matches << package.slice("registry", "purl", "repository_url").merge(
            "category" => record["source"], "science_id" => record["id"], "method" => method, "value" => value,
            "science_score" => data["science_score"] || data["repository_science_score"],
            "scientific_projects_count" => data["scientific_projects_count"], "evidence" => record["evidence"])
        end
      end
      membership = matches.group_by { |m| m.values_at("registry", "purl") }
      groups = SOURCES.keys.to_h do |source|
        selected = @packages.select { |p| membership.fetch(p.values_at("registry", "purl"), []).any? { |m| m["category"] == source } }
        [source, coverage(selected)]
      end
      unmatched = @packages.reject { |p| membership.key?(p.values_at("registry", "purl")) }
      matched_urls = matches.map { |m| m["repository_url"] }.compact.uniq
      unmatched_repositories = @repositories.values.reject { |r| matched_urls.include?(r["url"]) }
      sources = SOURCES.keys.to_h { |source| [source, @store.get("science:#{source}") || { "status" => "not_started" }] }
      complete = sources.values.all? { |s| s["status"] == "complete" }
      summary = { "reported_at" => captured_at, "cohort" => File.expand_path(cohort_path), "sources" => sources,
        "science_collection_complete" => complete, "all" => coverage(@packages), "groups" => groups,
        "#{complete ? 'not_matched' : 'not_matched_yet'}" => coverage(unmatched, repositories: unmatched_repositories) }
      directory = File.join(@store.path, "out")
      FileUtils.mkdir_p(directory)
      write_csv(File.join(directory, "science_matches.csv"), %w[registry purl repository_url category science_id method value science_score scientific_projects_count evidence], matches)
      rows = @packages.map do |p|
        categories = membership.fetch(p.values_at("registry", "purl"), []).map { |m| m["category"] }.uniq.sort
        p.merge("science_groups" => categories.empty? ? (complete ? "not_matched" : "not_matched_yet") : categories.join(";"),
          "current_commit_coverage" => p["repository_url"] ? @repositories.fetch(p["repository_url"])["current_commit_coverage"] : "no_repository")
      end
      write_csv(File.join(directory, "science_packages.csv"), %w[registry purl repository_url science_groups current_commit_coverage], rows)
      File.write(File.join(directory, "science_summary.json"), JSON.pretty_generate(summary) + "\n")
      @output.puts JSON.pretty_generate(summary)
    ensure
      cohort&.close
    end

    def coverage(packages, repositories: nil)
      repositories ||= packages.map { |p| p["repository_url"] }.compact.uniq.map { |url| @repositories.fetch(url) }
      releases = packages.map { |p| @releases[p.values_at("registry", "purl")] }
      { "packages" => packages.size, "repositories" => repositories.size,
        "packages_without_repository" => packages.count { |p| p["repository_url"].nil? },
        "current_commit_coverage" => repositories.map { |r| r["current_commit_coverage"] }.tally,
        "repository_coverage" => repositories.map { |r| r["coverage"] }.tally,
        "latest_release_tag_matching" => packages.zip(releases).map { |p, r| p["repository_url"].nil? ? "no_repository" : (r ? r["match_status"] : "unchecked") }.tally,
        "tag_target_revision_coverage" => releases.compact.select { |r| r["match_status"] == "matched" }.map { |r| r["target_status"] == "missing" ? "revision_not_found" : (r["target_status"] || "pending") }.tally,
        "annotated_release_coverage" => releases.compact.select { |r| r["release_swhid"] }.map { |r| r["release_status"] || "pending" }.tally }
    end

    def write_csv(path, columns, rows)
      @store.guard.check!
      CSV.open(path, "w") do |csv|
        csv << columns
        rows.each { |row| csv << columns.map { |column| row[column] } }
      end
    end

    def log(message)
      @output.puts "[#{Time.now.utc.iso8601}] #{message}"
      @output.flush
    end
  end
end
