require "rails_helper"
require_relative "../support/screenshot_helpers"

RSpec.describe ScreenshotStagingService do
  include ScreenshotHelpers
  include ActiveJob::TestHelper

  let(:release) { create(:release) }

  before do
    allow(ScreenshotConfigurationService).to receive(:require_uploads!)
  end

  def stage_image
    described_class.create(release_id: release.public_id, source_sha1: release.sha1, kind: "title", io: StringIO.new(png), content_type: "image/png")
  end

  it "purges the canonical upload if saving its staging record fails" do
    existing_files = Dir.glob(Rails.root.join("tmp/storage/**/*")).select { |path| File.file?(path) }
    allow(ScreenshotStage).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)
    expect { stage_image }.to raise_error(ActiveRecord::RecordInvalid)
    expect(ActiveStorage::Blob.count).to eq(0)
    expect(ScreenshotStage.count).to eq(0)
    expect(Dir.glob(Rails.root.join("tmp/storage/**/*")).select { |path| File.file?(path) }).to match_array(existing_files)
  end

  it "rolls back replacement and consumption together when screenshot validation fails, leaving a retryable stage" do
    previous = upload_screenshot(release: release, kind: "title")
    stage = stage_image
    original, bytes = previous.attributes, previous.blob.download
    allow_any_instance_of(Screenshot).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)
    arguments = { staging_id: stage.public_id, release_id: release.public_id, source_sha1: release.sha1, kind: "title" }
    expect { described_class.publish(**arguments) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(previous.reload.attributes).to eq(original)
    expect(previous.blob.download).to eq(bytes)
    expect(stage.reload).to have_attributes(consumed_at: nil)
    expect(stage.blob.download).to eq(bytes)
  end

  it "returns consumed when another publisher transfers and removes the blob during a pending read" do
    stage = stage_image
    arguments = { staging_id: stage.public_id, release_id: release.public_id, source_sha1: release.sha1, kind: "title" }
    published = false
    allow(described_class).to receive(:validated_png).and_wrap_original do |method, **attributes|
      unless published
        published = true
        described_class.publish(**arguments)
        perform_enqueued_jobs { ScreenshotService.remove(public_id: release.public_id, kind: "title") }
      end
      method.call(**attributes)
    end
    expect { described_class.publish(**arguments) }.to raise_error(ScreenshotStage::Consumed)
    expect(Screenshot.count).to eq(0)
    expect(stage.reload.consumed_at).to be_present
  end
end
