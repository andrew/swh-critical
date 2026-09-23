require "timeout"
require_relative "store"

module SwhCritical
  class Heads
    def initialize(store, output)
      @store, @output = store, output
      @db = store.db
    end

    def run(limit: 100)
      rows = @db.execute("SELECT url, head_status FROM repositories WHERE head_status IN ('unchecked', 'unknown') ORDER BY (host = 'github.com') DESC, url LIMIT ?", [limit])
      total = @db.get_first_value("SELECT COUNT(*) FROM repositories")
      observed = @db.get_first_value("SELECT COUNT(*) FROM repositories WHERE head_status = 'observed'")
      unknown = @db.get_first_value("SELECT COUNT(*) FROM repositories WHERE head_status = 'unknown'")
      log("START heads data=#{@store.path} selected=#{rows.size} observed=#{observed}/#{total} unknown=#{unknown}")
      rows.each_with_index do |row, index|
        @store.guard.check!
        repository = row.fetch("url")
        data = { "observed_at" => Time.now.utc.iso8601, "url" => repository }
        begin
          stdout = command(repository)
          sha = stdout[/^([0-9a-f]{40})\tHEAD$/, 1]
          branch = stdout[/^ref: (refs\/heads\/[^\s]+)\tHEAD$/, 1]
          raise Error, "No SHA-1 HEAD returned" unless sha

          swhid = "swh:1:rev:#{sha}"
          data.merge!("commit" => sha, "branch" => branch, "stdout" => stdout)
          @db.transaction do
            @db.execute("INSERT OR IGNORE INTO objects(swhid) VALUES (?)", [swhid])
            @db.execute("UPDATE repositories SET head_status = 'observed', head_data = ?, head_swhid = ? WHERE url = ?", [JSON.generate(data), swhid, repository])
          end
          observed += 1
          unknown -= 1 if row["head_status"] == "unknown"
          log("RESULT heads run=#{index + 1}/#{rows.size} observed=#{observed}/#{total} unknown=#{unknown} #{repository}: #{sha}")
        rescue Error => error
          data["error"] = error.message
          @db.execute("UPDATE repositories SET head_status = 'unknown', head_data = ? WHERE url = ?", [JSON.generate(data), repository])
          unknown += 1 unless row["head_status"] == "unknown"
          log("RESULT heads run=#{index + 1}/#{rows.size} observed=#{observed}/#{total} unknown=#{unknown} #{repository}: #{error.message}")
        end
      end
      log("END heads observed=#{observed}/#{total} unknown=#{unknown}")
    end

    def log(message)
      @output.puts "[#{Time.now.utc.iso8601}] #{message.gsub(/[\r\n\t]+/, ' ')}"
      @output.flush
    end

    def command(url, refs: ["HEAD"], maximum_bytes: 65_536)
      output = +""
      env = { "GIT_TERMINAL_PROMPT" => "0", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL }
      Open3.popen2e(env, "git", "-c", "credential.helper=", "ls-remote", "--symref", "--", url, *refs, pgroup: true) do |input, stream, process|
        input.close
        begin
          Timeout.timeout(60) do
            loop do
              chunk = stream.readpartial(4096)
              raise Error, "Git output limit reached" if output.bytesize + chunk.bytesize > maximum_bytes
              output << chunk
            rescue EOFError
              break
            end
            raise Error, "git ls-remote failed: #{output.scrub[0, 500]}" unless process.value.success?
          end
        rescue Timeout::Error
          raise Error, "git ls-remote timed out"
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
      raise Error, error.message
    end
  end
end
