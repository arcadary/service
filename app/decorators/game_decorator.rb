class GameDecorator
  VERSION = 2

  def self.decorate(game)
    new(game)
  end

  def self.version
    [ VERSION, *ScreenshotDecorator.version ]
  end

  def initialize(game)
    @game = game
    @screenshot = game.selected_screenshot
  end

  def as_json(*)
    { id: @game.public_id, title: @game.title, screenshot: @screenshot && ScreenshotDecorator.decorate(@screenshot).as_json }
  end
end
