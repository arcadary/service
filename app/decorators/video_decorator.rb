class VideoDecorator
  VERSION = 1

  def self.version
    [ VERSION, StorageConfigurationService.media_base_url ]
  end

  def self.decorate(video)
    new(video)
  end

  def initialize(video)
    @video = video
  end

  def as_json(*)
    { "kind" => @video.kind, "url" => "#{StorageConfigurationService.media_base_url}/#{VideoService.key(public_id: @video.public_id, name: VideoHlsService::PLAYLIST)}" }
      .merge(@video.media.slice("duration", "chapters"))
  end

  def internal_json
    as_json.merge(@video.media.slice("format", "audio")).merge(
      "id" => @video.public_id, "source_sha1" => @video.source_sha1, "capture" => @video.capture, "verification" => @video.verification,
      "files" => @video.files.size, "created_at" => @video.created_at.utc.iso8601,
      "compatibility_result_ids" => @video.compatibility_results.map(&:id).sort
    )
  end
end
