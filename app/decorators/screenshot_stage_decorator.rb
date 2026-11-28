class ScreenshotStageDecorator
  VERSION = 1

  def self.version
    [ VERSION ]
  end

  def self.decorate(stage)
    new(stage)
  end

  def initialize(stage)
    @stage = stage
  end

  def as_json(*)
    { staging_id: @stage.public_id, expires_at: @stage.expires_at.iso8601(6) }
  end
end
