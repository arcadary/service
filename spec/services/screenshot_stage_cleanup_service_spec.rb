require "rails_helper"
require_relative "../support/screenshot_helpers"

RSpec.describe ScreenshotStageCleanupService do
  include ScreenshotHelpers
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:release) { create(:release) }

  def stage_image
    ScreenshotStagingService.create(release_id: release.public_id, source_sha1: release.sha1, kind: "title", io: StringIO.new(png), content_type: "image/png")
  end

  before { allow(ScreenshotConfigurationService).to receive(:require_uploads!) }

  it "deletes expired receipts and private blobs but never transferred or unexpired blobs" do
    travel_to Time.current.change(usec: 0) do
      consumed, expired = stage_image, stage_image
      published_blob, expired_blob = consumed.blob, expired.blob
      ScreenshotStagingService.publish(staging_id: consumed.public_id, release_id: release.public_id, source_sha1: release.sha1, kind: "title")
      travel 24.hours
      live = stage_image
      perform_enqueued_jobs { described_class.call }
      expect(ScreenshotStage.pluck(:public_id)).to eq([ live.public_id ])
      expect(published_blob.download).to eq(live.blob.download)
      expect(expired_blob.service.exist?(expired_blob.key)).to be(false)
      expect(Screenshot.sole.blob).to eq(published_blob)
    end
  end

  it "bounds each cleanup pass and queues continuation for the remainder" do
    stub_const("ScreenshotStageCleanupService::BATCH_SIZE", 1)
    first, second = stage_image, stage_image
    travel_to first.expires_at + 1.second do
      expect { described_class.call }.to have_enqueued_job(ScreenshotStageCleanupJob)
      expect(ScreenshotStage.pluck(:id)).to eq([ second.id ])
    end
  end

  it "continues past failed deletions and retains their targets for the hourly retry" do
    stub_const("ScreenshotStageCleanupService::BATCH_SIZE", 2)
    stage, second, third = stage_image, stage_image, stage_image
    blob = stage.blob
    later_blobs = [ second.blob, third.blob ]
    travel_to third.expires_at, with_usec: true do
      allow(blob.service).to receive(:delete).and_call_original
      allow(blob.service).to receive(:delete).with(blob.key).and_raise(IOError)
      expect { described_class.call }.to have_enqueued_job(ScreenshotStageCleanupJob)
      expect(ScreenshotStage.pluck(:id)).to match_array([ stage.id, third.id ])
      perform_enqueued_jobs(only: ScreenshotStageCleanupJob)
      expect(ScreenshotStage.pluck(:id)).to eq([ stage.id ])
      expect(enqueued_jobs).to be_empty
      expect(stage.reload.blob).to eq(blob)
      later_blobs.each { |later| expect(later.service.exist?(later.key)).to be(false) }
      allow(blob.service).to receive(:delete).and_call_original
      described_class.call
      expect(ScreenshotStage.exists?(stage.id)).to be(false)
      expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
      expect(blob.service.exist?(blob.key)).to be(false)
    end
  end
end
