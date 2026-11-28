class PlaythroughDecorator
  def self.decorate(playthrough)
    new(playthrough)
  end

  def initialize(playthrough)
    @playthrough = playthrough
  end

  def as_json(*)
    {
      "id" => @playthrough.public_id, "release_id" => @playthrough.release.public_id, "source_sha1" => @playthrough.source_sha1,
      "files" => @playthrough.files.size
    }.merge(@playthrough.media)
  end
end
