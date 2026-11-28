require "rails_helper"
require "puma"
require "puma/configuration"
require "kamal"
require "erb"
require "yaml"
require "shellwords"

RSpec.describe "Shipped upload transport settings" do
  it "evaluates the Puma configuration with the 128 MiB body ceiling" do
    configuration = Puma::Configuration.new(config_files: [ Rails.root.join("config/puma.rb").to_s ])
    configuration.load
    configuration.clamp
    expect(configuration.options[:http_content_length_limit]).to eq(134_217_728)
  end

  it "ships bounded Thruster network reads/writes and disabled access logging in the image" do
    dockerfile = Rails.root.join("Dockerfile").read.gsub(/\\\n\s*/, " ")
    settings = dockerfile.scan(/^ENV (.+)$/).flat_map { |line| Shellwords.split(line.first) }.to_h { |entry| entry.split("=", 2) }
    expect(settings).to include("MAX_REQUEST_BODY" => "134217728", "HTTP_READ_TIMEOUT" => "120", "HTTP_WRITE_TIMEOUT" => "150", "LOG_REQUESTS" => "false")
  end

  it "evaluates Kamal's proxy flags with matching buffering, time budget and existing isolation protections" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("DEPLOY_HOST").and_return("synthetic-origin.invalid")
    raw = YAML.safe_load(ERB.new(Rails.root.join("config/deploy.yml").read).result, aliases: true)
    configuration = Kamal::Configuration.new(raw.symbolize_keys, version: "synthetic")
    expect(configuration.proxy.deploy_options).to include(
      "target-timeout": "300s", "buffer-requests": true, "buffer-responses": true,
      "max-request-body": 134_217_728, "buffer-memory": 1_048_576, "max-response-body": 0, "forward-headers": false
    )
    expect(configuration.proxy.run.version).to eq("v0.9.2")
    expect(raw.dig("proxy", "run", "options", "log-driver")).to eq("none")
    expect(raw.dig("proxy", "run", "publish")).to be(false)
    expect(raw.fetch("volumes")).to eq([ "/mnt/storage/arcadary_service:/rails/storage" ])
    expect(raw.dig("env", "clear")).not_to have_key("VALIDATION_UPLOADS_ENABLED")
    expect(raw.dig("env", "secret")).to include("SECRET_KEY_BASE", "VALIDATION_REVIEWER_USERNAME", "VALIDATION_REVIEWER_PASSWORD")
    expect(raw.dig("accessories", "cloudflared", "image")).to eq("cloudflare/cloudflared:2026.11.2")
  end
end
