class ScreenshotService
  def self.create(upload_id:, release_id:, kind:)
    raise Screenshot::InvalidKind unless Screenshot::KINDS.include?(kind)

    release = ReleaseService.find(public_id: release_id)
    UploadService.use(upload_id: upload_id, kind: "screenshot") do |upload|
      store(release: release, kind: kind, bytes: UploadStorageService.read(upload: upload, name: upload.files.sole.name))
    end
  end

  def self.list(release_id:)
    ReleaseService.find(public_id: release_id, includes: :screenshots).screenshots
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
      screenshot, replaced_blob = Screenshot.transaction { place(release: release, kind: kind, blob: blob, png: png) }
    rescue StandardError
      discard(blob: blob)
      raise
    end
    ScreenshotBlobCleanupJob.perform_later(replaced_blob) if replaced_blob && replaced_blob != blob
    screenshot
  end
  private_class_method :store

  def self.place(release:, kind:, blob:, png:)
    existing = Screenshot.find_by(release: release, sha256: png.fetch(:sha256))
    return [ existing, nil ] if existing

    refresh_game_picture(release: release) do
      replaced = kind == "title" ? Screenshot.find_by(release: release, kind: "title")&.destroy! : nil
      screenshot = Screenshot.create!(png.except(:bytes).merge(release: release, kind: kind, position: next_position(release: release, kind: kind),
        blob: blob, licence: release.game.screenshot_licence))
      [ screenshot, replaced&.blob ]
    end
  end
  private_class_method :place

  def self.next_position(release:, kind:)
    return Screenshot::TITLE_POSITION if kind == "title"

    position = Screenshot.where(release: release, kind: "gameplay").maximum(:position).to_i + 1
    raise Screenshot::LimitReached if position > Screenshot::GAMEPLAY_LIMIT

    position
  end
  private_class_method :next_position

  def self.remove(screenshot_id:)
    screenshot = Screenshot.transaction do
      found = find(screenshot_id: screenshot_id)
      refresh_game_picture(release: found.release) do
        found.destroy!
        close_gap(after: found) if found.kind == "gameplay"
      end
      found
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

  def self.close_gap(after:)
    after.release.screenshots.where(kind: "gameplay", position: (after.position + 1)..).each do |later|
      later.update!(position: later.position - 1)
    end
  end
  private_class_method :close_gap

  def self.key(sha256:)
    "screenshots/#{sha256}.png"
  end

  def self.selected_for(game:)
    screenshots = game.releases.select { |release| release.screenshots.any? }.min_by(&:public_id)&.screenshots
    screenshots&.find { |screenshot| screenshot.kind == "gameplay" } || screenshots&.first
  end

  def self.refresh_game_picture(release:)
    selected = selected_attributes(game_id: release.game_id)
    result = yield
    release.game.releases.touch_all if selected != selected_attributes(game_id: release.game_id)
    result
  end
  private_class_method :refresh_game_picture

  def self.selected_attributes(game_id:)
    selected_for(game: Game.includes(releases: :screenshots).find(game_id))&.slice(:sha256, :kind, :width, :height, :licence)
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
