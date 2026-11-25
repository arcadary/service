# The public JSON shape of a release and its game.
class ReleaseDecorator
  # Part of the lookup's ETag. Bump it with every change to the JSON below, so
  # clients holding the old shape get the new one instead of a 304.
  VERSION = 1

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
