require "net/http"
require "uri"
require "digest"
require "zlib"
require_relative "store"

module SwhCritical
  class RateLimited < Error; end
  class ResponseTooLarge < Error; end

  class Http
    PACKAGES = "https://packages.ecosyste.ms/api/v1"
    SWH = "https://archive.softwareheritage.org/api/1"
    SCIENCE = "https://science.ecosyste.ms/api/v1"
    MAX_RESPONSE_BYTES = 32 * 1024**2
    TIMEOUT_RETRY_DELAYS = [5, 15, 30].freeze

    def initialize(store, offline: false, output: $stderr)
      @store = store
      @offline = offline
      @output = output
      @cache = File.join(store.path, "cache")
      FileUtils.mkdir_p(@cache)
    end

    def request(method, url, body: nil, raw: false)
      uri = URI(url)
      content_bytes = method == :get && uri.host == "archive.softwareheritage.org" && uri.path.match?(%r{\A/api/1/content/sha1_git:[0-9a-f]{40}/raw/\z})
      allowed = uri.scheme == "https" && uri.userinfo.nil? && uri.port == 443 && uri.fragment.nil?
      allowed &&= (uri.host == "packages.ecosyste.ms" && method == :get && uri.path.start_with?("/api/v1/")) ||
        (uri.host == "science.ecosyste.ms" && method == :get && %w[/api/v1/projects/search_seeds /api/v1/packages].include?(uri.path)) ||
        (uri.host == "archive.softwareheritage.org" &&
          ((method == :get && uri.path.start_with?("/api/1/origin/", "/api/1/snapshot/", "/api/1/revision/", "/api/1/release/", "/api/1/directory/")) || content_bytes ||
           (method == :post && uri.path == "/api/1/known/")))
      allowed &&= !raw || content_bytes
      raise Error, "Request outside lookup allowlist: #{method} #{url}" unless allowed

      key = Digest::SHA256.hexdigest(JSON.generate(raw ? [method, url, body, "raw"] : [method, url, body]))
      file = File.join(@cache, "#{key}.json.gz")
      return JSON.parse(Zlib::GzipReader.open(file, &:read)) if File.exist?(file)
      raise Error, "Not cached: #{url}" if @offline

      token = uri.host == "archive.softwareheritage.org" ? ENV["SWH_API_TOKEN"].to_s.strip : ""
      cooldown_key = "cooldown:#{uri.host}"
      cooldown_key += ":#{Digest::SHA256.hexdigest(token)}" unless token.empty?
      cooldown = @store.get(cooldown_key)
      raise RateLimited, "#{uri.host}: retry after #{cooldown}" if cooldown && Time.iso8601(cooldown) > Time.now

      @store.guard.check!
      sleep 0.2
      klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      request = klass.new(uri, "Accept" => raw ? "*/*" : "application/json", "User-Agent" => "swh-critical (local coverage research)")
      unless token.empty?
        request["Authorization"] = "Bearer #{token}"
      end
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      attempts = 0
      begin
        @store.guard.check!
        response = nil
        bytes = +"".b
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30, write_timeout: 30) do |http|
          http.max_retries = 0
          http.request(request) do |received|
            response = received
            received.read_body do |chunk|
              raise ResponseTooLarge, "Response exceeds #{MAX_RESPONSE_BYTES} bytes: #{url}" if bytes.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
              bytes << chunk.b
            end
          end
        end
      rescue Timeout::Error => error
        delay = TIMEOUT_RETRY_DELAYS[attempts]
        raise unless delay

        attempts += 1
        @output.puts "[#{Time.now.utc.iso8601}] RETRY #{error.class} #{method.to_s.upcase} #{url} retry=#{attempts}/#{TIMEOUT_RETRY_DELAYS.size} delay=#{delay}s"
        @output.flush
        sleep delay
        retry
      end
      code = response.code.to_i
      if code == 429
        retry_at = retry_time(response["retry-after"])
        @store.set(cooldown_key, retry_at.iso8601)
        raise RateLimited, "#{uri.host}: retry after #{retry_at.iso8601}"
      end
      raise Error, "HTTP #{code}: #{url}" unless [200, 404].include?(code)
      if raw
        raise Error, "Content unavailable: #{url}" unless code == 200
        raise Error, "Expected file bytes: #{url}" unless response["content-type"].to_s.start_with?("application/octet-stream")
      else
        raise Error, "Expected JSON: #{url}" unless response["content-type"].to_s.include?("json")
      end

      result = {
        "url" => url, "status" => code, "fetched_at" => Time.now.utc.iso8601,
        "headers" => response.to_hash.slice("link", "date", "etag", "last-modified", "content-type"),
        "body" => raw ? [bytes].pack("m0") : JSON.parse(bytes), "cache_file" => File.basename(file)
      }
      result["encoding"] = "base64" if raw
      @store.guard.check!
      temporary = "#{file}.tmp"
      begin
        Zlib::GzipWriter.open(temporary) { |gzip| gzip.write(JSON.generate(result)) }
        File.rename(temporary, file)
      ensure
        FileUtils.rm_f(temporary)
      end
      result
    rescue JSON::ParserError, URI::InvalidURIError, IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => error
      raise Error, "#{error.class}: #{error.message}"
    end

    def retry_time(header)
      value = header.to_s.strip
      time = value.match?(/\A\d+\z/) ? Time.now + value.to_i : Time.httpdate(value)
      [time, Time.now + 60].max.utc
    rescue ArgumentError
      (Time.now + 3600).utc
    end

    def self.next_url(response)
      link = Array(response.dig("headers", "link")).join(",")
      next_link = link.split(",").find { |part| part.match?(/;\s*rel="?next"?(?:\s|;|\z)/) }
      return unless next_link

      target = URI.join(response.fetch("url"), next_link[/<([^>]+)>/, 1].to_s)
      source = URI(response.fetch("url"))
      unless [target.scheme, target.host, target.port, target.path, target.userinfo] ==
          [source.scheme, source.host, source.port, source.path, nil] && target.query && target.to_s != source.to_s
        raise Error, "Invalid pagination link"
      end
      target.to_s
    end
  end
end
