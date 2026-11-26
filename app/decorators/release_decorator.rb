class ReleaseDecorator
  VERSION = 2

  def self.decorate(release, sha1: release.sha1)
    new(release, sha1: sha1)
  end

  def self.version
    [ VERSION, *GameDecorator.version, *ReleaseMediumDecorator.version ]
  end

  def initialize(release, sha1:)
    @release, @sha1 = release, sha1
    @startup = ReleaseStartupService.for_release(release: release)
  end

  def as_json(*)
    {
      release: @release.slice(:system, :region, :revision).merge("id" => @release.public_id, "sha1" => @sha1),
      game: GameDecorator.decorate(@release.game).as_json,
      media: @release.release_media.map { |medium| ReleaseMediumDecorator.decorate(medium).as_json },
      startup: @startup
    }
  end
end
