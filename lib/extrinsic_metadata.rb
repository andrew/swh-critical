require_relative "http"

module SwhCritical
  class ExtrinsicMetadata
    TARGET = /\Aswh:1:(?:cnt|dir|rev|rel|snp):[0-9a-f]{40}\z/
    MAX_AUTHORITIES = 10
    MAX_PAGES = 3
    PAGE_SIZE = 10

    def initialize(store, http, output)
      @store, @http, @output = store, http, output
    end

    def run(targets, limit: 100)
      raise Error, "Expected core SWHIDs, one per line" unless targets.any? && targets.all? { |target| target.match?(TARGET) }

      @rows = targets.uniq.map { |target| @store.get("extrinsic_metadata:#{target}") || { "target" => target, "status" => "unchecked" } }
      @rows.reject { |row| row["status"] == "complete" }.first(limit).each do |row|
        row.replace("target" => row.fetch("target"), "checked_at" => Time.now.utc.iso8601,
          "status" => "incomplete", "authorities" => [])
        begin
          lookup(row)
        rescue RateLimited, DiskSpaceError, Interrupt => error
          row["error"] = error.message
          raise
        rescue Error, ArgumentError => error
          row["error"] = error.message
        ensure
          @store.set("extrinsic_metadata:#{row.fetch('target')}", row)
          report
        end
        @output.puts "[#{Time.now.utc.iso8601}] RESULT extrinsic-metadata #{row['target']} status=#{row['status']} authorities=#{row['authorities'].size}"
        @output.flush
      end
      report
    end

    def lookup(data)
      target = data.fetch("target")
      response = @http.request(:get, "#{Http::SWH}/raw-extrinsic-metadata/swhid/#{target}/authorities/")
      data["authorities_evidence"] = evidence(response)
      authorities = array_response(response)
      data["authorities_found"] = authorities.size
      raise Error, "Incomplete authorities response" if Http.next_url(response)

      authorities.first(MAX_AUTHORITIES).each do |authority|
        unless authority.is_a?(Hash) && %w[deposit_client forge registry].include?(authority["type"]) && authority["url"].is_a?(String) && !authority["url"].empty?
          raise Error, "Invalid metadata authority"
        end
        entry = authority.slice("type", "url").merge("records" => [], "pages" => [], "complete" => false)
        data["authorities"] << entry
        records(target, entry)
      end
      raise Error, "Authority limit reached" if authorities.size > MAX_AUTHORITIES

      data["status"] = "complete" if data["authorities"].all? { |authority| authority["complete"] }
    end

    def records(target, authority)
      identifier = "#{authority.fetch('type')} #{authority.fetch('url')}"
      base = "#{Http::SWH}/raw-extrinsic-metadata/swhid/#{target}/"
      url = "#{base}?#{URI.encode_www_form(authority: identifier, limit: PAGE_SIZE)}"
      seen = []
      MAX_PAGES.times do
        raise Error, "Metadata pagination loop" if seen.include?(url)
        raise Error, "Metadata pagination changed authority" unless URI.decode_www_form(URI(url).query.to_s).select { |key, _| key == "authority" } == [["authority", identifier]]

        seen << url
        response = @http.request(:get, url)
        authority["pages"] << evidence(response)
        records = array_response(response)
        raise Error, "Metadata page exceeds requested limit" if records.size > PAGE_SIZE

        records.each do |record|
          validate_record(record, target, authority)
          entry = record.merge("evidence" => evidence(response))
          authority["records"] << entry
          entry["payload"] = payload(record.fetch("metadata_url"))
        end
        url = Http.next_url(response)
        authority["next_url"] = url
        unless url
          authority["complete"] = true
          return
        end
      end
      authority["error"] = "Metadata page limit reached"
    rescue RateLimited, DiskSpaceError
      raise
    rescue Error, ArgumentError, URI::InvalidURIError => error
      authority["error"] = error.message
    end

    def validate_record(record, target, authority)
      unless record.is_a?(Hash) && record["target"] == target && record["authority"].is_a?(Hash) &&
          record["authority"].slice("type", "url") == authority.slice("type", "url") &&
          record["discovery_date"].is_a?(String) && record["format"].is_a?(String) &&
          record["fetcher"].is_a?(Hash) && record["metadata_url"].is_a?(String)
        raise Error, "Invalid metadata record"
      end
      Time.iso8601(record.fetch("discovery_date"))
      uri = URI(record.fetch("metadata_url"))
      unless uri.scheme == "https" && uri.host == "archive.softwareheritage.org" && uri.port == 443 && uri.userinfo.nil? && uri.fragment.nil? &&
          uri.path.match?(%r{\A/api/1/raw-extrinsic-metadata/get/[0-9a-f]{40}/\z})
        raise Error, "Invalid metadata payload URL"
      end
    end

    def payload(url)
      response = @http.request(:get, url, raw: true)
      bytes = response.fetch("body").unpack1("m0")
      result = { "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes), "evidence" => evidence(response) }
      begin
        result["json"] = JSON.parse(bytes)
      rescue JSON::ParserError
        result["encoding"] = "base64"
      end
      result
    end

    def array_response(response)
      raise Error, "HTTP #{response['status']} for metadata lookup" unless response["status"] == 200
      raise Error, "Invalid metadata list" unless response["body"].is_a?(Array)

      response.fetch("body")
    end

    def evidence(response)
      response.slice("url", "status", "fetched_at", "cache_file")
    end

    def report
      @store.guard.check!
      directory = File.join(@store.path, "out")
      FileUtils.mkdir_p(directory)
      data = { "reported_at" => Time.now.utc.iso8601,
        "scope" => "Metadata returned for the requested objects and authorities. Empty results do not establish object absence or absence of links elsewhere.",
        "targets" => @rows }
      File.write(File.join(directory, "extrinsic_metadata.json"), JSON.pretty_generate(data) + "\n")
    end
  end
end
