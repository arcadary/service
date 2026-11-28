require "rails_helper"
require_relative "../support/mcp_helpers"

RSpec.describe "Videos through MCP", type: :request do
  include McpHelpers

  let(:release) { create(:release) }
  let(:media) { StorageConfigurationService.media_service }

  before do
    host! "localhost"
    stub_admin_credentials
  end

  it "lists a release's videos with the compatibility results they are attached to" do
    video = create(:video, release: release)
    create(:video)
    result = create(:compatibility_result, release: release, videos: [ video ])

    listed = mcp_tool(name: "list_videos", release_id: release.public_id)
    expect(listed.fetch("release_id")).to eq(release.public_id)
    expect(listed.fetch("videos").map { |entry| entry.values_at("id", "kind", "source_sha1", "compatibility_result_ids") }).to eq([
      [ video.public_id, "playthrough", release.sha1, [ result.id ] ]
    ])
    expect(mcp_tool(name: "list_videos", release_id: "unknown")).to eq("code" => "not_found")
  end

  it "withdraws a video from the media bucket and the release's public JSON and keeps the results it was attached to" do
    video = create(:video, release: release)
    playlist = VideoService.key(public_id: video.public_id, name: "index.m3u8")
    media.upload(playlist, StringIO.new("#EXTM3U\n"))
    result = create(:compatibility_result, release: release, videos: [ video ])
    get "/v1/releases/#{release.sha1}.json"
    etag = response.headers.fetch("ETag")
    expect(response.parsed_body.dig("release", "videos", 0, "url")).to end_with(playlist)

    expect(mcp_tool(name: "remove_video", video_id: video.public_id)).to eq("release_id" => release.public_id, "videos" => [])
    expect(media.exist?(playlist)).to be(false)
    expect(result.reload.videos).to be_empty
    get "/v1/releases/#{release.sha1}.json", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("release", "videos")).to eq([])
    expect(mcp_tool(name: "remove_video", video_id: video.public_id)).to eq("code" => "not_found")
  end

  it "keeps the video when its files cannot be deleted" do
    video = create(:video, release: release)
    allow(media).to receive(:delete_prefixed).and_raise(IOError)
    expect(mcp_tool(name: "remove_video", video_id: video.public_id)).to eq("code" => "storage_unavailable")
    expect(Video.exists?(video.id)).to be(true)
  end
end
