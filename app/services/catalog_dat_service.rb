require "strscan"

class CatalogDatService
  class InvalidDat < StandardError; end

  def self.parse(path:, system:)
    new(text: File.read(path, encoding: "UTF-8"), system: system).parse
  rescue ArgumentError, EncodingError => error
    raise InvalidDat, error.message
  end

  def initialize(text:, system:)
    @scanner = StringScanner.new(text)
    @system = system
  end

  def parse
    nodes = pairs
    rows = []
    skipped = []
    skipped_releases = 0
    skipped_game_keys = []
    nodes.select { |key, _| key == "game" }.each do |_, game|
      raise InvalidDat, "game must be a block" unless game.is_a?(Array)

      title = game.assoc("name")&.last
      raise InvalidDat, "game has no name" unless title.is_a?(String) && title.present?

      attributes = CatalogNameService.attributes(title: title, system: @system)
      raise InvalidDat, "game has an empty display title" if attributes[:title].empty?

      roms = game.select { |key, _| key == "rom" }
      skipped << "no ROM checksum entries for #{title}" if roms.empty?
      valid_count = rows.size
      roms.each do |_, rom|
        raise InvalidDat, "rom must be a block" unless rom.is_a?(Array)

        sha1 = rom.assoc("sha1")&.last.to_s.downcase
        unless ReleaseService::SHA1.match?(sha1)
          skipped << "missing or invalid SHA-1 for #{title}"
          skipped_releases += 1
          next
        end
        rows << attributes.merge(sha1: sha1, system: @system, source_title: title)
      end
      skipped_game_keys << attributes[:key] if rows.size == valid_count
    end
    raise InvalidDat, "no valid releases" if rows.empty?
    raise InvalidDat, "duplicate SHA-1 in system" if rows.map { |row| row[:sha1] }.uniq.size != rows.size

    { rows: rows, skipped: { reasons: skipped, releases: skipped_releases, games: (skipped_game_keys - rows.map { |row| row[:key] }).uniq.size } }
  end

  private
    def token
      @scanner.skip(/\s+/)
      return if @scanner.eos?
      return :open if @scanner.scan(/\(/)
      return :close if @scanner.scan(/\)/)

      if @scanner.peek(1) == '"'
        quoted = @scanner.scan(/"(?:\\.|[^"\\])*"/m)
        raise InvalidDat, "unterminated quoted value" unless quoted

        quoted[1...-1].gsub(/\\(["\\])/, '\1')
      else
        @scanner.scan(/[^\s()"]+/) or raise InvalidDat, "invalid token"
      end
    end

    def pairs(nested: false)
      result = []
      while (key = token)
        return result if key == :close && nested
        raise InvalidDat, "unexpected parenthesis" if key.in?([ :open, :close ])

        value = token
        raise InvalidDat, "missing value for #{key}" unless value && value != :close

        result << [ key, value == :open ? pairs(nested: true) : value ]
      end
      raise InvalidDat, "unclosed block" if nested

      result
    end
end
