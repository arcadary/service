class PlaythroughStageCleanupJob < ApplicationJob
  def perform_now
    Rails.logger.silence(Logger::UNKNOWN) { super }
  end

  def perform
    Rails.logger.silence(Logger::UNKNOWN) { PlaythroughStageCleanupService.call }
  end
end
