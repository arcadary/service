class ScreenshotStageDecorator
  def self.decorate(stage)
    { staging_id: stage.public_id, expires_at: stage.expires_at.iso8601(6) }
  end
end
