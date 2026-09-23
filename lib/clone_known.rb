require "csv"
require "zlib"
require_relative "known"

module SwhCritical
  class CloneKnown
    def initialize(store, http, output)
      @store, @http, @output = store, http, output
    end

    def run(limit: 1000)
      repositories = @store.db.execute("SELECT value FROM metadata WHERE key LIKE 'clone_check:%' ORDER BY key").filter_map do |row|
        data = JSON.parse(row.fetch("value"))
        next unless data["status"] == "complete"

        evidence = JSON.parse(Zlib::GzipReader.open(File.join(@store.path, data.fetch("evidence_file")), &:read))
        revisions = evidence.fetch("revisions").lines.map { |sha| "swh:1:rev:#{sha.strip}" }.uniq
        snapshot = data.fetch("snapshot_swhid")
        unless snapshot.match?(/\Aswh:1:snp:[0-9a-f]{40}\z/) && revisions.all? { |id| id.match?(/\Aswh:1:rev:[0-9a-f]{40}\z/) }
          raise Error, "Invalid clone identifiers: #{data.fetch('url')}"
        end
        { "url" => data.fetch("url"), "snapshot_swhid" => snapshot, "revisions" => revisions }
      end
      identifiers = (repositories.map { |r| r["snapshot_swhid"] } + repositories.flat_map { |r| r["revisions"] }).uniq
      @store.guard.check!
      @store.db.transaction do
        identifiers.each { |id| @store.db.execute("INSERT OR IGNORE INTO objects(swhid) VALUES (?)", [id]) }
      end
      statuses = @store.db.execute("SELECT swhid, status FROM objects").to_h { |row| row.values_at("swhid", "status") }
      pending = identifiers.select { |id| %w[pending unknown].include?(statuses.fetch(id)) }.first(limit)
      begin
        Known.new(@store, @http, @output).check(pending)
      ensure
        report(repositories, identifiers)
      end
    end

    def report(repositories, identifiers)
      @store.guard.check!
      objects = @store.db.execute("SELECT swhid, status, checked_at FROM objects").to_h { |row| [row["swhid"], row] }
      rows = repositories.map do |repository|
        revisions = repository.fetch("revisions")
        counts = revisions.map { |id| objects.fetch(id).fetch("status") }.tally
        snapshot_status = objects.fetch(repository.fetch("snapshot_swhid")).fetch("status")
        found = snapshot_status == "present" || counts.fetch("present", 0).positive?
        complete = ([snapshot_status] + counts.keys).all? { |status| %w[present missing].include?(status) }
        repository.reject { |key, _| key == "revisions" }.merge(
          "snapshot_status" => snapshot_status, "revision_count" => revisions.size,
          "revisions_present" => counts.fetch("present", 0), "revisions_missing" => counts.fetch("missing", 0),
          "revisions_pending" => counts.fetch("pending", 0), "revisions_unknown" => counts.fetch("unknown", 0),
          "archive_evidence" => found ? "found" : (complete ? "none_in_checked_objects" : "incomplete"),
          "checks_complete" => complete, "present_revision_example" => revisions.find { |id| objects.fetch(id)["status"] == "present" })
      end
      directory = File.join(@store.path, "out")
      FileUtils.mkdir_p(directory)
      CSV.open(File.join(directory, "clone_known.csv"), "w") do |csv|
        columns = %w[url snapshot_swhid snapshot_status revision_count revisions_present revisions_missing revisions_pending revisions_unknown archive_evidence checks_complete present_revision_example]
        csv << columns
        rows.each { |row| csv << columns.map { |column| row[column] } }
      end
      summary = {
        "reported_at" => Time.now.utc.iso8601, "repositories" => rows.size,
        "repository_evidence" => rows.map { |row| row["archive_evidence"] }.tally,
        "repositories_checks_complete" => rows.count { |row| row["checks_complete"] },
        "snapshots" => identifiers.grep(/\Aswh:1:snp:/).map { |id| objects.fetch(id)["status"] }.tally,
        "revisions" => identifiers.grep(/\Aswh:1:rev:/).map { |id| objects.fetch(id)["status"] }.tally
      }
      File.write(File.join(directory, "clone_known_summary.json"), JSON.pretty_generate(summary) + "\n")
      @output.puts JSON.generate(summary)
    end
  end
end
