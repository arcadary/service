class ScreenshotService
  def self.create(upload_id:, release_id:, kind:)
    raise Screenshot::InvalidKind unless Screenshot::KINDS.include?(kind)

    release = Release.find_by(public_id: release_id)
    raise Release::ReleaseNotFound unless release

    UploadService.use(upload_id: upload_id, kind: "screenshot") do |upload|
      store(release: release, kind: kind, bytes: UploadStorageService.read(upload: upload, name: upload.files.sole.name))
    end
  end

  def self.file_type?(content_type:, bytes:)
    content_type == "image/png" && bytes.start_with?(ScreenshotPngService::SIGNATURE)
  end

  def self.check(upload:)
    raise Upload::Rejected, "too_many_files" unless upload.files.one?
  end

  def self.expire(upload:); end

  def self.store(release:, kind:, bytes:)
    png = ScreenshotPngService.new(bytes: bytes, system: release.system).decode
    blob = upload(png: png)
    begin
      screenshot, old_blob = Screenshot.transaction { replace(release: release, kind: kind, blob: blob, png: png) }
    rescue StandardError
      discard(blob: blob)
      raise
    end
    ScreenshotBlobCleanupJob.perform_later(old_blob) if old_blob && old_blob != blob
    screenshot
  end
  private_class_method :store

  def self.replace(release:, kind:, blob:, png:)
    selected = selected_attributes(game_id: release.game_id)
    record = Screenshot.find_or_initialize_by(release: release, kind: kind)
    old_blob = record.blob if record.persisted?
    record.update!(png.except(:bytes).merge(blob: blob, licence: release.game.screenshot_licence))
    release.game.releases.touch_all if selected != selected_attributes(game_id: release.game_id)
    [ record, old_blob ]
  end

  def self.remove(public_id:, kind:)
    raise Screenshot::InvalidKind unless Screenshot::KINDS.include?(kind)

    release = Release.find_by(public_id: public_id)
    raise Release::ReleaseNotFound unless release

    blob = Screenshot.transaction do
      selected = selected_attributes(game_id: release.game_id)
      screenshot = Screenshot.find_by(release: release, kind: kind)
      raise Screenshot::NotFound unless screenshot

      screenshot.destroy!
      release.game.releases.touch_all if selected != selected_attributes(game_id: release.game_id)
      screenshot.blob
    end
    ScreenshotBlobCleanupJob.perform_later(blob)
  end

  def self.key(sha256:)
    "screenshots/#{sha256}.png"
  end

  def self.selected_for(game:)
    game.releases.select { |release| release.screenshots.any? }.min_by(&:public_id)&.screenshots&.max_by { |screenshot| Screenshot::KINDS.index(screenshot.kind) }
  end

  def self.selected_attributes(game_id:)
    Screenshot.joins(:release).where(releases: { game_id: game_id }).order("releases.public_id", :kind)
      .first&.slice(:sha256, :kind, :width, :height, :licence)
  end
  private_class_method :selected_attributes

  def self.purge(blob:)
    return if Screenshot.exists?(blob_id: blob.id)

    blob.delete
    blob.destroy!
  end

  def self.discard(blob:)
    purge(blob: blob)
  rescue StandardError
    ScreenshotBlobCleanupJob.perform_later(blob)
  end
  private_class_method :discard

  def self.upload(png:)
    key = key(sha256: png.fetch(:sha256))
    blob = ActiveStorage::Blob.find_by(key: key) || create_blob(key: key, bytes: png.fetch(:bytes))
    blob.upload_without_unfurling(StringIO.new(png.fetch(:bytes)))
    blob
  rescue ActiveRecord::RecordNotUnique
    retry
  rescue StandardError
    discard(blob: blob) if blob&.persisted?
    raise Screenshot::StorageUnavailable
  end
  private_class_method :upload

  def self.create_blob(key:, bytes:)
    ActiveStorage::Blob.build_after_unfurling(key: key, io: StringIO.new(bytes), filename: "screenshot.png",
      content_type: "image/png", identify: false, service_name: StorageConfigurationService.media_service_name).tap(&:save!)
  end
  private_class_method :create_blob
end
