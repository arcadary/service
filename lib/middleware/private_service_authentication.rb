require "base64"

class PrivateServiceAuthentication
  def initialize(app, paths:)
    @app = app
    @paths = paths
  end

  def call(env)
    path = env.fetch("PATH_INFO").gsub(%r{/+}, "/")
    return @app.call(env) unless @paths.call.any? { |pattern| pattern === path }

    Rails.logger.silence(Logger::UNKNOWN) do
      authenticate(env)
    end
  end

  private
    def authenticate(env)
      username, password = credentials(env["HTTP_AUTHORIZATION"])
      PrivateServiceAuthenticationService.authenticate!(username: username, password: password)
      env["action_dispatch.show_detailed_exceptions"] = false
      status, headers, body = @app.call(env)
      [ status, headers.merge("cache-control" => "no-store"), body ]
    rescue PrivateServiceAuthenticationService::ConfigurationMissing
      error("authentication_unavailable", status: 503)
    rescue PrivateServiceAuthenticationService::InvalidCredentials
      error("unauthorized", status: 401, headers: { "www-authenticate" => 'Basic realm="Arcadary", charset="UTF-8"' })
    end

    def credentials(authorization)
      scheme, encoded = authorization.to_s.split(" ", 2)
      return unless scheme&.casecmp?("Basic") && encoded

      Base64.strict_decode64(encoded).split(":", 2)
    rescue ArgumentError
      nil
    end

    def error(code, status:, headers: {})
      [ status, headers.merge("content-type" => "application/json", "cache-control" => "no-store"), [ { error: code }.to_json ] ]
    end
end
