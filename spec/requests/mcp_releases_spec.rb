require "rails_helper"
require_relative "../support/mcp_helpers"

RSpec.describe "Registering releases through MCP", type: :request do
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
end
