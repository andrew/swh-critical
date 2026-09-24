require "optparse"
require "dotenv"
require_relative "collector"
require_relative "origins"
require_relative "heads"
require_relative "known"
require_relative "report"
require_relative "recovery"
require_relative "tags"
require_relative "science"
require_relative "clone_checks"
require_relative "clone_known"
require_relative "history_coverage"
require_relative "origin_search"
require_relative "trace_origins"
require_relative "package_contents"
require_relative "candidate_origins"
require_relative "content_coverage"
require_relative "origin_contents"
require_relative "restore"
require_relative "freshness"
require_relative "extrinsic_metadata"

module SwhCritical
  class CLI
    def self.run(argv, out: $stdout, err: $stderr, env_file: File.expand_path("../.env", __dir__))
      Dotenv.load(env_file)
      options = { data: "data/default", limit: nil, registries: [], per_page: 100, pages_per_registry: nil, minimum_gib: 5.0, offline: false, missing_heads: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby swh-critical.rb COMMAND [options]\nCommands: collect, origins, heads, tags, known, recover, report, freshness, science, science-report, clones, clone-known, history, origin-search, trace, package-contents, origin-candidates, contents, origin-contents, restore, extrinsic-metadata"
        opts.on("--data PATH", "Investigation directory; use a new path for a fresh cohort") { |value| options[:data] = value }
        opts.on("--limit N", Integer, "Maximum repositories, identifiers, or science pages per source") { |value| options[:limit] = value }
        opts.on("--registry NAME", "Restrict collection; repeat for multiple registries") { |value| options[:registries] << value }
        opts.on("--package NAME", "Restore: package name in the selected registry") { |value| options[:package] = value }
        opts.on("--package-version VERSION", "Restore: version (default: latest in ecosyste.ms)") { |value| options[:package_version] = value }
        opts.on("--per-page N", Integer, "Records per page (1..100; science packages up to 1000)") { |value| options[:per_page] = value }
        opts.on("--cohort PATH", "Science report: read-only coverage investigation") { |value| options[:cohort] = value }
        opts.on("--swhid PATH", "Clones, package-contents or contents: swhid executable") { |value| options[:swhid] = value }
        opts.on("--repositories PATH", "Trace or content investigation: repository URLs, one per line") { |value| options[:repositories] = value }
        opts.on("--targets PATH", "Extrinsic metadata: core SWHIDs, one per line") { |value| options[:targets] = value }
        opts.on("--pages-per-registry N", Integer, "Collection page limit per registry for a pilot") { |value| options[:pages_per_registry] = value }
        opts.on("--min-free-gib N", Float, "Minimum free disk space (default: 5)") { |value| options[:minimum_gib] = value }
        opts.on("--offline", "Use cached HTTP responses only") { options[:offline] = true }
        opts.on("--missing-heads", "Origins: check only repositories whose observed HEAD is missing from SWH") { options[:missing_heads] = true }
        opts.on("--missing-releases", "Origins: check release gaps without other archival evidence") { options[:missing_releases] = true }
        opts.on("--mappings PATH", "Recover: CSV of verified repository links and evidence") { |value| options[:mappings] = value }
        opts.on("--help") { out.puts opts; return 0 }
      end
      args = argv.dup
      parser.parse!(args)
      command = args.shift
      raise Error, parser.to_s unless %w[collect origins heads tags known recover report freshness science science-report clones clone-known history origin-search trace package-contents origin-candidates contents origin-contents restore extrinsic-metadata].include?(command) && args.empty?
      raise Error, "extrinsic-metadata requires --targets" if command == "extrinsic-metadata" && !options[:targets]
      raise Error, "--targets requires extrinsic-metadata" if options[:targets] && command != "extrinsic-metadata"
      raise Error, "restore requires one --registry and --package" if command == "restore" && (options[:registries].size != 1 || !options[:package])
      raise Error, "--package and --package-version require restore" if command != "restore" && (options[:package] || options[:package_version])
      raise Error, "#{command} requires --repositories" if %w[trace origin-candidates contents origin-contents].include?(command) && !options[:repositories]
      raise Error, "--repositories requires trace, origin-candidates, contents or origin-contents" if options[:repositories] && !%w[trace origin-candidates contents origin-contents].include?(command)
      raise Error, "--swhid requires clones, package-contents or contents" if options[:swhid] && !%w[clones package-contents contents].include?(command)
      raise Error, "clones requires network access; omit --offline" if command == "clones" && options[:offline]
      raise Error, "Limits must be positive" if [options[:limit], options[:pages_per_registry]].compact.any? { |n| n <= 0 }
      maximum_page = command == "science" ? 1000 : 100
      raise Error, "per-page must be between 1 and #{maximum_page}" unless (1..maximum_page).cover?(options[:per_page])
      raise Error, "science-report requires --cohort" if command == "science-report" && !options[:cohort]
      raise Error, "--cohort requires science-report" if options[:cohort] && command != "science-report"
      raise Error, "min-free-gib must be finite and nonnegative" unless options[:minimum_gib].finite? && options[:minimum_gib] >= 0
      raise Error, "heads requires network access; omit --offline" if command == "heads" && options[:offline]
      raise Error, "--missing-heads requires the origins command" if options[:missing_heads] && command != "origins"
      raise Error, "--missing-releases requires the origins command" if options[:missing_releases] && command != "origins"
      raise Error, "Choose either --missing-heads or --missing-releases" if options[:missing_heads] && options[:missing_releases]
      raise Error, "recover requires --mappings" if command == "recover" && !options[:mappings]
      raise Error, "--mappings requires the recover command" if options[:mappings] && command != "recover"

      FileUtils.mkdir_p(options[:data])
      lock = File.open(File.join(options[:data], ".lock"), "a")
      raise Error, "Another command is using this investigation directory" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      store = Store.new(options[:data], minimum_bytes: (options[:minimum_gib] * 1024**3).to_i)
      http = Http.new(store, offline: options[:offline], output: err)
      case command
      when "collect"
        Collector.new(store, http, out).run(registries: options[:registries], per_page: options[:per_page], pages_per_registry: options[:pages_per_registry])
        return 1 if store.db.get_first_value("SELECT COUNT(*) FROM registries WHERE status = 'error'").positive?
      when "origins"
        Origins.new(store, http, out).run(limit: options[:limit] || 100, missing_heads: options[:missing_heads], missing_releases: options[:missing_releases])
      when "heads"
        Heads.new(store, out).run(limit: options[:limit] || 100)
      when "tags"
        Tags.new(store, out, offline: options[:offline]).run(limit: options[:limit] || 100)
      when "known"
        Known.new(store, http, out).run(limit: options[:limit] || 1000)
      when "report"
        Report.new(store, out).run
      when "freshness"
        Freshness.new(store, out).run
      when "extrinsic-metadata"
        ExtrinsicMetadata.new(store, http, out).run(File.readlines(options[:targets], chomp: true).map(&:strip).reject(&:empty?), limit: options[:limit] || 100)
      when "recover"
        Recovery.new(store, out).run(options[:mappings])
      when "science"
        Science.new(store, http, out).run(per_page: options[:per_page], limit: options[:limit])
      when "science-report"
        Science.new(store, http, out).report(options[:cohort])
      when "clones"
        CloneChecks.new(store, out, swhid: options[:swhid] || "swhid").run(limit: options[:limit] || 100)
      when "clone-known"
        CloneKnown.new(store, http, out).run(limit: options[:limit] || 1000)
      when "history"
        HistoryCoverage.new(store, out).run(limit: options[:limit] || 100, offline: options[:offline])
      when "origin-search"
        OriginSearch.new(store, http, out).run(limit: options[:limit] || 100)
      when "trace"
        TraceOrigins.new(store, http, out).run(File.readlines(options[:repositories], chomp: true).reject(&:empty?).uniq.first(options[:limit] || 100))
      when "package-contents"
        PackageContents.new(store, http, out, swhid: options[:swhid] || "swhid").run(limit: options[:limit] || 100, offline: options[:offline])
      when "origin-candidates"
        CandidateOrigins.new(store, http, out).run(File.readlines(options[:repositories], chomp: true).reject(&:empty?).uniq.first(options[:limit] || 100))
      when "contents"
        ContentCoverage.new(store, http, out, swhid: options[:swhid] || "swhid").run(
          File.readlines(options[:repositories], chomp: true).reject(&:empty?).uniq.first(options[:limit] || 100), offline: options[:offline])
      when "origin-contents"
        OriginContents.new(store, http, out).run(File.readlines(options[:repositories], chomp: true).reject(&:empty?).uniq.first(options[:limit] || 100))
      when "restore"
        Restore.new(store, http, out).run(registry: options[:registries].first, name: options[:package], version: options[:package_version])
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
