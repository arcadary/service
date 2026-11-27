class ScreenshotService
  def self.create(release:, kind:, io:, content_type:)
    raise Screenshot::InvalidKind unless Screenshot::KINDS.include?(kind)
    raise Screenshot::InvalidImage unless content_type == "image/png"

    png = ScreenshotPngService.decode(io: io, system: release.system)
    blob = upload(bytes: png.fetch(:bytes))
    begin
      old_blob = nil
      screenshot = Screenshot.transaction do
        selected = selected_attributes(game_id: release.game_id)
        record = Screenshot.find_or_initialize_by(release: release, kind: kind)
        old_blob = record.blob if record.persisted?
        record.update!(png.except(:bytes).merge(blob: blob, licence: release.game.screenshot_licence))
        release.game.releases.touch_all if selected != selected_attributes(game_id: release.game_id)
        record
      end
    rescue StandardError
      blob.purge
      raise
    end
    old_blob&.purge_later
    screenshot
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
    blob.purge_later
  end

  def self.find_by(sha256:)
    raise Screenshot::NotFound unless /\A[0-9a-f]{64}\z/.match?(sha256)

    screenshot = Screenshot.includes(:blob).find_by(sha256: sha256)
    raise Screenshot::NotFound unless screenshot

    screenshot.blob.download
  rescue ActiveStorage::FileNotFoundError
    raise Screenshot::NotFound
  end

  def self.selected_for(game:)
    game.releases.select { |release| release.screenshots.any? }.min_by(&:public_id)&.screenshots&.max_by { |screenshot| Screenshot::KINDS.index(screenshot.kind) }
  end

  def self.selected_attributes(game_id:)
    Screenshot.joins(:release).where(releases: { game_id: game_id }).order("releases.public_id", :kind)
      .first&.slice(:sha256, :kind, :width, :height, :licence)
  end
  private_class_method :selected_attributes

  def self.upload(bytes:)
    blob = ActiveStorage::Blob.build_after_unfurling(io: StringIO.new(bytes), filename: "screenshot.png", content_type: "image/png", identify: false)
    blob.save!
    blob.upload_without_unfurling(StringIO.new(bytes))
    blob
  rescue StandardError
    blob&.purge_later
    raise Screenshot::StorageUnavailable
  end
  private_class_method :upload
end
