class ScreenshotStageCleanupJob < ApplicationJob
  def perform
    ScreenshotStageCleanupService.call
  end
end
