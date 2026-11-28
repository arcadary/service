require "rails_helper"
require "timeout"
require_relative "../support/playthrough_helpers"

RSpec.describe "Concurrent playthrough staging" do
  include PlaythroughHelpers
  self.use_transactional_tests = false

  it "serializes declaration retries into one durable stage and one accounting result" do
    release = create(:release)
    declaration = playthrough_declaration(release: release)
    ready, start = Queue.new, Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready.push(true)
          start.pop
          declare_playthrough(input: declaration).id
        end
      end
    end
    Timeout.timeout(10) { 2.times { ready.pop } }
    2.times { start.push(true) }
    expect(threads.map(&:value).uniq.size).to eq(1)
    stages = PlaythroughStage.where(release: release)
    expect(stages.count).to eq(1)
    expect(stages.sole.objects.count).to eq(1)
  ensure
    2.times { start.push(true) } if start
    threads&.each(&:join)
    cleanup_playthrough(release: release) if release
  end

  it "accepts concurrent verified transfers once and never overwrites the winning storage key" do
    release = create(:release)
    stage = declare_playthrough(input: playthrough_declaration(release: release))
    object = stage.objects.sole
    ready, start = Queue.new, Queue.new
    allow(PlaythroughTransferService).to receive(:upload).and_wrap_original do |method, **arguments|
      blob = method.call(**arguments)
      ready.push(true)
      start.pop
      blob
    end
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.cache do
            receive_playthrough(stage: stage, object: object).attributes
          end
        end
      end
    end
    Timeout.timeout(10) { 2.times { ready.pop } }
    2.times { start.push(true) }
    expect(threads.map(&:value).uniq.size).to eq(1)
    expect(object.reload.blob.download).to eq("synthetic segment")
    expect(ActiveStorage::Blob.where("key LIKE ?", "playthrough-stages/#{stage.public_id}/%").count).to eq(1)
  ensure
    2.times { start.push(true) } if start
    threads&.each(&:join)
    cleanup_playthrough(release: release) if release
  end

  def cleanup_playthrough(release:)
    stages = PlaythroughStage.where(release: release)
    stages.each do |stage|
      PlaythroughStageObject.where(playthrough_stage: stage).delete_all
      ActiveStorage::Blob.where("key LIKE ?", "playthrough-stages/#{stage.public_id}/%").each(&:purge)
    end
    stages.delete_all
    game = release.game
    media = release.media_files.to_a
    release.destroy!
    media.each(&:destroy!)
    game.destroy!
  end
end
