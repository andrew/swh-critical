require_relative "http"

module SwhCritical
  class SwhObjects
    def initialize(http)
      @http = http
    end

    def get(type, id)
      raise Error, "Invalid object identifier" unless %w[snapshot revision release directory].include?(type) && id.match?(/\A[0-9a-f]{40}\z/)

      response = @http.request(:get, "#{Http::SWH}/#{type}/#{id}/")
      raise Error, "#{type} #{id} not found" unless response["status"] == 200

      response.fetch("body")
    end

    def snapshot(id)
      raise Error, "Invalid snapshot identifier" unless id.match?(/\A[0-9a-f]{40}\z/)

      branches, pages, seen = {}, [], []
      cursor = nil
      3.times do
        url = "#{Http::SWH}/snapshot/#{id}/?branches_count=1000"
        url += "&branches_from=#{URI.encode_www_form_component(cursor)}" if cursor
        response = @http.request(:get, url)
        body = response.fetch("body")
        unless response["status"] == 200 && body.is_a?(Hash) && body["branches"].is_a?(Hash)
          raise Error, "Invalid snapshot response"
        end
        branches.merge!(body.fetch("branches"))
        pages << response.slice("url", "fetched_at", "cache_file")
        cursor = body["next_branch"]
        break unless cursor
        raise Error, "Snapshot pagination loop" if seen.include?(cursor)

        seen << cursor
      end
      { "id" => id, "branches" => branches, "complete" => cursor.nil?, "pages" => pages }
    end

    def resolve(branches, name)
      seen = []
      loop do
        raise Error, "Snapshot alias loop" if seen.include?(name)
        seen << name
        branch = branches[name]
        return branch unless branch && branch["target_type"] == "alias"

        name = branch.fetch("target")
      end
    end
  end
end
