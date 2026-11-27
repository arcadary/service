class ScreenshotConfigurationService
  R2_VARIABLES = %w[R2_BUCKET R2_ENDPOINT R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY].freeze

  def self.r2_configured?
    R2_VARIABLES.all? { |name| ENV[name].present? }
  end

  def self.public_base_url
    ENV.fetch("SCREENSHOT_PUBLIC_BASE_URL", "")
  end

  def self.valid_public_base_url?
    uri = URI.parse(public_base_url)
    uri.is_a?(URI::HTTPS) && uri.host.present? && uri.path.empty? && !uri.userinfo && !uri.query && !uri.fragment
  rescue URI::InvalidURIError
    false
  end

  def self.authenticate!(authorization:)
    token = ENV["SCREENSHOT_CAPTURE_TOKEN"]
    unless token.present? && valid_public_base_url? && (!Rails.env.production? || r2_configured?)
      raise Screenshot::UploadsDisabled
    end
    unless ActiveSupport::SecurityUtils.secure_compare(authorization.to_s, "Bearer #{token}")
      raise Screenshot::Unauthorized
    end
  end
end
