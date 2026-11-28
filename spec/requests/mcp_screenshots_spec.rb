require "rails_helper"
require_relative "../support/screenshot_helpers"

RSpec.describe "MCP screenshot publication", type: :request do
  include ScreenshotHelpers
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:release) { create(:release, public_id: "a") }
  let(:headers) do
    { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("synthetic-admin", "synthetic-password"),
      "CONTENT_TYPE" => "application/json", "Accept" => "application/json", "MCP-Protocol-Version" => "2025-11-25" }
  end

  before do
    host! "localhost"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_USERNAME").and_return("synthetic-admin")
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return("synthetic-password")
    allow(ENV).to receive(:fetch).with("SCREENSHOT_PUBLIC_BASE_URL", "").and_return("https://images.example")
  end

  def ingest(source: release.sha1, bytes: png)
    post "/v1/screenshot-stages/#{release.public_id}/#{source}/gameplay.json", params: bytes, headers: headers.merge("CONTENT_TYPE" => "image/png")
    expect(response).to have_http_status(:created)
    ScreenshotStage.find_by!(public_id: response.parsed_body.fetch("staging_id"))
  end

  def publish(stage:, **overrides)
    arguments = { staging_id: stage.public_id, release_id: release.public_id, source_sha1: stage.source_sha1, kind: "gameplay" }.merge(overrides)
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "publish_screenshot", arguments: arguments } }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    result = response.parsed_body.fetch("result")
    expect(JSON.parse(result.fetch("content").sole.fetch("text"))).to eq(result.fetch("structuredContent"))
    result
  end

  def expect_failure(stage:, code:, **overrides)
    expect(publish(stage: stage, **overrides)).to include("isError" => true, "structuredContent" => { "error" => { "code" => code } })
  end

  it "publishes a secondary shared medium to its explicit release, transfers its blob and invalidates release/media validators" do
    sibling = create(:release, public_id: "z", game: release.game)
    secondary = create(:release_medium, release: release)
    other = create(:release_medium, media_file: secondary.media_file)
    urls = [ "/v1/releases/#{sibling.sha1}.json", "/v1/media/#{secondary.media_file.sha1}.json" ]
    etags = urls.map do |url|
      get url, headers: { "User-Agent" => "Arcadary/1.0" }
      response.headers.fetch("ETag")
    end
    stage = ingest(source: secondary.media_file.sha1.upcase, bytes: png(chunks: [ png_chunk("tEXt", "Comment\0private image metadata") ]))
    blob, expiry = stage.blob, stage.expires_at
    expect(blob.download).not_to include("private image metadata")
    release.game.update!(screenshot_licence: "CC-BY-4.0")
    result = publish(stage: stage)
    expect(result).to include("isError" => false)
    screenshot = Screenshot.sole
    expect(result.dig("structuredContent", "data")).to eq("release_id" => release.public_id, "screenshot" => ScreenshotDecorator.decorate(screenshot).as_json)
    expect(screenshot).to have_attributes(release_id: release.id, licence: "CC-BY-4.0", blob_id: blob.id)
    expect(other.release.screenshots).to be_empty
    expect(stage.reload).to have_attributes(blob_id: nil, expires_at: expiry)
    expect(stage.consumed_at).to be_present
    expect(ActiveStorage::Blob.count).to eq(1)
    urls.each_with_index do |url, index|
      get url, headers: { "If-None-Match" => etags[index], "User-Agent" => "Arcadary/1.0" }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.to_json).to include(screenshot.sha256)
    end
    get "/v1/screenshots/#{screenshot.sha256}.png"
    expect(response.body.b).to eq(blob.download)
    expect(response.headers["Cache-Control"]).to eq("max-age=31536000, public")
  end

  it "rejects malformed arguments and unknown releases and leaves failed bindings retryable" do
    stage = ingest
    expires_at = stage.expires_at
    expect_failure(stage: stage, code: "invalid_input", staging_id: nil)
    expect_failure(stage: stage, code: "invalid_input", source_sha1: "bad")
    expect_failure(stage: stage, code: "not_found", release_id: "unknown")
    expect_failure(stage: stage, code: "target_mismatch", kind: "title")
    shared = create(:release, sha1: release.sha1)
    expect_failure(stage: stage, code: "target_mismatch", release_id: shared.public_id)
    expect(stage.reload).to have_attributes(consumed_at: nil, expires_at: expires_at)
    expect(publish(stage: stage).fetch("isError")).to be(false)
  end

  it "rechecks current checksum membership and preserves the previous image on failure" do
    previous = upload_screenshot(release: release)
    original, bytes = previous.attributes, previous.blob.download
    medium = create(:release_medium, release: release)
    stage = ingest(source: medium.media_file.sha1)
    medium.destroy!
    expect_failure(stage: stage, code: "target_mismatch")
    expect(stage.reload.consumed_at).to be_nil
    expect(previous.reload.attributes).to eq(original)
    expect(previous.blob.download).to eq(bytes)
  end

  it "accepts only ingest-issued IDs and rejects missing and corrupt staged bytes without replacing an image" do
    previous = upload_screenshot(release: release)
    stage = ingest
    [ "unknown", previous.blob.id.to_s, previous.blob.signed_id, previous.sha256 ].each do |id|
      expect_failure(stage: stage, code: "staged_image_unavailable", staging_id: id)
    end
    stage.blob.service.upload(stage.blob.key, StringIO.new("broken PNG"))
    expect_failure(stage: stage, code: "staged_image_unavailable")
    stage.update!(sha256: Digest::SHA256.hexdigest("broken PNG"))
    expect_failure(stage: stage, code: "staged_image_unavailable")
    stage.blob.delete
    expect_failure(stage: stage, code: "staged_image_unavailable")
    expect(previous.reload.sha256).to eq(ScreenshotPngService.decode(io: StringIO.new(png), system: "gb").fetch(:sha256))
    expect(previous.blob.download).to be_present
    expect(stage.reload.consumed_at).to be_nil
  end

  it "preserves screenshots and the stage through configuration and storage failures" do
    previous = upload_screenshot(release: release)
    original = previous.attributes
    stage = ingest(bytes: png(pixel: "\xff\0\0\xff".b))
    allow(ScreenshotConfigurationService).to receive(:valid_public_base_url?).and_return(false)
    expect_failure(stage: stage, code: "uploads_disabled")
    allow(ScreenshotConfigurationService).to receive(:valid_public_base_url?).and_call_original
    allow(ActiveStorage::Blob.service).to receive(:download).and_raise(IOError)
    expect_failure(stage: stage, code: "storage_unavailable")
    allow(ActiveStorage::Blob.service).to receive(:download).and_call_original
    expect(previous.reload.attributes).to eq(original)
    expect(previous.blob.download).to eq(png.then { |bytes| ScreenshotPngService.decode(io: StringIO.new(bytes), system: "gb").fetch(:bytes) })
    expect(stage.reload.consumed_at).to be_nil
    perform_enqueued_jobs { expect(publish(stage: stage).fetch("isError")).to be(false) }
    expect(previous.blob.service.exist?(previous.blob.key)).to be(false)
  end

  it "retains consumed receipts after replacement/removal until exact expiry and does not renew failed attempts" do
    travel_to Time.current.change(usec: 0) do
      first = ingest
      expiry = first.expires_at
      publish(stage: first)
      replacement = ingest(bytes: png(pixel: "\xff\0\0\xff".b))
      publish(stage: replacement)
      expect_failure(stage: first, code: "staged_image_consumed")
      ScreenshotService.remove(public_id: release.public_id, kind: "gameplay")
      expect_failure(stage: first, code: "staged_image_consumed")
      unconsumed = ingest
      travel 24.hours - 1.second
      expect_failure(stage: unconsumed, code: "target_mismatch", kind: "title")
      expect(unconsumed.reload.expires_at).to eq(expiry)
      expect_failure(stage: first, code: "staged_image_consumed")
      travel 1.second
      expect_failure(stage: first, code: "staged_image_unavailable")
      expect_failure(stage: unconsumed, code: "staged_image_unavailable")
      expect(ScreenshotStage.count).to eq(3)
      perform_enqueued_jobs { ScreenshotStageCleanupService.call }
      expect(ScreenshotStage.count).to eq(0)
      expect_failure(stage: first, code: "staged_image_unavailable")
    end
  end

  it "keeps publication arguments, bytes, checksums and errors out of application logs" do
    stage = ingest
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    begin
      publish(stage: stage)
      expect_failure(stage: stage, code: "staged_image_consumed")
      expect_failure(stage: stage, code: "target_mismatch", kind: "title")
      expect(output.string).to eq("")
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
  end
end
