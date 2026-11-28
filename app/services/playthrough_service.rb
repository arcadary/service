class PlaythroughService
  TIMESTAMP = { type: "string", maxLength: 64, pattern: "(Z|[+-][0-9]{2}:[0-9]{2})$", description: "ISO 8601 with a time zone." }.freeze
  CAPTURE = {
    type: "object", additionalProperties: false, required: %w[tool version captured_at],
    properties: { tool: { type: "string", minLength: 1, maxLength: 200 }, version: { type: "string", minLength: 1, maxLength: 200 }, captured_at: TIMESTAMP }
  }.freeze
  VERIFICATION = {
    type: "object", additionalProperties: false,
    required: %w[source_sha1 payload_sha1 relationship method result verifier verified_at evidence],
    description: "Explains a source_sha1 that is not one of the release's media. removed_bytes goes with trailing_padding only.",
    properties: {
      source_sha1: McpToolService::SHA1, payload_sha1: McpToolService::SHA1.merge(description: "The release medium the source corresponds to."),
      relationship: { type: "string", enum: %w[trailing_padding verified_equivalence] }, removed_bytes: { type: "integer", minimum: 1 },
      method: { type: "string", minLength: 1, maxLength: 8000 }, result: { type: "string", enum: %w[success] },
      verifier: { type: "string", minLength: 1, maxLength: 8000, description: "The admin username." }, verified_at: TIMESTAMP,
      evidence: { type: "string", minLength: 1, maxLength: 8000, description: "Names exactly source_sha1 and payload_sha1." }
    }
  }.freeze

  def self.create(upload_id:, release_id:, source_sha1:, capture:, verifier:, verification: nil)
    capture = capture.to_h.stringify_keys
    verification = verification!(verification.to_h.stringify_keys, source_sha1: source_sha1, verifier: verifier) if verification
    release = ReleaseService.find(public_id: release_id)
    raise Playthrough::TargetMismatch unless member?(release: release, source_sha1: source_sha1, verification: verification)

    UploadService.use(upload_id: upload_id, kind: "video") do |upload|
      Playthrough.create!(public_id: upload.public_id, release: release, source_sha1: source_sha1, verification: verification,
        capture: capture.merge("captured_at" => timestamp(capture.fetch("captured_at"))), media: upload.media,
        files: upload.files.map { |file| file.slice(:name, :byte_size, :sha256, :content_type) })
    end
  end

  def self.file_type?(content_type:, bytes:)
    case content_type
    when "application/vnd.apple.mpegurl" then bytes.start_with?("#EXTM3U")
    when "video/mp2t" then (bytes.bytesize % 188).zero? && bytes.getbyte(0) == 0x47
    when "text/vtt" then bytes.start_with?("WEBVTT", "\xEF\xBB\xBFWEBVTT".b)
    else false
    end
  end

  def self.check(upload:)
    files = upload.files.to_a
    media = PlaythroughHlsService.validate(files: files, reader: ->(path:) { UploadStorageService.read(upload: upload, name: path) })
    files.each { |file| store(upload: upload, file: file) }
    media
  rescue Playthrough::InvalidHls
    raise Upload::Rejected, "invalid_hls"
  end

  def self.expire(upload:)
    StorageConfigurationService.private_service.delete_prefixed("#{Playthrough.storage_prefix(public_id: upload.public_id)}/") unless upload.state == "used"
  end

  def self.store(upload:, file:)
    path = UploadStorageService.path(upload: upload, name: file.name)
    key = "#{Playthrough.storage_prefix(public_id: upload.public_id)}/#{file.name}"
    begin
      path.open("rb") do |io|
        StorageConfigurationService.private_service.upload(key, io, checksum: Digest::MD5.file(path).base64digest, content_type: file.content_type)
      end
    rescue StandardError
      raise Upload::StorageUnavailable
    end
  end
  private_class_method :store

  def self.member?(release:, source_sha1:, verification:)
    media = release.media_files.pluck(:sha1)
    verification ? media.exclude?(source_sha1) && media.include?(verification.fetch("payload_sha1")) : media.include?(source_sha1)
  end
  private_class_method :member?

  def self.verification!(value, source_sha1:, verifier:)
    payload = value.fetch("payload_sha1")
    unless value.fetch("source_sha1") == source_sha1 && payload != source_sha1 && value.fetch("verifier") == verifier &&
        value.fetch("evidence").scan(/[0-9a-fA-F]{40}/).sort == [ source_sha1, payload ].sort &&
        (value.fetch("relationship") == "trailing_padding") == value.key?("removed_bytes")
      raise Upload::InvalidInput
    end
    value.merge("verified_at" => timestamp(value.fetch("verified_at")))
  end
  private_class_method :verification!

  def self.timestamp(value)
    Time.iso8601(value).utc.iso8601(6)
  rescue ArgumentError
    raise Upload::InvalidInput
  end
  private_class_method :timestamp
end
