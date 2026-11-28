require "rails_helper"
require_relative "../support/screenshot_helpers"
require_relative "../support/video_hls_helpers"

RSpec.describe "Uploads through MCP", type: :request do
  include ScreenshotHelpers
  include VideoHlsHelpers
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

  it "copies a confirmed HLS package to the media host and links it from the release once it is a video" do
    media = StorageConfigurationService.media_service
    allow(media).to receive(:upload).and_call_original
    upload_id = upload(type: "video", files: hls_variant_files)
    expect(confirm(upload_id).fetch("state")).to eq("confirmed")
    expect(media.download(VideoService.key(public_id: upload_id, name: "low/index.m3u8"))).to eq(hls_variant_files.fetch("low/index.m3u8").b)
    { "index.m3u8" => "application/vnd.apple.mpegurl", "low/segment.ts" => "video/mp2t", "chapters.vtt" => "text/vtt" }.each do |name, content_type|
      expect(media).to have_received(:upload).with(VideoService.key(public_id: upload_id, name: name), anything, hash_including(content_type: content_type))
    end
    get "/v1/releases/#{release.sha1}.json"
    expect(response.parsed_body.dig("release", "videos")).to eq([])

    created = mcp_tool(name: "upload_video", upload_id: upload_id, release_id: release.public_id, kind: "playthrough", source_sha1: release.sha1, capture: capture)
    published = { "kind" => "playthrough", "url" => "https://media.example/videos/#{upload_id}/index.m3u8", "duration" => 2.5,
                  "chapters" => [ { "start" => 0.0, "end" => 2.5, "title" => "First chapter" } ] }
    expect(created).to include("release_id" => release.public_id, "video" => include(published.merge("id" => upload_id, "format" => "ts", "audio" => true, "files" => 6)))
    expect(Video.sole.capture).to include("captured_at" => "2026-11-28T11:00:00.000000Z")
    expect(StorageConfigurationService.uploads_root.join(upload_id)).not_to exist
    get "/v1/releases/#{release.sha1}.json"
    expect(response.parsed_body.dig("release", "videos")).to eq([ published ])
    expect(response.body).not_to include("synthetic-capture", "synthetic-admin")
  end

  it "publishes a single-file fragmented MP4 package with video/mp4 objects and refuses a file that is not MP4" do
    media = StorageConfigurationService.media_service
    allow(media).to receive(:upload).and_call_original
    upload_id = upload(type: "video", files: hls_fmp4_files)
    put_upload_file("/v1/uploads/#{upload_id}/files/other.mp4", bytes: "not an MP4 box", content_type: "video/mp4")
    expect(response).to have_http_status(:unprocessable_content)
    expect(confirm(upload_id).fetch("state")).to eq("confirmed")

    created = mcp_tool(name: "upload_video", upload_id: upload_id, release_id: release.public_id, kind: "playthrough", source_sha1: release.sha1, capture: capture)
    expect(created.fetch("video")).to include("duration" => 2.5, "format" => "fmp4", "audio" => nil, "files" => 2)
    expect(media).to have_received(:upload).with(VideoService.key(public_id: upload_id, name: "index.mp4"), anything, hash_including(content_type: "video/mp4"))
    expect(media).to have_received(:upload).with(VideoService.key(public_id: upload_id, name: "index.m3u8"), anything, hash_including(content_type: "application/vnd.apple.mpegurl"))
  end

  it "replaces the release's playthrough and deletes the previous one's files, keeping the results it was attached to" do
    arguments = { release_id: release.public_id, kind: "playthrough", source_sha1: release.sha1, capture: capture }
    first = upload(type: "video", files: hls_files)
    confirm(first)
    mcp_tool(name: "upload_video", upload_id: first, **arguments)
    result = create(:compatibility_result, release: release, videos: [ Video.sole ])
    second = upload(type: "video", files: hls_fmp4_files)
    confirm(second)

    expect(mcp_tool(name: "upload_video", upload_id: second, **arguments).dig("video", "id")).to eq(second)
    expect(release.videos.reload.map(&:public_id)).to eq([ second ])
    expect(StorageConfigurationService.media_service.exist?(VideoService.key(public_id: first, name: "index.m3u8"))).to be(false)
    expect(result.reload.videos).to be_empty
  end

  it "rejects a package whose playlists and segments disagree and goes back to receiving when storing fails" do
    rejected = upload(type: "video", files: hls_files.except("segment.ts"))
    expect(confirm(rejected)).to include("state" => "rejected", "rejection_reason" => "invalid_hls")
    expect(mcp_tool(name: "confirm_upload", upload_id: rejected).fetch("state")).to eq("rejected")
    expect(StorageConfigurationService.uploads_root.join(rejected)).not_to exist

    retried = upload(type: "video", files: hls_files)
    allow(StorageConfigurationService.media_service).to receive(:upload).and_raise(IOError)
    expect(confirm(retried)).to eq("code" => "storage_unavailable")
    expect(Upload.find_by!(public_id: retried).state).to eq("receiving")
    expect(mcp_tool(name: "confirm_upload", upload_id: retried).fetch("state")).to eq("checking")
  end

  it "keeps the previous video, files and evidence attachments when the database replacement fails" do
    arguments = { release_id: release.public_id, kind: "playthrough", source_sha1: release.sha1, capture: capture }
    first = upload(type: "video", files: hls_files)
    confirm(first)
    mcp_tool(name: "upload_video", upload_id: first, **arguments)
    result = create(:compatibility_result, release: release, videos: [ Video.sole ])
    second = upload(type: "video", files: hls_fmp4_files)
    confirm(second)
    allow(Video).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

    expect { VideoService.create(upload_id: second, verifier: "synthetic-admin", **arguments) }.to raise_error(ActiveRecord::RecordNotUnique)

    expect(release.videos.reload.map(&:public_id)).to eq([ first ])
    expect(result.reload.videos.map(&:public_id)).to eq([ first ])
    expect(StorageConfigurationService.media_service.exist?(VideoService.key(public_id: first, name: "index.m3u8"))).to be(true)
    expect(Upload.find_by!(public_id: second).state).to eq("confirmed")
  end

  it "keeps the new publication and retries deletion when the replaced video's storage is unavailable" do
    arguments = { release_id: release.public_id, kind: "playthrough", source_sha1: release.sha1, capture: capture }
    first = upload(type: "video", files: hls_files)
    confirm(first)
    mcp_tool(name: "upload_video", upload_id: first, **arguments)
    second = upload(type: "video", files: hls_fmp4_files)
    confirm(second)
    media = StorageConfigurationService.media_service
    allow(media).to receive(:delete_prefixed).and_raise(IOError)

    expect do
      expect(mcp_tool(name: "upload_video", upload_id: second, **arguments).dig("video", "id")).to eq(second)
    end.to have_enqueued_job(VideoFileCleanupJob).with(first)
    expect(release.videos.reload.map(&:public_id)).to eq([ second ])
    expect(Upload.find_by!(public_id: second).state).to eq("used")

    allow(media).to receive(:delete_prefixed).and_call_original
    perform_enqueued_jobs(only: VideoFileCleanupJob)
    expect(media.exist?(VideoService.key(public_id: first, name: "index.m3u8"))).to be(false)
    expect(media.exist?(VideoService.key(public_id: second, name: "index.m3u8"))).to be(true)
  end

  it "attaches a video only to the release's own media unless the admin's verification explains the difference" do
    upload_id = upload(type: "video", files: hls_files)
    confirm(upload_id)
    padded = "f" * 40
    arguments = { upload_id: upload_id, release_id: release.public_id, kind: "playthrough", source_sha1: padded, capture: capture }
    expect(mcp_tool(name: "upload_video", **arguments)).to eq("code" => "target_mismatch")
    expect(mcp_tool(name: "upload_video", **arguments, kind: "trailer")).to eq("code" => "invalid_input")

    verification = { source_sha1: padded, payload_sha1: release.sha1, relationship: "trailing_padding", removed_bytes: 127,
      method: "byte comparison", result: "success", verifier: "synthetic-admin", verified_at: "2026-11-28T12:00:00Z",
      evidence: "#{padded} is #{release.sha1} with 127 trailing bytes" }
    expect(mcp_tool(name: "upload_video", **arguments, verification: verification.merge(verifier: "someone")).fetch("code")).to eq("invalid_input")
    expect(mcp_tool(name: "upload_video", **arguments, verification: verification.except(:removed_bytes)).fetch("code")).to eq("invalid_input")
    expect(mcp_tool(name: "upload_video", **arguments, verification: verification).dig("video", "source_sha1")).to eq(padded)
    expect(Video.sole.verification).to include("removed_bytes" => 127, "verified_at" => "2026-11-28T12:00:00.000000Z")
  end

  it "refuses uploads until storage is configured and expires an upload after 24 hours" do
    allow(Rails.application.config.active_storage).to receive(:service).and_return(nil)
    expect(mcp_tool(name: "request_upload", type: "screenshot")).to eq("code" => "uploads_disabled")
    allow(Rails.application.config.active_storage).to receive(:service).and_call_original
    upload_id = upload(type: "screenshot", files: { "title.png" => png })
    travel 25.hours
    expect(mcp_tool(name: "confirm_upload", upload_id: upload_id)).to eq("code" => "upload_expired")
  end
end
