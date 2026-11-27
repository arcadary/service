require "rails_helper"
require_relative "../support/validation_helpers"

RSpec.describe "Validation receipt gates", type: :request do
  include_context "private validation storage"
  include ActiveSupport::Testing::TimeHelpers

  def unread_body
    double("unread body").tap { |body| expect(body).not_to receive(:read) }
  end

  def raw_upload(body:, token: "invalid", length: payload.bytesize.to_s, sha1: checksum, headers: {})
    rack_receipt(method: "PUT", path: "/v1/validations/#{sha1}/file.json", body: body,
      headers: { "CONTENT_LENGTH" => length, "HTTP_X_VALIDATION_ADMISSION" => token }.merge(headers))
  end

  it "fails unavailable before unsupported, oversized input or any submission change on both routes" do
    @receipt_env["VALIDATION_UPLOADS_ENABLED"] = "false"
    expect(rack_receipt(method: "POST", body: unread_body, headers: { "CONTENT_TYPE" => "text/plain", "CONTENT_LENGTH" => "999999999" })).to eq([ 503, { "error" => "unavailable" } ])
    expect(raw_upload(body: unread_body, headers: { "CONTENT_TYPE" => "application/json" }, length: "999999999")).to eq([ 503, { "error" => "unavailable" } ])
    expect(ValidationSubmission.count).to eq(0)
  end

  it "rejects an unsupported JSON PUT without invoking the Rails parameter parser" do
    expect_any_instance_of(ActionDispatch::Request).not_to receive(:request_parameters)
    expect(raw_upload(body: unread_body, length: nil, headers: { "CONTENT_TYPE" => "application/json" })).to eq([ 415, { "error" => "unsupported_media_type" } ])
  end

  it "checks media and encoding before metadata length and never reads an oversized declaration" do
    expect(rack_receipt(method: "POST", body: unread_body, headers: { "HTTP_CONTENT_ENCODING" => "br", "CONTENT_LENGTH" => "1025" })).to eq([ 415, { "error" => "unsupported_media_type" } ])
    expect(rack_receipt(method: "POST", body: unread_body, headers: { "CONTENT_LENGTH" => "1025" })).to eq([ 413, { "error" => "metadata_too_large" } ])
  end

  it "bounds actual JSON reads to 1,025 bytes, including short Rack reads" do
    body = StringIO.new(" " * 1025 + "private tail")
    expect(rack_receipt(method: "POST", body: body)).to eq([ 413, { "error" => "metadata_too_large" } ])
    expect(body.pos).to eq(1025)

    short_body = double("short reads")
    expect(short_body).to receive(:read).with(1025).ordered.and_return(" " * 512)
    expect(short_body).to receive(:read).with(513).ordered.and_return(" " * 513)
    expect(rack_receipt(method: "POST", body: short_body)).to eq([ 413, { "error" => "metadata_too_large" } ])
  end

  it "rejects malformed JSON, a non-object and invalid fields without persisting metadata" do
    [ "{", "[]", { sha1: checksum, byte_size: 1.5, system: "c64" }.to_json,
      { sha1: checksum, byte_size: 134_217_729, system: "unknown" }.to_json ].each do |json|
      expect(rack_receipt(method: "POST", body: StringIO.new(json))).to eq([ 400, { "error" => "invalid_metadata" } ])
    end
    expect(ValidationSubmission.count).to eq(0)
  end

  it "checks PUT length presence, format and ceiling before path or admission" do
    expect(raw_upload(body: unread_body, length: nil, sha1: "malformed")).to eq([ 411, { "error" => "length_required" } ])
    expect(raw_upload(body: unread_body, length: "-1", sha1: "malformed")).to eq([ 400, { "error" => "invalid_metadata" } ])
    expect(raw_upload(body: unread_body, length: "12.5")).to eq([ 400, { "error" => "invalid_metadata" } ])
    expect(raw_upload(body: unread_body, length: "134217729", sha1: "malformed")).to eq([ 413, { "error" => "file_too_large" } ])
    expect(raw_upload(body: unread_body, sha1: "malformed")).to eq([ 400, { "error" => "invalid_metadata" } ])
  end

  it "checks signature, expiry, path and persisted facts before known release and admitted length" do
    token = admission_for
    expect(raw_upload(body: unread_body, token: "invalid", length: "1")).to eq([ 403, { "error" => "invalid_admission" } ])
    expect(raw_upload(body: unread_body, token: token, sha1: "a" * 40)).to eq([ 403, { "error" => "invalid_admission" } ])
    travel 11.minutes do
      expect(raw_upload(body: unread_body, token: token)).to eq([ 403, { "error" => "invalid_admission" } ])
    end
    ValidationSubmission.find_by!(sha1: checksum).destroy!
    create(:validation_submission, sha1: checksum, byte_size: payload.bytesize + 1, system: "c64")
    create(:release, sha1: checksum)
    expect(raw_upload(body: unread_body, token: token, length: "1")).to eq([ 403, { "error" => "invalid_admission" } ])
  end

  it "accepts the token only in the admission header, never a query string or cookie" do
    token = admission_for
    expect(rack_receipt(method: "PUT", path: "/v1/validations/#{checksum}/file.json?admission=#{token}", body: unread_body,
      headers: { "CONTENT_LENGTH" => payload.bytesize.to_s, "HTTP_COOKIE" => "admission=#{token}" })).to eq([ 403, { "error" => "invalid_admission" } ])
  end

  it "rejects secondary/shared release media across systems and rechecks an import after admission" do
    token = admission_for
    release = create(:release, system: "nes")
    medium = create(:media_file, sha1: checksum)
    create(:release_medium, release: release, media_file: medium, position: 2, key: "second")
    create(:release_medium, media_file: medium)
    expect(raw_upload(body: unread_body, token: token, length: "1")).to eq([ 409, { "error" => "known_release" } ])
    post "/v1/validations.json", params: { sha1: checksum, byte_size: payload.bytesize, system: "c64" }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(response.parsed_body).to eq("error" => "known_release")
  end

  it "returns fresh admissions for matching incomplete retries and preserves conflicting facts" do
    first = admission_for
    second = admission_for(sha1: checksum.upcase)
    expect(second).not_to eq(first)
    post "/v1/validations.json", params: { sha1: checksum, byte_size: payload.bytesize, system: "nes" }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(response.parsed_body).to eq("error" => "submission_conflict")
    expect(ValidationSubmission.sole).to have_attributes(sha1: checksum, system: "c64", completed_at: nil)
    expect(Dir.children(@receipt_folder)).to eq([ "#{checksum}.lock" ])
  end

  it "confirms completed retries without a body read or file rewrite, after all pre-body gates" do
    token = admission_for
    upload(admission: token)
    final = File.join(@receipt_folder, "#{checksum}.data")
    original = File.stat(final)
    expect(raw_upload(body: unread_body, token: token)).to eq([ 200, { "status" => "received" } ])
    expect(raw_upload(body: unread_body, token: token, length: "1")).to eq([ 422, { "error" => "size_mismatch" } ])
    expect(raw_upload(body: unread_body, token: "bad")).to eq([ 403, { "error" => "invalid_admission" } ])
    travel 11.minutes do
      expect(raw_upload(body: unread_body, token: token)).to eq([ 403, { "error" => "invalid_admission" } ])
    end
    expect(File.stat(final).ino).to eq(original.ino)
    expect(File.stat(final).mtime).to eq(original.mtime)
    expect(ValidationSubmission.count).to eq(1)
  end

  it "orders actual size before checksum mismatch and permits an intact retry" do
    token = admission_for
    expect(raw_upload(body: StringIO.new("short"), token: token)).to eq([ 422, { "error" => "size_mismatch" } ])
    expect(raw_upload(body: StringIO.new("x" * payload.bytesize), token: token)).to eq([ 422, { "error" => "checksum_mismatch" } ])
    expect(ValidationSubmission.sole.completed_at).to be_nil
    expect(Dir.glob(File.join(@receipt_folder, "*.{stage,data}"))).to be_empty
    upload(admission: token)
    expect(response.parsed_body).to eq("status" => "received")
  end

  it "interrupts a blocked application body read at the deadline and leaves a retryable submission" do
    token = admission_for
    stub_const("ValidationStorageService::READ_SECONDS", 0.02)
    body = double("slow body")
    allow(body).to receive(:read) { sleep 1; payload }
    expect(raw_upload(body: body, token: token)).to eq([ 408, { "error" => "upload_timeout" } ])
    expect(ValidationSubmission.sole.completed_at).to be_nil
    expect(Dir.glob(File.join(@receipt_folder, "*.{stage,data}"))).to be_empty
  end

  it "stops reading on the first byte beyond 128 MiB in chunks no larger than 64 KiB" do
    token = admission_for
    count = 0
    body = double("oversized body")
    allow(body).to receive(:read) do |length|
      expect(length).to be <= 65_536
      count += length
      "x" * length
    end
    expect(raw_upload(body: body, token: token)).to eq([ 413, { "error" => "file_too_large" } ])
    expect(count).to eq(134_217_729)
    expect(ValidationSubmission.sole.completed_at).to be_nil
    expect(Dir.glob(File.join(@receipt_folder, "*.{stage,data}"))).to be_empty
  end

  it "never confirms a completed submission with missing storage" do
    token = admission_for
    upload(admission: token)
    File.unlink(File.join(@receipt_folder, "#{checksum}.data"))
    expect(raw_upload(body: unread_body, token: token)).to eq([ 503, { "error" => "unavailable" } ])
    post "/v1/validations.json", params: { sha1: checksum, byte_size: payload.bytesize, system: "c64" }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(response.parsed_body).to eq("error" => "unavailable")
  end

  it "keeps the catalog, both seeds, lookups and verification untouched by receipt" do
    load Rails.root.join("db/seeds.rb")
    catalog = [ Game, Release, ReleaseMedium, MediaFile ].map { |model| model.order(:id).map(&:attributes) }
    upload(admission: admission_for)
    expect(response.parsed_body).to eq("status" => "received")
    expect([ Game, Release, ReleaseMedium, MediaFile ].map { |model| model.order(:id).map(&:attributes) }).to eq(catalog)
    expect(Game.where(public_id: %w[ucity tobu-tobu-girl]).count).to eq(2)
    get "/v1/lookup/#{checksum}.json"
    expect(response).to have_http_status(:not_found)
    get "/#{checksum}.data"
    expect(response).to have_http_status(:not_found)
  end
end
