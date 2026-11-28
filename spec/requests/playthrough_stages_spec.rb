require "swagger_helper"
require_relative "../support/playthrough_helpers"
require_relative "../support/screenshot_helpers"
require_relative "../support/playthrough_hls_helpers"

RSpec.describe "Private playthrough staging", type: :request do
  include PlaythroughHelpers
  include ScreenshotHelpers
  include PlaythroughHlsHelpers

  let!(:release) { create(:release) }
  let(:declaration) { playthrough_declaration(release: release) }
  let(:Authorization) { ActionController::HttpAuthentication::Basic.encode_credentials("synthetic-admin", "synthetic-password") }
  let(:headers) { { "Authorization" => self.Authorization, "CONTENT_TYPE" => "application/json" } }
  let(:payload) { declaration }
  let(:stage) { declare_playthrough }
  let(:staging_id) { stage.public_id }
  let(:stage_object_id) { stage.objects.sole.public_id }
  let(:segment) { "synthetic segment" }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_USERNAME").and_return("synthetic-admin")
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return("synthetic-password")
  end

  stage_schema = {
    type: :object, additionalProperties: false, required: %w[staging_id package_sha256 declaration state objects], properties: {
      staging_id: { type: :string }, package_sha256: { type: :string, pattern: "^[0-9a-f]{64}$" },
      declaration: { "$ref" => "#/components/schemas/playthrough_declaration" }, state: { type: :string, enum: %w[incomplete received validated validation_failed] },
      validation_result: { "$ref" => "#/components/schemas/playthrough_validation_result" },
      validation_error: { type: :string, enum: %w[invalid_hls package_integrity_mismatch] },
      objects: { type: :array, items: { type: :object, additionalProperties: false, required: %w[object_id path received],
        properties: { object_id: { type: :string }, path: { type: :string }, received: { type: :boolean } } } }
    }
  }

  path "/v1/playthrough-stages.json" do
    post "Declare a private release-bound playthrough package" do
      consumes "application/json"
      produces "application/json"
      security [ private_service_basic: [] ]
      parameter name: :payload, in: :body, required: true, schema: { "$ref" => "#/components/schemas/playthrough_declaration" }
      description <<~TEXT
        Authenticated by shared admin Basic before parsing, body reads or logging. A strict single-target declaration binds a stable release public_id, capture source SHA-1, provenance and immutable manifest. Unknown fields and duplicate JSON keys are rejected. SHA-1s and SHA-256s are lowercase. Capture and verification times require ISO 8601 with an explicit timezone and normalize to UTC microseconds.

        The source must belong to the named release, or carry a single offline successful verification attestation whose payload belongs to that release. The verifier must equal the authenticated admin username. Evidence must name exactly the source and payload SHA-1s, with no other checksum proposals. trailing_padding requires a positive removed_bytes, including 127 for the trial when verified; verified_equivalence accepts other byte-verified relationships without removed_bytes. No game bytes are accepted, no title matching or launcher-checksum inference occurs.

        Each entry has a unique package-relative path, positive byte_size, lowercase sha256 and exact MIME content_type without parameters. Paths exclude absolute paths, URLs, traversal/dot/empty components, whitespace, backslashes, colon, percent, query/fragment and control characters. Package identity is SHA-256 of UTF-8 compact JSON of [path, byte_size, sha256, content_type] arrays sorted bytewise by path. Reordering manifest entries or JSON keys and equivalent timestamp offsets replay the original stage; changing the normalized declaration with the same retry_key conflicts. Successful replays return 201 with current progress.

        Ceilings: 1 MiB actual declaration bytes, 4096 objects, 8 MiB per object, 4 GiB summed declared bytes. Actual reads are bounded independently of Content-Length. All responses are no-store and log-suppressed across the complete subtree. No download, playback, redirect, direct-upload capability or public storage route exists. received means all objects stored, still unvalidated. Internal validation fixes the root at index.m3u8 without changing declaration or package identity. Terminal validated/validation_failed states and their persisted result/error are replayed in metadata. No HTTP validation route exists; publication/cleanup and private delivery/trial checks remain separate. Catalog and screenshot licences grant no video rights; commercial footage remains private and absent from anonymous responses.
      TEXT

      response "201", "declaration persisted or identical replay" do
        schema stage_schema
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test! do
          expect(response.parsed_body.fetch("state")).to eq("incomplete")
          expect(response.headers["Cache-Control"]).to eq("no-store")
          expect(response.headers["Set-Cookie"]).to be_nil
        end
      end

      {
        "400" => [ "invalid declaration or interrupted read", %w[invalid_declaration interrupted_transfer] ],
        "401" => [ "authentication failed", %w[unauthorized] ],
        "404" => [ "release not found", %w[not_found] ],
        "409" => [ "target mismatch or changed retry declaration", %w[target_mismatch stage_conflict] ],
        "413" => [ "declaration or package exceeds a ceiling", %w[stage_too_large] ],
        "503" => [ "authentication not configured", %w[authentication_unavailable] ]
      }.each do |status, (label, codes)|
        response status, label do
          schema type: :object, additionalProperties: false, required: %w[error], properties: { error: { type: :string, enum: codes } }
          header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
          case status
          when "400"
            let(:payload) { declaration.except("capture") }
          when "401"
            let(:Authorization) { "Bearer wrong" }
          when "404"
            let(:payload) { declaration.merge("release_id" => "unknown") }
          when "409"
            let(:payload) { declaration.merge("source_sha1" => "f" * 40) }
          when "413"
            let(:payload) { declaration.merge("capture" => declaration["capture"].merge("tool" => "x" * 1.megabyte)) }
          when "503"
            before { allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return(nil) }
          end
          run_test! { expect(response.headers["Cache-Control"]).to eq("no-store") }
        end
      end
    end
  end

  path "/v1/playthrough-stages/{staging_id}.json" do
    get "Read private declaration and durable object progress" do
      produces "application/json"
      security [ private_service_basic: [] ]
      parameter name: :staging_id, in: :path, required: true, schema: { type: :string }
      description <<~TEXT
        Existing stages always return 200. incomplete means missing receipts; received means stored but unvalidated. validated includes validation_result; validation_failed includes validation_error (invalid_hls or package_integrity_mismatch). Other states omit both validation fields. Results bind this exact staging ID, immutable normalized manifest/declaration fingerprint/package digest, stable release ID, source SHA-1 and capture/verification evidence. duration is exact summed decimal seconds, audio_codec is null for silent H.264, and absent chapters use chapters_path:null and chapters:[]. No public object, descriptor, redirect or playback is created.

        PlaythroughValidationService.validate(staging_id:) is an internal operation for the authenticated MCP workflow, without a validation HTTP route. Unknown IDs raise not_found. Persisted success or terminal failure replays before completeness or storage checks, including after restart; concurrent validation cannot overwrite it. stage_incomplete is retryable and precedes all byte reads/parsing, including malformed received playlists or wrong role MIME. All completed objects are then read and verified before HLS interpretation: missing/unreadable blobs raise retryable storage_unavailable; readable bytes or stored size/hash/MIME disagreement raises terminal package_integrity_mismatch. Wrong declared role MIME, undeclared references, malformed/unsupported HLS, transport or chapters raises terminal invalid_hls. Retryable failures leave state unchanged; terminal failures require a new declaration/retry key to correct bytes. PUT receipts and declaration replays stay immutable. Internal validation suppresses logs, including failures.

        Restricted RFC 8216 profile: UTF-8 NFC, no BOM/control characters, LF or CRLF, first-line EXTM3U, exactly one EXT-X-VERSION:3 in every playlist. One media playlist or one master directly referencing media playlists, with shared media references allowed; no nested masters, alternate renditions or other tags/attributes. Masters require positive unsigned 64-bit BANDWIDTH; optional positive AVERAGE-BANDWIDTH, quoted CODECS list and positive RESOLUTION dimensions use RFC syntax and unique attributes. Media requires segments, a single positive unsigned 64-bit TARGETDURATION, PLAYLIST-TYPE:VOD, terminal ENDLIST and optional single MEDIA-SEQUENCE:0 before segments. Every URI follows one positive finite decimal EXTINF and required comma; optional UTF-8 titles are ignored. Half-up rounded durations cannot exceed target. Variant segment counts and numeric duration sequences must match. References use declaration path grammar relative to their playlist; every declared object must be reachable except optional root chapters.vtt, which is also required and validated. MIME roles: application/vnd.apple.mpegurl, video/mp2t, text/vtt.

        Each MPEG-TS segment is nonempty, 188-byte framed with sync 0x47, valid packet/adaptation/PSI lengths, no transport errors/scrambling, and complete CRC-checked PAT then matching PMT before elementary payload. One nonzero program, exactly one H.264 stream (0x1B), optionally one AAC/ADTS (0x0F), no other streams, with payload for every declared stream. Audio presence must agree across the package. PMT determines codecs; full decoding is outside validation. chapters.vtt permits one initial UTF-8 BOM, exact WEBVTT then blank line, and 1–256 chronological non-overlapping cues within summed duration. Each cue is HH:MM:SS.mmm --> HH:MM:SS.mmm (two-digit hours, minutes/seconds 00–59), one nonblank title without <, & or -->, and blank separation. No header text, identifiers, settings, markup or STYLE/REGION/NOTE blocks.
      TEXT
      response "200", "metadata only; no bytes or storage URLs" do
        schema stage_schema
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        context "incomplete" do
          run_test! do
            expect(response.headers["Cache-Control"]).to eq("no-store")
            expect(response.parsed_body.fetch("state")).to eq("incomplete")
            expect(response.parsed_body.keys).not_to include("validation_result", "validation_error")
          end
        end
        context "received" do
          before { receive_playthrough(stage: stage) }
          run_test! { expect(response.parsed_body.fetch("state")).to eq("received") }
        end
        context "validated" do
          let(:files) { hls_variant_files }
          let(:stage) { declare_hls(release: release, files: files) }
          before { receive_hls(stage: stage, files: files); PlaythroughValidationService.validate(staging_id: stage.public_id) }
          run_test! do
            expect(response.headers["Cache-Control"]).to eq("no-store")
            expect(response.headers["Set-Cookie"]).to be_nil
            expect(response.parsed_body.fetch("state")).to eq("validated")
            expect(response.parsed_body.fetch("validation_result")).to eq(stage.reload.validation_result)
            expect(response.parsed_body).not_to have_key("validation_error")
          end
        end
        context "validation_failed" do
          before do
            receive_playthrough(stage: stage)
            expect { PlaythroughValidationService.validate(staging_id: stage.public_id) }.to raise_error(PlaythroughStage::InvalidHls)
          end
          run_test! do
            expect(response.headers["Cache-Control"]).to eq("no-store")
            expect(response.parsed_body.fetch("state")).to eq("validation_failed")
            expect(response.parsed_body.fetch("validation_error")).to eq("invalid_hls")
            expect(response.parsed_body).not_to have_key("validation_result")
          end
        end
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
      parameter name: :segment, in: :body, required: true, schema: { type: :string, format: :binary }
      description "Raw bytes with the exact declared Content-Type; any valid declared MIME type without parameters is accepted. Exact size and SHA-256 must match, including on successful retries. Reads are bounded at 8 MiB regardless of Content-Length. Success returns an immutable object_id/received_at receipt; identical retries return exactly that receipt, even after other objects finish. GET stage metadata for aggregate progress. Fresh private storage keys isolate attempts and stages; completion follows storage success. Interrupted reads and storage failure leave the object incomplete and retryable after restart. No HLS validation or playback is performed. The deployment owner must verify the zone upload setting, which can be lower than Cloudflare's documented 100 MB minimum plan limit: https://developers.cloudflare.com/cache/concepts/default-cache-behavior/#upload-limits (#57)."

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
        "404" => [ "stage or declared object not found", %w[not_found] ],
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
          when "404"
            let(:stage_object_id) { "unknown" }
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
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    begin
      post "/v1/playthrough-stages.json", params: JSON.generate(declaration), headers: headers
      expect(response).to have_http_status(:created)
      receipt = response.parsed_body
      upload_path = "/v1/playthrough-stages/#{receipt.fetch('staging_id')}/objects/#{receipt.fetch('objects').sole.fetch('object_id')}.json"
      post "/v1/playthrough-stages.json", params: "private broken JSON", headers: headers
      expect(response).to have_http_status(:bad_request)
      put upload_path, params: "private wrong bytes", headers: headers.merge("CONTENT_TYPE" => "video/mp2t")
      expect(response).to have_http_status(:conflict)
      allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(IOError, "private storage failure")
      put upload_path, params: segment, headers: headers.merge("CONTENT_TYPE" => "video/mp2t")
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
    files = hls_files
    staged = declare_hls(release: release, files: files)
    receive_hls(stage: staged, files: files)
    PlaythroughValidationService.validate(staging_id: staged.public_id)
    failed = declare_playthrough
    receive_playthrough(stage: failed)
    expect { PlaythroughValidationService.validate(staging_id: failed.public_id) }.to raise_error(PlaythroughStage::InvalidHls)
    public_paths.each_with_index do |path, index|
      get path, headers: { "User-Agent" => "Arcadary/1.0" }
      expect([ response.status, response.body, response.headers.slice("ETag", "Last-Modified", "Cache-Control") ]).to eq(previous[index])
    end
    object = staged.objects.first.reload
    get "/v1/playthrough-stages/#{staged.public_id}/objects/#{object.public_id}.json", headers: headers
    expect(response).to have_http_status(:not_found)
    get "/rails/active_storage/blobs/redirect/#{object.blob.signed_id}/playthrough-object"
    expect(response).to have_http_status(:not_found)
    post "/v1/playthrough-stages/#{staged.public_id}/validate.json", headers: headers
    expect(response).to have_http_status(:not_found)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "bounds declaration and object reads with missing or dishonest Content-Length" do
    post "/v1/playthrough-stages.json", params: "x" * (1.megabyte + 1), headers: headers.merge("CONTENT_LENGTH" => "1")
    expect(response).to have_http_status(:content_too_large)
    post "/v1/playthrough-stages.json", params: JSON.generate(declaration), headers: headers.merge("CONTENT_LENGTH" => "")
    expect(response).to have_http_status(:created)
    put "/v1/playthrough-stages/#{PlaythroughStage.sole.public_id}/objects/#{PlaythroughStageObject.sole.public_id}.json",
      params: "x" * (8.megabytes + 1), headers: headers.merge("CONTENT_TYPE" => "video/mp2t", "CONTENT_LENGTH" => "1")
    expect(response).to have_http_status(:content_too_large)
    put "/v1/playthrough-stages/#{PlaythroughStage.sole.public_id}/objects/#{PlaythroughStageObject.sole.public_id}.json",
      params: segment, headers: headers.merge("CONTENT_TYPE" => "video/mp2t", "CONTENT_LENGTH" => "")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("received_at")).to be_present
  end

  it "replays the identical object receipt after other objects finish" do
    declaration["manifest"] << declaration["manifest"].first.merge("path" => "video/next.ts")
    staged = declare_playthrough
    first, second = staged.objects.to_a
    first_path = "/v1/playthrough-stages/#{staged.public_id}/objects/#{first.public_id}.json"
    put first_path, params: segment, headers: headers.merge("CONTENT_TYPE" => "video/mp2t")
    original = response.body
    put "/v1/playthrough-stages/#{staged.public_id}/objects/#{second.public_id}.json", params: segment,
      headers: headers.merge("CONTENT_TYPE" => "video/mp2t")
    put first_path, params: segment, headers: headers.merge("CONTENT_TYPE" => "video/mp2t")
    expect(response.body).to eq(original)
    get "/v1/playthrough-stages/#{staged.public_id}.json", headers: headers
    expect(response.parsed_body.fetch("state")).to eq("received")
  end
end
