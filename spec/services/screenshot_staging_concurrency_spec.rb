require "rails_helper"
require "timeout"
require_relative "../support/screenshot_helpers"

RSpec.describe "Concurrent screenshot publication" do
  include ScreenshotHelpers
  self.use_transactional_tests = false

  it "lets one publisher consume the stage and rejects the other without another publication" do
    allow(ScreenshotConfigurationService).to receive(:require_uploads!)
    release = create(:release)
    game, medium = release.game, release.media_files.sole
    stage = ScreenshotStagingService.create(release_id: release.public_id, source_sha1: release.sha1, kind: "title", io: StringIO.new(png), content_type: "image/png")
    blob = stage.blob
    ready, proceed = Queue.new, Queue.new
    allow(ScreenshotStagingService).to receive(:validated_png).and_wrap_original do |method, **arguments|
      result = method.call(**arguments)
      ready.push(true)
      proceed.pop
      result
    end
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.cache do
            ScreenshotStagingService.publish(staging_id: stage.public_id, release_id: release.public_id, source_sha1: release.sha1, kind: "title")
          end
          :published
        rescue ScreenshotStage::Consumed
          :consumed
        end
      end
    end
    Timeout.timeout(10) { 2.times { ready.pop } }
    2.times { proceed.push(true) }
    expect(threads.map(&:value)).to contain_exactly(:published, :consumed)
    expect(Screenshot.where(release: release).count).to eq(1)
    expect(stage.reload).to have_attributes(blob_id: nil)
    expect(stage.consumed_at).to be_present
    expect(Screenshot.find_by!(release: release).blob_id).to eq(blob.id)
  ensure
    2.times { proceed.push(true) } if proceed
    threads&.each(&:join)
    Screenshot.where(release: release).destroy_all if release
    stage&.destroy!
    blob&.purge
    release&.destroy!
    medium&.destroy!
    game&.destroy!
  end
end
