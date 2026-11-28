require "rails_helper"
require_relative "../support/playthrough_hls_helpers"

RSpec.describe "Playthrough stage lifecycle" do
  include PlaythroughHlsHelpers
  include ActiveSupport::Testing::TimeHelpers

  let!(:release) { create(:release) }
  let(:declaration) { playthrough_declaration(release: release) }

  it "expires validated results at the original declaration deadline before replay" do
    freeze_time do
      files = hls_files
      stage = declare_hls(release: release, files: files)
      receive_hls(stage: stage, files: files)
      result = PlaythroughValidationService.validate(staging_id: stage.public_id)
      travel 24.hours - 1
      expect(PlaythroughValidationService.validate(staging_id: stage.public_id)).to eq(result)
      token = PlaythroughUploadAuthorizationService.issue(stage: stage)
      expect(Time.iso8601(token.fetch(:expires_at))).to eq(Time.current + 900)
      travel 1
      expect { PlaythroughValidationService.validate(staging_id: stage.public_id) }.to raise_error(PlaythroughStage::Expired)
      expect(stage.reload.expired_at).to eq(stage.declared_at + 24.hours)
      expect { PlaythroughUploadAuthorizationService.issue(stage: stage) }.to raise_error(PlaythroughStage::Expired)
      PlaythroughStageCleanupService.call
      expect(stage.reload.reclaimed_at).to be_present
      expect(stage.validation_result).to eq(result.except("manifest"))
      expect(stage.declaration).not_to have_key("manifest")
    end
  end

  it "prunes all manifest copies while retaining identity, mismatch evidence and reserved retry keys" do
    freeze_time do
      declaration["source_sha1"] = "f" * 40
      declaration["verification"] = playthrough_verification(source: "f" * 40, payload: release.sha1)
      stage = declare_playthrough
      object_id = stage.objects.sole.public_id
      receive_playthrough(stage: stage)
      expect { PlaythroughValidationService.validate(staging_id: stage.public_id) }.to raise_error(PlaythroughStage::InvalidHls)
      original = stage.reload.declaration.except("manifest")
      travel 25.hours
      expect { PlaythroughValidationService.validate(staging_id: stage.public_id) }.to raise_error(PlaythroughStage::Expired)
      PlaythroughStageCleanupService.call
      receipt = PlaythroughStagingService.find_by(staging_id: stage.public_id)
      expect(receipt.declaration).to eq(original)
      expect(receipt.expired_at).to eq(stage.declared_at + 24.hours)
      expect(receipt.reclaimed_at).to eq(Time.current)
      expect(receipt.objects.sole).to have_attributes(public_id: object_id, path: nil, byte_size: nil, sha256: nil, content_type: nil, blob_id: nil)
      expect(ActiveStorage::Blob.count).to eq(0)
      expect { declare_playthrough }.to raise_error(PlaythroughStage::Expired)
      expect { declare_playthrough(input: declaration.merge("capture" => declaration["capture"].merge("version" => "2"))) }
        .to raise_error(PlaythroughStage::Conflict)
    end
  end

  it "recovers at exact lease equality and fences only the abandoned attempt" do
    freeze_time do
      stage = declare_playthrough
      first = PlaythroughLifecycleService.synchronize(stage_id: stage.id) { |current| PlaythroughAttemptService.register(stage: current, kind: "validation") }
      travel 1.minute
      live = PlaythroughLifecycleService.synchronize(stage_id: stage.id) { |current| PlaythroughAttemptService.register(stage: current, kind: "validation") }
      travel 14.minutes
      expect { PlaythroughAttemptService.renew(attempt: first) }.to raise_error(PlaythroughStage::Conflict)
      PlaythroughLifecycleService.synchronize(stage_id: stage.id) { |current| PlaythroughAttemptService.fence_stale(stage: current) }
      expect(first.reload).to have_attributes(state: "fenced", generation: 2)
      expect(live.reload).to have_attributes(state: "active", generation: 1)
      expect { PlaythroughAttemptService.renew(attempt: live) }.to change { live.reload.lease_expires_at }.by(14.minutes)
    end
  end

  it "keeps failed deletions pending, continues other work and retries after restart" do
    freeze_time do
      stage = declare_playthrough
      receive_playthrough(stage: stage)
      other = declare_playthrough(input: declaration.merge("retry_key" => "other"))
      receive_playthrough(stage: other)
      key = stage.objects.sole.reload.blob.key
      service = ActiveStorage::Blob.service
      allow(service).to receive(:delete).and_call_original
      allow(service).to receive(:delete).with(key).and_wrap_original do |method, private_key|
        method.call(private_key)
        raise IOError, "private failure after deletion"
      end
      travel 24.hours
      expect { PlaythroughStageCleanupService.call }.to raise_error(PlaythroughStage::StorageUnavailable, "storage_unavailable")
      expect(stage.reload.reclaimed_at).to be_nil
      expect(stage.attempts.find_by!(kind: "transfer").cleanup_pending).to be(true)
      expect(service.exist?(key)).to be(false)
      expect(other.reload.reclaimed_at).to be_present
      allow(service).to receive(:delete).with(key).and_call_original
      PlaythroughStageCleanupService.call
      expect(stage.reload.reclaimed_at).to be_present
      expect(stage.attempts.find_by!(kind: "transfer").cleanup_pending).to be(false)
    end
  end

  it "preserves reclaimed receipts throughout clean tombstone revisits" do
    freeze_time do
      stage = declare_playthrough
      receive_playthrough(stage: stage)
      travel 24.hours
      PlaythroughStageCleanupService.call
      reclaimed_at = stage.reload.reclaimed_at
      attempt = stage.attempts.find_by!(kind: "transfer")
      travel 1.hour
      service = ActiveStorage::Blob.service
      allow(service).to receive(:exist?).with(attempt.private_key).and_wrap_original do |method, key|
        expect(stage.reload.reclaimed_at).to eq(reclaimed_at)
        expect(attempt.reload.cleanup_pending).to be(false)
        method.call(key)
      end
      PlaythroughStageCleanupService.call
      expect(stage.reload.reclaimed_at).to eq(reclaimed_at)
    end
  end

  it "revisits reclaimed tombstones after a late write and failed self-deletion" do
    freeze_time do
      stage = declare_playthrough
      object, attempt = PlaythroughTransferService.send(:prepare, stage: stage, object_id: stage.objects.sole.public_id, content_type: "video/mp2t")
      travel 24.hours
      PlaythroughStageCleanupService.call
      expect(stage.reload.reclaimed_at).to be_present
      expect(attempt.reload.state).to eq("fenced")
      service = ActiveStorage::Blob.service
      service.upload(attempt.private_key, StringIO.new("late bytes"))
      allow(service).to receive(:delete).with(attempt.private_key).and_raise(IOError)
      PlaythroughReclamationService.discard(attempt: attempt)
      expect(stage.reload.reclaimed_at).to be_nil
      expect(attempt.reload.cleanup_pending).to be(true)
      allow(service).to receive(:delete).with(attempt.private_key).and_call_original
      PlaythroughStageCleanupService.call
      expect(stage.reload.reclaimed_at).to be_present
      expect(service.exist?(attempt.private_key)).to be(false)
      expect(stage.objects.find(object.id).blob_id).to be_nil
      service.upload(attempt.private_key, StringIO.new("crashed before recording pending work"))
      allow(service).to receive(:delete).with(attempt.private_key).and_wrap_original do |method, key|
        expect(stage.reload.reclaimed_at).to be_nil
        expect(attempt.reload.cleanup_pending).to be(true)
        method.call(key)
      end
      PlaythroughStageCleanupService.call
      expect(service.exist?(attempt.private_key)).to be(false)
      expect(stage.attempts.find(attempt.id).private_key).to eq(attempt.private_key)
    end
  end

  it "protects legacy uploads before their owning declaration deadline and unrelated attachments afterward" do
    freeze_time do
      stage = declare_playthrough
      orphan = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("legacy"), filename: "synthetic",
        key: "playthrough-stages/#{stage.public_id}/legacy")
      unrelated = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("unrelated"), filename: "synthetic")
      PlaythroughStageCleanupService.call
      expect(orphan.download).to eq("legacy")
      travel 24.hours
      PlaythroughStageCleanupService.call
      expect(ActiveStorage::Blob.exists?(orphan.id)).to be(false)
      expect(unrelated.download).to eq("unrelated")
      expect(stage.reload.reclaimed_at).to be_present
    end
  end

  it "skips expiry reclamation while a validator retains a live lease" do
    freeze_time do
      stage = declare_playthrough
      receive_playthrough(stage: stage)
      travel 24.hours - 1.minute
      attempt = PlaythroughLifecycleService.synchronize(stage_id: stage.id) { |current| PlaythroughAttemptService.register(stage: current, kind: "validation") }
      travel 1.minute
      PlaythroughStageCleanupService.call
      expect(stage.reload).to have_attributes(expired_at: stage.declared_at + 24.hours, reclaimed_at: nil)
      expect(stage.objects.sole.reload.blob.download).to eq("synthetic segment")
      expect { PlaythroughAttemptService.renew(attempt: attempt) }.to raise_error(PlaythroughStage::Expired)
      PlaythroughAttemptService.relinquish(attempt: attempt)
      PlaythroughStageCleanupService.call
      expect(stage.reload.reclaimed_at).to be_present
    end
  end

  it "bounds blob work at 500 and fairly advances a larger package across invocations" do
    freeze_time do
      entry = declaration.fetch("manifest").first
      declaration["manifest"] = Array.new(501) { |index| entry.merge("path" => "#{index}.ts") }
      stage = declare_playthrough
      stage.objects.each do |object|
        blob = ActiveStorage::Blob.create_before_direct_upload!(filename: "synthetic", byte_size: object.byte_size,
          checksum: Digest::MD5.base64digest("synthetic segment"), content_type: object.content_type,
          key: "playthrough-stages/#{stage.public_id}/#{object.public_id}/legacy")
        object.update!(blob: blob, received_at: Time.current)
      end
      travel 24.hours
      allow(ActiveStorage::Blob.service).to receive(:delete).and_call_original
      PlaythroughStageCleanupService.call
      expect(ActiveStorage::Blob.service).to have_received(:delete).exactly(500).times
      expect(stage.reload.reclaimed_at).to be_nil
      expect(stage.objects.where.not(blob_id: nil).count).to eq(1)
      PlaythroughStageCleanupService.call
      expect(ActiveStorage::Blob.service).to have_received(:delete).exactly(501).times
      expect(stage.reload.reclaimed_at).to be_present
      expect(stage.attempts.where(kind: "transfer").count).to eq(501)
    end
  end

  it "bounds stage work at 100 and revisits retained receipts fairly" do
    freeze_time do
      stages = Array.new(101) { declare_playthrough(input: declaration.merge("retry_key" => SecureRandom.uuid)) }
      travel 24.hours
      PlaythroughStageCleanupService.call
      expect(PlaythroughStage.where.not(reclaimed_at: nil).count).to eq(100)
      PlaythroughStageCleanupService.call
      expect(stages.last.reload.reclaimed_at).to be_present
      expect(PlaythroughStage.where(cleanup_visits: 0).count).to eq(0)
    end
  end

  it "suppresses all cleanup and ownership failure logs and schedules cleanup after screenshots" do
    stage = declare_playthrough
    receive_playthrough(stage: stage)
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    begin
      travel_to stage.declared_at + 24.hours, with_usec: true do
        allow(ActiveStorage::Blob.service).to receive(:delete).and_raise(IOError, "private failure")
        expect { PlaythroughStageCleanupJob.perform_now }.to raise_error(PlaythroughStage::StorageUnavailable)
        expect(output.string).to eq("")
      end
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production")
    expect(schedule.keys.index("cleanup_playthrough_stages")).to be > schedule.keys.index("cleanup_screenshot_stages")
    expect(schedule.fetch("cleanup_playthrough_stages")).to eq("class" => "PlaythroughStageCleanupJob", "schedule" => "every hour at minute 5")
  end
end
