require_relative "store"

module SwhCritical
  class ReleaseGaps
    def self.rows(db)
      db.execute(<<~SQL).each do |row|
        SELECT r.url, r.coverage, r.origin_data, r.head_status, h.status AS head_coverage,
          MAX(CASE WHEN t.status = 'present' THEN 1 ELSE 0 END) AS target_present,
          MAX(CASE WHEN a.status = 'present' THEN 1 ELSE 0 END) AS release_present,
          MAX(CASE WHEN t.status = 'missing' THEN 1 ELSE 0 END) AS target_missing,
          MAX(CASE WHEN a.status = 'missing' THEN 1 ELSE 0 END) AS release_missing
        FROM repositories r LEFT JOIN objects h ON h.swhid = r.head_swhid
        JOIN packages p ON p.repository_url = r.url
        JOIN package_releases v ON v.registry = p.registry AND v.purl = p.purl
        LEFT JOIN objects t ON t.swhid = v.target_swhid
        LEFT JOIN objects a ON a.swhid = v.release_swhid
        WHERE v.match_status = 'matched'
        GROUP BY r.url
        HAVING MAX(CASE WHEN t.status = 'missing' OR a.status = 'missing' THEN 1 ELSE 0 END) = 1
        ORDER BY r.url
      SQL
        evidence = []
        evidence << "snapshot" if row["coverage"] == "snapshot_found"
        evidence << "head" if row["head_coverage"] == "present"
        evidence << "tag_target_revision" if row["target_present"] == 1
        evidence << "annotated_release" if row["release_present"] == 1
        row["archive_evidence"] = evidence
        row["archive_status"] = if evidence.any?
          "archived_evidence_found"
        elsif %w[origin_not_found no_snapshot].include?(row["coverage"])
          "no_snapshot_at_checked_origins"
        else
          "unresolved"
        end
      end
    end
  end
end
