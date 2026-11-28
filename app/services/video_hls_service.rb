class VideoHlsService
  PLAYLIST = "index.m3u8"
  FRAGMENT_STARTS = %w[styp moof].freeze

  def self.validate(files:, reader:)
    new(files: files, reader: reader).validate
  end

  def initialize(files:, reader:)
    @manifest = files.index_by(&:name)
    @reader = reader
    @visited = Set.new
    @audio = {}
    @covered = {}
  end

  def validate
    root = playlist(path: PLAYLIST)
    media = if root.fetch(:type) == :master
      root.fetch(:variants).uniq.map do |uri|
        path = resolve(from: PLAYLIST, uri: uri)
        child = playlist(path: path)
        invalid! unless child.fetch(:type) == :media
        [ path, child ]
      end
    else
      [ [ PLAYLIST, root ] ]
    end
    formats = media.map { |_path, child| child.fetch(:format) }.uniq
    invalid! unless formats.size == 1
    timelines = media.map do |path, child|
      child.fetch(:parts).flat_map { |part| formats.first == :fmp4 ? fragments(path: path, part: part) : transport_segments(path: path, part: part) }
    end
    invalid! unless timelines.uniq.length == 1 && @audio.values.uniq.length <= 1
    covered!
    duration = timelines.first.sum
    chapters = if @manifest.key?("chapters.vtt")
      VideoChaptersService.parse(bytes: read(path: "chapters.vtt", content_type: "text/vtt"), duration: duration)
    else
      []
    end
    invalid! unless @visited == @manifest.keys.to_set
    { "format" => formats.first.to_s, "audio" => @audio.values.first, "duration" => duration.to_f, "chapters" => chapters }
  end

  private

  def transport_segments(path:, part:)
    part.fetch(:segments).map do |segment|
      segment_path = resolve(from: path, uri: segment.fetch(:uri))
      unless @audio.key?(segment_path)
        bytes = read(path: segment_path, content_type: "video/mp2t")
        @audio[segment_path] = VideoTransportService.validate(bytes: bytes)
      end
      segment.fetch(:duration)
    end
  end

  def fragments(path:, part:)
    map = part.fetch(:map)
    init_path = resolve(from: path, uri: map.fetch(:uri))
    types = boxes(path: init_path, range: claim(path: init_path, range: map.fetch(:range)))
    invalid! unless types.first == "ftyp" && types.include?("moov")
    part.fetch(:segments).map do |segment|
      segment_path = resolve(from: path, uri: segment.fetch(:uri))
      invalid! unless FRAGMENT_STARTS.include?(boxes(path: segment_path, range: claim(path: segment_path, range: segment.fetch(:range))).first)
      segment.fetch(:duration)
    end
  end

  def claim(path:, range:)
    size = entry(path: path, content_type: "video/mp4").byte_size
    range ||= 0...size
    invalid! unless range.begin == @covered.fetch(path, 0) && range.end <= size
    @covered[path] = range.end
    range
  end

  def covered!
    @covered.each do |path, offset|
      size = @manifest.fetch(path).byte_size
      invalid! unless offset == size || boxes(path: path, range: offset...size).uniq == [ "mfra" ]
    end
  end

  def boxes(path:, range:)
    types = []
    offset = range.begin
    while offset < range.end
      size, type = @reader.call(path: path, range: offset...[ offset + 8, range.end ].min).unpack("Na4")
      invalid! unless size && size >= 8 && offset + size <= range.end
      types << type
      offset += size
    end
    types
  end

  def playlist(path:)
    VideoPlaylistService.parse(bytes: read(path: path, content_type: "application/vnd.apple.mpegurl"))
  end

  def read(path:, content_type:)
    entry(path: path, content_type: content_type)
    @reader.call(path: path)
  end

  def entry(path:, content_type:)
    entry = @manifest[path]
    invalid! unless entry&.content_type == content_type
    @visited.add(path)
    entry
  end

  def resolve(from:, uri:)
    invalid! unless UploadFile.valid_name?(uri)
    directory = from.rpartition("/").first
    directory.empty? ? uri : "#{directory}/#{uri}"
  end

  def invalid!
    raise Video::InvalidHls, "invalid_hls"
  end
end
