require "rails_helper"
require_relative "../support/validation_helpers"

RSpec.describe ValidationConfigurationService, type: :request do
  include ValidationHelpers

  let(:payload) { "synthetic production upload" }
  let(:checksum) { Digest::SHA1.hexdigest(payload) }
  let(:credentials) { { "VALIDATION_REVIEWER_USERNAME" => "synthetic-reviewer", "VALIDATION_REVIEWER_PASSWORD" => "synthetic-password" } }

  around do |example|
    Dir.mktmpdir("validation-config-", Rails.root.join("tmp")) do |folder|
      @root = Pathname.new(folder).join("rails")
      FileUtils.mkdir_p(@root.join("storage"))
      FileUtils.mkdir_p(@root.join("public"))
      example.run
    end
  end

  def configuration(env: credentials, environment: "production")
    described_class.new(env: env, environment: environment, root: @root)
  end

  def production_env
    credentials.merge("VALIDATION_UPLOADS_ENABLED" => "true", "VALIDATION_STORAGE_PATH" => @root.join("storage/validations").to_s)
  end

  it "defaults development/test to enabled with distinct private storage, and production to disabled" do
    expect(configuration(environment: "development").check!.storage_path).to eq(@root.join("storage/validations"))
    expect(configuration(environment: "test").check!.storage_path).to eq(@root.join("tmp/validations-#{Process.pid}"))
    expect { configuration.check! }.to raise_error(ValidationSubmission::Unavailable)
  end

  it "accepts only literal true, and requires each reviewer credential with no default" do
    [ "TRUE", "1", "", "false" ].each do |enabled|
      expect { configuration(env: production_env.merge("VALIDATION_UPLOADS_ENABLED" => enabled)).check! }.to raise_error(ValidationSubmission::Unavailable)
    end
    %w[VALIDATION_REVIEWER_USERNAME VALIDATION_REVIEWER_PASSWORD].each do |key|
      expect { configuration(env: production_env.except(key)).check! }.to raise_error(ValidationSubmission::Unavailable)
      expect { configuration(env: production_env.merge(key => " \t")).check! }.to raise_error(ValidationSubmission::Unavailable)
    end
  end

  it "requires an absolute private production path below the existing persistent volume" do
    [ nil, "", "storage/validations", @root.join("public/validations").to_s, @root.join("storage").to_s,
      @root.join("storage/../../outside").to_s ].each do |path|
      expect { configuration(env: production_env.merge("VALIDATION_STORAGE_PATH" => path)).check! }.to raise_error(ValidationSubmission::Unavailable)
    end
    File.symlink(@root.join("public"), @root.join("storage/escape"))
    expect { configuration(env: production_env.merge("VALIDATION_STORAGE_PATH" => @root.join("storage/escape/validations").to_s)).check! }.to raise_error(ValidationSubmission::Unavailable)
    expect(@root.join("public/validations")).not_to exist
  end

  it "fails closed for an unusable storage path" do
    File.write(@root.join("storage/validations"), "not a directory")
    expect { configuration(env: production_env).check! }.to raise_error(ValidationSubmission::Unavailable)
  end

  it "admits and receives using production inputs and an isolated /rails/storage/validations layout" do
    configured = configuration(env: production_env)
    allow(described_class).to receive(:new).and_return(configured)
    upload(admission: admission_for)
    expect(response.parsed_body).to eq("status" => "received")
    folder = @root.join("storage/validations")
    expect(folder.stat.mode & 0o777).to eq(0o700)
    expect(folder.join("#{checksum}.data").stat.mode & 0o777).to eq(0o600)
    expect(folder.join("#{checksum}.data").binread).to eq(payload)
    expect(@root.join("public").children).to be_empty
  end
end
