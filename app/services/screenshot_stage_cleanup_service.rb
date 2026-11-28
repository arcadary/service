class ScreenshotStageCleanupService
  BATCH_SIZE = 100

  def self.call
    ScreenshotStage.where(expires_at: ..Time.current).order(:expires_at).limit(BATCH_SIZE).pluck(:id).each do |id|
      cleanup(id: id)
    end
    ScreenshotStageCleanupJob.perform_later if ScreenshotStage.where(expires_at: ..Time.current).exists?
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

    blob.delete
    ScreenshotStage.transaction do
      ScreenshotStage.find_by(id: id)&.destroy!
      blob.destroy!
    end
  end
  private_class_method :cleanup
end
