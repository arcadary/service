class CompatibilityService
  def self.record(release_id:, device_class:, core:, core_version:, state:, tested_at:, reason:, evidence: nil, limitations: nil,
    attested: false, playthrough_ids: [])
    release = ReleaseService.find(public_id: release_id, includes: { release_media: :media_file })
    playthroughs = release.playthroughs.where(public_id: playthrough_ids).to_a
    raise CompatibilityVerdict::InvalidInput unless playthroughs.size == playthrough_ids.size

    release.compatibility_verdicts.create!(device_class: device_class, core: core, core_version: core_version,
      startup_revision: ReleaseStartupService.revision(release: release), state: state, tested_at: time(tested_at),
      evidence: evidence, limitations: limitations, attested: attested, reason: reason,
      reviewer: CatalogAuthoringService.admin_name, playthroughs: playthroughs)
  rescue ActiveRecord::RecordInvalid
    raise CompatibilityVerdict::InvalidInput
  end

  def self.current(release:)
    release.compatibility_verdicts.group_by(&:environment).map { |_environment, verdicts| verdicts.last }.reject(&:unknown?)
  end

  def self.time(value)
    Time.iso8601(value)
  rescue ArgumentError
    raise CompatibilityVerdict::InvalidInput
  end
  private_class_method :time
end
