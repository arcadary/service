class PrivateServiceAuthenticationService
  class ConfigurationMissing < StandardError; end
  class InvalidCredentials < StandardError; end

  def self.authenticate!(username:, password:)
    configured_username = ENV["VALIDATION_REVIEWER_USERNAME"]
    configured_password = ENV["VALIDATION_REVIEWER_PASSWORD"]
    raise ConfigurationMissing if configured_username.blank? || configured_password.blank?

    username_matches = ActiveSupport::SecurityUtils.fixed_length_secure_compare(
      Digest::SHA256.digest(username.to_s), Digest::SHA256.digest(configured_username))
    password_matches = ActiveSupport::SecurityUtils.fixed_length_secure_compare(
      Digest::SHA256.digest(password.to_s), Digest::SHA256.digest(configured_password))
    raise InvalidCredentials unless username_matches & password_matches

    true
  end
end
