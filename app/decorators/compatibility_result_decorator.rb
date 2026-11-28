class CompatibilityResultDecorator
  VERSION = 1
  UNKNOWN = { "status" => "unknown" }.freeze

  def self.version
    [ VERSION ]
  end

  def self.decorate(result)
    new(result)
  end

  def self.current(results)
    results.transform_values { |result| result && result.status != "unknown" ? decorate(result).as_json : UNKNOWN.dup }
  end

  def initialize(result)
    @result = result
  end

  def as_json(*)
    @result.slice(:status, :core, :core_version, :startup_revision, :reason, :observed, :limits, :requires_input).merge("tested_at" => @result.tested_at.utc.iso8601)
  end

  def history_json
    @result.slice(:id, :device, :status, :sha1, :core, :core_version, :startup_revision, :reason, :observed, :limits, :requires_input, :reviewer)
      .merge("playthrough_ids" => @result.playthroughs.map(&:public_id),
        "tested_at" => @result.tested_at.utc.iso8601, "recorded_at" => @result.created_at.utc.iso8601(6))
  end
end
