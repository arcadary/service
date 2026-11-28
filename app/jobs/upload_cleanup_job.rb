class UploadCleanupJob < ApplicationJob
  def perform
    UploadService.cleanup
  end
end
