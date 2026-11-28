class PlaythroughDeclarationService
  SHA1 = /\A[0-9a-f]{40}\z/
  SHA256 = /\A[0-9a-f]{64}\z/
  CONTENT_TYPE = %r{\A[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+\z}

  def self.normalize(declaration:, verifier:)
    raise PlaythroughStage::TooLarge if JSON.generate(declaration).bytesize > PlaythroughStageInputService::DECLARATION_BYTES

    input = canonical(value: declaration.deep_stringify_keys)
    exact_keys!(input, required: %w[retry_key release_id source_sha1 capture manifest], optional: %w[verification])
    text!(input["retry_key"], maximum: 200)
    text!(input["release_id"], maximum: 200)
    checksum!(input["source_sha1"], pattern: SHA1)
    capture = input.fetch("capture")
    exact_keys!(capture, required: %w[tool version captured_at])
    text!(capture["tool"], maximum: 200)
    text!(capture["version"], maximum: 200)
    capture["captured_at"] = timestamp!(capture["captured_at"])
    input["manifest"] = manifest!(input.fetch("manifest"))
    input["verification"] = verification!(input.fetch("verification"), source_sha1: input.fetch("source_sha1"), verifier: verifier) if input.key?("verification")
    input
  rescue JSON::GeneratorError, ArgumentError, EncodingError
    raise PlaythroughStage::InvalidDeclaration
  end

  def self.exact_keys!(value, required:, optional: [])
    unless value.is_a?(Hash) && (required - value.keys).empty? && (value.keys - required - optional).empty?
      raise PlaythroughStage::InvalidDeclaration
    end
  end

  def self.text!(value, maximum:)
    raise PlaythroughStage::InvalidDeclaration unless value.is_a?(String) && value.present? && value.length <= maximum
  end

  def self.checksum!(value, pattern:)
    raise PlaythroughStage::InvalidDeclaration unless value.is_a?(String) && pattern.match?(value)
  end

  def self.timestamp!(value)
    text!(value, maximum: 64)
    raise PlaythroughStage::InvalidDeclaration unless /(?:Z|[+-]\d{2}:\d{2})\z/.match?(value)

    Time.iso8601(value).utc.iso8601(6)
  end

  def self.manifest!(entries)
    raise PlaythroughStage::InvalidDeclaration unless entries.is_a?(Array) && entries.any?
    raise PlaythroughStage::TooLarge if entries.length > PlaythroughStageInputService::OBJECT_COUNT

    entries.each do |entry|
      exact_keys!(entry, required: %w[path byte_size sha256 content_type])
      path = entry["path"]
      text!(path, maximum: 1024)
      unless /\A[^\s\\:%?#\x00-\x1f\x7f]+\z/.match?(path) && path.split("/", -1).none? { |part| [ "", ".", ".." ].include?(part) }
        raise PlaythroughStage::InvalidDeclaration
      end
      size = entry["byte_size"]
      raise PlaythroughStage::InvalidDeclaration unless size.is_a?(Integer) && size.positive?
      raise PlaythroughStage::TooLarge if size > PlaythroughStageInputService::OBJECT_BYTES

      checksum!(entry["sha256"], pattern: SHA256)
      text!(entry["content_type"], maximum: 200)
      raise PlaythroughStage::InvalidDeclaration unless CONTENT_TYPE.match?(entry["content_type"])
    end
    raise PlaythroughStage::InvalidDeclaration unless entries.map { |entry| entry["path"] }.uniq.length == entries.length
    raise PlaythroughStage::TooLarge if entries.sum { |entry| entry["byte_size"] } > PlaythroughStageInputService::PACKAGE_BYTES

    entries.sort_by { |entry| entry.fetch("path").b }
  end

  def self.verification!(value, source_sha1:, verifier:)
    exact_keys!(value, required: %w[source_sha1 payload_sha1 relationship method result verifier verified_at evidence], optional: %w[removed_bytes])
    checksum!(value["source_sha1"], pattern: SHA1)
    checksum!(value["payload_sha1"], pattern: SHA1)
    %w[relationship method verifier evidence].each { |key| text!(value[key], maximum: 8000) }
    unless value["source_sha1"] == source_sha1 && value["payload_sha1"] != source_sha1 &&
        %w[trailing_padding verified_equivalence].include?(value["relationship"]) &&
        value["result"] == "success" && value["verifier"] == verifier &&
        value["evidence"].scan(/[0-9a-fA-F]{40}/).sort == [ source_sha1, value["payload_sha1"] ].sort
      raise PlaythroughStage::InvalidDeclaration
    end
    if value["relationship"] == "trailing_padding"
      raise PlaythroughStage::InvalidDeclaration unless value["removed_bytes"].is_a?(Integer) && value["removed_bytes"].positive?
    elsif value.key?("removed_bytes")
      raise PlaythroughStage::InvalidDeclaration
    end
    value.merge("verified_at" => timestamp!(value["verified_at"]))
  end

  def self.package_sha256(manifest:)
    Digest::SHA256.hexdigest(JSON.generate(manifest.map { |entry| entry.values_at("path", "byte_size", "sha256", "content_type") }))
  end

  def self.fingerprint(declaration:)
    Digest::SHA256.hexdigest(JSON.generate(canonical(value: declaration)))
  end

  def self.canonical(value:)
    case value
    when Hash then value.sort.to_h.transform_values { |entry| canonical(value: entry) }
    when Array then value.map { |entry| canonical(value: entry) }
    else value
    end
  end
end
