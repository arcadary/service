require "swagger_helper"
require_relative "../support/screenshot_helpers"

RSpec.describe "Uploads", type: :request do
  include ScreenshotHelpers
  include ActiveSupport::Testing::TimeHelpers

  let(:Authorization) { admin_authorization }
  let(:upload) { UploadService.create(kind: "screenshot") }
  let(:upload_id) { upload.public_id }
  let(:file) { png }
  let(:"Content-Digest") { content_digest(file) }

  before { stub_admin_credentials }

  def put_file(name: "screenshot.png", bytes: png, content_type: "image/png", digest: content_digest(bytes), id: upload_id)
    put_upload_file("/v1/uploads/#{id}/files/#{name}", bytes: bytes, content_type: content_type, digest: digest)
  end

  error_schema = ->(codes) { { type: :object, required: [ "error" ], additionalProperties: false, properties: { error: { type: :string, enum: codes } } } }

  path "/v1/uploads/{upload_id}/files/{name}" do
    put "Store one file of an upload" do
      consumes "image/png", "application/vnd.apple.mpegurl", "video/mp2t", "video/mp4", "text/vtt"
      produces "application/json"
      security [ private_service_basic: [] ]
      description "Stores one file, exactly as sent, on the service host's own disk until the upload is confirmed, used or expires 24 hours after request_upload. The upload_id comes from the MCP tool request_upload, whose limits apply; name is the file's package-relative path. Send the file's Content-Type and its SHA-256 in Content-Digest (sha-256=:BASE64:). Each file is checked on arrival: digest, size and file type. Sending the same name with the same digest again changes nothing."
      parameter name: :upload_id, in: :path, required: true, schema: { type: :string }
      parameter name: :name, in: :path, required: true, schema: { type: :string }
      parameter name: :"Content-Digest", in: :header, required: true, schema: { type: :string, pattern: "^sha-256=:[A-Za-z0-9+/]{43}=:$" }
      parameter name: :file, in: :body, required: true, schema: { type: :string, format: :binary }
      let(:name) { "screenshot.png" }

      response "200", "file stored, or the same file sent again" do
        schema "$ref" => "#/components/schemas/UploadFile"
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        run_test! do
          expect(response.parsed_body).to eq("name" => "screenshot.png", "size" => file.bytesize, "sha256" => Digest::SHA256.hexdigest(file))
        end
      end

      {
        "400" => [ "interrupted read", %w[interrupted_transfer] ],
        "401" => [ "authentication failed", %w[unauthorized] ],
        "404" => [ "unknown upload", %w[not_found] ],
        "409" => [ "upload no longer takes files, or the name holds a different file", %w[upload_conflict] ],
        "410" => [ "the 24-hour lease ran out", %w[upload_expired] ],
        "413" => [ "a file or the upload exceeds its cap", %w[upload_too_large] ],
        "422" => [ "digest, size, name, type or file check failed", %w[upload_rejected] ],
        "503" => [ "storage unavailable", %w[storage_unavailable] ],
        "507" => [ "stored uploads already total 10 GB", %w[uploads_full] ]
      }.each do |status, (summary, codes)|
        response status, summary do
          schema error_schema.call(codes)
          header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
          let(:Authorization) { "Basic wrong" } if status == "401"
          let(:upload_id) { "unknown" } if status == "404"
          let(:"Content-Digest") { content_digest("other") } if status == "422"
          before { put_file && UploadService.confirm(upload_id: upload_id) } if status == "409"
          before { upload && travel(25.hours) } if status == "410"
          let(:file) { png(chunks: [ png_chunk("tEXt", "a" * 1.megabyte) ]) } if status == "413"
          before { stub_const("Upload::QUOTA_BYTES", 10) } if status == "507"
          before { allow(UploadStorageService).to receive(:write).and_raise(Upload::StorageUnavailable) } if status == "503"
          before { allow(UploadService).to receive(:receive).and_raise(Upload::InterruptedTransfer) } if status == "400"
          run_test!
        end
      end
    end
  end

  path "/v1/uploads/{upload_id}.json" do
    get "An upload's state and files" do
      produces "application/json"
      security [ private_service_basic: [] ]
      description "Lists the files stored so far, so an interrupted upload resumes by sending the missing ones. States: requested, receiving, checking (confirm_upload is checking it in the background), confirmed, rejected (with rejection_reason) and used."
      parameter name: :upload_id, in: :path, required: true, schema: { type: :string }

      response "200", "upload" do
        schema "$ref" => "#/components/schemas/Upload"
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        before { put_file }
        run_test! do
          expect(response.parsed_body).to include("state" => "receiving", "files" => [ include("name" => "screenshot.png") ])
        end
      end

      response "404", "unknown upload" do
        schema error_schema.call(%w[not_found])
        let(:upload_id) { "unknown" }
        run_test!
      end
    end
  end

  it "accepts the same file again, keeps nested video paths and refuses a different file under a stored name" do
    put_file
    put_file
    expect(response).to have_http_status(:ok)
    put_file(bytes: png(pixel: "\xff\0\0\xff".b))
    expect(response).to have_http_status(:conflict)
    video = UploadService.create(kind: "video")
    put_file(id: video.public_id, name: "low/index.m3u8", bytes: "#EXTM3U\n", content_type: "application/vnd.apple.mpegurl")
    expect(response.parsed_body.fetch("name")).to eq("low/index.m3u8")
    expect(UploadStorageService.read(upload: video, name: "low/index.m3u8")).to eq("#EXTM3U\n")
  end

  it "rejects files of the wrong type for the upload, malformed names and missing digests before storing anything" do
    put_file(content_type: "video/mp2t")
    expect(response).to have_http_status(:unprocessable_content)
    put_file(bytes: "not a PNG")
    expect(response).to have_http_status(:unprocessable_content)
    put_file(name: "a%3Ab.png")
    expect(response).to have_http_status(:unprocessable_content)
    put_file(digest: "")
    expect(response).to have_http_status(:unprocessable_content)
    expect(upload.files.reload).to be_empty
  end

  it "keeps a second screenshot file out of a screenshot upload" do
    put_file
    put_file(name: "second.png", bytes: png(pixel: "\xff\0\0\xff".b))
    expect(response).to have_http_status(:content_too_large)
  end

  it "requires credentials before reading the body and keeps uploads out of the logs" do
    path = "/v1/uploads/#{upload_id}/files/screenshot.png"
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(capture)
    begin
      expect(UploadService).not_to receive(:receive)
      put path, params: png, headers: { "CONTENT_TYPE" => "image/png" }
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
    expect(output.string).not_to include(upload_id)
  end
end
