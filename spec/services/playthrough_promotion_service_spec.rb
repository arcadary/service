require "rails_helper"
require_relative "../support/playthrough_hls_helpers"

RSpec.describe PlaythroughPromotionService do
  include PlaythroughHlsHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:release) { create(:release) }
  let(:files) { hls_files }
  let(:stage) { declare_hls(release: release, files: files) }

  def claim(stage: self.stage, release_id: release.public_id, package_sha256: stage.package_sha256)
    described_class.claim_promotion(staging_id: stage.public_id, release_id: release_id, package_sha256: package_sha256)
  end

  def validate_stage
    receive_hls(stage: stage, files: files)
    result = PlaythroughValidationService.validate(staging_id: stage.public_id)
    stage.reload
    result
  end

  it "requires a known validated stage and its exact stable release and package" do
    expect { described_class.claim_promotion(staging_id: "unknown", release_id: release.public_id, package_sha256: stage.package_sha256) }
      .to raise_error(PlaythroughStage::NotFound, "not_found")
    expect { claim }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
    validate_stage
    expect { claim(release_id: create(:release).public_id) }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
    expect { claim(package_sha256: "0" * 64) }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
    token = claim
    expect(claim).to eq(token)
    expect(stage.reload).to have_attributes(promotion_state: "promoting", validation_state: "validated")
    expect { claim(release_id: create(:release).public_id) }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
  end

  it "rejects changed persisted validation bindings and never creates a pin" do
    validate_stage
    stage.update!(validation_result: stage.validation_result.merge("release_id" => create(:release).public_id))
    expect { claim }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
    expect(stage.reload.promotion_state).to be_nil
    expect(stage.promotion_claims).to be_empty
  end

  it "allows promotion after an identical PUT retry leaves orphan cleanup pending" do
    validate_stage
    original_objects = stage.objects.map(&:attributes)
    object = stage.objects.first
    allow(ActiveStorage::Blob.service).to receive(:delete).and_raise(IOError)
    receive_playthrough(stage: stage, object: object, bytes: files.fetch(object.path))
    allow(ActiveStorage::Blob.service).to receive(:delete).and_call_original
    pending = stage.attempts.where(cleanup_pending: true).sole

    expect(claim).to be_present
    PlaythroughReclamationService.discard(attempt: pending)
    expect(pending.reload.cleanup_pending).to be(false)
    expect(stage.reload.promotion_state).to eq("promoting")
    expect(stage.objects.reload.map(&:attributes)).to eq(original_objects)
    expect(stage.objects.map { |entry| entry.blob.download.b }).to eq(stage.objects.map { |entry| files.fetch(entry.path).b })
  end

  it "rejects claims at the original deadline and after reclamation" do
    validate_stage
    travel_to stage.declared_at + 24.hours, with_usec: true do
      expect { claim }.to raise_error(PlaythroughStage::Expired, "stage_expired")
      PlaythroughStageCleanupService.call
      expect(stage.reload.reclaimed_at).to be_present
      expect { claim }.to raise_error(PlaythroughStage::Expired, "stage_expired")
    end
  end

  it "keeps active claims durable beyond the deadline and completes once after restart" do
    validate_stage
    token = claim
    travel_to stage.declared_at + 48.hours, with_usec: true do
      stage.reload
      expect(claim).to eq(token)
      described_class.complete_promotion(claim: token.dup)
      described_class.complete_promotion(claim: token.dup)
      expect(stage.reload).to have_attributes(promotion_state: "published", expired_at: nil, reclaimed_at: nil)
      expect { described_class.release_promotion(claim: token) }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
      expect { claim }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
    end
  end

  it "releases before the deadline and fences the old identity through a fresh claim and completion" do
    validate_stage
    old = claim
    described_class.release_promotion(claim: old)
    expect(stage.reload.promotion_state).to be_nil
    expect(stage.validation_state).to eq("validated")
    fresh = claim
    expect(fresh).not_to eq(old)
    described_class.release_promotion(claim: old.dup)
    expect { described_class.complete_promotion(claim: old) }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
    expect(stage.reload.promotion_state).to eq("promoting")
    described_class.complete_promotion(claim: fresh)
    described_class.release_promotion(claim: old.dup)
    expect(stage.reload.promotion_state).to eq("published")
  end

  it "releases at the deadline into expiry and replays release after cleanup" do
    validate_stage
    token = claim
    travel_to stage.declared_at + 24.hours, with_usec: true do
      described_class.release_promotion(claim: token)
      expect(stage.reload).to have_attributes(promotion_state: nil, expired_at: stage.declared_at + 24.hours)
      PlaythroughStageCleanupService.call
      expect(stage.reload.reclaimed_at).to be_present
      described_class.release_promotion(claim: token.dup)
      expect { described_class.complete_promotion(claim: token) }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
      expect { claim }.to raise_error(PlaythroughStage::Expired, "stage_expired")
    end
  end

  it "rejects wrong claims without releasing the pin" do
    validate_stage
    token = claim
    expect { described_class.complete_promotion(claim: "0" * 96) }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
    expect { described_class.release_promotion(claim: "wrong") }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
    expect(claim).to eq(token)
  end

  it "rolls completion back with the caller's release-pointer transaction" do
    validate_stage
    token = claim
    PlaythroughStage.transaction do
      described_class.complete_promotion(claim: token)
      expect(stage.reload.promotion_state).to eq("published")
      raise ActiveRecord::Rollback
    end
    expect(stage.reload.promotion_state).to eq("promoting")
    expect(stage.promotion_claims.sole.state).to eq("active")
    expect(claim).to eq(token)
    described_class.complete_promotion(claim: token)
    expect(stage.reload.promotion_state).to eq("published")
  end

  %w[promoting published].each do |state|
    it "preserves #{state} validation, PUT and begin replays until the deadline, including reloaded callers" do
      expected = validate_stage
      original_objects = stage.objects.map(&:attributes)
      token = claim
      described_class.complete_promotion(claim: token) if state == "published"
      allow(PlaythroughHlsService).to receive(:validate).and_raise("must not revalidate")
      allow(ActiveStorage::Blob.service).to receive(:download).and_raise("must not read storage")
      allow(ActiveStorage::Blob.service).to receive(:upload).and_raise("must not write storage")
      stage.reload
      expect(PlaythroughValidationService.validate(staging_id: stage.public_id)).to eq(expected)
      receive_hls(stage: stage, files: files)
      expect(stage.objects.reload.map(&:attributes)).to eq(original_objects)
      first = McpPlaythroughToolsService.call(arguments: stage.declaration).structured_content.fetch(:data)
      second = McpPlaythroughToolsService.call(arguments: stage.declaration).structured_content.fetch(:data)
      expect(first.except(:capability, :expires_at)).to eq(second.except(:capability, :expires_at))
      expect(first.fetch(:state)).to eq("received")
      expect(first.fetch(:staging_id)).to eq(stage.public_id)
      expect(first.fetch(:capability)).not_to eq(second.fetch(:capability))
      travel_to stage.declared_at + 24.hours, with_usec: true do
        expect { PlaythroughValidationService.validate(staging_id: stage.public_id) }.to raise_error(PlaythroughStage::Expired, "stage_expired")
        result = McpPlaythroughToolsService.call(arguments: stage.declaration).structured_content
        expect(result).to eq(error: { code: "stage_expired" })
        changed = McpPlaythroughToolsService.call(arguments: stage.declaration.merge("capture" => stage.declaration.fetch("capture").merge("version" => "changed")))
        expect(changed.structured_content).to eq(error: { code: "stage_conflict" })
        expect(stage.reload).to have_attributes(promotion_state: state, expired_at: nil, reclaimed_at: nil)
      end
    end
  end

  it "excludes protected stages from bounded cleanup visits while retaining every published package" do
    validate_stage
    first = stage
    token = claim
    published = declare_hls(release: release, files: files)
    receive_hls(stage: published, files: files)
    PlaythroughValidationService.validate(staging_id: published.public_id)
    described_class.complete_promotion(claim: claim(stage: published))
    published_receipt = PlaythroughStageDecorator.decorate(published.reload).as_json
    unprotected = declare_hls(release: release, files: files)
    travel_to first.declared_at + 48.hours, with_usec: true do
      stub_const("PlaythroughStageCleanupService::STAGE_LIMIT", 1)
      PlaythroughStageCleanupService.call
      expect(unprotected.reload.reclaimed_at).to be_present
      [ first, published ].each do |protected_stage|
        expect(protected_stage.reload).to have_attributes(cleanup_visits: 0, expired_at: nil, reclaimed_at: nil)
        expect(protected_stage.objects.map { |object| object.blob.download.b }).to eq(protected_stage.objects.map { |object| files.fetch(object.path).b })
      end
      described_class.complete_promotion(claim: token)
      PlaythroughStageCleanupService.call
      expect(PlaythroughStageDecorator.decorate(published.reload).as_json).to eq(published_receipt)
      expect(first.reload.cleanup_visits).to eq(0)
    end
  end

  it "suppresses claim secrets, evidence and failures from logs and receipts" do
    validate_stage
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    begin
      token = claim
      expect { claim(package_sha256: "private-invalid-digest") }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
      expect { described_class.complete_promotion(claim: "private-invalid-token") }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
      described_class.complete_promotion(claim: token)
      expect { described_class.release_promotion(claim: token) }.to raise_error(PlaythroughStage::Conflict, "stage_conflict")
      expect(output.string).to eq("")
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
    expect(stage.promotion_claims.sole.inspect).not_to include(token)
    expect(JSON.generate(PlaythroughStageDecorator.decorate(stage.reload).as_json)).not_to include(token)
  end
end
