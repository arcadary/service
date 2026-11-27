require "rails_helper"
require "open3"

RSpec.describe "Production runtime signing" do
  around do |example|
    Dir.mktmpdir("production-smoke-", Rails.root.join("tmp")) do |folder|
      @folder = Pathname.new(folder)
      %w[app bin config data db lib Gemfile Gemfile.lock Rakefile config.ru].each do |entry|
        FileUtils.cp_r(Rails.root.join(entry), @folder.join(entry))
      end
      FileUtils.mkdir_p(@folder.join("tmp"))
      FileUtils.mkdir_p(@folder.join("storage"))
      FileUtils.mkdir_p(@folder.join("public"))
      @env = {
        "RAILS_ENV" => "production", "RACK_ENV" => "production", "BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s,
        "SECRET_KEY_BASE" => nil, "SECRET_KEY_BASE_DUMMY" => nil, "RAILS_MASTER_KEY" => nil,
        "VALIDATION_UPLOADS_ENABLED" => "false", "VALIDATION_REVIEWER_USERNAME" => nil, "VALIDATION_REVIEWER_PASSWORD" => nil,
        "BOOTSNAP_CACHE_DIR" => @folder.join("tmp/cache").to_s, "DATABASE_URL" => nil, "SOLID_QUEUE_IN_PUMA" => nil
      }
      File.write(@folder.join("server_probe.rb"), <<~RUBY)
        require "bundler/setup"
        require "rackup"
        require "rack/handler/puma"
        module Rackup::Handler::Puma
          def self.run(app, **options)
            puts "server initialized without listening"
          end
        end
      RUBY
      example.run
    end
  end

  def run_rails(*arguments, server: false)
    command = [ RbConfig.ruby ]
    command.concat([ "-r", @folder.join("server_probe.rb").to_s ]) if server
    command.concat([ "bin/rails", *arguments ])
    output, status = Open3.capture2e(@env, *command, chdir: @folder)
    [ output, status ]
  end

  def expect_runtime_rejection(*arguments, server: false)
    output, status = run_rails(*arguments, server: server)
    expect(status).not_to be_success, output
    expect(output).to include("Production runtime requires a nonblank environment SECRET_KEY_BASE")
  end

  it "rejects missing/blank ENV signer for server, entrypoint db:prepare and runner, even with uploads disabled" do
    expect_runtime_rejection("server", server: true)
    expect_runtime_rejection("db:prepare")
    @env["SECRET_KEY_BASE"] = " \t"
    expect_runtime_rejection("runner", "puts :booted")
  end

  it "rejects dummy-only runtime and a synthetic credentials-file signer" do
    @env["SECRET_KEY_BASE_DUMMY"] = "1"
    expect_runtime_rejection("runner", "puts :booted")
    @env["SECRET_KEY_BASE_DUMMY"] = nil
    key = "a" * 32
    @env["RAILS_MASTER_KEY"] = key
    file = ActiveSupport::EncryptedFile.new(content_path: @folder.join("config/credentials.yml.enc"), key_path: @folder.join("config/master.key"), env_key: "SYNTHETIC_CREDENTIALS_KEY", raise_if_missing_key: true)
    allow(file).to receive(:key).and_return(key)
    file.write({ "secret_key_base" => "synthetic-credentials-signer-" * 4 }.to_yaml)
    expect_runtime_rejection("runner", "puts :booted")
  end

  it "boots all three runtime commands with a synthetic ENV signer" do
    @env["SECRET_KEY_BASE"] = "synthetic-environment-signer-" * 4
    output, status = run_rails("db:prepare")
    expect(status).to be_success, output
    expect(@folder.join("storage/production.sqlite3")).to exist
    expect(@folder.join("storage/production_cache.sqlite3")).to exist
    expect(@folder.join("storage/production_queue.sqlite3")).to exist
    expect(@folder.join("storage/production_cable.sqlite3")).to exist
    @env["SECRET_KEY_BASE_DUMMY"] = "1"
    output, status = run_rails("runner", "abort unless Rails.application.initialized? && Rails.application.secret_key_base == ENV.fetch('SECRET_KEY_BASE'); puts :booted")
    expect(status).to be_success, output
    expect(output).to include("booted")
    output, status = run_rails("server", server: true)
    expect(status).to be_success, output
    expect(output).to include("server initialized without listening")
  end

  it "keeps dummy-secret asset precompilation working through initialization and eager loading" do
    @env["SECRET_KEY_BASE_DUMMY"] = "1"
    File.write(@folder.join("config/initializers/smoke_eager_load.rb"), "Rails.application.config.eager_load = true\n")
    output, status = run_rails("assets:precompile")
    expect(status).to be_success, output
    expect(@folder.join("public/assets/.manifest.json")).to exist
  end
end
