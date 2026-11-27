require "swagger_helper"
require_relative "../support/validation_helpers"

RSpec.describe "Validation receipts", type: :request do
  include_context "private validation storage"

  after do
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.headers["Set-Cookie"]).to be_nil
  end

  path "/v1/validations.json" do
    post "Admit an unknown file for private validation" do
      consumes "application/json"
      produces "application/json"
      description "Anonymous and cookie-free. JSON is at most 1,024 bytes and contains exactly sha1, byte_size and system. Availability precedes media/encoding, metadata size, structure/fields, file size, known-release and conflict checks. Absent or identity Content-Encoding only. The launcher checks its reference lists and unknown lookup and obtains player confirmation; the service cannot prove those checks. No filename is accepted."
      parameter name: :metadata, in: :body, required: true, schema: {
        type: :object, required: %w[sha1 byte_size system], additionalProperties: false,
        properties: {
          sha1: { type: :string, pattern: "^[0-9a-fA-F]{40}$" },
          byte_size: { type: :integer, minimum: 1, maximum: 134_217_728 },
          system: { type: :string, enum: Release::SYSTEMS }
        }
      }
      parameter name: :"Content-Encoding", in: :header, required: false, schema: { type: :string, enum: [ "identity" ] }
      let(:metadata) { { sha1: checksum.upcase, byte_size: payload.bytesize, system: "c64" } }

      response "201", "admitted, including a matching incomplete retry" do
        schema type: :object, required: %w[status admission expires_at], additionalProperties: false,
          properties: { status: { type: :string, enum: [ "admitted" ] }, admission: { type: :string }, expires_at: { type: :string, format: "date-time" } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test! do
          expect(ValidationSubmission.find_by!(sha1: checksum)).to have_attributes(byte_size: payload.bytesize, system: "c64", completed_at: nil)
          expect(Time.iso8601(response.parsed_body.fetch("expires_at"))).to be_within(1.second).of(10.minutes.from_now)
        end
      end

      response "200", "already received; no further transfer" do
        schema "$ref" => "#/components/schemas/ValidationReceived"
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        before { upload(admission: admission_for) }
        run_test!
      end

      response "400", "invalid JSON object or metadata" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "invalid_metadata" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:metadata) { { sha1: checksum, byte_size: payload.bytesize, system: "c64", filename: "not accepted" } }
        run_test!
      end

      response "409", "known release or conflicting submission facts" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: %w[known_release submission_conflict] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        before { create(:release, sha1: checksum, system: "nes") }
        run_test! { expect(response.parsed_body).to eq("error" => "known_release") }

        context "conflicting size" do
          before do
            Release.destroy_all
            admission_for(byte_size: payload.bytesize + 1)
          end
          run_test! { expect(response.parsed_body).to eq("error" => "submission_conflict") }
        end
      end

      response "413", "metadata or file above its bound" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: %w[metadata_too_large file_too_large] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:metadata) { { sha1: checksum, byte_size: 134_217_729, system: "c64" } }
        run_test! { expect(response.parsed_body).to eq("error" => "file_too_large") }

        context "oversized admission JSON" do
          let(:metadata) { { sha1: "a" * 1025, byte_size: 1, system: "c64" } }
          run_test! { expect(response.parsed_body).to eq("error" => "metadata_too_large") }
        end
      end

      response "415", "unsupported media type or content encoding" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "unsupported_media_type" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:"Content-Encoding") { "gzip" }
        run_test!
      end

      response "503", "receipt unavailable; no admission or submission change" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "unavailable" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        before { @receipt_env["VALIDATION_UPLOADS_ENABLED"] = "false" }
        run_test! { expect(ValidationSubmission.count).to eq(0) }
      end
    end
  end

  path "/v1/validations/{sha1}/file.json" do
    put "Receive the admitted raw file into private storage" do
      consumes "application/octet-stream"
      produces "application/json"
      description "Admission is accepted only in X-Validation-Admission. Fresh signed admissions expire in ten minutes and bind normalized SHA-1, size and system. Availability, media/encoding, Rack Content-Length presence/format/global bound, path, admission/persisted facts, known release and admitted length are checked before body reading, even for completed retries. Completed retries confirm without reading or rewriting the file. Incomplete uploads have a 120-second application read deadline, 64 KiB chunks and a 134,217,728-byte ceiling; after EOF, count precedes SHA-1. Transport rejection can fall outside this JSON contract: repeat POST to recover. No public file route or signed download link exists."
      parameter name: :sha1, in: :path, required: true, schema: { type: :string, pattern: "^[0-9a-fA-F]{40}$" }
      parameter name: :"X-Validation-Admission", in: :header, required: true, schema: { type: :string }
      parameter name: :"Content-Length", in: :header, required: true, schema: { type: :integer, minimum: 1, maximum: 134_217_728 }
      parameter name: :"Content-Encoding", in: :header, required: false, schema: { type: :string, enum: [ "identity" ] }
      parameter name: :file, in: :body, required: true, schema: { type: :string, format: :binary }
      let(:sha1) { checksum }
      let(:"X-Validation-Admission") { admission_for }
      let(:"Content-Length") { payload.bytesize }
      let(:file) { payload }

      response "200", "received, including a completed retry" do
        schema "$ref" => "#/components/schemas/ValidationReceived"
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test! do
          expect(File.binread(File.join(@receipt_folder, "#{checksum}.data"))).to eq(payload)
          expect(ValidationSubmission.find_by!(sha1: checksum).completed_at).to be_present
        end
      end

      response "400", "malformed path checksum or invalid Rack Content-Length" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "invalid_metadata" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:sha1) { "malformed" }
        run_test!
      end

      response "403", "missing, invalid, expired or mismatched admission" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "invalid_admission" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:"X-Validation-Admission") { "invalid" }
        run_test!
      end

      response "408", "application body-read deadline exceeded" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "upload_timeout" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        before { allow_any_instance_of(ValidationStorageService).to receive(:verify_body!).and_raise(ValidationSubmission::UploadTimeout) }
        run_test!
      end

      response "409", "file joined a release after admission, in any system or media position" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "known_release" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        before do
          public_send(:"X-Validation-Admission")
          create(:release, sha1: checksum)
        end
        run_test!
      end

      response "411", "Rack Content-Length absent" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "length_required" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        before do
          allow(Rails.application).to receive(:call).and_wrap_original do |original, env|
            env.delete("CONTENT_LENGTH") if env["REQUEST_METHOD"] == "PUT"
            original.call(env)
          end
        end
        run_test!
      end

      response "413", "declared or actual body above the global ceiling" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "file_too_large" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:"Content-Length") { 134_217_729 }
        run_test!
      end

      response "415", "unsupported media type or content encoding" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "unsupported_media_type" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:"Content-Encoding") { "gzip" }
        run_test!
      end

      response "422", "admitted/actual size or actual SHA-1 mismatch" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: %w[size_mismatch checksum_mismatch] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:"Content-Length") { payload.bytesize + 1 }
        run_test! { expect(response.parsed_body).to eq("error" => "size_mismatch") }

        context "wrong checksum with matching size" do
          let(:"Content-Length") { payload.bytesize }
          let(:file) { "x" * payload.bytesize }
          run_test! { expect(response.parsed_body).to eq("error" => "checksum_mismatch") }
        end
      end

      response "503", "receipt or private storage unavailable" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "unavailable" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        before do
          public_send(:"X-Validation-Admission")
          @receipt_env.delete("VALIDATION_REVIEWER_PASSWORD")
        end
        run_test!
      end
    end
  end
end
