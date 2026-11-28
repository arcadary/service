require "rails_helper"
require_relative "../support/screenshot_helpers"

RSpec.describe "Screenshots through MCP", type: :request do
  include ScreenshotHelpers
  include ActiveJob::TestHelper

  let(:release) { create(:release, system: "gb") }

  before do
    host! "localhost"
    stub_admin_credentials
  end

  def upload_over_mcp(kind:, bytes: png)
    mcp_tool(name: "upload_screenshot", upload_id: confirmed_screenshot(bytes: bytes).public_id, release_id: release.public_id, kind: kind)
  end

  it "lists a release's screenshots in order and removes one by id" do
    first = upload_over_mcp(kind: "gameplay").fetch("screenshot")
    title = upload_over_mcp(kind: "title", bytes: red_png).fetch("screenshot")
    second = upload_over_mcp(kind: "gameplay", bytes: green_png).fetch("screenshot")
    stored = Screenshot.find_by!(public_id: first.fetch("id"))
    expect(first).to eq("id" => stored.public_id, "kind" => "gameplay", "url" => "https://media.example/screenshots/#{stored.sha256}.png",
      "width" => 2, "height" => 2, "licence" => "", "sha256" => stored.sha256, "created_at" => stored.created_at.utc.iso8601(6))
    expect(mcp_tool(name: "list_screenshots", release_id: release.public_id)).to eq("release_id" => release.public_id, "screenshots" => [ title, first, second ])

    remaining = perform_enqueued_jobs { mcp_tool(name: "remove_screenshot", screenshot_id: first.fetch("id")) }
    expect(remaining).to eq("release_id" => release.public_id, "screenshots" => [ title, second ])
    expect(ActiveStorage::Blob.services.fetch(:test_media).exist?("screenshots/#{stored.sha256}.png")).to be(false)
    get "/v1/releases/#{release.sha1}.json"
    expect(response.parsed_body.dig("release", "screenshots").pluck("url")).to eq([ title, second ].pluck("url"))
    expect(mcp_tool(name: "remove_screenshot", screenshot_id: first.fetch("id"))).to eq("code" => "not_found")
    expect(mcp_tool(name: "list_screenshots", release_id: "unknown")).to eq("code" => "not_found")
  end

  it "advertises list_screenshots as read-only and remove_screenshot as destructive" do
    tools = mcp_rpc(method: "tools/list").dig("result", "tools").index_by { |tool| tool.fetch("name") }
    expect(tools.dig("list_screenshots", "annotations")).to include("readOnlyHint" => true, "destructiveHint" => false)
    expect(tools.dig("remove_screenshot", "annotations")).to include("readOnlyHint" => false, "destructiveHint" => true)
    expect(tools.dig("remove_screenshot", "inputSchema")).to include("additionalProperties" => false, "required" => [ "screenshot_id" ])
  end

  it "refuses a gameplay screenshot past the limit with screenshot_limit_reached" do
    create_list(:screenshot, Screenshot::GAMEPLAY_LIMIT, release: release)
    expect(upload_over_mcp(kind: "gameplay")).to eq("code" => "screenshot_limit_reached")
    expect(release.screenshots.count).to eq(Screenshot::GAMEPLAY_LIMIT)
  end
end
