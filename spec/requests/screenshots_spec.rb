require "swagger_helper"
require_relative "../support/screenshot_helpers"

RSpec.describe "Screenshots", type: :request do
  include ScreenshotHelpers

  let!(:release) { create(:release, system: "gb") }
  let(:sha1) { release.sha1 }
  let(:kind) { "gameplay" }
  let(:image) { png }
  let(:Authorization) { "Bearer capture-test-token" }
  let(:upload_url) { "/v1/releases/#{sha1}/screenshots/#{kind}.json" }
  let(:capture_headers) { { "Authorization" => self.Authorization, "CONTENT_TYPE" => "image/png", "User-Agent" => "Arcadary/1.0" } }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with("SCREENSHOT_CAPTURE_TOKEN").and_return("capture-test-token")
    allow(ENV).to receive(:fetch).with("SCREENSHOT_PUBLIC_BASE_URL", "").and_return("https://images.example")
  end

  path "/v1/releases/{sha1}/screenshots/{kind}.json" do
    put "Publish a capture-device screenshot" do
      consumes "image/png"
      produces "application/json"
      security [ capture_token: [] ]
      parameter name: :sha1, in: :path, required: true, schema: { type: :string, pattern: "^[0-9a-fA-F]{40}$" }
      parameter name: :kind, in: :path, required: true, schema: { type: :string, enum: %w[title gameplay] }
      parameter name: :image, in: :body, required: true, schema: { type: :string, format: :binary }
      description <<~TEXT
        Raw image/png body, authenticated before decoding or storing. A secondary-disk checksum targets its containing release; shared checksums are ambiguous. Success replaces only this release/kind; failure preserves its previous image. The service copies game screenshot_licence, never a client-supplied licence. Upload grants no rights. All responses are no-store.

        Maximum input: 8 MiB (8,388,608 bytes). PNG only; malformed and animated PNGs are rejected. Dimensions are positive and checked before decoding, followed by full decoding and pixel-only PNG re-encoding. Fixed capture ceilings, independent of crop, overscan, borders or interlace:

        | System | Maximum width | Maximum height |
        | --- | ---: | ---: |
        | nes | 1024 | 960 |
        | snes | 2048 | 1912 |
        | gb | 640 | 576 |
        | gbc | 640 | 576 |
        | megadrive | 1280 | 1920 |
        | pcengine | 2048 | 960 |
        | atari2600 | 640 | 768 |
        | c64 | 1536 | 1088 |

        Unset/empty SCREENSHOT_CAPTURE_TOKEN or incomplete production R2/public-origin configuration disables uploads. URLs use the configured HTTPS origin, never request headers, R2 URLs or signed URLs.
      TEXT

      response "200", "screenshot published" do
        schema "$ref" => "#/components/schemas/Screenshot"
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test! do
          screenshot = Screenshot.sole
          expect(response.parsed_body).to eq(
            "kind" => "gameplay", "url" => "https://images.example/v1/screenshots/#{screenshot.sha256}.png",
            "width" => 2, "height" => 2, "licence" => ""
          )
          expect(response.headers["Set-Cookie"]).to be_nil
        end
      end

      {
        "400" => [ "malformed SHA-1", "invalid_sha1" ],
        "401" => [ "missing or wrong capture token", "unauthorized" ],
        "404" => [ "unknown release", "release_not_found" ],
        "409" => [ "checksum shared by releases", "ambiguous_release" ],
        "413" => [ "input exceeds 8 MiB", "screenshot_too_large" ],
        "422" => [ "invalid kind, PNG, animation or dimensions", "invalid_screenshot" ],
        "503" => [ "uploads disabled or storage unavailable", "uploads_disabled", "storage_unavailable" ]
      }.each do |status, (label, *codes)|
        response status, label do
          schema type: :object, required: [ "error" ], additionalProperties: false,
            properties: { error: { type: :string, enum: codes } }
          header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
          case status
          when "400"
            let(:sha1) { "bad" }
          when "401"
            let(:Authorization) { "" }
            before { expect(ScreenshotPngService).not_to receive(:decode) }
          when "404"
            let(:sha1) { "0" * 40 }
          when "409"
            before { create(:release, sha1: release.sha1) }
          when "413"
            let(:image) { "a" * 8_388_609 }
          when "422"
            let(:image) { "broken PNG" }
          when "503"
            before { allow(ENV).to receive(:[]).with("SCREENSHOT_CAPTURE_TOKEN").and_return("") }
          end
          run_test! { expect(Screenshot.count).to eq(0) }
        end
      end
    end
  end

  path "/v1/screenshots/{sha256}.png" do
    get "Read a published screenshot" do
      produces "image/png"
      description "Anonymous Rails-origin PNG delivery. Content-addressed URLs cache publicly for 31,536,000 seconds. A missing or unreferenced image returns JSON with no-store. Origin removal cannot erase CDN or client cached copies."
      parameter name: :sha256, in: :path, required: true, schema: { type: :string, pattern: "^[0-9a-f]{64}$" }

      response "200", "stored PNG" do
        metadata[:response][:content] = { "image/png" => { schema: { type: :string, format: :binary } } }
        header "Content-Type", schema: { type: :string, enum: [ "image/png" ] }
        header "Cache-Control", schema: { type: :string, enum: [ "max-age=31536000, public" ] }
        let(:screenshot) { upload_screenshot(release: release) }
        let(:sha256) { screenshot.sha256 }
        run_test! do
          expect(response.body.b).to eq(screenshot.blob.download)
          expect(Digest::SHA256.hexdigest(response.body)).to eq(sha256)
          expect(response.headers["Content-Type"]).to eq("image/png")
          expect(response.headers["Cache-Control"]).to eq("max-age=31536000, public")
        end
      end

      response "404", "missing or unreferenced image" do
        produces "application/json"
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "screenshot_not_found" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:sha256) { "0" * 64 }
        run_test!
      end
    end
  end

  it "authenticates before parsing and disables incomplete production configuration" do
    put upload_url, params: "broken", headers: capture_headers.merge("Authorization" => "Bearer wrong")
    expect(response).to have_http_status(:unauthorized)
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(ENV).to receive(:[]).with("R2_BUCKET").and_return(nil)
    put upload_url, params: png, headers: capture_headers
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(Screenshot.count).to eq(0)
  end

  it "targets secondary disks, refuses shared checksums and ignores the request host" do
    medium = create(:release_medium, release: release)
    put "/v1/releases/#{medium.media_file.sha1}/screenshots/title.json", params: png,
      headers: capture_headers.merge("Host" => "www.example.com", "X-Forwarded-Host" => "injected.example")
    expect(response).to have_http_status(:ok)
    expect(Screenshot.sole.release).to eq(release)
    expect(response.parsed_body.fetch("url")).to start_with("https://images.example/")
    previous = Screenshot.sole.attributes
    create(:release_medium, media_file: medium.media_file)
    put "/v1/releases/#{medium.media_file.sha1}/screenshots/title.json", params: png, headers: capture_headers
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq("error" => "ambiguous_release")
    expect(Screenshot.sole.attributes).to eq(previous)
  end

  it "rejects invalid kinds and non-PNG content types without storing" do
    put "/v1/releases/#{sha1}/screenshots/box-art.json", params: png, headers: capture_headers
    expect(response).to have_http_status(:unprocessable_content)
    put upload_url, params: png, headers: capture_headers.merge("CONTENT_TYPE" => "image/jpeg")
    expect(response).to have_http_status(:unprocessable_content)
    expect(Screenshot.count).to eq(0)
  end

  it "serves launcher headers, returns 404 for lost stored bytes and exposes no Active Storage routes" do
    screenshot = upload_screenshot(release: release)
    path = "/v1/screenshots/#{screenshot.sha256}.png"
    get path, headers: { "User-Agent" => "Arcadary/1.0", "Accept" => "image/png" }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Set-Cookie"]).to be_nil
    screenshot.blob.delete
    get path, headers: { "User-Agent" => "Arcadary/1.0" }
    expect(response).to have_http_status(:not_found)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    get "/rails/active_storage/blobs/redirect/#{screenshot.blob.signed_id}/screenshot.png"
    expect(response).to have_http_status(:not_found)
  end

  it "silences reads and uploads, including failures, before request logging" do
    screenshot = upload_screenshot(release: release)
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    begin
      headers = capture_headers.merge("REMOTE_ADDR" => "198.51.100.18")
      put upload_url, params: png, headers: headers
      put upload_url, params: "sensitive body", headers: headers
      put upload_url, params: png, headers: headers.merge("Authorization" => "Bearer sensitive-token")
      get "/v1/screenshots/#{screenshot.sha256}.png", headers: headers
      get "/v1/screenshots/#{'0' * 64}.png", headers: headers
      get "/v1//screenshots//bad.png", headers: headers
      expect(output.string).to eq("")
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
  end
end
