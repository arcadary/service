require "rails_helper"
require_relative "../support/screenshot_helpers"
require_relative "../support/playthrough_hls_helpers"

RSpec.describe "Uploads through MCP", type: :request do
  include ScreenshotHelpers
  include PlaythroughHlsHelpers
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:release) { create(:release, system: "gb") }
  let(:capture) { { tool: "synthetic-capture", version: "1", captured_at: "2026-11-28T12:00:00+01:00" } }

  before do
    host! "localhost"
    stub_admin_credentials
  end

  def upload(type:, files:)
    requested = mcp_tool(name: "request_upload", type: type)
    files.each do |name, bytes|
      put_upload_file(URI.join(requested.fetch("upload_url"), name).path, bytes: bytes,
        content_type: type == "screenshot" ? "image/png" : hls_content_type(name))
      expect(response).to have_http_status(:ok)
    end
    requested.fetch("upload_id")
  end

  def confirm(upload_id)
    perform_enqueued_jobs { mcp_tool(name: "confirm_upload", upload_id: upload_id) }
  end

  it "uploads a screenshot over HTTP, confirms it and shows it on the release from the media host" do
    requested = mcp_tool(name: "request_upload", type: "screenshot")
    expect(requested.fetch("upload_url")).to eq("http://localhost/v1/uploads/#{requested.fetch("upload_id")}/files/")
    upload_id = upload(type: "screenshot", files: { "title.png" => png })
    expect(mcp_tool(name: "confirm_upload", upload_id: upload_id).fetch("state")).to eq("checking")
    perform_enqueued_jobs
    expect(confirm(upload_id)).to include("state" => "confirmed", "files" => [ include("name" => "title.png") ])

    created = mcp_tool(name: "upload_screenshot", upload_id: upload_id, release_id: release.public_id, kind: "title")
    url = created.dig("screenshot", "url")
    expect(url).to match(%r{\Ahttps://media\.example/screenshots/[0-9a-f]{64}\.png\z})
    expect(Screenshot.sole.blob.service_name).to eq("test_media")
    get "/v1/releases/#{release.sha1}.json"
    expect(response.parsed_body.dig("release", "screenshots", 0, "url")).to eq(url)
    expect(StorageConfigurationService.uploads_root.join(upload_id)).not_to exist
    expect(mcp_tool(name: "upload_screenshot", upload_id: upload_id, release_id: release.public_id, kind: "title")).to eq("code" => "upload_conflict")
  end

  it "stores a confirmed HLS package privately and records it as a playthrough of the release" do
    upload_id = upload(type: "video", files: hls_variant_files)
    expect(confirm(upload_id).fetch("state")).to eq("confirmed")
    stored = ActiveStorage::Blob.service.download("playthroughs/#{upload_id}/low/index.m3u8")
    expect(stored).to eq(hls_variant_files.fetch("low/index.m3u8").b)
    expect(ActiveStorage::Blob.services.fetch(:test_media).exist?("playthroughs/#{upload_id}/low/index.m3u8")).to be(false)

    created = mcp_tool(name: "upload_video", upload_id: upload_id, release_id: release.public_id, source_sha1: release.sha1, capture: capture)
    expect(created.fetch("playthrough")).to include("id" => upload_id, "release_id" => release.public_id, "duration" => "2.5", "video_codec" => "h264", "files" => 6)
    expect(Playthrough.sole.capture).to include("captured_at" => "2026-11-28T11:00:00.000000Z")
    expect(StorageConfigurationService.uploads_root.join(upload_id)).not_to exist
  end

  it "rejects a package whose playlists and segments disagree and goes back to receiving when storing fails" do
    rejected = upload(type: "video", files: hls_files.except("segment.ts"))
    expect(confirm(rejected)).to include("state" => "rejected", "rejection_reason" => "invalid_hls")
    expect(mcp_tool(name: "confirm_upload", upload_id: rejected).fetch("state")).to eq("rejected")
    expect(StorageConfigurationService.uploads_root.join(rejected)).not_to exist

    retried = upload(type: "video", files: hls_files)
    allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(IOError)
    expect(confirm(retried)).to eq("code" => "storage_unavailable")
    expect(Upload.find_by!(public_id: retried).state).to eq("receiving")
    expect(mcp_tool(name: "confirm_upload", upload_id: retried).fetch("state")).to eq("checking")
  end

  it "attaches a video only to the release's own media unless the admin's verification explains the difference" do
    upload_id = upload(type: "video", files: hls_files)
    confirm(upload_id)
    padded = "f" * 40
    arguments = { upload_id: upload_id, release_id: release.public_id, source_sha1: padded, capture: capture }
    expect(mcp_tool(name: "upload_video", **arguments)).to eq("code" => "target_mismatch")

    verification = { source_sha1: padded, payload_sha1: release.sha1, relationship: "trailing_padding", removed_bytes: 127,
      method: "byte comparison", result: "success", verifier: "synthetic-admin", verified_at: "2026-11-28T12:00:00Z",
      evidence: "#{padded} is #{release.sha1} with 127 trailing bytes" }
    expect(mcp_tool(name: "upload_video", **arguments, verification: verification.merge(verifier: "someone")).fetch("code")).to eq("invalid_input")
    expect(mcp_tool(name: "upload_video", **arguments, verification: verification.except(:removed_bytes)).fetch("code")).to eq("invalid_input")
    expect(mcp_tool(name: "upload_video", **arguments, verification: verification).dig("playthrough", "source_sha1")).to eq(padded)
    expect(Playthrough.sole.verification).to include("removed_bytes" => 127, "verified_at" => "2026-11-28T12:00:00.000000Z")
  end

  it "refuses uploads until storage is configured and expires an upload after 24 hours" do
    allow(Rails.application.config.x).to receive(:media_service).and_return(nil)
    expect(mcp_tool(name: "request_upload", type: "screenshot")).to eq("code" => "uploads_disabled")
    allow(Rails.application.config.x).to receive(:media_service).and_call_original
    upload_id = upload(type: "screenshot", files: { "title.png" => png })
    travel 25.hours
    expect(mcp_tool(name: "confirm_upload", upload_id: upload_id)).to eq("code" => "upload_expired")
  end
end
