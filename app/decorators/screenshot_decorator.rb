class ScreenshotDecorator
  VERSION = 2

  def self.version
    [ VERSION, StorageConfigurationService.media_base_url ]
  end

  def self.decorate(screenshot)
    new(screenshot)
  end

  def initialize(screenshot)
    @screenshot = screenshot
  end

  def as_json(*)
    @screenshot.slice(:kind, :width, :height, :licence).merge(
      "url" => "#{StorageConfigurationService.media_base_url}/#{ScreenshotService.key(sha256: @screenshot.sha256)}"
    )
  end
end
