class ScreenshotStageCleanupService
  BATCH_SIZE = 100

  def self.call(after_id: 0)
    expired = ScreenshotStage.where(expires_at: ..Time.current).where("id > ?", after_id)
    ids = expired.order(:id).limit(BATCH_SIZE).pluck(:id)
    ids.each do |id|
      cleanup(id: id)
    end
    if ids.any? && expired.where("id > ?", ids.last).exists?
      ScreenshotStageCleanupJob.perform_later(after_id: ids.last)
    end
  end

  def self.cleanup(id:)
    blob = ScreenshotStage.uncached do
      ScreenshotStage.transaction do
        stage = ScreenshotStage.find_by(id: id)
        next unless stage && stage.expires_at <= Time.current

        blob = stage.blob
        stage.destroy! unless blob
        blob
      end
    end
    return unless blob

    begin
      blob.delete
    rescue StandardError
      return
    end
    ScreenshotStage.transaction do
      ScreenshotStage.find_by(id: id)&.destroy!
      blob.destroy!
    end
  end
  private_class_method :cleanup
end
