class ScreenshotService
  def self.create(upload_id:, release_id:, kind:)
    raise Screenshot::InvalidKind unless Screenshot::KINDS.include?(kind)

    release = ReleaseService.find(public_id: release_id)
    UploadService.use(upload_id: upload_id, kind: "screenshot") do |upload|
      store(release: release, kind: kind, bytes: UploadStorageService.read(upload: upload, name: upload.files.sole.name))
    end
  end

  def self.list(release_id:)
    ReleaseService.find(public_id: release_id).screenshots
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
      screenshot, replaced_blob = place(release: release, kind: kind, blob: blob, png: png)
    rescue StandardError
      discard(blob: blob)
      raise
    end
    ScreenshotBlobCleanupJob.perform_later(replaced_blob) if replaced_blob
    screenshot
  end
  private_class_method :store

  def self.place(release:, kind:, blob:, png:)
    Screenshot.transaction do
      existing = Screenshot.find_by(release: release, sha256: png.fetch(:sha256))
      next [ existing, nil ] if existing

      refresh_game_picture(release: release) do
        if kind == "title"
          replaced = Screenshot.find_by(release: release, kind: "title")&.destroy!
        elsif Screenshot.where(release: release, kind: "gameplay").count >= Screenshot::GAMEPLAY_LIMIT
          raise Screenshot::LimitReached
        end
        [ Screenshot.create!(png.except(:bytes).merge(release: release, kind: kind, blob: blob, licence: release.game.screenshot_licence)), replaced&.blob ]
      end
    end
  rescue ActiveRecord::RecordNotUnique
    [ Screenshot.find_by!(release: release, sha256: png.fetch(:sha256)), nil ]
  end
  private_class_method :place

  def self.remove(screenshot_id:)
    screenshot = Screenshot.transaction do
      found = find(screenshot_id: screenshot_id)
      refresh_game_picture(release: found.release) { found.destroy! }
    end
    ScreenshotBlobCleanupJob.perform_later(screenshot.blob)
    screenshot
  end

  def self.find(screenshot_id:)
    screenshot = Screenshot.includes(:release, :blob).find_by(public_id: screenshot_id)
    raise Screenshot::NotFound unless screenshot

    screenshot
  end
  private_class_method :find

  def self.key(sha256:)
    "screenshots/#{sha256}.png"
  end

  def self.selected_for(game_id:)
    Screenshot.joins(:release).where(releases: { game_id: game_id })
      .order("releases.public_id").in_order_of(:kind, %w[gameplay title]).order(:id).first
  end

  def self.refresh_game_picture(release:)
    selected = selected_attributes(game_id: release.game_id)
    result = yield
    release.game.releases.touch_all if selected != selected_attributes(game_id: release.game_id)
    result
  end
  private_class_method :refresh_game_picture

  def self.selected_attributes(game_id:)
    selected_for(game_id: game_id)&.slice(:sha256, :kind, :width, :height, :licence)
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
