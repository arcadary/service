class VideoService
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

  def self.create(upload_id:, release_id:, kind:, source_sha1:, capture:, verifier:, verification: nil)
    raise Upload::InvalidInput unless Video::KINDS.include?(kind)

    capture = capture.to_h.stringify_keys
    verification = verification!(verification.to_h.stringify_keys, source_sha1: source_sha1, verifier: verifier) if verification
    release = ReleaseService.find(public_id: release_id)
    raise Video::TargetMismatch unless member?(release: release, source_sha1: source_sha1, verification: verification)

    UploadService.use(upload_id: upload_id, kind: "video") do |upload|
      replaced = release.videos.find_by(kind: kind)
      delete_files(public_id: replaced.public_id) if replaced
      Video.transaction do
        replaced&.destroy!
        Video.create!(public_id: upload.public_id, release: release, kind: kind, source_sha1: source_sha1, verification: verification,
          capture: capture.merge("captured_at" => timestamp(capture.fetch("captured_at"))), media: upload.media,
          files: upload.files.map { |file| file.slice(:name, :byte_size, :sha256, :content_type) })
      end
    end
  end

  def self.remove(video_id:)
    video = Video.includes(:release).find_by(public_id: video_id.to_s)
    raise Video::NotFound unless video

    delete_files(public_id: video.public_id)
    video.destroy!
    video.release
  end

  def self.key(public_id:, name:)
    "videos/#{public_id}/#{name}"
  end

  def self.file_type?(content_type:, bytes:)
    case content_type
    when "application/vnd.apple.mpegurl" then bytes.start_with?("#EXTM3U")
    when "video/mp2t" then (bytes.bytesize % 188).zero? && bytes.getbyte(0) == 0x47
    when "video/mp4" then [ "ftyp", *VideoHlsService::FRAGMENT_STARTS ].include?(bytes.byteslice(4, 4))
    when "text/vtt" then bytes.start_with?("WEBVTT", "\xEF\xBB\xBFWEBVTT".b)
    else false
    end
  end

  def self.check(upload:)
    files = upload.files.to_a
    reader = ->(path:, range: nil) { UploadStorageService.read(upload: upload, name: path, range: range) }
    media = VideoHlsService.validate(files: files, reader: reader)
    files.each { |file| store(upload: upload, file: file) }
    media
  rescue Video::InvalidHls
    raise Upload::Rejected, "invalid_hls"
  end

  def self.expire(upload:)
    delete_files(public_id: upload.public_id) unless upload.state == "used"
  end

  def self.store(upload:, file:)
    path = UploadStorageService.path(upload: upload, name: file.name)
    begin
      path.open("rb") do |io|
        StorageConfigurationService.media_service.upload(key(public_id: upload.public_id, name: file.name), io,
          checksum: Digest::MD5.file(path).base64digest, content_type: file.content_type)
      end
    rescue StandardError
      raise Upload::StorageUnavailable
    end
  end
  private_class_method :store

  def self.delete_files(public_id:)
    StorageConfigurationService.media_service.delete_prefixed(key(public_id: public_id, name: ""))
  rescue StandardError
    raise Video::StorageUnavailable
  end
  private_class_method :delete_files

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
