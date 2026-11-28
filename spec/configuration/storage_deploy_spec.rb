require "rails_helper"
require "kamal"

RSpec.describe "Storage container configuration" do
  let(:fake_environment) do
    { "DEPLOY_HOST" => "192.0.2.1", "SECRET_KEY_BASE" => "test-rails-key", "TUNNEL_TOKEN" => "test-tunnel-token" }
  end

  before { stub_const("ENV", fake_environment) }

  def configuration
    Kamal::Configuration.create_from(config_file: Rails.root.join("config/deploy.yml"), version: "test")
  end

  it "resolves valid Kamal declarations and values without any R2 configuration" do
    config = configuration
    expect(config.env.secret_keys).to eq([ "SECRET_KEY_BASE", "VALIDATION_REVIEWER_USERNAME", "VALIDATION_REVIEWER_PASSWORD" ])
    expect(config.env.to_h).to eq(
      "SECRET_KEY_BASE" => "test-rails-key", "VALIDATION_REVIEWER_USERNAME" => "", "VALIDATION_REVIEWER_PASSWORD" => "",
      "CATALOG_ADMIN_NAME" => "Admin", "SOLID_QUEUE_IN_PUMA" => true
    )
  end

  it "passes the media bucket's configuration to the app container and keeps uploads off the database volume" do
    r2_values = {
      "R2_PUBLIC_BUCKET" => "test-media", "R2_ENDPOINT" => "https://r2.example", "R2_ACCESS_KEY_ID" => "test-key", "R2_SECRET_ACCESS_KEY" => "test-secret"
    }
    fake_environment.merge!(r2_values)
    config = configuration
    expect(config.env.secret_keys).to eq([ "SECRET_KEY_BASE", "VALIDATION_REVIEWER_USERNAME", "VALIDATION_REVIEWER_PASSWORD", *r2_values.keys ])
    expect(config.env.to_h).to include(r2_values)
    expect(config.volume_args).to include("--volume", "/mnt/storage/arcadary_service:/rails/storage", "arcadary_service_uploads:/rails/uploads")
    storage = YAML.safe_load(ERB.new(Rails.root.join("config/storage.yml").read).result)
    expect(storage.keys).to contain_exactly("test_media", "local_media", "r2_media")
    expect(storage.fetch("r2_media")).to include("bucket" => "test-media", "upload" => { "cache_control" => "public, max-age=31536000, immutable" })
  end

  it "omits empty optional secrets from both declarations and container values" do
    fake_environment.merge!("R2_PUBLIC_BUCKET" => "test-media", "R2_ACCESS_KEY_ID" => "")
    config = configuration
    expect(config.env.secret_keys).to eq([ "SECRET_KEY_BASE", "VALIDATION_REVIEWER_USERNAME", "VALIDATION_REVIEWER_PASSWORD", "R2_PUBLIC_BUCKET" ])
    expect(config.env.to_h).not_to have_key("R2_ACCESS_KEY_ID")
  end
end
