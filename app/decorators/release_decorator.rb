class ReleaseDecorator
  VERSION = 1

  def self.decorate(release)
    new(release)
  end

  def self.version
    [ VERSION, *GameDecorator.version ]
  end

  def initialize(release)
    @release = release
  end

  def as_json(*)
    {
      release: @release.slice(:sha1, :system, :region, :revision),
      game: GameDecorator.decorate(@release.game).as_json
    }
  end
end
