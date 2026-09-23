require "uri"

module SwhCritical
  module RepositoryUrl
    def self.normalize(value)
      return unless value.is_a?(String) && !value.strip.empty?

      value = value.strip.sub(/\Agit\+/, "")
      value = value.sub(/\Agit@([^:]+):/, 'https://\1/')
      uri = URI(value)
      return unless %w[http https git ssh].include?(uri.scheme) && uri.host && !uri.query && !uri.fragment
      return if uri.userinfo && !(uri.scheme == "ssh" && uri.userinfo == "git")

      host = uri.host.downcase
      path = uri.path.sub(%r{/+\z}, "").sub(/\.git\z/, "")
      return if path.empty? || path == "/"
      if host == "github.com"
        parts = path.split("/").reject(&:empty?)
        return unless parts.length >= 2 && (parts.length == 2 || %w[tree blob].include?(parts[2]))
        path = "/#{parts.first(2).join('/')}"
      end
      "https://#{host}#{path}"
    rescue URI::InvalidURIError
      nil
    end

    def self.key(value)
      normalized = normalize(value)
      return unless normalized

      URI(normalized).host == "github.com" ? normalized.downcase : normalized
    end

    def self.variants(value)
      normalized = normalize(value)
      return [] unless normalized

      original = value.strip if value.strip.match?(%r{\Ahttps?://}) && URI(value.strip).userinfo.nil?
      [original, normalized, "#{normalized}.git"].compact.uniq
    end
  end
end
