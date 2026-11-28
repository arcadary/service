class VideoFileCleanupJob < ApplicationJob
  retry_on Video::StorageUnavailable, wait: 1.hour, attempts: :unlimited

  def perform(public_id)
    VideoService.purge(public_id: public_id)
  end
end
