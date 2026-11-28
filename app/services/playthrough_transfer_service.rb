class PlaythroughTransferService
  def self.receive(staging_id:, object_id:, io:, content_type:)
    Rails.logger.silence(Logger::UNKNOWN) do
      stage = PlaythroughStagingService.find_by(staging_id: staging_id)
      object, attempt = prepare(stage: stage, object_id: object_id, content_type: content_type)
      begin
        PlaythroughAttemptService.during(attempt: attempt) do
          bytes = PlaythroughStageInputService.read(io: io, limit: PlaythroughStageInputService::OBJECT_BYTES)
          unless bytes.bytesize == object.byte_size && Digest::SHA256.hexdigest(bytes) == object.sha256
            raise PlaythroughStage::Conflict
          end
          upload(bytes: bytes, object: object, stage: stage, attempt: attempt) unless object.received_at
          PlaythroughLifecycleService.synchronize(stage_id: stage.id) do |current|
            PlaythroughAttemptService.require_live!(stage: current, attempt: attempt)
            object = current.objects.find(object.id)
            object.update!(blob_id: attempt.blob_identity, received_at: Time.current) unless object.received_at
            PlaythroughAttemptService.finish(stage: current, attempt: attempt)
          end
          object
        end
      ensure
        PlaythroughAttemptService.relinquish(attempt: attempt)
        PlaythroughReclamationService.discard(attempt: attempt)
      end
    end
  end

  def self.prepare(stage:, object_id:, content_type:)
    PlaythroughLifecycleService.synchronize(stage_id: stage.id) do |current|
      PlaythroughLifecycleService.require_open!(stage: current)
      object = current.objects.find_by(public_id: object_id)
      raise PlaythroughStage::NotFound unless object
      raise PlaythroughStage::Conflict unless content_type == object.content_type

      blob = ActiveStorage::Blob.create_before_direct_upload!(filename: "playthrough-object",
        byte_size: object.byte_size, checksum: Digest::MD5.base64digest(""), content_type: object.content_type,
        key: "playthrough-stages/#{current.public_id}/#{object.public_id}/#{SecureRandom.hex(24)}")
      [ object, PlaythroughAttemptService.register(stage: current, kind: "transfer", blob: blob) ]
    end
  end
  private_class_method :prepare

  def self.upload(bytes:, object:, stage:, attempt:)
    if Rails.env.production? && !ScreenshotConfigurationService.r2_configured?
      raise PlaythroughStage::StorageUnavailable
    end

    blob = PlaythroughLifecycleService.synchronize(stage_id: stage.id) do |current|
      PlaythroughAttemptService.require_live!(stage: current, attempt: attempt)
      blob = ActiveStorage::Blob.find(attempt.blob_identity)
      blob.update!(checksum: Digest::MD5.base64digest(bytes))
      blob
    end
    begin
      blob.upload_without_unfurling(StringIO.new(bytes))
    rescue StandardError
      raise PlaythroughStage::StorageUnavailable, "storage_unavailable", cause: nil
    end
    blob
  end
  private_class_method :upload
end
