module ValidationHelpers
  def configure_receipts
    @receipt_env = {
      "VALIDATION_REVIEWER_USERNAME" => "synthetic-reviewer",
      "VALIDATION_REVIEWER_PASSWORD" => "synthetic-password",
      "VALIDATION_STORAGE_PATH" => @receipt_folder
    }
    @receipt_configuration = ValidationConfigurationService.new(env: @receipt_env)
    allow(ValidationConfigurationService).to receive(:new).and_return(@receipt_configuration)
  end

  def admission_for(sha1: checksum, byte_size: payload.bytesize, system: "c64")
    post "/v1/validations.json", params: { sha1: sha1, byte_size: byte_size, system: system }.to_json, headers: { "CONTENT_TYPE" => "application/json" }
    expect(response).to have_http_status(:created)
    response.parsed_body.fetch("admission")
  end

  def upload(admission:, body: payload, sha1: checksum, length: body.bytesize)
    put "/v1/validations/#{sha1}/file.json", params: body, headers: {
      "CONTENT_TYPE" => "application/octet-stream", "CONTENT_LENGTH" => length.to_s, "X-Validation-Admission" => admission
    }
  end

  def rack_receipt(method:, path: "/v1/validations.json", body:, headers: {})
    env = Rack::MockRequest.env_for("http://example.org#{path}", method: method)
    env.delete("CONTENT_LENGTH")
    env.merge!("rack.input" => body, "CONTENT_TYPE" => method == "POST" ? "application/json" : "application/octet-stream")
    env.merge!(headers)
    status, response_headers, response_body = Rails.application.call(env)
    json = response_body.each.to_a.join
    response_body.close if response_body.respond_to?(:close)
    expect(response_headers["cache-control"]).to eq("no-store")
    expect(response_headers["set-cookie"]).to be_nil
    [ status, JSON.parse(json) ]
  end
end

RSpec.shared_context "private validation storage" do
  include ValidationHelpers

  let(:payload) { "unknown game bytes\x00\xff".b }
  let(:checksum) { Digest::SHA1.hexdigest(payload) }

  around do |example|
    Dir.mktmpdir("validation-spec-", Rails.root.join("tmp")) do |folder|
      @receipt_folder = folder
      example.run
    end
  end

  before { configure_receipts }
end
