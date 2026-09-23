require "optparse"
require "dotenv"
require_relative "collector"
require_relative "origins"
require_relative "heads"
require_relative "known"
require_relative "report"

module SwhCritical
  class CLI
    def self.run(argv, out: $stdout, err: $stderr, env_file: File.expand_path("../.env", __dir__))
      Dotenv.load(env_file)
      options = { data: "data/default", limit: nil, registries: [], per_page: 100, pages_per_registry: nil, minimum_gib: 5.0, offline: false, missing_heads: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby swh-critical.rb COMMAND [options]\nCommands: collect, origins, heads, known, report"
        opts.on("--data PATH", "Investigation directory; use a new path for a fresh cohort") { |value| options[:data] = value }
        opts.on("--limit N", Integer, "Maximum repositories or identifiers this invocation") { |value| options[:limit] = value }
        opts.on("--registry NAME", "Restrict collection; repeat for multiple registries") { |value| options[:registries] << value }
        opts.on("--per-page N", Integer, "Packages per page (1..100)") { |value| options[:per_page] = value }
        opts.on("--pages-per-registry N", Integer, "Collection page limit per registry for a pilot") { |value| options[:pages_per_registry] = value }
        opts.on("--min-free-gib N", Float, "Minimum free disk space (default: 5)") { |value| options[:minimum_gib] = value }
        opts.on("--offline", "Use cached HTTP responses only") { options[:offline] = true }
        opts.on("--missing-heads", "Origins: check only repositories whose observed HEAD is missing from SWH") { options[:missing_heads] = true }
        opts.on("--help") { out.puts opts; return 0 }
      end
      args = argv.dup
      parser.parse!(args)
      command = args.shift
      raise Error, parser.to_s unless %w[collect origins heads known report].include?(command) && args.empty?
      raise Error, "Limits must be positive" if [options[:limit], options[:pages_per_registry]].compact.any? { |n| n <= 0 }
      raise Error, "per-page must be between 1 and 100" unless (1..100).cover?(options[:per_page])
      raise Error, "min-free-gib must be finite and nonnegative" unless options[:minimum_gib].finite? && options[:minimum_gib] >= 0
      raise Error, "heads requires network access; omit --offline" if command == "heads" && options[:offline]
      raise Error, "--missing-heads requires the origins command" if options[:missing_heads] && command != "origins"

      FileUtils.mkdir_p(options[:data])
      lock = File.open(File.join(options[:data], ".lock"), "a")
      raise Error, "Another command is using this investigation directory" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      store = Store.new(options[:data], minimum_bytes: (options[:minimum_gib] * 1024**3).to_i)
      http = Http.new(store, offline: options[:offline])
      case command
      when "collect"
        Collector.new(store, http, out).run(registries: options[:registries], per_page: options[:per_page], pages_per_registry: options[:pages_per_registry])
        return 1 if store.db.get_first_value("SELECT COUNT(*) FROM registries WHERE status = 'error'").positive?
      when "origins"
        Origins.new(store, http, out).run(limit: options[:limit] || 100, missing_heads: options[:missing_heads])
      when "heads"
        Heads.new(store, out).run(limit: options[:limit] || 100)
      when "known"
        Known.new(store, http, out).run(limit: options[:limit] || 1000)
      when "report"
        Report.new(store, out).run
      end
      0
    rescue RateLimited => error
      err.puts "[#{Time.now.utc.iso8601}] Paused: #{error.message}. Rerun the same command after that time."
      75
    rescue Error, OptionParser::ParseError, SQLite3::Exception, SystemCallError => error
      err.puts "[#{Time.now.utc.iso8601}] Error: #{error.message}"
      1
    rescue Interrupt
      err.puts "[#{Time.now.utc.iso8601}] Interrupted. Completed records are saved; rerun to resume."
      130
    ensure
      store&.close
      lock&.close
    end
  end
end
