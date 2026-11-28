require "bigdecimal"
require "strscan"

class PlaythroughPlaylistService
  INTEGER = /\A[0-9]{1,20}\z/
  MAX_INTEGER = (2**64) - 1

  def self.parse(bytes:)
    new(bytes: bytes).parse
  end

  def self.positive_integer(value:)
    invalid! unless INTEGER.match?(value) && value.to_i.between?(1, MAX_INTEGER)

    value.to_i
  end

  def self.invalid!
    raise PlaythroughStage::InvalidHls, "invalid_hls"
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
    @segments = []
    @variants = []
  end

  def parse
    @lines.each_with_index do |line, index|
      if @pending
        self.class.invalid! if line.start_with?("#")
        if @pending == :variant
          @variants << line
        else
          @segments << { uri: line, duration: @pending }
        end
        @pending = nil
      elsif line.start_with?("#")
        tag, value = line.split(":", 2)
        parse_tag(tag: tag, value: value, last: index == @lines.length - 1)
      else
        self.class.invalid!
      end
    end
    self.class.invalid! if @pending || !@seen.include?("#EXT-X-VERSION")
    if @variants.any?
      self.class.invalid! unless @segments.empty? && (@seen - %w[#EXT-X-VERSION]).empty?
      { type: :master, variants: @variants }
    else
      self.class.invalid! unless @segments.any? && @target && @seen.superset?(Set.new(%w[#EXT-X-PLAYLIST-TYPE #EXT-X-ENDLIST]))
      self.class.invalid! unless @segments.all? { |segment| segment.fetch(:duration).round(0, :half_up) <= @target }
      { type: :media, segments: @segments }
    end
  end

  private

  def parse_tag(tag:, value:, last:)
    unless %w[#EXTINF #EXT-X-STREAM-INF].include?(tag)
      self.class.invalid! unless @seen.add?(tag)
    end
    case tag
    when "#EXT-X-VERSION"
      self.class.invalid! unless value == "3"
    when "#EXT-X-TARGETDURATION"
      @target = self.class.positive_integer(value: value.to_s)
    when "#EXT-X-PLAYLIST-TYPE"
      self.class.invalid! unless value == "VOD"
    when "#EXT-X-MEDIA-SEQUENCE"
      self.class.invalid! unless value == "0" && @segments.empty?
    when "#EXT-X-ENDLIST"
      self.class.invalid! unless value.nil? && last
    when "#EXTINF"
      match = /\A([0-9]+(?:\.[0-9]*)?|\.[0-9]+),(.*)\z/.match(value.to_s)
      self.class.invalid! unless match
      @pending = BigDecimal(match[1])
      self.class.invalid! unless @pending.finite? && @pending.positive?
    when "#EXT-X-STREAM-INF"
      attributes!(value: value.to_s)
      @pending = :variant
    else
      self.class.invalid!
    end
  end

  def attributes!(value:)
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
    self.class.invalid! unless attributes.key?("BANDWIDTH") && (attributes.keys - %w[BANDWIDTH AVERAGE-BANDWIDTH CODECS RESOLUTION]).empty?
    %w[BANDWIDTH AVERAGE-BANDWIDTH].each do |name|
      self.class.positive_integer(value: attributes.fetch(name)) if attributes.key?(name)
    end
    if attributes.key?("CODECS")
      self.class.invalid! unless /\A"[A-Za-z0-9][A-Za-z0-9.-]*(?:,[A-Za-z0-9][A-Za-z0-9.-]*)*"\z/.match?(attributes.fetch("CODECS"))
    end
    if attributes.key?("RESOLUTION")
      dimensions = attributes.fetch("RESOLUTION").split("x", -1)
      self.class.invalid! unless dimensions.length == 2
      dimensions.each { |dimension| self.class.positive_integer(value: dimension) }
    end
  end
end
