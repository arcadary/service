require "digest"
require "json"

class CatalogNameService
  REGIONS = %w[Asia Australia Brazil Canada China Denmark Europe Finland France Germany Greece Hong\ Kong India Italy Japan Korea Mexico Netherlands New\ Zealand Norway Portugal Russia Scandinavia Spain Sweden Taiwan United\ Kingdom USA World].freeze
  REVISION = /\A(?:Rev [A-Za-z0-9]+(?:\.[A-Za-z0-9]+)*|v\d+(?:\.\d+)*(?:[a-z])?)\z/
  ANNOTATION = /\(([^()]*)\)/

  def self.normalize(title:)
    title.unicode_normalize(:nfc).gsub(/[[:space:]]+/, " ").strip
  end

  def self.display_title(title:)
    normalize(title: title.gsub(ANNOTATION, ""))
  end

  def self.attributes(title:, system:)
    annotations = title.scan(ANNOTATION).flatten
    regions = annotations.select { |value| region?(value: value) }
    revisions = annotations.grep(REVISION)
    exact_title = normalize(title: title.gsub(ANNOTATION) { |match| region?(value: Regexp.last_match(1)) || REVISION.match?(Regexp.last_match(1)) ? "" : match })
    {
      key: JSON.generate([ system, exact_title ]),
      title: display_title(title: title),
      region: regions.presence&.join(", "),
      revision: revisions.presence&.join(", ")
    }
  end

  def self.public_id(key:, title:, system:)
    slug = title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "").presence || "game"
    "#{system}-#{slug}-#{Digest::SHA256.hexdigest(key)}"
  end

  def self.region?(value:)
    value.split(", ").all? { |region| REGIONS.include?(region) } && value.present?
  end
  private_class_method :region?
end
