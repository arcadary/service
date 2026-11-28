class CompatibilityVerdictDecorator
  VERSION = 1

  def self.version
    [ VERSION ]
  end

  def self.decorate(verdict)
    new(verdict)
  end

  def self.current(release:)
    CompatibilityService.current(release: release).map { |verdict| decorate(verdict).as_json }
  end

  def initialize(verdict)
    @verdict = verdict
  end

  def as_json(*)
    @verdict.slice(:id, :device_class, :core, :core_version, :startup_revision, :state, :evidence, :limitations)
      .merge("tested_at" => @verdict.tested_at.utc.iso8601)
  end

  def as_record
    as_json.merge(@verdict.slice(:reviewer, :reason)).merge(
      "playthrough_ids" => @verdict.playthroughs.map(&:public_id), "recorded_at" => @verdict.created_at.utc.iso8601
    )
  end
end
