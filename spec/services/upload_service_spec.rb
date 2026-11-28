require "rails_helper"
require_relative "../support/screenshot_helpers"
require_relative "../support/video_hls_helpers"

RSpec.describe UploadService do
  include ScreenshotHelpers
  include VideoHlsHelpers
  include ActiveSupport::Testing::TimeHelpers

  def stored_screenshot
    described_class.create(kind: "screenshot").tap do |upload|
      receive_file(upload: upload, name: "screenshot.png", bytes: png, content_type: "image/png")
    end
  end

  it "deletes expired uploads, the unlinked media copy of a confirmed video nobody used and folders a crash left behind" do
    expired = stored_screenshot
    video = confirmed_upload(kind: "video", files: hls_files.to_h { |name, bytes| [ name, [ bytes, hls_content_type(name) ] ] })
    playlist = VideoService.key(public_id: video.public_id, name: "index.m3u8")
    expect(StorageConfigurationService.media_service.exist?(playlist)).to be(true)
    travel 25.hours
    live = stored_screenshot
    orphan = StorageConfigurationService.uploads_root.join(SecureRandom.uuid).tap(&:mkpath)

    UploadCleanupJob.perform_now

    expect(Upload.where(id: [ expired.id, video.id ])).to be_empty
    expect(StorageConfigurationService.uploads_root.join(expired.public_id)).not_to exist
    expect(StorageConfigurationService.media_service.exist?(playlist)).to be(false)
    expect(orphan).not_to exist
    expect(StorageConfigurationService.uploads_root.join(live.public_id, "screenshot.png")).to exist
  end

  it "counts only uploads still holding files against the disk quota" do
    stub_const("Upload::QUOTA_BYTES", png.bytesize)
    upload = stored_screenshot
    expect { stored_screenshot }.to raise_error(Upload::Full)
    described_class.confirm(upload_id: upload.public_id)
    UploadCheckJob.perform_now(upload.id)
    described_class.use(upload_id: upload.public_id, kind: "screenshot") { :used }
    expect(stored_screenshot.files.size).to eq(1)
  end
end
