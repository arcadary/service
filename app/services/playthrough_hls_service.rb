class PlaythroughHlsService
  def self.validate(manifest:, reader:)
    new(manifest: manifest, reader: reader).validate
  end

  def initialize(manifest:, reader:)
    @manifest = manifest.index_by { |entry| entry.fetch("path") }
    @reader = reader
    @visited = Set.new
    @audio = {}
  end

  def validate
    root = playlist(path: "index.m3u8")
    media = if root.fetch(:type) == :master
      root.fetch(:variants).uniq.map do |uri|
        path = resolve(from: "index.m3u8", uri: uri)
        child = playlist(path: path)
        invalid! unless child.fetch(:type) == :media
        [ path, child ]
      end
    else
      [ [ "index.m3u8", root ] ]
    end
    timelines = media.map do |path, child|
      child.fetch(:segments).map do |segment|
        segment_path = resolve(from: path, uri: segment.fetch(:uri))
        unless @audio.key?(segment_path)
          bytes = read(path: segment_path, content_type: "video/mp2t")
          @audio[segment_path] = PlaythroughTransportService.validate(bytes: bytes)
        end
        segment.fetch(:duration)
      end
    end
    invalid! unless timelines.uniq.length == 1 && @audio.values.uniq.length == 1
    duration = timelines.first.sum
    chapters_path = "chapters.vtt" if @manifest.key?("chapters.vtt")
    chapters = if chapters_path
      PlaythroughChaptersService.parse(bytes: read(path: chapters_path, content_type: "text/vtt"), duration: duration)
    else
      []
    end
    invalid! unless @visited == @manifest.keys.to_set
    { "root" => "index.m3u8", "duration" => duration.to_s("F"), "video_codec" => "h264",
      "audio_codec" => @audio.values.first ? "aac" : nil, "chapters_path" => chapters_path, "chapters" => chapters }
  end

  private

  def playlist(path:)
    PlaythroughPlaylistService.parse(bytes: read(path: path, content_type: "application/vnd.apple.mpegurl"))
  end

  def read(path:, content_type:)
    entry = @manifest[path]
    invalid! unless entry && entry.fetch("content_type") == content_type
    @visited.add(path)
    @reader.call(path: path)
  end

  def resolve(from:, uri:)
    unless /\A[^\s\\:%?#\x00-\x1f\x7f]+\z/.match?(uri) && uri.split("/", -1).none? { |part| [ "", ".", ".." ].include?(part) }
      invalid!
    end
    directory = from.rpartition("/").first
    directory.empty? ? uri : "#{directory}/#{uri}"
  end

  def invalid!
    raise PlaythroughStage::InvalidHls, "invalid_hls"
  end
end
