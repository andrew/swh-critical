require "csv"
require_relative "store"
require_relative "release_gaps"

module SwhCritical
  class Report
    def initialize(store, output)
      @store, @output = store, output
      @db = store.db
    end

    def run
      @store.guard.check!
      directory = File.join(@store.path, "out")
      FileUtils.mkdir_p(directory)
      summary = {
        "created_at" => @store.get("created_at"), "reported_at" => Time.now.utc.iso8601,
        "registries_discovered" => @store.get("registries_complete") == true,
        "registries" => counts("SELECT status, COUNT(*) AS count FROM registries GROUP BY status"),
        "packages" => @db.get_first_value("SELECT COUNT(*) FROM packages"),
        "packages_without_repository" => @db.get_first_value("SELECT COUNT(*) FROM packages WHERE repository_url IS NULL"),
        "packages_with_recovered_repository" => @db.get_first_value("SELECT COUNT(*) FROM repository_recoveries"),
        "repositories" => @db.get_first_value("SELECT COUNT(*) FROM repositories"),
        "repository_coverage" => counts("SELECT coverage AS status, COUNT(*) AS count FROM repositories GROUP BY coverage"),
        "current_commit_coverage" => counts(<<~SQL),
          SELECT CASE WHEN r.head_status = 'observed' THEN COALESCE(o.status, 'pending') ELSE r.head_status END AS status,
            COUNT(*) AS count FROM repositories r LEFT JOIN objects o ON o.swhid = r.head_swhid GROUP BY 1
        SQL
        "missing_heads_repository_coverage" => counts(<<~SQL),
          SELECT r.coverage AS status, COUNT(*) AS count FROM repositories r
          JOIN objects o ON o.swhid = r.head_swhid
          WHERE r.head_status = 'observed' AND o.status = 'missing' GROUP BY r.coverage
        SQL
        "distinct_objects" => counts("SELECT status, COUNT(*) AS count FROM objects GROUP BY status")
      }
      summary["latest_release_tag_matching"] = counts(<<~SQL)
        SELECT CASE WHEN p.repository_url IS NULL THEN 'no_repository' ELSE COALESCE(v.match_status, 'unchecked') END AS status,
          COUNT(*) AS count FROM packages p LEFT JOIN package_releases v ON v.registry = p.registry AND v.purl = p.purl GROUP BY 1
      SQL
      summary["tag_target_revision_coverage"] = counts(<<~SQL)
        SELECT CASE WHEN o.status = 'missing' THEN 'revision_not_found' ELSE COALESCE(o.status, 'pending') END AS status,
          COUNT(*) AS count FROM package_releases v LEFT JOIN objects o ON o.swhid = v.target_swhid
          WHERE v.match_status = 'matched' GROUP BY 1
      SQL
      summary["annotated_release_coverage"] = counts(<<~SQL)
        SELECT COALESCE(o.status, 'pending') AS status, COUNT(*) AS count FROM package_releases v
          LEFT JOIN objects o ON o.swhid = v.release_swhid WHERE v.release_swhid IS NOT NULL GROUP BY 1
      SQL
      summary["cohort_complete"] = summary["registries_discovered"] && @db.get_first_value("SELECT COUNT(*) FROM registries WHERE status != 'complete'").zero?
      gaps = ReleaseGaps.rows(@db)
      summary["release_gap_repositories"] = {
        "repositories" => gaps.size, "archive_status" => gaps.map { |r| r["archive_status"] }.tally,
        "repository_coverage" => gaps.map { |r| r["coverage"] }.tally,
        "missing_tag_target_revision" => gaps.count { |r| r["target_missing"] == 1 },
        "missing_annotated_release" => gaps.count { |r| r["release_missing"] == 1 }
      }
      CSV.open(File.join(directory, "release_gap_repositories.csv"), "w") do |csv|
        columns = %w[url archive_status archive_evidence coverage head_status head_coverage target_missing release_missing origin_data]
        csv << columns
        gaps.each { |row| csv << columns.map { |column| column == "archive_evidence" ? JSON.generate(row[column]) : row[column] } }
      end
      write_csv(File.join(directory, "repositories.csv"), %w[url host packages coverage head_status current_commit_coverage head_swhid origin_data head_data], <<~SQL)
        SELECT r.url, r.host, COUNT(p.purl) AS packages, r.coverage, r.head_status,
          CASE WHEN r.head_status = 'observed' THEN COALESCE(o.status, 'pending') ELSE r.head_status END AS current_commit_coverage,
          r.head_swhid, r.origin_data, r.head_data
        FROM repositories r LEFT JOIN packages p ON p.repository_url = r.url
        LEFT JOIN objects o ON o.swhid = r.head_swhid GROUP BY r.url ORDER BY r.url
      SQL
      write_csv(File.join(directory, "packages.csv"), %w[purl registry name ecosystem original_url repository_url fetched_at], "SELECT * FROM packages ORDER BY registry, purl")
      write_csv(File.join(directory, "repository_recoveries.csv"), %w[registry purl evidence], "SELECT * FROM repository_recoveries ORDER BY registry, purl")
      write_csv(File.join(directory, "release_tags.csv"), %w[registry purl repository_url version match_status tag_name target_revision_coverage annotated_release_coverage target_swhid release_swhid metadata_evidence match_data], <<~SQL)
        SELECT v.*, p.repository_url,
          CASE WHEN target.status = 'missing' THEN 'revision_not_found' ELSE target.status END AS target_revision_coverage,
          release.status AS annotated_release_coverage
        FROM package_releases v JOIN packages p ON p.registry = v.registry AND p.purl = v.purl
        LEFT JOIN objects target ON target.swhid = v.target_swhid
        LEFT JOIN objects release ON release.swhid = v.release_swhid ORDER BY v.registry, v.purl
      SQL
      write_csv(File.join(directory, "registries.csv"), %w[name ecosystem status packages repositories packages_without_repository next_url error], <<~SQL)
        SELECT r.name, r.ecosystem, r.status, COUNT(p.purl) AS packages,
          COUNT(DISTINCT p.repository_url) AS repositories,
          SUM(CASE WHEN p.purl IS NOT NULL AND p.repository_url IS NULL THEN 1 ELSE 0 END) AS packages_without_repository,
          r.next_url, r.error FROM registries r LEFT JOIN packages p ON p.registry = r.name
        GROUP BY r.name ORDER BY r.name
      SQL
      text = JSON.pretty_generate(summary)
      File.write(File.join(directory, "summary.json"), text + "\n")
      @output.puts text
    end

    def counts(sql)
      @db.execute(sql).to_h { |row| [row["status"], row["count"]] }
    end

    def write_csv(path, columns, sql)
      CSV.open(path, "w") do |csv|
        csv << columns
        @db.execute(sql) { |row| csv << columns.map { |column| row[column] } }
      end
    end
  end
end
