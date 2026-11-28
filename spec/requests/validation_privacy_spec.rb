require "rails_helper"
require_relative "../support/validation_helpers"

RSpec.describe "Validation receipt privacy", type: :request do
  include_context "private validation storage"

  it "silences successful writes and failures, including malformed paths, headers and raw bodies" do
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)
    logger.level = Logger::DEBUG
    Rails.logger.broadcast_to(logger)
    token = admission_for
    upload(admission: token)
    rack_receipt(method: "PUT", path: "//v1//validations//malformed-private-checksum//file.json", body: StringIO.new("private raw body"), headers: {
      "CONTENT_LENGTH" => "16", "REMOTE_ADDR" => "192.0.2.42", "HTTP_AUTHORIZATION" => "private credential", "HTTP_X_VALIDATION_ADMISSION" => "private token"
    })
    rack_receipt(method: "POST", path: "/v1/validations.json", body: StringIO.new("private malformed JSON"))
    @receipt_env["VALIDATION_UPLOADS_ENABLED"] = "false"
    rack_receipt(method: "POST", path: "/v1/validations/malformed", body: StringIO.new("private body"))
    expect(log.string).to be_empty
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  it "filters credentials, admission and raw-body fields defensively" do
    fields = { "sha1" => checksum, "Authorization" => "synthetic", "HTTP_X_VALIDATION_ADMISSION" => "synthetic", "admission" => "synthetic",
      "token" => "synthetic", "raw_post" => payload, "raw_body" => payload, "VALIDATION_REVIEWER_USERNAME" => "synthetic", "VALIDATION_REVIEWER_PASSWORD" => "synthetic" }
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(fields)
    expect(filtered.values.uniq).to eq([ "[FILTERED]" ])
    expect(ValidationSubmission.column_names).to match_array(%w[id sha1 byte_size system completed_at created_at updated_at])
  end
end
