class GameDecorator
  VERSION = 1

  def self.decorate(game)
    new(game)
  end

  def self.version
    [ VERSION ]
  end

  def initialize(game)
    @game = game
  end

  def as_json(*)
    { id: @game.public_id, title: @game.title }
  end
end
