require "rails_helper"
require_relative "../support/playthrough_hls_helpers"

RSpec.describe PlaythroughValidationService do
  include PlaythroughHlsHelpers

  let!(:release) { create(:release) }
  let(:files) { hls_files }
  let(:stage) { declare_hls(release: release, files: files) }

  def validate_stage
    described_class.validate(staging_id: stage.public_id)
  end

  it "persists exact identity and replays success after restart without any storage or parsing" do
    receive_hls(stage: stage, files: files)
    result = validate_stage
    expect(stage.reload.validation_state).to eq("validated")
    expect(result).to include("staging_id" => stage.public_id, "declaration_sha256" => stage.declaration_sha256,
      "package_sha256" => stage.package_sha256, "manifest" => stage.declaration.fetch("manifest"),
      "release_id" => release.public_id, "source_sha1" => release.sha1, "capture" => stage.declaration.fetch("capture"), "verification" => nil)
    expect(result).to include("root" => "index.m3u8", "duration" => "2.5", "video_codec" => "h264", "audio_codec" => "aac")
    stage.objects.first.blob.delete
    expect(ActiveStorage::Blob.service).not_to receive(:download)
    expect(PlaythroughHlsService).not_to receive(:validate)
    expect(validate_stage).to eq(result)
    expect(declare_playthrough(input: stage.declaration).validation_result).to eq(result)
    expect(receive_playthrough(stage: stage, object: stage.objects.first, bytes: files.fetch(stage.objects.first.path)).received_at).to be_present
  end

  it "retains the verified source/payload distinction and full capture provenance" do
    input = playthrough_declaration(release: release).merge("source_sha1" => "f" * 40,
      "verification" => playthrough_verification(source: "f" * 40, payload: release.sha1), "manifest" => stage.declaration.fetch("manifest"))
    verified = declare_playthrough(input: input)
    receive_hls(stage: verified, files: files)
    result = described_class.validate(staging_id: verified.public_id)
    expect(result).to include("source_sha1" => "f" * 40, "verification" => verified.declaration.fetch("verification"), "release_id" => release.public_id)
  end

  it "returns not_found for an unknown staging ID without storage reads" do
    expect(ActiveStorage::Blob.service).not_to receive(:download)
    expect { described_class.validate(staging_id: "unknown") }.to raise_error(PlaythroughStage::NotFound)
  end

  [ "application/vnd.apple.mpegurl", "video/mp4" ].each do |mime|
    it "checks completeness before a malformed received playlist with #{mime}" do
      broken_files = files.merge("index.m3u8" => "private malformed playlist")
      partial = declare_hls(release: release, files: broken_files, types: { "index.m3u8" => mime })
      object = partial.objects.find_by!(path: "index.m3u8")
      receive_playthrough(stage: partial, object: object, bytes: broken_files.fetch("index.m3u8"))
      expect(ActiveStorage::Blob.service).not_to receive(:download)
      expect { described_class.validate(staging_id: partial.public_id) }.to raise_error(PlaythroughStage::StageIncomplete, "stage_incomplete")
      expect(partial.reload.validation_state).to be_nil
    end
  end

  it "persists malformed HLS failure and replays it without reading even when storage changes" do
    files["index.m3u8"] = "private malformed playlist"
    receive_hls(stage: stage, files: files)
    expect { validate_stage }.to raise_error(PlaythroughStage::InvalidHls, "invalid_hls")
    expect(stage.reload.validation_state).to eq("validation_failed")
    expect(stage.validation_error).to eq("invalid_hls")
    stage.objects.first.blob.delete
    expect(ActiveStorage::Blob.service).not_to receive(:download)
    expect(PlaythroughHlsService).not_to receive(:validate)
    expect { validate_stage }.to raise_error(PlaythroughStage::InvalidHls, "invalid_hls")
    expect(declare_playthrough(input: stage.declaration).validation_error).to eq("invalid_hls")
  end

  it "makes a completed wrong-role MIME terminal invalid_hls" do
    wrong = declare_hls(release: release, files: files, types: { "index.m3u8" => "video/mp4" })
    receive_hls(stage: wrong, files: files)
    expect { described_class.validate(staging_id: wrong.public_id) }.to raise_error(PlaythroughStage::InvalidHls)
    expect(wrong.reload.validation_error).to eq("invalid_hls")
  end

  it "allows incomplete stages to complete and validate later" do
    expect { validate_stage }.to raise_error(PlaythroughStage::StageIncomplete)
    receive_hls(stage: stage, files: files)
    expect(validate_stage.fetch("staging_id")).to eq(stage.public_id)
  end

  it "retries missing blobs after storage is restored" do
    receive_hls(stage: stage, files: files)
    object = stage.objects.first.reload
    object.blob.delete
    expect { validate_stage }.to raise_error(PlaythroughStage::StorageUnavailable, "storage_unavailable") { |error| expect(error.cause).to be_nil }
    expect(stage.reload.validation_state).to be_nil
    object.blob.upload_without_unfurling(StringIO.new(files.fetch(object.path)))
    expect(validate_stage.fetch("staging_id")).to eq(stage.public_id)
  end

  it "retries unreadable storage without persisting an outcome" do
    receive_hls(stage: stage, files: files)
    allow(ActiveStorage::Blob.service).to receive(:download).and_raise(IOError, "private unreadable blob")
    expect { validate_stage }.to raise_error(PlaythroughStage::StorageUnavailable, "storage_unavailable")
    expect(stage.reload.validation_state).to be_nil
    allow(ActiveStorage::Blob.service).to receive(:download).and_call_original
    expect(validate_stage.fetch("staging_id")).to eq(stage.public_id)
  end

  it "checks every object's integrity before interpreting any playlist" do
    files["index.m3u8"] = "malformed playlist"
    receive_hls(stage: stage, files: files)
    object = stage.objects.find_by!(path: "segment.ts")
    object.blob.service.upload(object.blob.key, StringIO.new("changed readable bytes"))
    expect(PlaythroughHlsService).not_to receive(:validate)
    expect { validate_stage }.to raise_error(PlaythroughStage::PackageIntegrityMismatch, "package_integrity_mismatch")
    expect(stage.reload.validation_error).to eq("package_integrity_mismatch")
    expect(ActiveStorage::Blob.service).not_to receive(:download)
    expect { validate_stage }.to raise_error(PlaythroughStage::PackageIntegrityMismatch)
  end

  [ { byte_size: 1 }, { content_type: "video/mp4" }, { checksum: "AAAAAAAAAAAAAAAAAAAAAA==" } ].each do |attributes|
    it "makes altered stored metadata #{attributes.keys.sole} a terminal integrity failure" do
      receive_hls(stage: stage, files: files)
      stage.objects.first.reload.blob.update!(attributes)
      expect { validate_stage }.to raise_error(PlaythroughStage::PackageIntegrityMismatch)
      expect(stage.reload.validation_error).to eq("package_integrity_mismatch")
    end
  end

  it "suppresses all internal validation logs on success, terminal failure and retryable failure" do
    receive_hls(stage: stage, files: files)
    invalid = declare_hls(release: release, files: files.merge("index.m3u8" => "private broken playlist"))
    receive_hls(stage: invalid, files: files.merge("index.m3u8" => "private broken playlist"))
    unavailable = declare_hls(release: release, files: files)
    receive_hls(stage: unavailable, files: files)
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    begin
      validate_stage
      expect { described_class.validate(staging_id: invalid.public_id) }.to raise_error(PlaythroughStage::InvalidHls)
      allow(ActiveStorage::Blob.service).to receive(:download).and_raise(IOError, "private failure")
      expect { described_class.validate(staging_id: unavailable.public_id) }.to raise_error(PlaythroughStage::StorageUnavailable)
      expect(output.string).to eq("")
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
  end
end
