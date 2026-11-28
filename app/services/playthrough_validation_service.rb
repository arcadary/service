class PlaythroughValidationService
  FAILURES = {
    "invalid_hls" => PlaythroughStage::InvalidHls,
    "package_integrity_mismatch" => PlaythroughStage::PackageIntegrityMismatch
  }.freeze

  def self.validate(staging_id:)
    Rails.logger.silence(Logger::UNKNOWN) do
      stage = PlaythroughStagingService.find_by(staging_id: staging_id)
      PlaythroughLifecycleService.require_open!(stage: stage)
      next replay(stage: stage) if stage.validation_state

      receipts = stage.objects.index_by(&:path)
      unless stage.declaration.fetch("manifest").all? { |entry| receipts[entry.fetch("path")]&.received_at }
        raise PlaythroughStage::StageIncomplete, "stage_incomplete"
      end

      attempt = PlaythroughLifecycleService.synchronize(stage_id: stage.id) do |current|
        PlaythroughAttemptService.register(stage: current, kind: "validation")
      end
      begin
        PlaythroughAttemptService.during(attempt: attempt) { new(stage: stage, attempt: attempt).validate }
      rescue StandardError
        PlaythroughLifecycleService.synchronize(stage_id: stage.id) do |current|
          PlaythroughAttemptService.require_live!(stage: current, attempt: attempt, allow_finished: true)
        end
        raise
      ensure
        PlaythroughAttemptService.relinquish(attempt: attempt)
      end
    end
  end

  def self.replay(stage:)
    PlaythroughLifecycleService.require_open!(stage: stage)
    raise FAILURES.fetch(stage.validation_error), stage.validation_error if stage.validation_error

    stage.validation_result
  end

  def initialize(stage:, attempt:)
    @stage = stage
    @attempt = attempt
    @objects = stage.objects.index_by(&:path)
    @manifest = stage.declaration.fetch("manifest")
    @entries = @manifest.index_by { |entry| entry.fetch("path") }
  end

  def validate
    begin
      verify_manifest!
      @manifest.each { |entry| read(path: entry.fetch("path")) }
      package = PlaythroughHlsService.validate(manifest: @manifest, reader: method(:read))
      result = identity.merge(package)
    rescue *FAILURES.values => error
      failure = FAILURES.key(error.class)
    end
    persist(result: result, failure: failure)
  end

  def read(path:)
    object = @objects.fetch(path)
    entry = @entries.fetch(path)
    unless object.attributes.slice("path", "byte_size", "sha256", "content_type") == entry
      raise PlaythroughStage::PackageIntegrityMismatch, "package_integrity_mismatch"
    end
    blob = object.blob
    raise PlaythroughStage::StorageUnavailable, "storage_unavailable" unless blob

    bytes = download(blob: blob)
    unless blob.byte_size == entry.fetch("byte_size") && blob.content_type == entry.fetch("content_type") &&
        bytes.bytesize == entry.fetch("byte_size") && Digest::SHA256.hexdigest(bytes) == entry.fetch("sha256") &&
        blob.checksum == Digest::MD5.base64digest(bytes)
      raise PlaythroughStage::PackageIntegrityMismatch, "package_integrity_mismatch"
    end
    bytes
  end

  private

  def download(blob:)
    bytes = +"".b
    blob.download do |chunk|
      if bytes.bytesize + chunk.bytesize > PlaythroughStageInputService::OBJECT_BYTES
        raise PlaythroughStage::PackageIntegrityMismatch, "package_integrity_mismatch"
      end
      bytes << chunk
    end
    bytes
  rescue PlaythroughStage::PackageIntegrityMismatch
    raise
  rescue StandardError
    raise PlaythroughStage::StorageUnavailable, "storage_unavailable", cause: nil
  end

  def verify_manifest!
    unless @objects.keys.sort == @manifest.map { |entry| entry.fetch("path") }.sort &&
        PlaythroughDeclarationService.fingerprint(declaration: @stage.declaration) == @stage.declaration_sha256 &&
        PlaythroughDeclarationService.package_sha256(manifest: @manifest) == @stage.package_sha256
      raise PlaythroughStage::PackageIntegrityMismatch, "package_integrity_mismatch"
    end
  end

  def identity
    declaration = @stage.declaration
    {
      "staging_id" => @stage.public_id, "declaration_sha256" => @stage.declaration_sha256,
      "package_sha256" => @stage.package_sha256, "manifest" => @manifest,
      "release_id" => @stage.release.public_id, "source_sha1" => declaration.fetch("source_sha1"),
      "capture" => declaration.fetch("capture"), "verification" => declaration["verification"]
    }
  end

  def persist(result:, failure:)
    stage = PlaythroughLifecycleService.synchronize(stage_id: @stage.id) do |current|
      PlaythroughAttemptService.require_live!(stage: current, attempt: @attempt)
      unless current.validation_state
        current.update!(validation_state: failure ? "validation_failed" : "validated",
          validation_result: result, validation_error: failure)
      end
      PlaythroughAttemptService.finish(stage: current, attempt: @attempt)
      current
    end
    PlaythroughLifecycleService.synchronize(stage_id: stage.id) do |current|
      PlaythroughAttemptService.require_live!(stage: current, attempt: @attempt, allow_finished: true)
      self.class.replay(stage: current)
    end
  end
end
