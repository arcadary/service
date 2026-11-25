require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module ArcadaryService
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Anonymous checksum reads still reveal the file and caller IP to the service
    # and CDN. Silence Rails request-start, parameters, controller and SQL logs
    # before they can associate the URL with a household (including caller headers).
    # Match repeated slashes too: routing squeezes them after this middleware runs.
    # Thruster logging is disabled in Dockerfile. External CDN and deployment-proxy
    # logging, including kamal-proxy, remains unverified until deployment; local log
    # checks do not cover it. See README.md, "Privacy and logging".
    config.middleware.insert_before Rails::Rack::Logger, Rails::Rack::SilenceRequest,
      path: %r{\A/+v1/+releases/+sha1/+}

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
