require "tmpdir"
require "csv"
require "zlib"
require "digest"
require "uri"
require_relative "release_gaps"

module SwhCritical
  class CloneChecks
    def initialize(store, output, swhid: "swhid")
      @store, @output, @swhid = store, output, swhid
    end

    def run(limit: 100)
      rows = ReleaseGaps.rows(@store.db).select do |row|
        row["archive_status"] == "no_snapshot_at_checked_origins" && @store.get("clone_check:#{row['url']}")&.fetch("status", nil) != "complete"
      end.first(limit)
      version = command(@swhid, "version").strip
      log("START clones selected=#{rows.size} tool=#{version}")
      rows.each_with_index do |row, index|
        url = row.fetch("url")
        data = { "url" => url, "observed_at" => Time.now.utc.iso8601, "tool_version" => version, "cloned" => false }
        log("START clone run=#{index + 1}/#{rows.size} #{url}")
        begin
          with_repository(url) do |repository|
            data["cloned"] = true
            raise Error, "Clone is shallow" unless command("git", "-C", repository, "rev-parse", "--is-shallow-repository").strip == "false"
            head = command("git", "-C", repository, "rev-parse", "HEAD").strip
            data["snapshot_swhid"] = identifier("snapshot", repository, "snp")
            data["revision_swhid"] = identifier("revision", repository, "rev")
            raise Error, "Generated revision SWHID differs from Git HEAD" unless data["revision_swhid"] == "swh:1:rev:#{head}"
            data["clone_bytes"] = Integer(command("du", "-sk", repository).split.first) * 1024
            refs = command("git", "-C", repository, "show-ref", "--head", "--dereference")
            revisions = command("git", "-C", repository, "rev-list", "--all")
            data["commit_count"] = revisions.lines.size
            relative = "clone-evidence/#{Digest::SHA256.hexdigest(url)}.json.gz"
            @store.guard.check!
            FileUtils.mkdir_p(File.join(@store.path, "clone-evidence"))
            Zlib::GzipWriter.open(File.join(@store.path, relative)) do |gzip|
              gzip.write(JSON.generate(data.merge("refs" => refs, "revisions" => revisions)))
            end
            data.merge!("status" => "complete", "evidence_file" => relative)
          end
        rescue DiskSpaceError
          raise
        rescue Error => error
          data.merge!("status" => "error", "error" => error.message)
        end
        @store.set("clone_check:#{url}", data)
        log("RESULT clone run=#{index + 1}/#{rows.size} #{url} status=#{data['status']} cloned=#{data['cloned']} #{data['snapshot_swhid'] || data['error']}")
        report
      end
      report
      log("END clones processed=#{rows.size}")
    end

    def identifier(kind, repository, type)
      value = command(@swhid, kind, "--format", "raw", repository).strip
      raise Error, "Invalid #{kind} SWHID output" unless value.match?(/\Aswh:1:#{type}:[0-9a-f]{40}\z/)

      value
    end

    def with_repository(url)
      parts = URI(url).path.split("/").reject(&:empty?)
      candidates = [File.join(Dir.home, "code", *parts.last(2)), File.join(Dir.home, "code", parts.last)]
      existing = candidates.find { |path| File.exist?(path) }
      raise Error, "Existing checkout needs review before a fresh clone: #{existing}" if existing

      @store.guard.check!
      root = File.join(@store.path, "clone-tmp")
      FileUtils.mkdir_p(root)
      Dir.mktmpdir("repository-", root) do |temporary|
        repository = File.join(temporary, "repository.git")
        command("git", "-c", "credential.helper=", "clone", "--mirror", "--quiet", "--no-local", "--", url, repository)
        yield repository
      end
    end

    def command(*args)
      output = +""
      errors = +""
      env = { "GIT_TERMINAL_PROMPT" => "0", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      checked = started - 1
      logged = started
      Open3.popen3(env, *args, pgroup: true) do |input, stdout, stderr, process|
        input.close
        streams = { stdout => output, stderr => errors }
        begin
          until streams.empty?
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise Error, "Command timed out after 600 seconds: #{args.first}" if now - started > 600
            if now - checked >= 1
              @store.guard.check!
              checked = now
            end
            if now - logged >= 30
              log("PROGRESS clone command=#{File.basename(args.first)} elapsed=#{(now - started).to_i}s")
              logged = now
            end
            ready = IO.select(streams.keys, nil, nil, 0.2)
            next unless ready

            ready.first.each do |stream|
              begin
                streams.fetch(stream) << stream.readpartial(16_384)
              rescue EOFError
                streams.delete(stream)
              end
            end
            raise Error, "Command output exceeds 32 MiB" if output.bytesize + errors.bytesize > 32 * 1024**2
          end
          raise Error, "#{args.first} failed: #{(errors + output).scrub[0, 2000]}" unless process.value.success?
        ensure
          if process.alive?
            begin
              Process.kill("KILL", -process.pid)
            rescue Errno::ESRCH
              nil
            end
            process.join
          end
        end
      end
      output
    rescue SystemCallError => error
      raise Error, "#{error.class}: #{error.message}"
    end

    def report
      @store.guard.check!
      directory = File.join(@store.path, "out")
      FileUtils.mkdir_p(directory)
      rows = @store.db.execute("SELECT value FROM metadata WHERE key LIKE 'clone_check:%' ORDER BY key").map { |row| JSON.parse(row["value"]) }
      CSV.open(File.join(directory, "clone_checks.csv"), "w") do |csv|
        columns = %w[url status cloned snapshot_swhid revision_swhid commit_count clone_bytes observed_at tool_version evidence_file error]
        csv << columns
        rows.each { |row| csv << columns.map { |column| row[column] } }
      end
    end

    def log(message)
      @output.puts "[#{Time.now.utc.iso8601}] #{message.gsub(/[\r\n\t]+/, ' ')}"
      @output.flush
    end
  end
end
