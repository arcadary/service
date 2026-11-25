# The public JSON shape of a release and its game.
class ReleaseDecorator
  def self.decorate(release)
    new(release)
  end

  def initialize(release)
    @release = release
  end

  def as_json(*)
    {
      release: @release.slice(:sha1, :system, :region, :revision),
      game: { id: @release.game.public_id, title: @release.game.title }
    }
  end
end
