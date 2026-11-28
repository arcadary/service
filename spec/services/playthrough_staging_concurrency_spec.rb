require "rails_helper"
require "timeout"
require_relative "../support/playthrough_helpers"
require_relative "../support/playthrough_hls_helpers"

RSpec.describe "Concurrent playthrough staging" do
  include PlaythroughHelpers
  include PlaythroughHlsHelpers
  include ActiveSupport::Testing::TimeHelpers
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

  it "persists one result when complete packages validate concurrently" do
    release = create(:release)
    files = hls_files
    stage = declare_hls(release: release, files: files)
    receive_hls(stage: stage, files: files)
    ready, start = Queue.new, Queue.new
    allow(PlaythroughHlsService).to receive(:validate).and_wrap_original do |method, **arguments|
      result = method.call(**arguments)
      ready.push(true)
      start.pop
      result
    end
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          PlaythroughValidationService.validate(staging_id: stage.public_id)
        end
      end
    end
    Timeout.timeout(10) { 2.times { ready.pop } }
    2.times { start.push(true) }
    results = threads.map(&:value)
    expect(results.uniq.size).to eq(1)
    expect(stage.reload.validation_result).to eq(results.first)
    expect(stage.validation_state).to eq("validated")
  ensure
    2.times { start.push(true) } if start
    threads&.each(&:join)
    cleanup_playthrough(release: release) if release
  end

  it "replays the terminal winner when another validator finishes with a conflicting outcome" do
    release = create(:release)
    files = hls_files
    stage = declare_hls(release: release, files: files)
    receive_hls(stage: stage, files: files)
    ready, start = Queue.new, Queue.new
    allow(PlaythroughHlsService).to receive(:validate).and_wrap_original do |method, **arguments|
      if Thread.current[:delayed_failure]
        ready.push(true)
        start.pop
        raise PlaythroughStage::InvalidHls, "invalid_hls"
      end
      method.call(**arguments)
    end
    thread = Thread.new do
      Thread.current[:delayed_failure] = true
      ActiveRecord::Base.connection_pool.with_connection do
        PlaythroughValidationService.validate(staging_id: stage.public_id)
      end
    end
    Timeout.timeout(10) { ready.pop }
    winner = PlaythroughValidationService.validate(staging_id: stage.public_id)
    start.push(true)
    expect(thread.value).to eq(winner)
    expect(stage.reload.validation_state).to eq("validated")
    expect(stage.validation_error).to be_nil
  ensure
    start&.push(true)
    thread&.join
    cleanup_playthrough(release: release) if release
  end

  it "lets different declared objects upload concurrently without a stage owner conflict" do
    release = create(:release)
    declaration = playthrough_declaration(release: release)
    declaration["manifest"] << declaration["manifest"].first.merge("path" => "video/other.ts")
    stage = declare_playthrough(input: declaration)
    ready, start = Queue.new, Queue.new
    allow(PlaythroughTransferService).to receive(:upload).and_wrap_original do |method, **arguments|
      ready.push(true)
      start.pop
      method.call(**arguments)
    end
    threads = stage.objects.map do |object|
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { receive_playthrough(stage: stage, object: object) } }
    end
    Timeout.timeout(10) { 2.times { ready.pop } }
    2.times { start.push(true) }
    expect(threads.map(&:value).map(&:public_id)).to match_array(stage.objects.map(&:public_id))
    expect(stage.objects.reload).to all(have_attributes(received_at: be_present))
  ensure
    2.times { start.push(true) } if start
    threads&.each(&:join)
    cleanup_playthrough(release: release) if release
  end

  %w[transfer validation].each do |kind|
    it "renews a #{kind} lease independently while one storage call blocks beyond fifteen minutes" do
      freeze_time
      release = create(:release)
      files = hls_files
      stage = declare_hls(release: release, files: files)
      receive_hls(stage: stage, files: files) if kind == "validation"
      ready, start, renewed = Queue.new, Queue.new, Queue.new
      stub_const("PlaythroughAttemptService::RENEW_INTERVAL", 0.01)
      allow(PlaythroughAttemptService).to receive(:renew).and_wrap_original do |method, **arguments|
        result = method.call(**arguments)
        renewed.push(Time.current)
        result
      end
      operation = kind == "transfer" ? :upload : :download
      blocked = false
      allow(ActiveStorage::Blob.service).to receive(operation).and_wrap_original do |method, *arguments, **keywords, &block|
        unless blocked
          blocked = true
          ready.push(true)
          start.pop
        end
        method.call(*arguments, **keywords, &block)
      end
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          if kind == "transfer"
            object = stage.objects.first
            receive_playthrough(stage: stage, object: object, bytes: files.fetch(object.path))
          else
            PlaythroughValidationService.validate(staging_id: stage.public_id)
          end
        end
      end
      Timeout.timeout(10) { ready.pop }
      travel 14.minutes
      Timeout.timeout(10) { loop { break if renewed.pop == Time.current } }
      travel 2.minutes
      start.push(true)
      expect(thread.value).to be_present
      expect(stage.attempts.where(kind: kind).order(:id).last.state).to eq("finished")
    ensure
      start&.push(true)
      thread&.join
      travel_back
      cleanup_playthrough(release: release) if release
    end
  end

  it "fences an abandoned writer, reclaims its absent key, then deletes only that key when the writer resumes" do
    freeze_time
    release = create(:release)
    stage = declare_playthrough(input: playthrough_declaration(release: release))
    ready, start = Queue.new, Queue.new
    allow(PlaythroughAttemptService).to receive(:during) { |**_, &block| block.call }
    allow(ActiveStorage::Blob.service).to receive(:upload).and_wrap_original do |method, *arguments, **keywords|
      ready.push(true)
      start.pop
      method.call(*arguments, **keywords)
    end
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        receive_playthrough(stage: stage)
      rescue PlaythroughStage::Expired => error
        error
      end
    end
    Timeout.timeout(10) { ready.pop }
    attempt = stage.attempts.find_by!(kind: "transfer")
    travel 24.hours
    PlaythroughStageCleanupService.call
    expect(stage.reload.reclaimed_at).to be_present
    start.push(true)
    expect(thread.value).to be_a(PlaythroughStage::Expired)
    expect(ActiveStorage::Blob.service.exist?(attempt.private_key)).to be(false)
    expect(stage.objects.sole.reload.blob_id).to be_nil
    expect(attempt.reload).to have_attributes(state: "fenced", generation: 2, cleanup_pending: false)
    expect(stage.reload.reclaimed_at).to be_nil
    PlaythroughStageCleanupService.call
    expect(stage.reload.reclaimed_at).to be_present
  ensure
    start&.push(true)
    thread&.join
    travel_back
    cleanup_playthrough(release: release) if release
  end

  it "rejects a fenced validator instead of replaying another validator's terminal success" do
    freeze_time
    release = create(:release)
    files = hls_files
    stage = declare_hls(release: release, files: files)
    receive_hls(stage: stage, files: files)
    ready, start = Queue.new, Queue.new
    allow(PlaythroughAttemptService).to receive(:during) { |**_, &block| block.call }
    blocked = false
    allow(PlaythroughHlsService).to receive(:validate).and_wrap_original do |method, **arguments|
      unless blocked
        blocked = true
        ready.push(true)
        start.pop
      end
      method.call(**arguments)
    end
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        PlaythroughValidationService.validate(staging_id: stage.public_id)
      rescue PlaythroughStage::Conflict => error
        error
      end
    end
    Timeout.timeout(10) { ready.pop }
    travel 15.minutes
    PlaythroughLifecycleService.synchronize(stage_id: stage.id) { |current| PlaythroughAttemptService.fence_stale(stage: current) }
    winner = PlaythroughValidationService.validate(staging_id: stage.public_id)
    start.push(true)
    expect(thread.value).to be_a(PlaythroughStage::Conflict)
    expect(stage.reload.validation_result).to eq(winner)
  ensure
    start&.push(true)
    thread&.join
    travel_back
    cleanup_playthrough(release: release) if release
  end

  it "prevents a stale cleanup owner from committing deletion progress or deleting another key" do
    freeze_time
    release = create(:release)
    files = hls_files
    stage = declare_hls(release: release, files: files)
    receive_hls(stage: stage, files: files)
    travel 24.hours
    ready, start = Queue.new, Queue.new
    allow(PlaythroughAttemptService).to receive(:during) { |**_, &block| block.call }
    blocked = false
    service = ActiveStorage::Blob.service
    allow(service).to receive(:delete).and_wrap_original do |method, key|
      unless blocked
        blocked = true
        ready.push(key)
        start.pop
      end
      method.call(key)
    end
    thread = Thread.new { ActiveRecord::Base.connection_pool.with_connection { PlaythroughStageCleanupService.call } }
    deleted_key = Timeout.timeout(10) { ready.pop }
    claim = stage.attempts.find_by!(kind: "cleanup")
    travel 15.minutes
    PlaythroughLifecycleService.synchronize(stage_id: stage.id) { |current| PlaythroughAttemptService.fence_stale(stage: current) }
    start.push(true)
    thread.value
    expect(service).to have_received(:delete).once.with(deleted_key)
    expect(service).to have_received(:delete).exactly(1).times
    expect(claim.reload.state).to eq("fenced")
    expect(stage.reload.reclaimed_at).to be_nil
    expect(stage.attempts.find_by!(private_key: deleted_key).cleanup_pending).to be(true)
    PlaythroughStageCleanupService.call
    expect(stage.reload.reclaimed_at).to be_present
  ensure
    start&.push(true)
    thread&.join
    travel_back
    cleanup_playthrough(release: release) if release
  end

  it "rejects a validation result when a live validator crosses the declaration deadline" do
    freeze_time
    release = create(:release)
    files = hls_files
    stage = declare_hls(release: release, files: files)
    receive_hls(stage: stage, files: files)
    travel 24.hours - 1.minute
    ready, start = Queue.new, Queue.new
    allow(PlaythroughAttemptService).to receive(:during) { |**_, &block| block.call }
    allow(PlaythroughHlsService).to receive(:validate).and_wrap_original do |method, **arguments|
      ready.push(true)
      start.pop
      method.call(**arguments)
    end
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        PlaythroughValidationService.validate(staging_id: stage.public_id)
      rescue PlaythroughStage::Expired => error
        error
      end
    end
    Timeout.timeout(10) { ready.pop }
    travel 1.minute
    start.push(true)
    expect(thread.value).to be_a(PlaythroughStage::Expired)
    expect(stage.reload.validation_result).to be_nil
    expect(stage.attempts.find_by!(kind: "validation").state).to eq("finished")
  ensure
    start&.push(true)
    thread&.join
    travel_back
    cleanup_playthrough(release: release) if release
  end

  it "serializes identical promotion claims and refuses a competing binding" do
    release = create(:release)
    files = hls_files
    stage = declare_hls(release: release, files: files)
    receive_hls(stage: stage, files: files)
    PlaythroughValidationService.validate(staging_id: stage.public_id)
    ready, start = Queue.new, Queue.new
    threads = [ stage.package_sha256, stage.package_sha256, "0" * 64 ].map do |package|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready.push(true)
          start.pop
          PlaythroughPromotionService.claim_promotion(staging_id: stage.public_id, release_id: release.public_id, package_sha256: package)
        rescue PlaythroughStage::Conflict => error
          error
        end
      end
    end
    Timeout.timeout(10) { 3.times { ready.pop } }
    3.times { start.push(true) }
    results = threads.map(&:value)
    expect(results.first(2).uniq.size).to eq(1)
    expect(results.last).to be_a(PlaythroughStage::Conflict)
    expect(stage.promotion_claims.count).to eq(1)
    expect(stage.reload.promotion_state).to eq("promoting")
  ensure
    3.times { start.push(true) } if start
    threads&.each(&:join)
    cleanup_playthrough(release: release) if release
  end

  it "rechecks protection when cleanup selected a stage before its promotion transaction committed" do
    freeze_time
    release = create(:release)
    files = hls_files
    stage = declare_hls(release: release, files: files)
    receive_hls(stage: stage, files: files)
    PlaythroughValidationService.validate(staging_id: stage.public_id)
    pinned, commit, selected, reclaim = Queue.new, Queue.new, Queue.new, Queue.new
    allow(PlaythroughLifecycleService).to receive(:synchronize).and_wrap_original do |method, **arguments, &operation|
      method.call(**arguments) do |current|
        result = operation.call(current)
        if Thread.current[:claiming_promotion]
          pinned.push(true)
          commit.pop
        end
        result
      end
    end
    allow(PlaythroughStageCleanupService).to receive(:claim).and_wrap_original do |method, **arguments|
      selected.push(true)
      reclaim.pop
      method.call(**arguments)
    end
    promoter = Thread.new do
      Thread.current[:claiming_promotion] = true
      ActiveRecord::Base.connection_pool.with_connection do
        PlaythroughPromotionService.claim_promotion(staging_id: stage.public_id, release_id: release.public_id, package_sha256: stage.package_sha256)
      end
    end
    Timeout.timeout(10) { pinned.pop }
    travel 24.hours
    cleaner = Thread.new { ActiveRecord::Base.connection_pool.with_connection { PlaythroughStageCleanupService.call } }
    Timeout.timeout(10) { selected.pop }
    commit.push(true)
    expect(promoter.value).to be_a(String)
    reclaim.push(true)
    cleaner.value
    expect(stage.reload).to have_attributes(promotion_state: "promoting", expired_at: nil, reclaimed_at: nil, cleanup_visits: 0)
    expect(stage.objects.reload.map(&:blob_id)).to all(be_present)
  ensure
    commit&.push(true)
    reclaim&.push(true)
    promoter&.join
    cleaner&.join
    travel_back
    cleanup_playthrough(release: release) if release
  end

  %w[completed released].each do |outcome|
    it "protects a fake publisher paused before copying and completion across expiry until #{outcome}" do
      freeze_time
      release = create(:release)
      files = hls_files
      stage = declare_hls(release: release, files: files)
      receive_hls(stage: stage, files: files)
      result = PlaythroughValidationService.validate(staging_id: stage.public_id)
      claimed, copy, copied, finish = Queue.new, Queue.new, Queue.new, Queue.new
      publisher = lambda do
        token = PlaythroughPromotionService.claim_promotion(staging_id: stage.public_id, release_id: release.public_id, package_sha256: stage.package_sha256)
        claimed.push(token)
        copy.pop
        expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
        copied.push(stage.objects.reload.to_h { |object| [ object.path, object.blob.download.b ] })
        finish.pop
        raise IOError, "synthetic copy failure" if outcome == "released"

        PlaythroughStage.transaction { PlaythroughPromotionService.complete_promotion(claim: token) }
      rescue IOError
        PlaythroughPromotionService.release_promotion(claim: token)
      end
      thread = Thread.new { ActiveRecord::Base.connection_pool.with_connection { publisher.call } }
      token = Timeout.timeout(10) { claimed.pop }
      PlaythroughStageCleanupService.call
      travel 24.hours
      PlaythroughStageCleanupService.call
      expect(stage.reload).to have_attributes(promotion_state: "promoting", expired_at: nil, cleanup_visits: 0)
      expect(PlaythroughPromotionService.claim_promotion(staging_id: stage.public_id, release_id: release.public_id, package_sha256: stage.package_sha256)).to eq(token)
      copy.push(true)
      expect(Timeout.timeout(10) { copied.pop }).to eq(files.transform_values(&:b))
      PlaythroughStageCleanupService.call
      expect(stage.reload.validation_result).to eq(result)
      finish.push(true)
      thread.value
      PlaythroughStageCleanupService.call
      if outcome == "completed"
        expect(stage.reload).to have_attributes(promotion_state: "published", expired_at: nil, reclaimed_at: nil, cleanup_visits: 0)
        expect(stage.objects.reload.map(&:blob_id)).to all(be_present)
        expect(stage.validation_result).to eq(result)
      else
        expect(stage.reload).to have_attributes(promotion_state: nil, expired_at: stage.declared_at + 24.hours, reclaimed_at: be_present)
        expect(stage.objects.reload.map(&:blob_id)).to all(be_nil)
      end
    ensure
      copy&.push(true)
      finish&.push(true)
      thread&.join
      travel_back
      cleanup_playthrough(release: release) if release
    end
  end

  def cleanup_playthrough(release:)
    stages = PlaythroughStage.where(release: release)
    stages.each do |stage|
      PlaythroughPromotionClaim.where(playthrough_stage: stage).delete_all
      PlaythroughStageAttempt.where(playthrough_stage: stage).delete_all
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
