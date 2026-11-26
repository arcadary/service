class CatalogMappingService
  class InvalidMapping < StandardError; end

  def self.load(path: Rails.root.join("data/catalog/games.txt"))
    new(text: File.read(path)).mappings
  end

  attr_reader :mappings

  def initialize(text:)
    @mappings = {}
    games = {}
    current = nil
    text.each_line.with_index(1) do |line, number|
      content = line.split("#", 2).first.to_s.rstrip
      next if content.strip.empty?

      if content.start_with?(" ", "\t")
        sha1 = content.strip.downcase
        raise InvalidMapping, "line #{number}: invalid or duplicate checksum" unless current && ReleaseService::SHA1.match?(sha1) && !@mappings.key?(sha1)

        @mappings[sha1] = current
        current[:checksums] << sha1
      else
        id, title = content.split(/\s+/, 2)
        raise InvalidMapping, "line #{number}: invalid or duplicate game ID/title" unless /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/.match?(id) && title.present? && !games.key?(id)

        current = { public_id: id, title: title, checksums: [] }
        games[id] = current
      end
    end
    raise InvalidMapping, "mapping contains an empty game" if games.values.any? { |game| game[:checksums].empty? }
  end
end
