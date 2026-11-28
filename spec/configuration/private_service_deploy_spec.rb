require "rails_helper"
require "kamal"

RSpec.describe "Private service login container configuration" do
  let(:fake_environment) do
    { "DEPLOY_HOST" => "192.0.2.1", "SECRET_KEY_BASE" => "test-rails-key", "TUNNEL_TOKEN" => "test-tunnel-token",
      "VALIDATION_REVIEWER_USERNAME" => "test-admin", "VALIDATION_REVIEWER_PASSWORD" => "test-password" }
  end

  before { stub_const("ENV", fake_environment) }

  it "passes the shared admin login from fnox's environment to the app container" do
    config = Kamal::Configuration.create_from(config_file: Rails.root.join("config/deploy.yml"), version: "test")
    expect(config.env.to_h).to include(
      "VALIDATION_REVIEWER_USERNAME" => "test-admin", "VALIDATION_REVIEWER_PASSWORD" => "test-password"
    )
  end
end
