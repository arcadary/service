class ScreenshotStageCleanupJob < ApplicationJob
  def perform(after_id: 0)
    ScreenshotStageCleanupService.call(after_id: after_id)
  end
end
