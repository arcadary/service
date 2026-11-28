class UploadCheckJob < ApplicationJob
  def perform(upload_id)
    upload = Upload.find_by(id: upload_id, state: "checking")
    UploadService.check(upload: upload) if upload
  end
end
