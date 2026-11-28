require "rails_helper"
require_relative "../support/mcp_helpers"

RSpec.describe "Releases and compatibility through MCP", type: :request do
  include McpHelpers

  let(:sha1) { "0123456789abcdef0123456789abcdef01234567" }
  let(:registration) do
    { reason: "Homebrew release", idempotency_key: "register-1", new_game: { id: "synthetic-homebrew", title: "Synthetic Homebrew" },
      system: "gb", media: [ { sha1: sha1, size: 32_768, crc32: "0badc0de" } ] }
  end

  before do
    host! "localhost"
    stub_admin_credentials
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Admin")
  end

  it "registers a release by its checksums alone, under a new or an existing game, and replays only an identical retry" do
    release = mcp_tool(name: "register_release", **registration)
    expect(release.dig("canonical", "game_id")).to eq("synthetic-homebrew")
    expect(mcp_tool(name: "register_release", **registration)).to eq(release)
    expect(mcp_tool(name: "register_release", **registration, system: "gbc").fetch("code")).to eq("conflict")
    get "/v1/lookup/#{sha1}.json"
    expect(response).to redirect_to("/v1/releases/#{sha1}.json")

    second = mcp_tool(name: "register_release", reason: "Revision B", idempotency_key: "register-2", game_id: "synthetic-homebrew",
      system: "gb", revision: "B", media: [ { sha1: "f" * 40 } ])
    expect(second.dig("canonical", "revision")).to eq("B")
    expect(mcp_tool(name: "register_release", **registration, idempotency_key: "register-3").fetch("code")).to eq("conflict")
    expect(Game.where(public_id: "synthetic-homebrew").count).to eq(1)
  end

  it "records verdicts with attached playthroughs, refreshes the public release and keeps the history" do
    release = create(:release)
    playthrough = create(:playthrough, release: release)
    get "/v1/releases/#{release.sha1}.json", headers: { "User-Agent" => "Arcadary/1.0" }
    etag = response.headers["ETag"]

    verdict = { release_id: release.public_id, device_class: "steam_machine", core: "mesen", core_version: "0.9.9",
      state: "works", tested_at: "2026-11-28T12:00:00+01:00", evidence: "Finished the first level", attested: true,
      playthrough_ids: [ playthrough.public_id ], reason: "First test" }
    recorded = mcp_tool(name: "record_verdict", **verdict).fetch("verdict")
    expect(recorded).to include("reviewer" => "Admin", "tested_at" => "2026-11-28T11:00:00Z", "playthrough_ids" => [ playthrough.public_id ])

    get "/v1/releases/#{release.sha1}.json", headers: { "User-Agent" => "Arcadary/1.0", "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    get "/v1/releases/#{release.sha1}.json", headers: { "User-Agent" => "Arcadary/1.0", "If-None-Match" => response.headers["ETag"] }
    expect(response).to have_http_status(:not_modified)

    mcp_tool(name: "record_verdict", **verdict.merge(state: "unknown", attested: false, playthrough_ids: [], reason: "Retest pending"))
    compatibility = mcp_tool(name: "get_compatibility", release_id: release.public_id)
    expect(compatibility).to include("release_id" => release.public_id, "current" => [])
    expect(compatibility.fetch("history").map { |entry| entry.fetch("state") }).to eq(%w[unknown works])
  end

  it "refuses to record a verdict without a configured admin name" do
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return(nil)
    result = mcp_tool(name: "record_verdict", release_id: create(:release).public_id, device_class: "steam_deck", core: "mesen",
      core_version: "1", state: "unknown", tested_at: "2026-11-28T12:00:00Z", reason: "Placeholder")
    expect(result).to eq("code" => "admin_unavailable")
  end
end
