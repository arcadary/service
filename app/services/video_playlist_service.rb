require "bigdecimal"
require "strscan"

class VideoPlaylistService
  INTEGER = /\A[0-9]{1,20}\z/
  MAX_INTEGER = (2**64) - 1
  CODEC_FORMAT = /[!#$%&'*+.^_\x60|~0-9A-Za-z-]{4}(?:\.[!#$%&'*+^_\x60|~0-9A-Za-z-]+)*/
  CODECS = /\A"#{CODEC_FORMAT}(?:, *#{CODEC_FORMAT})*"\z/
  BYTERANGE = /\A([0-9]{1,20})(?:@([0-9]{1,20}))?\z/
  VERSIONS = { ts: 3..3, fmp4: 7.. }.freeze
  REPEATABLE = %w[#EXTINF #EXT-X-STREAM-INF #EXT-X-MAP #EXT-X-DISCONTINUITY].freeze

  def self.parse(bytes:)
    new(bytes: bytes).parse
  end

  def self.positive_integer(value:)
    invalid! unless INTEGER.match?(value) && value.to_i.between?(1, MAX_INTEGER)

    value.to_i
  end

  def self.invalid!
    raise Video::InvalidHls, "invalid_hls"
  end

  def initialize(bytes:)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    self.class.invalid! unless text.valid_encoding?
    if text.match?(/[\u0000-\u0009\u000b\u000c\u000e-\u001f\u007f-\u009f\ufeff]/) || !text.unicode_normalized?(:nfc)
      self.class.invalid!
    end
    text = text.gsub("\r\n", "\n")
    self.class.invalid! if text.include?("\r")
    @lines = text.split("\n", -1)
    self.class.invalid! unless @lines.shift == "#EXTM3U"
    @lines.reject! { |line| line.empty? || (line.start_with?("#") && !line.start_with?("#EXT")) }
    @seen = Set.new
    @parts = [ { map: nil, segments: [] } ]
    @variants = []
  end

  def parse
    @lines.each_with_index do |line, index|
      if @pending == :variant
        self.class.invalid! if line.start_with?("#")
        @variants << line
        @pending = nil
      elsif @pending
        line.start_with?("#") ? segment_byterange(line: line) : segment(uri: line)
      elsif line.start_with?("#")
        tag, value = line.split(":", 2)
        parse_tag(tag: tag, value: value, last: index == @lines.length - 1)
      else
        self.class.invalid!
      end
    end
    self.class.invalid! if @pending || !@version
    if @variants.any?
      self.class.invalid! unless @parts == [ { map: nil, segments: [] } ] && (@seen - %w[#EXT-X-VERSION]).empty?
      self.class.invalid! unless VERSIONS.values.any? { |versions| versions.cover?(@version) }
      { type: :master, variants: @variants }
    else
      media(parts: @parts.reject { |part| part.fetch(:segments).empty? })
    end
  end

  private

  def media(parts:)
    segments = parts.flat_map { |part| part.fetch(:segments) }
    self.class.invalid! unless segments.any? && @target && @seen.superset?(Set.new(%w[#EXT-X-PLAYLIST-TYPE #EXT-X-ENDLIST]))
    self.class.invalid! unless segments.all? { |segment| segment.fetch(:duration).round(0, :half_up) <= @target }
    format = parts.first.fetch(:map) ? :fmp4 : :ts
    self.class.invalid! unless VERSIONS.fetch(format).cover?(@version)
    self.class.invalid! unless format == :fmp4 ? parts.all? { |part| part.fetch(:map) } : parts.size == 1 && segments.none? { |segment| segment.fetch(:range) }
    { type: :media, format: format, parts: parts }
  end

  def parse_tag(tag:, value:, last:)
    self.class.invalid! unless REPEATABLE.include?(tag) || @seen.add?(tag)
    case tag
    when "#EXT-X-VERSION"
      @version = self.class.positive_integer(value: value.to_s)
    when "#EXT-X-TARGETDURATION"
      @target = self.class.positive_integer(value: value.to_s)
    when "#EXT-X-PLAYLIST-TYPE"
      self.class.invalid! unless value == "VOD"
    when "#EXT-X-MEDIA-SEQUENCE"
      self.class.invalid! unless value == "0" && @parts.all? { |part| part.fetch(:segments).empty? }
    when "#EXT-X-ENDLIST"
      self.class.invalid! unless value.nil? && last
    when "#EXTINF"
      match = /\A([0-9]+(?:\.[0-9]*)?|\.[0-9]+),(.*)\z/.match(value.to_s)
      self.class.invalid! unless match
      duration = BigDecimal(match[1])
      self.class.invalid! unless duration.finite? && duration.positive?
      @pending = { duration: duration }
    when "#EXT-X-STREAM-INF"
      stream_attributes!(value: value.to_s)
      @pending = :variant
    when "#EXT-X-MAP"
      @parts << { map: map(value: value.to_s), segments: [] }
    when "#EXT-X-DISCONTINUITY"
      self.class.invalid! unless value.nil?
    else
      self.class.invalid!
    end
  end

  def segment_byterange(line:)
    tag, value = line.split(":", 2)
    self.class.invalid! unless tag == "#EXT-X-BYTERANGE" && !@pending.key?(:range)
    @pending[:range] = byterange(value: value.to_s, previous: @previous_range)
  end

  def segment(uri:)
    @previous_range = @pending[:range]
    @parts.last.fetch(:segments) << { uri: uri, duration: @pending.fetch(:duration), range: @pending[:range] }
    @pending = nil
  end

  def byterange(value:, previous: nil)
    match = BYTERANGE.match(value)
    self.class.invalid! unless match && (match[2] || previous)
    offset = match[2] ? match[2].to_i : previous.end
    offset...(offset + self.class.positive_integer(value: match[1]))
  end

  def map(value:)
    attributes = attribute_list(value: value)
    self.class.invalid! unless attributes.key?("URI") && (attributes.keys - %w[URI BYTERANGE]).empty?
    { uri: quoted(attributes.fetch("URI")), range: attributes.key?("BYTERANGE") ? byterange(value: quoted(attributes.fetch("BYTERANGE"))) : nil }
  end

  def quoted(value)
    match = /\A"([^"]+)"\z/.match(value)
    self.class.invalid! unless match
    match[1]
  end

  def attribute_list(value:)
    scanner = StringScanner.new(value)
    attributes = {}
    until scanner.eos?
      name = scanner.scan(/[A-Z0-9-]+/)
      self.class.invalid! unless name && scanner.scan(/=/) && !attributes.key?(name)
      entry = scanner.scan(/"[^"\r\n]*"|[^,\s"]+/)
      self.class.invalid! unless entry
      attributes[name] = entry
      break if scanner.eos?
      self.class.invalid! unless scanner.scan(/,/) && !scanner.eos?
    end
    attributes
  end

  def stream_attributes!(value:)
    attributes = attribute_list(value: value)
    self.class.invalid! unless attributes.key?("BANDWIDTH") && (attributes.keys - %w[BANDWIDTH AVERAGE-BANDWIDTH CODECS RESOLUTION]).empty?
    %w[BANDWIDTH AVERAGE-BANDWIDTH].each do |name|
      self.class.positive_integer(value: attributes.fetch(name)) if attributes.key?(name)
    end
    if attributes.key?("CODECS")
      self.class.invalid! unless CODECS.match?(attributes.fetch("CODECS"))
    end
    if attributes.key?("RESOLUTION")
      dimensions = attributes.fetch("RESOLUTION").split("x", -1)
      self.class.invalid! unless dimensions.length == 2
      dimensions.each { |dimension| self.class.positive_integer(value: dimension) }
    end
  end
end
