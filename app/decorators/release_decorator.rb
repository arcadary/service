class ReleaseDecorator
  VERSION = 5

  def self.decorate(release, sha1: release.sha1)
    new(release, sha1: sha1)
  end

  def self.version
    [ VERSION, *GameDecorator.version, *ReleaseMediumDecorator.version, *ScreenshotDecorator.version, *ReleaseControllerProfileDecorator.version, *CompatibilityResultDecorator.version ]
  end

  def initialize(release, sha1:)
    @release, @sha1 = release, sha1
    @startup = ReleaseStartupService.for_release(release: release)
    @compatibility = CompatibilityResultDecorator.current(CompatibilityService.current(release: release, startup_revision: @startup.fetch("revision")))
  end

  def as_json(*)
    {
      release: @release.slice(:system, :region, :revision).merge("id" => @release.public_id, "sha1" => @sha1,
        "screenshots" => @release.screenshots.sort_by { |screenshot| Screenshot::KINDS.index(screenshot.kind) }.map { |screenshot| ScreenshotDecorator.decorate(screenshot).as_json })
        .merge(@release.controller_profile ? { "controller_profile" => ReleaseControllerProfileDecorator.decorate(@release.controller_profile).as_json } : {})
        .merge("compatibility" => @compatibility),
      game: GameDecorator.decorate(@release.game).as_json,
      media: @release.release_media.map { |medium| ReleaseMediumDecorator.decorate(medium).as_json },
      startup: @startup
    }
  end
end
