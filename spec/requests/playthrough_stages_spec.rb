require "swagger_helper"
require_relative "../support/playthrough_helpers"
require_relative "../support/screenshot_helpers"
require_relative "../support/playthrough_hls_helpers"

RSpec.describe "Private playthrough staging", type: :request do
  include PlaythroughHelpers
  include ScreenshotHelpers
  include PlaythroughHlsHelpers
  include ActiveSupport::Testing::TimeHelpers

  let!(:release) { create(:release) }
  let(:declaration) { playthrough_declaration(release: release) }
  let(:Authorization) { ActionController::HttpAuthentication::Basic.encode_credentials("synthetic-admin", "synthetic-password") }
  let(:headers) { { "Authorization" => self.Authorization, "CONTENT_TYPE" => "application/json" } }
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
    type: :object, additionalProperties: false, required: %w[staging_id release_id package_sha256 declaration state declared_at stage_expires_at], properties: {
      staging_id: { type: :string }, release_id: { type: :string }, package_sha256: { type: :string, pattern: "^[0-9a-f]{64}$" },
      declaration: { oneOf: [ { "$ref" => "#/components/schemas/playthrough_declaration" },
        McpPlaythroughToolsService.input_schema.merge(required: %w[retry_key release_id source_sha1 capture],
          properties: McpPlaythroughToolsService.input_schema.fetch(:properties).except(:manifest)) ] },
      state: { type: :string, enum: %w[incomplete received validated validation_failed promoting published expired reclaimed] },
      declared_at: { type: :string, format: "date-time" }, stage_expires_at: { type: :string, format: "date-time" },
      expired_at: { type: :string, format: "date-time" }, reclaimed_at: { type: :string, format: "date-time" },
      declaration_sha256: { type: :string, pattern: "^[0-9a-f]{64}$" },
      validation_result: { "$ref" => "#/components/schemas/playthrough_validation_result" },
      validation_error: { type: :string, enum: %w[invalid_hls package_integrity_mismatch] },
      objects: { type: :array, items: { type: :object, additionalProperties: false, required: %w[object_id path received],
        properties: { object_id: { type: :string }, path: { type: :string }, received: { type: :boolean } } } }
    }
  }

  path "/v1/playthrough-stages/{staging_id}.json" do
    get "Read private declaration and durable object progress" do
      produces "application/json"
      security [ private_service_basic: [] ]
      parameter name: :staging_id, in: :path, required: true, schema: { type: :string }
      description <<~TEXT
        declared_at is the original declaration/creation time; stage_expires_at is exactly 24 hours later. At that deadline every stage closes staging writes and internal validation rejects before replay. Unprotected stages expire on access; promoting/published retain their state without expired_at or reclaimed_at. GET remains 200: expired includes expired_at equal to the deadline; reclaimed adds reclaimed_at only after all associated reclaimable keys are confirmed absent with no deletion work pending. Receipts retain retry/stage identity, declaration fingerprint/package digest, exact release, source, capture and full mismatch evidence. Reclaimed receipts omit objects and manifests, including nested copies, and have no media attachments or bytes. Identical normalized begin replay returns stage_expired without authorization after the deadline; changed input returns stage_conflict even after pruning, with the retry key reserved.

        Transfers and validators have independent renewable fenced 15-minute leases. Concurrent different-object transfers proceed independently; same-object transfers return the winning receipt and delete only their own loser keys. Concurrent live validators replay the first terminal outcome, including conflicting local outcomes. Heartbeats renew during blocking upload/download and validation, without extending the declaration deadline. At lease equality abandoned attempts are fenced; stale attachment, validation commit/replay or renewal fails stage_conflict, or stage_expired after the deadline. Hourly cleanup at minute 5 after screenshot cleanup handles at most 100 stages and 500 keys with durable fair progress, skips live transfer/validation owners and uses renewable fenced claims. It deletes only owned private staging keys after reference rechecks; legacy bytes wait for the retained owning stage's original deadline. Failed deletion stays pending with retryable storage_unavailable while other work continues. Transfer key/blob identities and fencing tombstones persist with the stage, even after reclamation. Fenced late writers record pending work and delete only their own keys; failed deletion clears reclaimed_at until absence is reconfirmed. Cleanup revisits reclaimed tombstones even when a late writer crashes before recording pending work. Staging never reopens. All private HTTP, validation, cleanup and ownership failures suppress logs.

        Existing stages always return 200. incomplete means missing receipts; received means stored but unvalidated. validated, promoting and published include validation_result; promoting/published retain the exact validated payload, objects and declaration with only state changed, even after the deadline. They add no publication timestamp, claim data or terminal-expiry timestamps. validation_failed includes validation_error (invalid_hls or package_integrity_mismatch). Other states omit both validation fields. Results bind this exact staging ID, immutable normalized manifest/declaration fingerprint/package digest, stable release ID, source SHA-1 and capture/verification evidence. duration is exact summed decimal seconds, audio_codec is null for silent H.264, and absent chapters use chapters_path:null and chapters:[]. Before the deadline, promoting/published validation replays without storage reads, PUT retains identical receipts and MCP begin retains the same stage/objects/received summary with a fresh capability. No public object, descriptor, redirect or playback is created.

        Internal PlaythroughPromotionService.claim_promotion(staging_id:, release_id:, package_sha256:) verifies persisted validation/stage/stable-release/package bindings and atomically pins an unexpired validated stage as promoting. Identical active requests return the same durable opaque claim, even after the deadline; active claims never time out. complete_promotion(claim:) records published; release_promotion(claim:) restores validated before the original deadline or expired at/after it. Matching terminal outcomes replay after restart; crossed operations, wrong/stale claims, ineligible/published stages and changed bindings fail stage_conflict. Unknown stages raise not_found; expired/reclaimed stages reject claims with stage_expired. A fresh claim after release has a new identity; repeating the old release is a no-op. Promotion uses the same atomic exclusion as expiry, attachment, validation finalization and reclamation. Cleanup excludes promoting/published stages from selection and visit counts; published staging objects, blobs and complete manifests remain indefinitely, even after pointer replacement. The #57 publisher must complete inside its successful release-pointer transaction (completion rolls back with it), release only after copying stops, and own historical successful-publication retries. Storage stays outside transactions; claims and private failures are never logged or exposed. No copying, release pointer, validation/promotion HTTP route or MCP publication tool is added here.

        PlaythroughValidationService.validate(staging_id:) is an internal operation for the authenticated MCP workflow, without a validation HTTP route. Unknown IDs raise not_found. Before the declaration deadline, persisted success or terminal failure replays before completeness or storage checks, including after restart; concurrent live validation cannot overwrite it. stage_incomplete is retryable and precedes all byte reads/parsing, including malformed received playlists or wrong role MIME. All completed objects are then read and verified before HLS interpretation: missing/unreadable blobs raise retryable storage_unavailable; readable bytes or stored size/hash/MIME disagreement raises terminal package_integrity_mismatch. Wrong declared role MIME, undeclared references, malformed/unsupported HLS, transport or chapters raises terminal invalid_hls. Retryable failures leave state unchanged; terminal failures require a new declaration/retry key to correct bytes. PUT receipts and declaration replays stay immutable. Internal validation suppresses logs, including failures.

        Restricted RFC 8216 profile: UTF-8 NFC, no BOM/control characters, LF or CRLF, first-line EXTM3U, exactly one EXT-X-VERSION:3 in every playlist. One media playlist or one master directly referencing media playlists, with shared media references allowed; no nested masters, alternate renditions or other tags/attributes. Masters require positive unsigned 64-bit BANDWIDTH; optional positive AVERAGE-BANDWIDTH, quoted CODECS list and positive RESOLUTION dimensions use RFC syntax and unique attributes. Media requires segments, a single positive unsigned 64-bit TARGETDURATION, PLAYLIST-TYPE:VOD, terminal ENDLIST and optional single MEDIA-SEQUENCE:0 before segments. Every URI follows one positive finite decimal EXTINF and required comma; optional UTF-8 titles are ignored. Half-up rounded durations cannot exceed target. Variant segment counts and numeric duration sequences must match. References use declaration path grammar relative to their playlist; every declared object must be reachable except optional root chapters.vtt, which is also required and validated. MIME roles: application/vnd.apple.mpegurl, video/mp2t, text/vtt.

        Each MPEG-TS segment is nonempty, 188-byte framed with sync 0x47, valid packet/adaptation/PSI lengths, no transport errors/scrambling, and complete CRC-checked PAT then matching PMT before elementary payload. DVB service-information PIDs 0x0010–0x001F (including SDT on 0x0011) pass packet/adaptation checks, then their payloads are ignored; they may precede the PAT and do not count as elementary streams. CAT and undeclared elementary-stream PIDs remain rejected. One nonzero program, exactly one H.264 stream (0x1B), optionally one AAC/ADTS (0x0F), no other elementary streams, with payload for every declared stream. Audio presence must agree across the package. PMT determines codecs; full decoding is outside validation. chapters.vtt permits one initial UTF-8 BOM, exact WEBVTT then blank line, and 1–256 chronological non-overlapping cues within summed duration. Each cue is HH:MM:SS.mmm --> HH:MM:SS.mmm (two-digit hours, minutes/seconds 00–59), one nonblank title without <, & or -->, and blank separation. No header text, identifiers, settings, markup or STYLE/REGION/NOTE blocks.
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
        %w[promoting published].each do |state|
          context state do
            let(:files) { hls_variant_files }
            let(:stage) { declare_hls(release: release, files: files) }
            before do
              receive_hls(stage: stage, files: files)
              PlaythroughValidationService.validate(staging_id: stage.public_id)
              @validated_receipt = PlaythroughStageDecorator.decorate(stage.reload).as_json.deep_stringify_keys
              claim = PlaythroughPromotionService.claim_promotion(staging_id: stage.public_id,
                release_id: release.public_id, package_sha256: stage.package_sha256)
              PlaythroughPromotionService.complete_promotion(claim: claim) if state == "published"
            end
            run_test! do
              expect(response.parsed_body).to eq(@validated_receipt.merge("state" => state))
              expect(response.headers["Cache-Control"]).to eq("no-store")
              expect(response.headers["Set-Cookie"]).to be_nil
              travel_to stage.declared_at + 24.hours, with_usec: true do
                get "/v1/playthrough-stages/#{stage.public_id}.json", headers: headers
                expect(response).to have_http_status(:ok)
                expect(response.parsed_body).to eq(@validated_receipt.merge("state" => state))
                expect(response.headers["Cache-Control"]).to eq("no-store")
                expect(response.headers["Set-Cookie"]).to be_nil
              end
            end
          end
        end
        context "expired" do
          before { travel_to stage.declared_at + 24.hours, with_usec: true }
          after { travel_back }
          run_test! do
            expect(response.parsed_body.fetch("state")).to eq("expired")
            expect(response.parsed_body.fetch("expired_at")).to eq((stage.declared_at + 24.hours).iso8601(6))
            expect(response.parsed_body).not_to have_key("reclaimed_at")
          end
        end
        context "reclaimed" do
          before do
            receive_playthrough(stage: stage)
            travel_to stage.declared_at + 24.hours, with_usec: true
            PlaythroughStageCleanupService.call
          end
          after { travel_back }
          run_test! do
            expect(response.parsed_body.fetch("state")).to eq("reclaimed")
            expect(response.parsed_body.fetch("reclaimed_at")).to be_present
            expect(response.parsed_body).not_to have_key("objects")
            expect(response.parsed_body.fetch("declaration")).not_to have_key("manifest")
            expect(response.headers["Cache-Control"]).to eq("no-store")
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
      parameter name: :"X-Arcadary-Upload-Capability", in: :header, required: true, schema: { type: :string }
      parameter name: :segment, in: :body, required: true, schema: { type: :string, format: :binary }
      description "Requires current shared Basic credentials plus X-Arcadary-Upload-Capability from MCP begin_playthrough_staging. Capabilities bind the exact release, stage, immutable manifest and declared objects, never travel in URLs, and expire exactly 900 seconds after issuance (invalid at or after expires_at). Identical begin replay renews before the 24-hour declaration deadline without extending older capabilities or the stage deadline; HTTP metadata reads never renew. After Basic authentication, missing, invalid, expired or mismatched capabilities and unknown object IDs return 403 upload_not_authorized first. Valid declared-object authorization on an expired/reclaimed stage returns 410 stage_expired, including accepted-object retries, before application body or storage reads. Capability expiry remains issuance plus 900 seconds even beyond the stage deadline. Raw bytes with the exact declared Content-Type; any valid declared MIME type without parameters is accepted. Exact size and SHA-256 must match, including on successful retries. Reads are bounded at 8 MiB regardless of Content-Length. Success returns an immutable object_id/received_at receipt; identical retries return exactly that receipt, even after other objects finish. GET stage metadata for aggregate progress. Fresh private storage keys isolate attempts and stages; completion follows storage success. Interrupted reads and storage failure leave the object incomplete and retryable after restart. No HLS validation or playback is performed. The deployment owner must verify the zone upload setting, which can be lower than Cloudflare's documented 100 MB minimum plan limit: https://developers.cloudflare.com/cache/concepts/default-cache-behavior/#upload-limits (#57)."

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
        "410" => [ "authorized object on an expired stage", %w[stage_expired] ],
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
          when "410"
            before do
              travel_to stage.declared_at + 24.hours - 1, with_usec: true
              capability
              travel 1, with_usec: true
            end
            after { travel_back }
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

  %w[promoting published].each do |state|
    it "keeps authorized #{state} PUT receipts immutable, then rejects them at the deadline before body or storage reads" do
      files = hls_files
      stage = declare_hls(release: release, files: files)
      receive_hls(stage: stage, files: files)
      PlaythroughValidationService.validate(staging_id: stage.public_id)
      object = stage.objects.reload.find_by!(path: "segment.ts")
      expected = PlaythroughStageObjectDecorator.decorate(object).as_json.deep_stringify_keys
      claim = PlaythroughPromotionService.claim_promotion(staging_id: stage.public_id,
        release_id: release.public_id, package_sha256: stage.package_sha256)
      PlaythroughPromotionService.complete_promotion(claim: claim) if state == "published"
      travel_to stage.declared_at + 24.hours - 1, with_usec: true do
        token = PlaythroughUploadAuthorizationService.issue(stage: stage).fetch(:capability)
        authorized_headers = headers.merge("X-Arcadary-Upload-Capability" => token, "CONTENT_TYPE" => object.content_type)
        path = "/v1/playthrough-stages/#{stage.public_id}/objects/#{object.public_id}.json"
        allow(ActiveStorage::Blob.service).to receive(:upload).and_raise("must not upload")
        allow(ActiveStorage::Blob.service).to receive(:download).and_raise("must not download")
        put path, params: files.fetch("segment.ts"), headers: authorized_headers
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq(expected)
        travel 1, with_usec: true
        allow(PlaythroughStageInputService).to receive(:read).and_raise("must not read body")
        put path, params: "unread body", headers: authorized_headers
        expect(response).to have_http_status(:gone)
        expect(response.parsed_body).to eq("error" => "stage_expired")
        expect(response.headers["Cache-Control"]).to eq("no-store")
        put path, params: "unread body", headers: authorized_headers.except("X-Arcadary-Upload-Capability")
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to eq("error" => "upload_not_authorized")
        expect(stage.reload).to have_attributes(promotion_state: state, expired_at: nil, reclaimed_at: nil)
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
    files = hls_files
    staged = declare_hls(release: release, files: files)
    receive_hls(stage: staged, files: files)
    PlaythroughValidationService.validate(staging_id: staged.public_id)
    failed = declare_playthrough
    receive_playthrough(stage: failed)
    expect { PlaythroughValidationService.validate(staging_id: failed.public_id) }.to raise_error(PlaythroughStage::InvalidHls)
    claim = PlaythroughPromotionService.claim_promotion(staging_id: staged.public_id,
      release_id: release.public_id, package_sha256: staged.package_sha256)
    %w[promoting published].each do |state|
      PlaythroughPromotionService.complete_promotion(claim: claim) if state == "published"
      public_paths.each_with_index do |path, index|
        get path, headers: { "User-Agent" => "Arcadary/1.0" }
        expect([ response.status, response.body, response.headers.slice("ETag", "Last-Modified", "Cache-Control") ]).to eq(previous[index])
      end
    end
    object = staged.objects.first.reload
    token = PlaythroughUploadAuthorizationService.issue(stage: staged).fetch(:capability)
    get "/v1/playthrough-stages/#{staged.public_id}/objects/#{object.public_id}.json", headers: headers.merge("X-Arcadary-Upload-Capability" => token)
    expect(response).to have_http_status(:not_found)
    get "/rails/active_storage/blobs/redirect/#{object.blob.signed_id}/playthrough-object"
    expect(response).to have_http_status(:not_found)
    %w[validate promote].each do |operation|
      post "/v1/playthrough-stages/#{staged.public_id}/#{operation}.json", headers: headers
      expect(response).to have_http_status(:not_found)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
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
