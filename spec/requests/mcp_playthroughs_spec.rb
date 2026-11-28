require "rails_helper"
require_relative "../support/playthrough_helpers"

RSpec.describe "MCP playthrough intake", type: :request do
  include PlaythroughHelpers
  include ActiveSupport::Testing::TimeHelpers

  let!(:release) { create(:release) }
  let(:declaration) { playthrough_declaration(release: release) }
  let(:headers) do
    { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("synthetic-admin", "synthetic-password"),
      "CONTENT_TYPE" => "application/json", "Accept" => "application/json", "MCP-Protocol-Version" => "2025-11-25" }
  end

  before do
    host! "localhost"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_USERNAME").and_return("synthetic-admin")
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return("synthetic-password")
  end

  def begin_stage(input: declaration, pretty: false)
    rpc = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "begin_playthrough_staging", arguments: input } }
    post "/mcp", params: pretty ? JSON.pretty_generate(rpc) : JSON.generate(rpc), headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.headers["Set-Cookie"]).to be_nil
    result = response.parsed_body.fetch("result")
    if result.key?("structuredContent")
      expect(JSON.parse(result.fetch("content").sole.fetch("text"))).to eq(result.fetch("structuredContent"))
      result.fetch("structuredContent")
    else
      result
    end
  end

  def upload(authorization:, object: authorization.fetch("objects").first, capability: authorization.fetch("capability"), extra_headers: {})
    put "/v1/playthrough-stages/#{authorization.fetch('staging_id')}/objects/#{object.fetch('object_id')}.json",
      params: "synthetic segment", headers: headers.merge("CONTENT_TYPE" => "video/mp2t", "X-Arcadary-Upload-Capability" => capability).merge(extra_headers)
  end

  it "discovers strict intake and complete compact result schemas" do
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json, headers: headers
    tool = response.parsed_body.dig("result", "tools").find { |entry| entry["name"] == "begin_playthrough_staging" }
    expect(tool.fetch("inputSchema")).to include("additionalProperties" => false, "required" => %w[retry_key release_id source_sha1 capture manifest])
    expect(tool.fetch("annotations")).to include("readOnlyHint" => false, "destructiveHint" => false, "idempotentHint" => false)
    result = begin_stage
    expect(JSONSchemer.schema(tool.fetch("outputSchema")).valid?(result)).to be(true)
    expect(result.fetch("data").keys).to contain_exactly("staging_id", "release_id", "package_sha256", "state", "objects", "capability", "expires_at")
    expect(result.dig("data", "objects").sole.keys).to contain_exactly("object_id", "path", "received")
  end

  it "targets shared and secondary media explicitly and retains authenticated mismatch verification" do
    create(:release, sha1: release.sha1)
    secondary = create(:release_medium, release: release)
    input = declaration.merge("source_sha1" => secondary.media_file.sha1)
    result = begin_stage(input: input).fetch("data")
    expect(result.fetch("release_id")).to eq(release.public_id)
    input = declaration.merge("source_sha1" => "f" * 40, "retry_key" => "verified")
    input["verification"] = playthrough_verification(source: input["source_sha1"], payload: release.sha1)
    expect(begin_stage(input: input)).to have_key("data")
    retained = PlaythroughStage.find_by!(retry_key: "verified").declaration.fetch("verification")
    expect(retained).to include("verifier" => "synthetic-admin", "removed_bytes" => 127, "payload_sha1" => release.sha1)
    input["verification"]["verifier"] = "another-admin"
    expect(begin_stage(input: input)).to eq("error" => { "code" => "invalid_declaration" })
  end

  it "rejects title-only, ambiguous and unverified targeting without issuing authorization" do
    expect(PlaythroughUploadAuthorizationService).not_to receive(:issue)
    expect(begin_stage(input: declaration.except("release_id").merge("title" => release.game.title))).to include("isError" => true)
    expect(begin_stage(input: declaration.merge("release_id" => [ release.public_id, "other" ]))).to eq("error" => { "code" => "invalid_declaration" })
    expect(begin_stage(input: declaration.merge("release_id" => "unknown"))).to eq("error" => { "code" => "not_found" })
    expect(begin_stage(input: declaration.merge("source_sha1" => "f" * 40))).to eq("error" => { "code" => "target_mismatch" })
    expect(PlaythroughStage.count).to eq(0)
  end

  it "renews normalized replays while preserving progress and each older token's exact expiry" do
    declaration["manifest"] << declaration["manifest"].first.merge("path" => "video/other.ts")
    travel_to Time.current.change(usec: 123456), with_usec: true do
      issued_at = Time.current
      first = begin_stage.fetch("data")
      expiry = Time.iso8601(first.fetch("expires_at"))
      expect(expiry - issued_at).to eq(900)
      upload(authorization: first)
      receipt = response.body
      expect(response).to have_http_status(:ok)
      travel_to expiry - Rational(1, 1_000_000), with_usec: true
      declaration["capture"]["captured_at"] = "2026-11-28T09:00:00+01:00"
      declaration["manifest"].reverse!
      renewed = begin_stage.fetch("data")
      expect(renewed.slice("staging_id", "release_id", "package_sha256")).to eq(first.slice("staging_id", "release_id", "package_sha256"))
      expect(renewed.fetch("state")).to eq("incomplete")
      expect(renewed.fetch("objects").first).to eq(first.fetch("objects").first.merge("received" => true))
      expect(renewed.fetch("objects").last).to eq(first.fetch("objects").last)
      expect(renewed.fetch("capability")).not_to eq(first.fetch("capability"))
      upload(authorization: first)
      expect(response.body).to eq(receipt)
      travel_to expiry, with_usec: true
      upload(authorization: first)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("error" => "upload_not_authorized")
      get "/v1/playthrough-stages/#{first.fetch('staging_id')}.json", headers: headers
      expect(response.parsed_body.fetch("objects").first.fetch("received")).to be(true)
      expect(response.parsed_body.keys).not_to include("capability", "expires_at")
      after_expiry = begin_stage.fetch("data")
      upload(authorization: after_expiry)
      expect(response.body).to eq(receipt)
      upload(authorization: renewed)
      expect(response.body).to eq(receipt)
      expect(begin_stage(input: declaration.merge("capture" => declaration["capture"].merge("version" => "2"))))
        .to eq("error" => { "code" => "stage_conflict" })
      expect(PlaythroughStage.count).to eq(1)
      expect(PlaythroughStageObject.count).to eq(2)
    end
  end

  it "rejects missing, tampered, cross-stage and undeclared-object capabilities before application reads or storage" do
    first = begin_stage.fetch("data")
    second = begin_stage(input: declaration.merge("retry_key" => "other")).fetch("data")
    other_release = create(:release)
    third = begin_stage(input: playthrough_declaration(release: other_release)).fetch("data")
    expect(PlaythroughStageInputService).not_to receive(:read)
    expect(ActiveStorage::Blob.service).not_to receive(:upload)
    expect(ActiveStorage::Blob.service).not_to receive(:download)
    [ nil, "invalid", second.fetch("capability"), third.fetch("capability") ].each do |capability|
      upload(authorization: first, capability: capability)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("error" => "upload_not_authorized")
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
    upload(authorization: first, object: { "object_id" => second.fetch("objects").sole.fetch("object_id") })
    expect(response).to have_http_status(:forbidden)
    upload(authorization: first, extra_headers: { "Authorization" => "" })
    expect(response).to have_http_status(:unauthorized)
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return("rotated-synthetic")
    upload(authorization: first)
    expect(response).to have_http_status(:unauthorized)
  end

  it "rejects an expired accepted-object retry before reading the Rack input or touching object storage" do
    travel_to Time.current do
      first = begin_stage.fetch("data")
      upload(authorization: first)
      travel 900
      expect(PlaythroughStageInputService).not_to receive(:read)
      expect(ActiveStorage::Blob.service).not_to receive(:upload)
      expect(ActiveStorage::Blob.service).not_to receive(:download)
      input = instance_double(StringIO)
      expect(input).not_to receive(:read)
      [ nil, first.fetch("capability") ].each do |capability|
        env = Rack::MockRequest.env_for("/v1/playthrough-stages/#{first.fetch('staging_id')}/objects/#{first.fetch('objects').sole.fetch('object_id')}.json",
          method: "PUT", "HTTP_AUTHORIZATION" => headers.fetch("Authorization"),
          "HTTP_X_ARCADARY_UPLOAD_CAPABILITY" => capability)
        env["rack.input"] = input
        status, response_headers, = Rails.application.call(env)
        expect(status).to eq(403)
        expect(response_headers["cache-control"]).to eq("no-store")
      end
    end
  end

  it "accepts all 4096 objects totaling 4 GiB and returns every object within the structured result ceiling" do
    entry = declaration.fetch("manifest").first
    declaration["manifest"] = Array.new(4096) { |index| entry.merge("path" => "v/#{index}.ts", "byte_size" => 1.megabyte) }
    result = begin_stage
    expect(result.dig("data", "objects").size).to eq(4096)
    expect(result.dig("data", "objects").map { |object| object.fetch("path") }).to match_array(declaration["manifest"].map { |object| object.fetch("path") })
    expect(JSON.generate(result).bytesize).to be <= 1.megabyte
    expect(PlaythroughStageObject.sum(:byte_size)).to eq(4.gigabytes)
  end

  it "measures the exact UTF-8 compact declaration before normalization and excludes envelope whitespace" do
    entry = declaration.fetch("manifest").first
    declaration["manifest"] = Array.new(1024) { |index| entry.merge("path" => "#{index}/é.ts") }
    padding, remainder = (1.megabyte - JSON.generate(declaration).bytesize).divmod(1024)
    declaration["manifest"].each_with_index { |object, index| object["path"] += "x" * (padding + (index < remainder ? 1 : 0)) }
    expect(JSON.generate(declaration).bytesize).to eq(1.megabyte)
    result = begin_stage(pretty: true)
    expect(result.dig("data", "objects").size).to eq(1024)
    expect(JSON.generate(result).bytesize).to be <= 1.megabyte
    declaration["manifest"].last["path"] += "x"
    expect(PlaythroughUploadAuthorizationService).not_to receive(:issue)
    expect(begin_stage).to eq("error" => { "code" => "stage_too_large" })
    expect(PlaythroughStage.count).to eq(1)
  end

  it "enforces count, individual size and package ceilings together without creating stages or capabilities" do
    entry = declaration.fetch("manifest").first
    manifests = [ Array.new(4097) { |index| entry.merge("path" => "#{index}.ts", "byte_size" => 1) },
      [ entry.merge("byte_size" => 8.megabytes + 1) ],
      Array.new(513) { |index| entry.merge("path" => "#{index}.ts", "byte_size" => 8.megabytes) } ]
    expect(PlaythroughUploadAuthorizationService).not_to receive(:issue)
    manifests.each do |manifest|
      expect(begin_stage(input: declaration.merge("manifest" => manifest))).to eq("error" => { "code" => "stage_too_large" })
    end
    expect(PlaythroughStage.count).to eq(0)
  end

  it "silences begin, renewal, changed declarations and rejected capabilities" do
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    begin
      first = begin_stage.fetch("data")
      begin_stage
      begin_stage(input: declaration.merge("capture" => declaration["capture"].merge("version" => "2")))
      upload(authorization: first, capability: "private wrong capability")
      expect(response).to have_http_status(:forbidden)
      expect(output.string).to eq("")
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
  end
end
