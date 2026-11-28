require "swagger_helper"
require_relative "../support/playthrough_helpers"
require_relative "../support/screenshot_helpers"

RSpec.describe "Private playthrough staging", type: :request do
  include PlaythroughHelpers
  include ScreenshotHelpers

  let!(:release) { create(:release) }
  let(:declaration) { playthrough_declaration(release: release) }
  let(:Authorization) { ActionController::HttpAuthentication::Basic.encode_credentials("synthetic-admin", "synthetic-password") }
  let(:headers) { { "Authorization" => self.Authorization, "CONTENT_TYPE" => "application/json" } }
  let(:payload) { declaration }
  let(:stage) { declare_playthrough }
  let(:staging_id) { stage.public_id }
  let(:stage_object_id) { stage.objects.sole.public_id }
  let(:capability) { PlaythroughUploadAuthorizationService.issue(stage: stage).fetch(:capability) }
  let(:"X-Arcadary-Upload-Capability") { capability }
  let(:upload_headers) { headers.merge("X-Arcadary-Upload-Capability" => capability, "CONTENT_TYPE" => "video/mp2t") }
  let(:segment) { "synthetic segment" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_USERNAME").and_return("synthetic-admin")
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return("synthetic-password")
  end

  stage_schema = {
    type: :object, additionalProperties: false, required: %w[staging_id release_id package_sha256 declaration state objects], properties: {
      staging_id: { type: :string }, release_id: { type: :string }, package_sha256: { type: :string, pattern: "^[0-9a-f]{64}$" },
      declaration: { "$ref" => "#/components/schemas/playthrough_declaration" }, state: { type: :string, enum: %w[incomplete received] },
      objects: { type: :array, items: { type: :object, additionalProperties: false, required: %w[object_id path received],
        properties: { object_id: { type: :string }, path: { type: :string }, received: { type: :boolean } } } }
    }
  }

  path "/v1/playthrough-stages/{staging_id}.json" do
    get "Read private declaration and durable object progress" do
      produces "application/json"
      security [ private_service_basic: [] ]
      parameter name: :staging_id, in: :path, required: true, schema: { type: :string }
      response "200", "metadata only; no bytes or storage URLs" do
        schema stage_schema
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test! { expect(response.headers["Cache-Control"]).to eq("no-store") }
      end
      response "404", "unknown stage" do
        let(:staging_id) { "unknown" }
        schema type: :object, additionalProperties: false, required: %w[error], properties: { error: { type: :string, enum: %w[not_found] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test! { expect(response.headers["Cache-Control"]).to eq("no-store") }
      end
      response "401", "authentication failed" do
        let(:Authorization) { "" }
        schema type: :object, additionalProperties: false, required: %w[error], properties: { error: { type: :string, enum: %w[unauthorized] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test! { expect(response.headers["Cache-Control"]).to eq("no-store") }
      end
      response "503", "authentication not configured" do
        before { allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return(nil) }
        schema type: :object, additionalProperties: false, required: %w[error], properties: { error: { type: :string, enum: %w[authentication_unavailable] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test! { expect(response.headers["Cache-Control"]).to eq("no-store") }
      end
    end
  end

  path "/v1/playthrough-stages/{staging_id}/objects/{stage_object_id}.json" do
    put "Receive one declared private object" do
      consumes "video/mp2t", "application/vnd.apple.mpegurl", "video/mp4", "application/json"
      produces "application/json"
      security [ private_service_basic: [] ]
      parameter name: :staging_id, in: :path, required: true, schema: { type: :string }
      parameter name: :stage_object_id, in: :path, required: true, schema: { type: :string }
      parameter name: :"X-Arcadary-Upload-Capability", in: :header, required: true, schema: { type: :string }
      parameter name: :segment, in: :body, required: true, schema: { type: :string, format: :binary }
      description "Requires current shared Basic credentials plus X-Arcadary-Upload-Capability from MCP begin_playthrough_staging. Capabilities bind the exact release, stage, immutable manifest and declared objects, never travel in URLs, and expire exactly 900 seconds after issuance (invalid at or after expires_at). Identical begin replay renews without extending older capabilities; HTTP metadata reads never renew. Missing, expired or mismatched authorization returns 403 upload_not_authorized before application body or storage reads, including accepted-object retries. Raw bytes with the exact declared Content-Type; any valid declared MIME type without parameters is accepted. Exact size and SHA-256 must match, including on successful retries. Reads are bounded at 8 MiB regardless of Content-Length. Success returns an immutable object_id/received_at receipt; identical retries return exactly that receipt, even after other objects finish. GET stage metadata for aggregate progress. Fresh private storage keys isolate attempts and stages; completion follows storage success. Interrupted reads and storage failure leave the object incomplete and retryable after restart. No HLS validation or playback is performed. The deployment owner must verify the zone upload setting, which can be lower than Cloudflare's documented 100 MB minimum plan limit: https://developers.cloudflare.com/cache/concepts/default-cache-behavior/#upload-limits (#57)."

      response "200", "verified object received, or identical successful retry" do
        schema type: :object, additionalProperties: false, required: %w[object_id received_at], properties: {
          object_id: { type: :string }, received_at: { type: :string, format: "date-time" }
        }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test! do
          expect(response.parsed_body.fetch("object_id")).to eq(stage_object_id)
          expect(response.headers["Cache-Control"]).to eq("no-store")
        end
      end
      {
        "400" => [ "interrupted read", %w[interrupted_transfer] ],
        "401" => [ "authentication failed", %w[unauthorized] ],
        "403" => [ "missing, expired or mismatched upload capability", %w[upload_not_authorized] ],
        "409" => [ "bytes, size or content type mismatch", %w[stage_conflict] ],
        "413" => [ "actual bytes exceed 8 MiB", %w[stage_too_large] ],
        "503" => [ "storage or authentication unavailable", %w[storage_unavailable authentication_unavailable] ]
      }.each do |status, (label, codes)|
        response status, label do
          schema type: :object, additionalProperties: false, required: %w[error], properties: { error: { type: :string, enum: codes } }
          header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
          case status
          when "400"
            before { allow(PlaythroughStageInputService).to receive(:read).and_call_original; allow(PlaythroughStageInputService).to receive(:read).with(io: anything, limit: 8.megabytes).and_raise(PlaythroughStage::InterruptedTransfer) }
          when "401"
            let(:Authorization) { "" }
          when "403"
            let(:"X-Arcadary-Upload-Capability") { "" }
          when "409"
            let(:segment) { "changed bytes" }
          when "413"
            let(:segment) { "x" * (8.megabytes + 1) }
          when "503"
            before { allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(IOError) }
          end
          run_test! { expect(response.headers["Cache-Control"]).to eq("no-store") }
        end
      end
    end
  end

  it "authenticates before bounded reads and silences success, parsing, integrity, storage and routing errors" do
    receipt = PlaythroughStageDecorator.decorate(stage).summary.deep_stringify_keys
    capability
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    begin
      post "/v1/playthrough-stages.json", params: JSON.generate(declaration), headers: headers
      expect(response).to have_http_status(:not_found)
      upload_path = "/v1/playthrough-stages/#{receipt.fetch('staging_id')}/objects/#{receipt.fetch('objects').sole.fetch('object_id')}.json"
      post "/v1/playthrough-stages.json", params: "private broken JSON", headers: headers
      expect(response).to have_http_status(:not_found)
      put upload_path, params: "private wrong bytes", headers: upload_headers
      expect(response).to have_http_status(:conflict)
      allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(IOError, "private storage failure")
      put upload_path, params: segment, headers: upload_headers
      expect(response).to have_http_status(:service_unavailable)
      get "/v1//playthrough-stages//unknown", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(PlaythroughStageInputService).not_to receive(:read)
      [ "/v1/playthrough-stages", "/v1/playthrough-stages.json", "/v1//playthrough-stages//unknown", "/v1/playthrough%2dstages/unknown" ].each do |path|
        post path, params: "private body"
        expect(response).to have_http_status(:unauthorized)
        expect(response.headers["Cache-Control"]).to eq("no-store")
      end
      expect(output.string).to eq("")
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
  end

  it "keeps public resources, validators and screenshot bytes unchanged and exposes no object download" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("SCREENSHOT_PUBLIC_BASE_URL", "").and_return("https://images.example")
    screenshot = upload_screenshot(release: release)
    public_paths = [ "/v1/lookup/#{release.sha1}.json", "/v1/releases/#{release.sha1}.json", "/v1/media/#{release.sha1}.json",
      "/v1/screenshots/#{screenshot.sha256}.png" ]
    previous = public_paths.map do |path|
      get path, headers: { "User-Agent" => "Arcadary/1.0" }
      [ response.status, response.body, response.headers.slice("ETag", "Last-Modified", "Cache-Control") ]
    end
    staged = declare_playthrough
    receive_playthrough(stage: staged)
    public_paths.each_with_index do |path, index|
      get path, headers: { "User-Agent" => "Arcadary/1.0" }
      expect([ response.status, response.body, response.headers.slice("ETag", "Last-Modified", "Cache-Control") ]).to eq(previous[index])
    end
    object = staged.objects.sole.reload
    get "/v1/playthrough-stages/#{staged.public_id}/objects/#{object.public_id}.json", headers: headers
    expect(response).to have_http_status(:not_found)
    get "/rails/active_storage/blobs/redirect/#{object.blob.signed_id}/playthrough-object"
    expect(response).to have_http_status(:not_found)
  end

  it "bounds object reads with missing or dishonest Content-Length" do
    put "/v1/playthrough-stages/#{stage.public_id}/objects/#{stage.objects.sole.public_id}.json",
      params: "x" * (8.megabytes + 1), headers: upload_headers.merge("CONTENT_LENGTH" => "1")
    expect(response).to have_http_status(:content_too_large)
    put "/v1/playthrough-stages/#{stage.public_id}/objects/#{stage.objects.sole.public_id}.json",
      params: segment, headers: upload_headers.merge("CONTENT_LENGTH" => "")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("received_at")).to be_present
  end

  it "replays the identical object receipt after other objects finish" do
    declaration["manifest"] << declaration["manifest"].first.merge("path" => "video/next.ts")
    staged = declare_playthrough
    first, second = staged.objects.to_a
    first_path = "/v1/playthrough-stages/#{staged.public_id}/objects/#{first.public_id}.json"
    put first_path, params: segment, headers: upload_headers
    original = response.body
    put "/v1/playthrough-stages/#{staged.public_id}/objects/#{second.public_id}.json", params: segment,
      headers: upload_headers
    put first_path, params: segment, headers: upload_headers
    expect(response.body).to eq(original)
    get "/v1/playthrough-stages/#{staged.public_id}.json", headers: headers
    expect(response.parsed_body.fetch("state")).to eq("received")
  end
end
