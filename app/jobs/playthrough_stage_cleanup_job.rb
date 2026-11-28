class PlaythroughStageCleanupJob < ApplicationJob
  def perform_now
    Rails.logger.silence(Logger::UNKNOWN) { super }
  end

  def perform
    PlaythroughStageCleanupService.call
  end
end
