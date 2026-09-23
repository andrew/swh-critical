require "sqlite3"
require "fileutils"
require "json"
require "time"
require "open3"

module SwhCritical
  class Error < StandardError; end
  class DiskSpaceError < Error; end

  class DiskGuard
    def initialize(path, minimum_bytes: 5 * 1024**3)
      @path = path
      @minimum_bytes = minimum_bytes
    end

    def check!
      output, status = Open3.capture2("df", "-Pk", @path)
      raise Error, "Cannot determine free disk space" unless status.success?

      free = Integer(output.lines.last.split[3]) * 1024
      raise DiskSpaceError, "Disk guard: #{free} bytes free, #{@minimum_bytes} required" if free < @minimum_bytes

      free
    end
  end

  class Store
    attr_reader :db, :path, :guard

    def initialize(path, minimum_bytes: 5 * 1024**3)
      @path = File.expand_path(path)
      FileUtils.mkdir_p(@path)
      @guard = DiskGuard.new(@path, minimum_bytes: minimum_bytes)
      @guard.check!
      @db = SQLite3::Database.new(File.join(@path, "investigation.sqlite3"))
      @db.results_as_hash = true
      @db.busy_timeout = 5000
      @db.execute_batch <<~SQL
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS registries (
          name TEXT PRIMARY KEY, ecosystem TEXT, next_url TEXT,
          status TEXT NOT NULL DEFAULT 'unchecked', error TEXT
        );
        CREATE TABLE IF NOT EXISTS repositories (
          url TEXT PRIMARY KEY, host TEXT NOT NULL,
          coverage TEXT NOT NULL DEFAULT 'unchecked', origin_data TEXT,
          head_status TEXT NOT NULL DEFAULT 'unchecked', head_data TEXT, head_swhid TEXT
        );
        CREATE TABLE IF NOT EXISTS aliases (
          repository_url TEXT NOT NULL, url TEXT NOT NULL, source TEXT NOT NULL,
          PRIMARY KEY (repository_url, url)
        );
        CREATE TABLE IF NOT EXISTS packages (
          purl TEXT NOT NULL, registry TEXT NOT NULL, name TEXT NOT NULL, ecosystem TEXT,
          original_url TEXT, repository_url TEXT, fetched_at TEXT NOT NULL,
          PRIMARY KEY (registry, purl)
        );
        CREATE INDEX IF NOT EXISTS packages_repository ON packages(repository_url);
        CREATE TABLE IF NOT EXISTS objects (
          swhid TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'pending',
          checked_at TEXT, evidence TEXT, error TEXT
        );
        CREATE INDEX IF NOT EXISTS objects_status ON objects(status);
        CREATE INDEX IF NOT EXISTS repositories_coverage ON repositories(coverage);
        CREATE INDEX IF NOT EXISTS repositories_head_status ON repositories(head_status);
      SQL
      set("created_at", Time.now.utc.iso8601) unless get("created_at")
    end

    def get(key)
      value = @db.get_first_value("SELECT value FROM metadata WHERE key = ?", [key])
      JSON.parse(value) if value
    end

    def set(key, value)
      @db.execute("INSERT INTO metadata VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, JSON.generate(value)])
    end

    def close
      @db.close
    end
  end
end
