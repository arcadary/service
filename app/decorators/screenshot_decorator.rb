class ScreenshotDecorator
  VERSION = 1

  def self.version
    [ VERSION, ScreenshotConfigurationService.public_base_url ]
  end

  def self.decorate(screenshot)
    new(screenshot)
  end

  def initialize(screenshot)
    @screenshot = screenshot
  end

  def as_json(*)
    @screenshot.slice(:kind, :width, :height, :licence).merge(
      "url" => "#{ScreenshotConfigurationService.public_base_url}/v1/screenshots/#{@screenshot.sha256}.png"
    )
  end
end
