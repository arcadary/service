require "rails_helper"
require "kamal"

RSpec.describe "Screenshot container configuration" do
  let(:fake_environment) do
    { "DEPLOY_HOST" => "192.0.2.1", "SECRET_KEY_BASE" => "test-rails-key", "TUNNEL_TOKEN" => "test-tunnel-token" }
  end

  before { stub_const("ENV", fake_environment) }

  def configuration
    Kamal::Configuration.create_from(config_file: Rails.root.join("config/deploy.yml"), version: "test")
  end

  it "resolves valid Kamal declarations and values without any screenshot configuration" do
    config = configuration
    expect(config.env.secret_keys).to eq([ "SECRET_KEY_BASE" ])
    expect(config.env.to_h).to eq(
      "SECRET_KEY_BASE" => "test-rails-key", "SCREENSHOT_PUBLIC_BASE_URL" => "", "SOLID_QUEUE_IN_PUMA" => true
    )
  end

  it "passes configured secrets and a clear public origin to the app container" do
    screenshot_values = {
      "R2_BUCKET" => "test-bucket", "R2_ENDPOINT" => "https://r2.example", "R2_ACCESS_KEY_ID" => "test-key",
      "R2_SECRET_ACCESS_KEY" => "test-secret", "SCREENSHOT_CAPTURE_TOKEN" => "test-capture",
      "SCREENSHOT_PUBLIC_BASE_URL" => "https://images.example"
    }
    fake_environment.merge!(screenshot_values)
    config = configuration
    expect(config.env.secret_keys).to eq([ "SECRET_KEY_BASE", "R2_BUCKET", "R2_ENDPOINT", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "SCREENSHOT_CAPTURE_TOKEN" ])
    expect(config.env.to_h).to include(screenshot_values)
    storage = YAML.safe_load(ERB.new(Rails.root.join("config/storage.yml").read).result).fetch("r2")
    expect(storage).to include("service" => "S3", "region" => "auto", "bucket" => "test-bucket", "public" => false)
  end

  it "omits empty optional secrets from both declarations and container values" do
    fake_environment.merge!("R2_BUCKET" => "test-bucket", "R2_ACCESS_KEY_ID" => "", "SCREENSHOT_CAPTURE_TOKEN" => "")
    config = configuration
    expect(config.env.secret_keys).to eq([ "SECRET_KEY_BASE", "R2_BUCKET" ])
    expect(config.env.to_h).not_to have_key("R2_ACCESS_KEY_ID")
    expect(config.env.to_h).not_to have_key("SCREENSHOT_CAPTURE_TOKEN")
  end
end
