class ScreenshotStageCleanupService
  BATCH_SIZE = 100

  def self.call
    ScreenshotStage.where(expires_at: ..Time.current).order(:expires_at).limit(BATCH_SIZE).pluck(:id).each do |id|
      blob = ScreenshotStage.transaction do
        stage = ScreenshotStage.find_by(id: id)
        next unless stage && stage.expires_at <= Time.current

        stage.blob.tap { stage.destroy! }
      end
      blob&.purge_later
    end
    ScreenshotStageCleanupJob.perform_later if ScreenshotStage.where(expires_at: ..Time.current).exists?
  end
end
