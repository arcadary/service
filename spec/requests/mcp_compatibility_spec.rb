require "rails_helper"
require_relative "../support/mcp_helpers"

RSpec.describe "MCP compatibility recording", type: :request do
  include McpHelpers

  let(:release) { create(:release) }
  let(:launcher) { { "User-Agent" => "Arcadary/1.0" } }

  before do
    host! "localhost"
    stub_admin_credentials
  end

  def record(**overrides)
    mcp_result(name: "record_compatibility_result", **{
      release_id: release.public_id, sha1: release.sha1, device: "steam_machine", status: "works", core: "sameboy", core_version: "1.0.2",
      startup_revision: ReleaseStartupService.revision(release: release), tested_at: "2026-11-20T18:00:00Z",
      observed: "Played the first level with sound.", limits: "Later levels not reached.", reviewer: "Synthetic Reviewer",
      owns_file: true, requires_input: [ "keyboard" ], retry_key: "machine-1"
    }.merge(overrides))
  end

  it "records a Steam Machine result that refreshes the launcher's validators and leaves Steam Deck unknown" do
    shared = create(:release_medium, release: release)
    create(:release_medium, media_file: shared.media_file)
    urls = [ "/v1/releases/#{release.sha1}.json", "/v1/media/#{shared.media_file.sha1}.json" ]
    etags = urls.map do |url|
      get url, headers: launcher
      response.headers.fetch("ETag")
    end
    expect(response.parsed_body.fetch("releases").map { |body| body.dig("release", "compatibility", "steam_machine") }).to all(eq("status" => "unknown"))

    result = record
    public_machine = { "status" => "works", "reason" => nil, "core" => "sameboy", "core_version" => "1.0.2", "startup_revision" => ReleaseStartupService.revision(release: release.reload),
      "tested_at" => "2026-11-20T18:00:00Z", "observed" => "Played the first level with sound.", "limits" => "Later levels not reached.", "requires_input" => [ "keyboard" ] }
    expect(result).to include("isError" => false)
    expect(result.dig("structuredContent", "data", "current")).to eq("steam_machine" => public_machine, "steam_deck" => { "status" => "unknown" })
    expect(result.dig("structuredContent", "data", "result")).to include("device" => "steam_machine", "reviewer" => "Synthetic Reviewer", "sha1" => release.sha1)

    get urls.first, headers: launcher.merge("If-None-Match" => etags.first)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("release", "compatibility")).to eq("steam_machine" => public_machine, "steam_deck" => { "status" => "unknown" })
    expect(response.parsed_body.to_json).not_to include("Synthetic Reviewer")
    get urls.first, headers: launcher.merge("If-None-Match" => response.headers.fetch("ETag"))
    expect(response).to have_http_status(:not_modified)
    get urls.last, headers: launcher.merge("If-None-Match" => etags.last)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("releases").find { |body| body.dig("release", "id") == release.public_id }.dig("release", "compatibility", "steam_machine")).to eq(public_machine)
  end

  it "keeps corrections as history and reads back exactly what launchers see" do
    record
    record(status: "unknown", observed: "The earlier result was recorded for the wrong device.", limits: "No test.", retry_key: "machine-2")
    record(device: "steam_deck", status: "attention", reason: "Audio crackles in busy scenes.", observed: "Plays to the second level; audio crackles when many sprites move.",
      limits: "Only the first two levels tried.", retry_key: "deck-1")
    expect(record(status: "does_not_work", retry_key: "deck-1")).to include("isError" => true, "structuredContent" => { "error" => { "code" => "retry_conflict" } })

    read = mcp_result(name: "get_compatibility", release_id: release.public_id, limit: 2)
    data = read.dig("structuredContent", "data")
    get "/v1/releases/#{release.sha1}.json", headers: launcher
    expect(data.fetch("current")).to eq(response.parsed_body.dig("release", "compatibility"))
    expect(data.fetch("current").fetch("steam_machine")).to eq("status" => "unknown")
    expect(data.fetch("current").fetch("steam_deck")).to include("status" => "attention", "reason" => "Audio crackles in busy scenes.")
    expect(data.fetch("startup_revision")).to eq(response.parsed_body.dig("startup", "revision"))
    expect(data.dig("history", "items").map { |item| item.values_at("device", "status") }).to eq([ %w[steam_deck attention], %w[steam_machine unknown] ])

    rest = mcp_result(name: "get_compatibility", cursor: data.dig("history", "next_cursor")).dig("structuredContent", "data")
    expect(rest).to eq("items" => [ CompatibilityResultDecorator.decorate(CompatibilityResult.order(:id).first).history_json ], "next_cursor" => nil)
  end

  it "targets the exact release, file and launch configuration" do
    other = create(:release)
    expect(record(sha1: other.sha1).dig("structuredContent", "error", "code")).to eq("target_mismatch")
    expect(record(startup_revision: "0" * 64).dig("structuredContent", "error", "code")).to eq("target_mismatch")
    expect(record(release_id: "unknown").dig("structuredContent", "error", "code")).to eq("not_found")
    expect(record(owns_file: false).dig("structuredContent", "error", "code")).to eq("invalid_input")
    expect(mcp_result(name: "get_compatibility", release_id: "unknown").dig("structuredContent", "error", "code")).to eq("not_found")
    expect(CompatibilityResult.count).to eq(0)
  end

  it "attaches the release's own playthroughs as internal evidence and refuses another release's" do
    playthrough = create(:playthrough, release: release)
    result = record(playthrough_ids: [ playthrough.public_id ]).dig("structuredContent", "data", "result")
    expect(result.fetch("playthrough_ids")).to eq([ playthrough.public_id ])
    get "/v1/releases/#{release.sha1}.json", headers: launcher
    expect(response.body).not_to include(playthrough.public_id)

    other = create(:playthrough)
    refused = record(playthrough_ids: [ other.public_id ], retry_key: "machine-2")
    expect(refused.dig("structuredContent", "error", "code")).to eq("target_mismatch")
  end
end
