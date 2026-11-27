class MediaDecorator
  VERSION = 1

  def self.version
    [ VERSION, *ReleaseDecorator.version ]
  end

  def self.decorate(releases, sha1:)
    new(releases, sha1: sha1)
  end

  def initialize(releases, sha1:)
    @releases, @sha1 = releases, sha1
  end

  def as_json(*)
    { releases: @releases.map { |release| ReleaseDecorator.decorate(release, sha1: @sha1).as_json } }
  end
end
