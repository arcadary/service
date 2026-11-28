class PlaythroughReclamationService
  def self.discard(attempt:, claim: nil)
    work = PlaythroughLifecycleService.synchronize(stage_id: attempt.playthrough_stage_id) do |stage|
      PlaythroughAttemptService.require_live!(stage: stage, attempt: claim) if claim
      current = stage.attempts.find(attempt.id)
      next if referenced?(stage: stage, attempt: current, reclaim: claim.present?)

      current
    end
    return unless work

    begin
      service = ActiveStorage::Blob.services.fetch(work.service_name)
      if claim && work.absence_checked_at && !work.cleanup_pending &&
          !ActiveStorage::Blob.exists?(id: work.blob_identity, key: work.private_key) && !service.exist?(work.private_key)
        return
      end

      PlaythroughLifecycleService.synchronize(stage_id: attempt.playthrough_stage_id) do |stage|
        PlaythroughAttemptService.require_live!(stage: stage, attempt: claim) if claim
        raise PlaythroughStage::Conflict if referenced?(stage: stage, attempt: work, reclaim: claim.present?)

        if stage.expired_at
          stage.objects.where(blob_id: work.blob_identity).each { |object| object.update!(blob_id: nil, received_at: nil) }
        end
        stage.attempts.find(work.id).update!(cleanup_pending: true, absence_checked_at: nil)
        stage.update!(reclaimed_at: nil) if stage.reclaimed_at
      end
      service.delete(work.private_key)
      raise PlaythroughStage::StorageUnavailable if service.exist?(work.private_key)
    rescue PlaythroughStage::Conflict
      raise
    rescue StandardError
      raise PlaythroughStage::StorageUnavailable, "storage_unavailable", cause: nil
    end
    PlaythroughLifecycleService.synchronize(stage_id: attempt.playthrough_stage_id) do |stage|
      PlaythroughAttemptService.require_live!(stage: stage, attempt: claim) if claim
      blob = ActiveStorage::Blob.find_by(id: work.blob_identity, key: work.private_key)
      blob&.destroy!
      stage.attempts.find(work.id).update!(cleanup_pending: false, absence_checked_at: Time.current)
    end
  rescue PlaythroughStage::StorageUnavailable
    raise if claim
  end

  def self.referenced?(stage:, attempt:, reclaim:)
    blob = ActiveStorage::Blob.find_by(id: attempt.blob_identity)
    return true if blob && (blob.key != attempt.private_key || blob.attachments.exists?)

    owners = PlaythroughStageObject.where(blob_id: attempt.blob_identity)
    owners.where.not(playthrough_stage_id: stage.id).exists? || ((!reclaim || !stage.expired_at) && owners.exists?)
  end
  private_class_method :referenced?
end
