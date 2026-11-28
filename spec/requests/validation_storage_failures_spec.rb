require "rails_helper"
require_relative "../support/validation_helpers"

RSpec.describe "Validation storage failures", type: :request do
  include_context "private validation storage"

  it "keeps an incomplete upload retryable after a failed final rename" do
    token = admission_for
    staging = Pathname.new(@receipt_folder).join("#{checksum}.stage")
    final = Pathname.new(@receipt_folder).join("#{checksum}.data")
    allow(File).to receive(:rename).and_call_original
    allow(File).to receive(:rename).with(staging, final).and_raise(Errno::ENOSPC)
    upload(admission: token)
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq("error" => "unavailable")
    expect(ValidationSubmission.sole.completed_at).to be_nil
    expect(staging).not_to exist
    expect(final).not_to exist
    allow(File).to receive(:rename).with(staging, final).and_call_original
    upload(admission: token)
    expect(response.parsed_body).to eq("status" => "received")
  end

  it "does not falsely complete on a database failure after file publication" do
    token = admission_for
    allow_any_instance_of(ValidationSubmission).to receive(:update!).and_raise(ActiveRecord::StatementInvalid)
    upload(admission: token)
    expect(response.parsed_body).to eq("error" => "unavailable")
    expect(ValidationSubmission.sole.completed_at).to be_nil
    expect(File.binread(File.join(@receipt_folder, "#{checksum}.data"))).to eq(payload)
    allow_any_instance_of(ValidationSubmission).to receive(:update!).and_call_original
    fresh = admission_for
    upload(admission: fresh)
    expect(response.parsed_body).to eq("status" => "received")
    expect(ValidationSubmission.count).to eq(1)
  end

  it "rejects storage probe failures before admission changes or body reading" do
    allow(Tempfile).to receive(:create).and_raise(Errno::EACCES)
    body = double("unread body")
    expect(body).not_to receive(:read)
    expect(rack_receipt(method: "POST", body: body)).to eq([ 503, { "error" => "unavailable" } ])
    expect(ValidationSubmission.count).to eq(0)
  end

  it "leaves a previously complete file intact when a retry fails its gates or storage probe" do
    token = admission_for
    upload(admission: token)
    file = File.join(@receipt_folder, "#{checksum}.data")
    original = File.stat(file)
    upload(admission: token, length: payload.bytesize + 1)
    expect(response.parsed_body).to eq("error" => "size_mismatch")
    allow(Tempfile).to receive(:create).and_raise(Errno::ENOSPC)
    upload(admission: token)
    expect(response.parsed_body).to eq("error" => "unavailable")
    expect(File.binread(file)).to eq(payload)
    expect(File.stat(file).ino).to eq(original.ino)
    expect(ValidationSubmission.sole.completed_at).to be_present
  end
end
