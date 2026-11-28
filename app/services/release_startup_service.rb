require "digest"

class ReleaseStartupService
  SLOTS = { "c64" => %w[8 9] }.freeze

  def self.for_release(release:)
    effective(release: release).merge("revision" => revision(release: release))
  end

  def self.effective(release:, media: release.release_media)
    media = media.reject(&:marked_for_destruction?).sort_by(&:position)
    slots = SLOTS.fetch(release.system, [])
    boot = media.find { |medium| medium.role == "game" }&.key
    startup = release.startup || { "schema" => 1, "boot" => boot, "drives" => slots.empty? ? {} : { slots.first => boot } }
    { "schema" => startup.fetch("schema"), "boot" => startup.fetch("boot"), "drives" => startup.fetch("drives", {}).sort.to_h }
  end

  def self.revision(release:)
    canonical = { "startup" => effective(release: release), "media" => release.release_media.reject(&:marked_for_destruction?).sort_by(&:position).map { |medium| medium.media_file.sha1 } }
    Digest::SHA256.hexdigest(JSON.generate(canonical))
  end

  def self.errors(release:, media:)
    errors = []
    positions = media.map(&:position)
    errors << "media positions must be consecutive from 1" unless positions.all?(Integer) && positions.sort == (1..media.size).to_a
    errors << "media keys must be unique" unless media.map(&:key).uniq.size == media.size
    errors << "requires a game medium" unless media.any? { |medium| medium.role == "game" }
    return errors if release.startup.nil?

    startup = release.startup
    unless startup.is_a?(Hash) && (startup.keys - %w[schema boot drives]).empty? && startup["schema"].is_a?(Integer) && startup["schema"] == 1 && startup["boot"].is_a?(String) && startup.fetch("drives", {}).is_a?(Hash)
      return errors << "must use schema 1 with boot and optional drives"
    end

    drives = startup.fetch("drives", {})
    slots = SLOTS.fetch(release.system, [])
    errors << "unknown drive slot" unless (drives.keys - slots).empty?
    errors << "a medium can occupy only one drive" unless drives.values.uniq.size == drives.size
    keys = media.map(&:key)
    errors << "unknown medium key" unless ([ startup["boot"] ] + drives.values).all? { |key| key.is_a?(String) && keys.include?(key) }
    boot = media.find { |medium| medium.key == startup["boot"] }
    errors << "boot must be a game medium" unless boot&.role == "game"
    errors << "boot must occupy a drive" if slots.any? && !drives.value?(startup["boot"])
    errors
  end
end
