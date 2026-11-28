class CompatibilityService
  FIELDS = %w[release_id sha1 device status core core_version startup_revision tested_at observed limits reviewer owns_file retry_key].freeze
  OPTIONAL = %w[requires_input reason playthrough_ids].freeze
  LISTS = %w[requires_input playthrough_ids].freeze
  REFERENCES = %w[release_id playthrough_ids].freeze
  ZONED = /(?:Z|[+-]\d{2}:\d{2})\z/
  PRINTABLE = /\A[^\p{Cc}]*\z/

  def self.record(**arguments)
    attributes = normalize(arguments: arguments.stringify_keys)
    fingerprint_attributes = attributes.fetch("playthrough_ids").empty? ? attributes.except("playthrough_ids") : attributes
    fingerprint = Digest::SHA256.hexdigest(JSON.generate(fingerprint_attributes.sort.to_h))
    CompatibilityResult.transaction do
      existing = CompatibilityResult.find_by(retry_key: attributes.fetch("retry_key"))
      next replay(result: existing, fingerprint: fingerprint) if existing

      release = ReleaseService.find(public_id: attributes.fetch("release_id"), includes: { release_media: :media_file })
      raise CompatibilityResult::TargetMismatch unless release.release_media.any? { |medium| medium.media_file.sha1 == attributes.fetch("sha1") }
      raise CompatibilityResult::TargetMismatch unless ReleaseStartupService.revision(release: release) == attributes.fetch("startup_revision")

      playthroughs = release.playthroughs.where(public_id: attributes.fetch("playthrough_ids")).to_a
      raise CompatibilityResult::TargetMismatch unless playthroughs.size == attributes.fetch("playthrough_ids").size

      release.compatibility_results.create!(attributes.except(*REFERENCES).merge("fingerprint" => fingerprint, "playthroughs" => playthroughs))
    end
  rescue ActiveRecord::RecordNotUnique
    replay(result: CompatibilityResult.find_by!(retry_key: attributes.fetch("retry_key")), fingerprint: fingerprint)
  end

  def self.find_release(release_id:)
    ReleaseService.find(public_id: release_id, includes: [ :compatibility_results, { release_media: :media_file } ])
  end

  def self.current(release:, startup_revision: ReleaseStartupService.revision(release: release))
    applying = release.compatibility_results.select { |result| result.startup_revision == startup_revision }
    CompatibilityResult::DEVICES.index_with do |device|
      applying.select { |result| result.device == device }.max_by(&:id)
    end
  end

  def self.normalize(arguments:)
    raise CompatibilityResult::InvalidInput unless (arguments.keys - OPTIONAL).sort == FIELDS.sort
    raise CompatibilityResult::InvalidInput unless arguments.fetch("owns_file") == true

    lists = LISTS.to_h { |name| [ name, arguments.fetch(name, []) ] }
    raise CompatibilityResult::InvalidInput unless lists.values.all? { |list| list.is_a?(Array) && list.all?(String) && list.uniq.size == list.size }

    text = arguments.except("owns_file", *LISTS)
    raise CompatibilityResult::InvalidInput unless text.values.all? { |value| value.is_a?(String) && value.strip.present? && PRINTABLE.match?(value) }

    attributes = text.merge(lists.transform_values(&:sort), "sha1" => text.fetch("sha1").downcase, "tested_at" => timestamp(value: text.fetch("tested_at")))
    result = CompatibilityResult.new(attributes.except(*REFERENCES))
    result.fingerprint = "pending"
    result.validate
    raise CompatibilityResult::InvalidInput unless (result.errors.attribute_names - [ :release ]).empty?
    raise CompatibilityResult::InvalidInput unless attributes.fetch("release_id").length <= 200 && attributes.fetch("retry_key").length <= 200

    attributes
  end
  private_class_method :normalize

  def self.timestamp(value:)
    raise CompatibilityResult::InvalidInput unless value.length <= 64 && ZONED.match?(value)

    time = Time.iso8601(value).utc
    raise CompatibilityResult::InvalidInput if time > Time.current

    time.iso8601(6)
  rescue ArgumentError
    raise CompatibilityResult::InvalidInput
  end
  private_class_method :timestamp

  def self.replay(result:, fingerprint:)
    raise CompatibilityResult::RetryConflict unless result.fingerprint == fingerprint

    result
  end
  private_class_method :replay
end
