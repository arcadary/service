class ReleaseService
  SHA1 = /\A[0-9a-fA-F]{40}\z/

  def self.find_by(sha1:)
    releases = containing(sha1: sha1)
    raise Release::AmbiguousRelease if releases.size > 1

    releases.first
  end

  def self.find(public_id:, includes: [])
    release = Release.includes(includes).find_by(public_id: public_id)
    raise Release::ReleaseNotFound unless release

    release
  end

  def self.containing(sha1:)
    checksum = normalize(sha1)
    ids = ReleaseMedium.joins(:media_file).where(media_files: { sha1: checksum }).distinct.pluck(:release_id)
    raise Release::ReleaseNotFound if ids.empty?

    releases = Release.where(id: ids).includes(:screenshots, :compatibility_verdicts, { game: { releases: :screenshots } }, release_media: :media_file).order(:public_id).to_a
    releases.each { |release| release.game.selected_screenshot = ScreenshotService.selected_for(game: release.game) }
    releases
  end

  def self.resource_for(sha1:)
    checksum = normalize(sha1)
    ids = ReleaseMedium.joins(:media_file).where(media_files: { sha1: checksum }).distinct.limit(2).pluck(:release_id)
    raise Release::ReleaseNotFound if ids.empty?

    { sha1: checksum, resource: ids.size == 1 ? :release : :media }
  end

  def self.synchronize_checksum(release_id:)
    release = Release.includes(release_media: :media_file).find(release_id)
    checksum = release.release_media.first&.media_file&.sha1
    release.update!(sha1: checksum) if checksum && checksum != release.sha1
  end

  def self.normalize(sha1)
    sha1 = sha1.to_s
    raise Release::InvalidSha1 unless SHA1.match?(sha1)

    sha1.downcase
  end
  private_class_method :normalize
end
