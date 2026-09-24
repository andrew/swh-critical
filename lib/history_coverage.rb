require "set"
require_relative "clone_checks"

module SwhCritical
  class HistoryCoverage
    def initialize(store, output)
      @store, @output = store, output
      @git = CloneChecks.new(store, output)
    end

    def run(limit: 100, offline: false)
      objects = @store.db.execute("SELECT swhid, status, checked_at FROM objects").to_h { |row| [row["swhid"], row] }
      clones = @store.db.execute("SELECT value FROM metadata WHERE key LIKE 'clone_check:%' ORDER BY key").filter_map do |row|
        data = JSON.parse(row["value"])
        next unless data["status"] == "complete"

        evidence = JSON.parse(Zlib::GzipReader.open(File.join(@store.path, data.fetch("evidence_file")), &:read))
        next unless evidence.fetch("revisions").lines.any? { |sha| objects.dig("swh:1:rev:#{sha.strip}", "status") == "present" }

        [data, evidence]
      end
      @git.log("START history repositories=#{clones.size} limit=#{limit}")
      processed = 0
      clones.each do |data, evidence|
        url = data.fetch("url")
        known = evidence.fetch("revisions").lines.map do |sha|
          [sha.strip, objects["swh:1:rev:#{sha.strip}"]]
        end
        fingerprint = Digest::SHA256.hexdigest(JSON.generate(known))
        saved = @store.get("history_coverage:#{url}")
        next if saved && saved["status"] == "complete" && saved["known_fingerprint"] == fingerprint
        break if processed >= limit

        result = { "url" => url, "observed_at" => Time.now.utc.iso8601, "baseline_observed_at" => data["observed_at"] }
        @git.log("START history run=#{processed + 1} #{url}")
        begin
          relative = "history-evidence/#{Digest::SHA256.hexdigest(url)}.json.gz"
          path = File.join(@store.path, relative)
          if File.exist?(path)
            graph_data = JSON.parse(Zlib::GzipReader.open(path, &:read))
          else
            raise Error, "History graph not cached: #{url}" if offline

            graph_data = collect(data, evidence)
            @store.guard.check!
            FileUtils.mkdir_p(File.dirname(path))
            Zlib::GzipWriter.open(path) { |gzip| gzip.write(JSON.generate(graph_data)) }
          end
          result.merge!(analyze(graph_data, evidence, objects))
          result.merge!("status" => "complete", "evidence_file" => relative, "graph_observed_at" => graph_data["observed_at"],
            "known_fingerprint" => fingerprint)
        rescue DiskSpaceError
          raise
        rescue Error => error
          result.merge!("status" => "error", "error" => error.message)
        end
        @store.set("history_coverage:#{url}", result)
        processed += 1
        @git.log("RESULT history #{url} status=#{result['status']} pattern=#{result['pattern']} #{result['error']}")
        report
      end
      report
      @git.log("END history processed=#{processed}")
    end

    def collect(data, evidence)
      head = data.fetch("revision_swhid").delete_prefix("swh:1:rev:")
      raise Error, "Invalid saved HEAD" unless head.match?(/\A[0-9a-f]{40}\z/)

      @git.with_repository(data.fetch("url")) do |repository|
        raise Error, "Clone is shallow" unless @git.command("git", "-C", repository, "rev-parse", "--is-shallow-repository").strip == "false"

        graph = @git.command("git", "-C", repository, "log", "--all", head, "--format=%H%x09%ct%x09%P").lines.to_h do |line|
          sha, timestamp, parents = line.strip.split("\t", 3)
          [sha, { "committed_at" => Time.at(Integer(timestamp)).utc.iso8601, "parents" => parents.to_s.split }]
        end
        baseline = evidence.fetch("revisions").lines.map(&:strip)
        missing = baseline.reject { |sha| graph.key?(sha) }
        raise Error, "Fresh clone lacks #{missing.size} saved commits" unless missing.empty?

        { "observed_at" => Time.now.utc.iso8601, "head" => head,
          "current_head" => @git.command("git", "-C", repository, "rev-parse", "HEAD").strip,
          "commits" => graph.slice(*baseline) }
      end
    end

    def ancestors(graph, tip)
      found = Set.new
      pending = [tip]
      until pending.empty?
        sha = pending.pop
        next unless found.add?(sha)
        raise Error, "Missing parent commit #{sha}" unless graph.key?(sha)

        pending.concat(graph.fetch(sha).fetch("parents"))
      end
      found
    end

    def analyze(data, evidence, objects)
      graph = data.fetch("commits")
      head = data.fetch("head")
      statuses = graph.keys.to_h { |sha| [sha, objects.dig("swh:1:rev:#{sha}", "status") || "pending"] }
      ancestry = ancestors(graph, head)
      first_parent = []
      sha = head
      while sha
        first_parent << sha
        sha = graph.fetch(sha).fetch("parents").first
      end
      runs = first_parent.reverse.chunk { |commit| statuses.fetch(commit) }.map do |status, commits|
        { "status" => status, "count" => commits.size, "oldest_sha" => commits.first, "newest_sha" => commits.last,
          "oldest_committed_at" => graph.fetch(commits.first)["committed_at"], "newest_committed_at" => graph.fetch(commits.last)["committed_at"] }
      end
      nearest = first_parent.find { |commit| statuses.fetch(commit) == "present" }
      present = statuses.select { |_, status| status == "present" }.keys.to_set
      holes = present.flat_map do |commit|
        graph.fetch(commit).fetch("parents").filter_map { |parent| [commit, parent] if statuses[parent] == "missing" }
      end
      complete = statuses.values.all? { |status| %w[present missing].include?(status) }
      pattern = if !complete
        "incomplete"
      elsif nearest.nil?
        (present & ancestry).empty? ? "outside_head_ancestry_only" : "merged_history_only"
      elsif statuses.fetch(head) == "present"
        "head_present"
      elsif runs.map { |run| run["status"] } == %w[present missing]
        "continuous_older_first_parent_history"
      else
        "gaps_in_first_parent_history"
      end
      branches = evidence.fetch("refs").lines.filter_map do |line|
        tip, name = line.split
        next unless name.start_with?("refs/heads/") && graph.key?(tip)

        counts = ancestors(graph, tip).map { |commit| statuses.fetch(commit) }.tally
        { "name" => name, "tip" => tip, "tip_status" => statuses.fetch(tip), "coverage" => counts }
      end
      head_date = graph.fetch(head).fetch("committed_at")
      nearest_date = nearest && graph.fetch(nearest).fetch("committed_at")
      {
        "pattern" => pattern, "head" => head, "current_head" => data["current_head"], "head_committed_at" => head_date,
        "first_parent_count" => first_parent.size, "first_parent_present" => first_parent.count { |commit| statuses.fetch(commit) == "present" },
        "missing_tip_commits" => first_parent.take_while { |commit| statuses.fetch(commit) == "missing" }.size,
        "nearest_present_revision" => nearest && "swh:1:rev:#{nearest}", "nearest_present_committed_at" => nearest_date,
        "commit_date_gap_days" => nearest_date && ((Time.iso8601(head_date) - Time.iso8601(nearest_date)) / 86_400.0).round(1),
        "present_in_head_ancestry" => (present & ancestry).size, "present_outside_head_ancestry" => (present - ancestry).size,
        "present_to_missing_parent_edges" => holes.size, "missing_parent_examples" => holes.first(10),
        "first_parent_runs" => runs, "branches" => branches,
        "known_checked_at_min" => graph.keys.filter_map { |commit| objects.dig("swh:1:rev:#{commit}", "checked_at") }.min,
        "known_checked_at_max" => graph.keys.filter_map { |commit| objects.dig("swh:1:rev:#{commit}", "checked_at") }.max
      }
    end

    def report
      @store.guard.check!
      rows = @store.db.execute("SELECT value FROM metadata WHERE key LIKE 'history_coverage:%' ORDER BY key").map { |row| JSON.parse(row["value"]) }
      directory = File.join(@store.path, "out")
      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, "history_coverage.json"), JSON.pretty_generate(rows) + "\n")
      CSV.open(File.join(directory, "history_coverage.csv"), "w") do |csv|
        columns = %w[url status pattern head_committed_at first_parent_count first_parent_present missing_tip_commits nearest_present_revision nearest_present_committed_at commit_date_gap_days present_in_head_ancestry present_outside_head_ancestry present_to_missing_parent_edges baseline_observed_at graph_observed_at evidence_file error]
        csv << columns
        rows.each { |row| csv << columns.map { |column| row[column] } }
      end
    end
  end
end
