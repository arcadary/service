class PlaythroughTransferService
  def self.receive(staging_id:, object_id:, io:, content_type:)
    stage = PlaythroughStage.find_by(public_id: staging_id)
    raise PlaythroughStage::NotFound unless stage

    object = stage.objects.find_by(public_id: object_id)
    raise PlaythroughStage::NotFound unless object
    raise PlaythroughStage::Conflict unless content_type == object.content_type

    bytes = PlaythroughStageInputService.read(io: io, limit: PlaythroughStageInputService::OBJECT_BYTES)
    unless bytes.bytesize == object.byte_size && Digest::SHA256.hexdigest(bytes) == object.sha256
      raise PlaythroughStage::Conflict
    end
    return object if object.received_at

    blob = upload(bytes: bytes, object: object, stage: stage)
    begin
      PlaythroughStageObject.transaction do
        current = stage.objects.find(object.id)
        current.update!(blob: blob, received_at: Time.current) unless current.received_at
        object = current
      end
    rescue StandardError
      discard(blob: blob)
      raise
    end
    discard(blob: blob) if object.blob_id != blob.id
    object
  end

  def self.upload(bytes:, object:, stage:)
    if Rails.env.production? && !ScreenshotConfigurationService.r2_configured?
      raise PlaythroughStage::StorageUnavailable
    end

    blob = ActiveStorage::Blob.build_after_unfurling(io: StringIO.new(bytes), filename: "playthrough-object",
      key: "playthrough-stages/#{stage.public_id}/#{object.public_id}/#{SecureRandom.hex(24)}",
      content_type: object.content_type, identify: false)
    blob.save!
    blob.upload_without_unfurling(StringIO.new(bytes))
    blob
  rescue StandardError
    discard(blob: blob) if blob&.persisted?
    raise PlaythroughStage::StorageUnavailable
  end
  private_class_method :upload

  def self.discard(blob:)
    blob.delete
    blob.destroy!
  rescue StandardError
    nil
  end
  private_class_method :discard
end
