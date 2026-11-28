require "swagger_helper"
require_relative "../support/screenshot_helpers"

RSpec.describe "Private screenshot staging", type: :request do
  include ScreenshotHelpers

  let!(:release) { create(:release) }
  let(:release_id) { release.public_id }
  let(:source_sha1) { release.sha1 }
  let(:kind) { "gameplay" }
  let(:image) { png }
  let(:Authorization) { ActionController::HttpAuthentication::Basic.encode_credentials("synthetic-admin", "synthetic-password") }
  let(:headers) { { "Authorization" => self.Authorization, "CONTENT_TYPE" => "image/png" } }
  let(:url) { "/v1/screenshot-stages/#{release_id}/#{source_sha1}/#{kind}.json" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_USERNAME").and_return("synthetic-admin")
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return("synthetic-password")
    allow(ENV).to receive(:[]).with("SCREENSHOT_CAPTURE_TOKEN").and_return(nil)
    allow(ENV).to receive(:fetch).with("SCREENSHOT_PUBLIC_BASE_URL", "").and_return("https://images.example")
  end

  path "/v1/screenshot-stages/{release_id}/{source_sha1}/{kind}.json" do
    post "Stage a private screenshot for MCP publication" do
      consumes "image/png"
      produces "application/json"
      security [ private_service_basic: [] ]
      parameter name: :release_id, in: :path, required: true, schema: { type: :string }
      parameter name: :source_sha1, in: :path, required: true, schema: { type: :string, pattern: "^[0-9a-fA-F]{40}$" }
      parameter name: :kind, in: :path, required: true, schema: { type: :string, enum: %w[title gameplay] }
      parameter name: :image, in: :body, required: true, schema: { type: :string, format: :binary }
      description <<~TEXT
        Raw PNG bytes, protected by shared single-admin HTTP Basic before parsing, logging or mutation; no capture token required. The stable release public ID, exact source-medium SHA-1 and kind are bound before decoding. Secondary and shared media are accepted only for the explicit containing release. Uses capture's 8 MiB input ceiling, system dimension ceilings, full PNG validation and pixel-only re-encoding.

        Returns only an opaque staging_id and expires_at, exactly 24 hours after successful ingest. Staging never changes public JSON, validators or PNG delivery and exposes no anonymous stage/read/redirect route. Missing or malformed public-base configuration or incomplete production R2 configuration disables ingest before PNG processing. All responses and the complete staging subtree are no-store and excluded from application logs; hosted proxy/CDN cache, access-log, body/header and tracing exclusions are required too.

        Call MCP publish_screenshot with staging_id and the same release_id, source_sha1 and kind. It rechecks membership, adopts the canonical blob without copying, uses the game image licence at publication and atomically consumes the ID. Before expiry a repeated successful-target call returns staged_image_consumed, even after replacement/removal; at expiry it returns staged_image_unavailable. Failed attempts leave the stage retryable and do not extend expiry. The hourly cleanup job processes bounded batches of expired stages/receipts and purges unconsumed blobs, never transferred screenshot blobs. Solid Queue workers and its recurring scheduler must run. No explicit discard API exists. Publication errors: invalid_input, not_found, target_mismatch, staged_image_unavailable, staged_image_consumed, uploads_disabled, storage_unavailable.
      TEXT

      response "201", "private stage created" do
        schema type: :object, additionalProperties: false, required: %w[staging_id expires_at], properties: {
          staging_id: { type: :string }, expires_at: { type: :string, format: "date-time" }
        }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test! do
          stage = ScreenshotStage.sole
          expect(response.parsed_body).to eq("staging_id" => stage.public_id, "expires_at" => stage.expires_at.iso8601(6))
          expect(stage.expires_at).to be_within(1.second).of(24.hours.from_now)
          expect(stage).to have_attributes(release_public_id: release.public_id, source_sha1: release.sha1, kind: "gameplay")
          expect(Screenshot.count).to eq(0)
          expect(response.headers["Set-Cookie"]).to be_nil
        end
      end

      {
        "400" => [ "malformed target", %w[invalid_input] ],
        "401" => [ "missing or wrong shared credentials", %w[unauthorized] ],
        "404" => [ "unknown release public ID", %w[not_found] ],
        "409" => [ "checksum outside this release", %w[target_mismatch] ],
        "413" => [ "input exceeds 8 MiB", %w[screenshot_too_large] ],
        "422" => [ "invalid PNG, animation, content type or dimensions", %w[invalid_screenshot] ],
        "503" => [ "authentication, uploads or storage unavailable", %w[authentication_unavailable uploads_disabled storage_unavailable] ]
      }.each do |status, (label, codes)|
        response status, label do
          schema type: :object, additionalProperties: false, required: [ "error" ], properties: { error: { type: :string, enum: codes } }
          header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
          case status
          when "400"
            let(:kind) { "box-art" }
            before { expect(ScreenshotPngService).not_to receive(:decode) }
          when "401"
            let(:Authorization) { "Bearer capture-token" }
            before { expect(ScreenshotPngService).not_to receive(:decode) }
          when "404"
            let(:release_id) { "unknown" }
          when "409"
            let(:source_sha1) { "0" * 40 }
            before { expect(ScreenshotPngService).not_to receive(:decode) }
          when "413"
            let(:image) { "x" * 8_388_609 }
          when "422"
            let(:image) { "broken PNG" }
          when "503"
            before do
              allow(ENV).to receive(:fetch).with("SCREENSHOT_PUBLIC_BASE_URL", "").and_return("")
              expect(ScreenshotPngService).not_to receive(:decode)
            end
          end
          run_test! do
            expect(ScreenshotStage.count).to eq(0)
            expect(ActiveStorage::Blob.count).to eq(0)
            expect(response.headers["Cache-Control"]).to eq("no-store")
          end
        end
      end
    end
  end

  it "keeps existing public JSON, validators and identical published pixels unchanged" do
    previous = upload_screenshot(release: release)
    get "/v1/releases/#{release.sha1}.json"
    body, etag, modified = response.body, response.headers["ETag"], response.headers["Last-Modified"]
    post url, params: png(pixel: "\xff\0\0\xff".b), headers: headers
    expect(response).to have_http_status(:created)
    stage = ScreenshotStage.sole
    get "/v1/releases/#{release.sha1}.json"
    expect([ response.body, response.headers["ETag"], response.headers["Last-Modified"] ]).to eq([ body, etag, modified ])
    get "/v1/screenshots/#{stage.sha256}.png"
    expect(response).to have_http_status(:not_found)
    get "/v1/screenshots/#{previous.sha256}.png"
    expect(response.body.b).to eq(previous.blob.download)
    post url, params: png, headers: headers
    get "/v1/screenshots/#{ScreenshotStage.last.sha256}.png"
    expect(response).to have_http_status(:ok)
    get "/rails/active_storage/blobs/redirect/#{stage.blob.signed_id}/screenshot.png"
    expect(response).to have_http_status(:not_found)
    get "/v1/screenshot-stages/#{stage.public_id}.json"
    expect(response).to have_http_status(:unauthorized)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "protects the complete subtree and suppresses success, routing, authentication and body failures before logging" do
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    begin
      post url, params: png, headers: headers.merge("REMOTE_ADDR" => "198.51.100.18")
      expect(response).to have_http_status(:created)
      post url, params: "sensitive PNG bytes", headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      get "/v1//screenshot-stages//unknown", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      [ "/v1/screenshot-stages", "/v1/screenshot-stages.json", "/v1//screenshot-stages//unknown", "/v1/screenshot%2dstages/unknown" ].each do |path|
        post path, params: "private body"
        expect(response).to have_http_status(:unauthorized)
      end
      expect(output.string).to eq("")
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
  end

  it "disables malformed public origins and incomplete production R2 before decoding" do
    expect(ScreenshotPngService).not_to receive(:decode)
    allow(ENV).to receive(:fetch).with("SCREENSHOT_PUBLIC_BASE_URL", "").and_return("https://images.example/path")
    post url, params: image, headers: headers
    expect(response.parsed_body).to eq("error" => "uploads_disabled")
    allow(ENV).to receive(:fetch).with("SCREENSHOT_PUBLIC_BASE_URL", "").and_return("https://images.example")
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(ENV).to receive(:[]).with("R2_BUCKET").and_return(nil)
    post url, params: image, headers: headers
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq("error" => "uploads_disabled")
  end

  it "maps storage failures without retaining an orphan or changing the working screenshot" do
    previous = upload_screenshot(release: release)
    attributes = previous.attributes
    allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(IOError)
    post url, params: image, headers: headers
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq("error" => "storage_unavailable")
    expect(previous.reload.attributes).to eq(attributes)
    expect(ActiveStorage::Blob.count).to eq(1)
    expect(ScreenshotStage.count).to eq(0)
  end
end
