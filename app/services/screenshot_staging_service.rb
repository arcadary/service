class ScreenshotStagingService
  def self.create(release_id:, source_sha1:, kind:, io:, content_type:)
    ScreenshotConfigurationService.require_uploads!
    release = target(release_id: release_id, source_sha1: source_sha1, kind: kind)
    require_membership!(release: release, source_sha1: source_sha1)
    raise Screenshot::InvalidImage unless content_type == "image/png"

    png = ScreenshotPngService.decode(io: io, system: release.system)
    blob = ScreenshotService.upload(bytes: png.fetch(:bytes))
    begin
      ingested_at = Time.current
      ScreenshotStage.create!(release_public_id: release.public_id, source_sha1: source_sha1.downcase,
        kind: kind, blob: blob, created_at: ingested_at, expires_at: ingested_at + 24.hours, **png.except(:bytes))
    rescue StandardError
      blob.purge
      raise
    end
  end

  def self.publish(staging_id:, release_id:, source_sha1:, kind:)
    ScreenshotConfigurationService.require_uploads!
    release = target(release_id: release_id, source_sha1: source_sha1, kind: kind)
    stage = available(staging_id: staging_id, release_id: release_id, source_sha1: source_sha1, kind: kind)
    require_membership!(release: release, source_sha1: source_sha1)
    png = validated_png(stage: stage, system: release.system)
    screenshot, old_blob = ScreenshotStage.uncached do
      ScreenshotStage.transaction do
        current = available(staging_id: staging_id, release_id: release_id, source_sha1: source_sha1, kind: kind)
        release = target(release_id: release_id, source_sha1: source_sha1, kind: kind)
        require_membership!(release: release, source_sha1: source_sha1)
        result = ScreenshotService.replace(release: release, kind: kind, blob: current.blob, png: png)
        current.update!(consumed_at: Time.current, blob: nil)
        result
      end
    end
    old_blob&.purge_later
    screenshot
  end

  def self.target(release_id:, source_sha1:, kind:)
    unless release_id.is_a?(String) && release_id.present? && release_id.length <= 200 &&
        source_sha1.is_a?(String) && ReleaseService::SHA1.match?(source_sha1) && Screenshot::KINDS.include?(kind)
      raise ScreenshotStage::InvalidInput
    end

    release = Release.includes(:game).find_by(public_id: release_id)
    raise Release::ReleaseNotFound unless release
    release
  end
  private_class_method :target

  def self.require_membership!(release:, source_sha1:)
    raise ScreenshotStage::TargetMismatch unless release.media_files.exists?(sha1: source_sha1.downcase)
  end
  private_class_method :require_membership!

  def self.available(staging_id:, release_id:, source_sha1:, kind:)
    raise ScreenshotStage::InvalidInput unless staging_id.is_a?(String) && staging_id.present? && staging_id.length <= 200

    stage = ScreenshotStage.find_by(public_id: staging_id)
    raise ScreenshotStage::Unavailable unless stage && stage.expires_at > Time.current
    unless stage.release_public_id == release_id && stage.source_sha1 == source_sha1.downcase && stage.kind == kind
      raise ScreenshotStage::TargetMismatch
    end
    raise ScreenshotStage::Consumed if stage.consumed_at
    raise ScreenshotStage::Unavailable unless stage.blob

    stage
  end
  private_class_method :available

  def self.validated_png(stage:, system:)
    bytes = download(stage: stage)
    raise ScreenshotStage::Unavailable unless Digest::SHA256.hexdigest(bytes) == stage.sha256

    png = ScreenshotPngService.new(bytes: bytes, system: system).decode
    raise ScreenshotStage::Unavailable unless png.slice(:width, :height) == stage.attributes.symbolize_keys.slice(:width, :height)

    stage.attributes.symbolize_keys.slice(:sha256, :width, :height)
  rescue Screenshot::InvalidImage, Screenshot::TooLarge
    raise ScreenshotStage::Unavailable
  end
  private_class_method :validated_png

  def self.download(stage:)
    stage.blob.download
  rescue ActiveStorage::FileNotFoundError
    raise ScreenshotStage::Unavailable
  rescue StandardError
    raise Screenshot::StorageUnavailable
  end
  private_class_method :download
end
