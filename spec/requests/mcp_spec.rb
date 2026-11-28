require "swagger_helper"
require_relative "../support/mcp_helpers"

RSpec.describe "Authenticated catalog MCP", type: :request do
  include McpHelpers

  let(:Authorization) { admin_authorization }

  before do
    host! "localhost"
    stub_admin_credentials
  end

  path "/mcp" do
    post "Authenticated stateless MCP Streamable HTTP" do
      consumes "application/json"
      produces "application/json"
      security [ private_service_basic: [] ]
      description <<~TEXT
        Catalog reads, uploads, append-only device compatibility results (record_compatibility_result, get_compatibility) and release registration (register_release) over MCP 1.11.0. See https://github.com/arcadary/service/blob/main/docs/mcp.md for discoverable input/output schemas, targeting, pagination and client setup. Every method and subtree requires current shared admin Basic credentials before parsing and returns no-store. No OAuth discovery/login, SSE subscriptions or persistent sessions.

        Complete HTTP request bodies are bounded at 2 MiB (2097152 bytes) regardless of Content-Length; an oversized request returns HTTP 413. JSON nesting remains limited to 64. request_upload returns an upload_id and the upload_url its files are PUT to; confirm_upload checks the upload as a whole; upload_screenshot and upload_video turn a confirmed upload into a release's public screenshot or video; list_videos and remove_video list and withdraw a release's videos. File bytes never travel through MCP.
      TEXT
      parameter name: :Authorization, in: :header, required: true, schema: { type: :string }
      parameter name: :request_body, in: :body, schema: {
        type: :object, additionalProperties: false, required: %w[jsonrpc id method],
        properties: { jsonrpc: { type: :string, enum: [ "2.0" ] }, id: { type: :integer }, method: { type: :string }, params: { type: :object } }
      }
      let(:request_body) { { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "synthetic-spec", version: "1" } } } }

      response "200", "JSON-RPC result or protocol error" do
        schema type: :object, additionalProperties: false, required: %w[jsonrpc id], properties: {
          jsonrpc: { type: :string, enum: [ "2.0" ] }, id: { type: :integer, nullable: true },
          result: { type: :object }, error: { type: :object }
        }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test! do
          expect(response.parsed_body.dig("result", "protocolVersion")).to eq("2025-11-25")
          expect(response.headers["Mcp-Session-Id"]).to be_nil
        end
      end

      response "401", "missing or invalid credentials" do
        let(:Authorization) { "Basic invalid!" }
        schema type: :object, additionalProperties: false, required: [ "error" ], properties: { error: { type: :string, enum: [ "unauthorized" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        header "WWW-Authenticate", schema: { type: :string }
        run_test!
      end

      response "503", "configured credentials absent or blank" do
        before { allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return(" ") }
        schema type: :object, additionalProperties: false, required: [ "error" ], properties: { error: { type: :string, enum: [ "authentication_unavailable" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test!
      end

      response "413", "complete HTTP request exceeds 2 MiB" do
        let(:request_body) { "x" * 2_097_153 }
        schema type: :object, additionalProperties: false, required: %w[jsonrpc error], properties: {
          jsonrpc: { type: :string, enum: [ "2.0" ] }, id: { type: :integer, nullable: true },
          error: { type: :object, additionalProperties: false, required: %w[code message], properties: {
            code: { type: :integer, enum: [ -32600 ] }, message: { type: :string }
          } }
        }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test! { expect(response.headers["Cache-Control"]).to eq("no-store") }
      end
    end
  end

  it "authenticates discovery, malformed bodies, unsupported methods and subtree misses before catalog access" do
    expect(McpTransportService).not_to receive(:call)
    [ [ :post, "/mcp" ], [ :get, "/mcp/discovery" ], [ :patch, "/mcp" ], [ :post, "/mcp//unknown" ], [ :get, "/m%63p/discovery" ], [ :get, "/mcp/%ff" ] ].each do |method, path|
      public_send(method, path, params: "malformed", headers: { "CONTENT_TYPE" => "application/json" })
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["WWW-Authenticate"]).to include("Basic")
    end
  end

  it "requires the current configured pair on every reconnect" do
    expect(mcp_rpc(method: "tools/list").dig("result", "tools").size).to eq(13)
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return("rotated-synthetic")
    mcp_rpc(method: "tools/list")
    expect(response).to have_http_status(:unauthorized)
    mcp_rpc(method: "tools/list", headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("synthetic-admin", "rotated-synthetic") })
    expect(response).to have_http_status(:ok)
  end

  it "advertises read tools, upload tools and compatibility recording with schemas and preserves SDK version negotiation" do
    discovered = mcp_rpc(method: "tools/list").dig("result", "tools")
    expect(discovered.map { |entry| entry.fetch("name") }).to eq(%w[search_games get_game get_release get_catalog_history get_compatibility request_upload confirm_upload upload_screenshot upload_video record_compatibility_result register_release list_videos remove_video])
    discovered.first(5).each do |entry|
      expect(entry.dig("annotations", "readOnlyHint")).to be(true)
      expect(entry.fetch("inputSchema")).to include("additionalProperties" => false)
      expect(entry.fetch("outputSchema").dig("$defs", "page", "properties", "items", "maxItems")).to eq(50)
    end
    publication = discovered.find { |entry| entry.fetch("name") == "upload_screenshot" }
    expect(publication.fetch("annotations")).to include("readOnlyHint" => false, "destructiveHint" => true, "idempotentHint" => false)
    expect(publication.fetch("inputSchema")).to include("additionalProperties" => false, "required" => %w[upload_id release_id kind])
    expect(publication.fetch("outputSchema").dig("properties", "error", "properties", "code", "enum")).to include("upload_conflict", "storage_unavailable")
    recording = discovered.find { |entry| entry.fetch("name") == "record_compatibility_result" }
    expect(recording.fetch("annotations")).to include("readOnlyHint" => false, "destructiveHint" => false, "idempotentHint" => true)
    expect(recording.fetch("inputSchema")).to include("additionalProperties" => false, "required" => CompatibilityService::FIELDS)
    negotiated = mcp_rpc(method: "initialize", params: { protocolVersion: "2099-01-01", capabilities: {}, clientInfo: { name: "synthetic-spec", version: "1" } })
    expect(negotiated.dig("result", "protocolVersion")).to eq("2025-11-25")
    mcp_rpc(method: "tools/list", headers: { "MCP-Protocol-Version" => "2099-01-01", "Accept" => "application/json, text/event-stream" })
    expect(response).to have_http_status(:bad_request)
    discovered = mcp_rpc(method: "server/discover", params: { _meta: {
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientInfo" => { name: "synthetic-spec", version: "1" },
      "io.modelcontextprotocol/clientCapabilities" => {}
    } }, headers: { "MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "server/discover", "Accept" => "application/json, text/event-stream" })
    expect(discovered.dig("result", "supportedVersions")).to include("2026-07-28")
    expect(discovered.dig("result", "capabilities", "tools")).to eq({})
    expect(response).to have_http_status(:ok)
  end

  it "distinguishes malformed protocol from domain failures" do
    post "/mcp", params: "{broken", headers: mcp_headers
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body.dig("error", "code")).to eq(-32700)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(mcp_result(name: "get_release", sha1: "bad")).to include("isError" => true, "structuredContent" => { "error" => { "code" => "invalid_input" } })
    expect(mcp_result(name: "get_game", id: "unknown").dig("structuredContent", "error", "code")).to eq("not_found")
    expect(mcp_result(name: "search_games", limit: 51).dig("structuredContent", "error", "code")).to eq("invalid_input")
  end

  it "bounds request bytes and nesting before catalog calls" do
    expect(McpCatalogReadService).not_to receive(:call)
    request = { jsonrpc: "2.0", id: 1, method: "ping" }.to_json
    post "/mcp", params: request.ljust(2_097_152), headers: mcp_headers.merge("CONTENT_LENGTH" => "")
    expect(response).to have_http_status(:ok)
    post "/mcp", params: request.ljust(2_097_153), headers: mcp_headers.merge("CONTENT_LENGTH" => "1")
    expect(response).to have_http_status(:content_too_large)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    post "/mcp", params: "[" * 65 + "0" + "]" * 65, headers: mcp_headers
    expect(response).to have_http_status(:bad_request)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "rejects hostile Host and Origin headers even with credentials and permits configured-header clients without Origin" do
    mcp_rpc(method: "tools/list", headers: { "Origin" => "https://hostile.invalid" })
    expect(response).to have_http_status(:forbidden)
    mcp_rpc(method: "tools/list", headers: { "Host" => "hostile.invalid" })
    expect(response).to have_http_status(:forbidden)
    mcp_rpc(method: "tools/list", headers: { "Origin" => "null" })
    expect(response).to have_http_status(:forbidden)
    mcp_rpc(method: "tools/list", headers: { "Host" => "api.arcadary.org", "Origin" => "https://api.arcadary.org" })
    expect(response).to have_http_status(:ok)
    expect(mcp_rpc(method: "tools/list").dig("result", "tools").size).to eq(13)
  end

  it "keeps unsupported methods, missing subpaths and application failures private" do
    get "/mcp", headers: mcp_headers
    expect(response).to have_http_status(:method_not_allowed)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    patch "/mcp", headers: mcp_headers
    expect(response).to have_http_status(:method_not_allowed)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    post "/mcp/missing", headers: mcp_headers
    expect(response).to have_http_status(:not_found)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    allow(McpCatalogToolsService).to receive(:tools).and_raise("sensitive failure")
    mcp_rpc(method: "tools/list")
    expect(response).to have_http_status(:internal_server_error)
    expect(response.body).not_to include("sensitive failure")
  end

  it "returns a domain failure rather than partial data when a catalog result exceeds the byte bound" do
    game = create(:game, title: "x" * McpToolService::MAX_RESULT_BYTES)
    result = mcp_result(name: "get_game", id: game.public_id)
    expect(result.dig("structuredContent", "error", "code")).to eq("invalid_input")
    expect(response.body.bytesize).to be < 1000
  end

  it "suppresses private bodies, checksums, audit notes and credentials before Rails request logging" do
    release = create(:release)
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    begin
      mcp_result(name: "get_release", sha1: release.sha1)
      post "/mcp", params: '{broken "reason":"private note"', headers: mcp_headers
      mcp_rpc(method: "tools/list", headers: { "Host" => "hostile.invalid" })
      mcp_rpc(method: "tools/list", headers: { "Authorization" => "Basic malformed!" })
      allow(McpCatalogToolsService).to receive(:tools).and_raise("private note")
      mcp_rpc(method: "tools/list")
      expect(output.string).to eq("")
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
  end

  it "reads catalog metadata through SDK structured results" do
    game = create(:game, title_aliases: [ "Alias" ], source_title: "Original")
    release = create(:release, game: game, system: "snes", source_system: "source-system", controller_profile: build(:controller_profile))
    result = mcp_result(name: "get_release", id: release.public_id)
    expect(result["isError"]).to be(false)
    data = result.dig("structuredContent", "data")
    expect(data).to include("id" => release.public_id, "authoring_revision" => 0, "source" => hash_including("source_system" => "source-system"))
    expect(data.dig("canonical", "startup")).to eq(ReleaseStartupService.for_release(release: release))
    expect(data.dig("canonical", "media", "items").sole).to include("sha1" => release.sha1, "position" => 1)
    profile = data.dig("canonical", "controller_profile")
    expect(profile.fetch("binding")).to eq(release.controller_profile.fetch("binding"))
    expect(profile.dig("layout", "items").first.dig("evidence", "items")).to eq(release.controller_profile.dig("layout", 0, "evidence"))
    expect(profile.dig("prompts", "items").sole).to include("letter" => "A", "position" => "right")
    expect(JSON.parse(result.fetch("content").sole.fetch("text"))).to eq(result.fetch("structuredContent"))
  end
end
