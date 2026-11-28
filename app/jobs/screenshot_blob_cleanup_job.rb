class ScreenshotBlobCleanupJob < ApplicationJob
  retry_on StandardError, wait: 1.hour, attempts: :unlimited
  discard_on ActiveJob::DeserializationError

  def perform(blob)
    ScreenshotService.purge(blob: blob)
  end
end
