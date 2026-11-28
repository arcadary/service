class PlaythroughStageCleanupService
  STAGE_LIMIT = 100
  BLOB_LIMIT = 500

  def self.call
    Rails.logger.silence(Logger::UNKNOWN) do
      remaining = BLOB_LIMIT
      failed = false
      stages = PlaythroughStage.where(declared_at: ..(Time.current - PlaythroughLifecycleService::LIFETIME))
        .order(:cleanup_visits, :id).limit(STAGE_LIMIT).pluck(:id)
      stages.each do |id|
        break if remaining.zero?

        claim = claim(stage_id: id, limit: remaining)
        next unless claim

        begin
          PlaythroughAttemptService.during(attempt: claim) do
            attempts = PlaythroughStageAttempt.where(playthrough_stage_id: id, kind: "transfer")
              .order(:cleanup_visits, :id).limit(remaining).to_a
            attempts.each do |attempt|
              remaining -= 1
              begin
                PlaythroughLifecycleService.synchronize(stage_id: id) do |stage|
                  PlaythroughAttemptService.require_live!(stage: stage, attempt: claim)
                  current = stage.attempts.find(attempt.id)
                  current.update!(cleanup_visits: current.cleanup_visits + 1)
                end
                PlaythroughReclamationService.discard(attempt: attempt, claim: claim)
              rescue PlaythroughStage::StorageUnavailable
                failed = true
              end
            end
            complete(claim: claim)
          end
        rescue PlaythroughStage::Conflict
          next
        ensure
          PlaythroughAttemptService.relinquish(attempt: claim)
        end
      end
      raise PlaythroughStage::StorageUnavailable, "storage_unavailable" if failed
    end
  end

  def self.claim(stage_id:, limit:)
    PlaythroughLifecycleService.synchronize(stage_id: stage_id) do |stage|
      stage.update!(cleanup_visits: stage.cleanup_visits + 1)
      next unless stage.expired_at

      PlaythroughAttemptService.fence_stale(stage: stage)
      next if stage.attempts.where(state: "active").exists?

      legacy_blobs(stage: stage).limit(limit).each do |blob|
        stage.attempts.create!(kind: "transfer", token: SecureRandom.hex(24), state: "fenced",
          lease_expires_at: stage.expired_at, blob_identity: blob.id, private_key: blob.key, service_name: blob.service_name)
      end
      previous = stage.attempts.find_by(kind: "cleanup")
      if previous
        previous.update!(generation: previous.generation + 1, state: "active", lease_expires_at: Time.current + PlaythroughAttemptService::LEASE)
        previous
      else
        stage.attempts.create!(kind: "cleanup", token: SecureRandom.hex(24), lease_expires_at: Time.current + PlaythroughAttemptService::LEASE)
      end
    end
  end
  private_class_method :claim

  def self.legacy_blobs(stage:)
    ActiveStorage::Blob.where("key LIKE ?", "playthrough-stages/#{stage.public_id}/%")
      .where.not(key: stage.attempts.where(kind: "transfer").select(:private_key))
  end
  private_class_method :legacy_blobs

  def self.complete(claim:)
    PlaythroughLifecycleService.synchronize(stage_id: claim.playthrough_stage_id) do |stage|
      PlaythroughAttemptService.require_live!(stage: stage, attempt: claim)
      transfers = stage.attempts.where(kind: "transfer")
      if !transfers.where(absence_checked_at: nil).exists? && !transfers.where(cleanup_pending: true).exists? &&
          !stage.objects.where.not(blob_id: nil).exists? && !legacy_blobs(stage: stage).exists?
        stage.objects.where(pruned_at: nil).each do |object|
          object.update!(path: nil, byte_size: nil, sha256: nil, content_type: nil, received_at: nil, pruned_at: Time.current)
        end
        stage.update!(declaration: stage.declaration.except("manifest"),
          validation_result: stage.validation_result&.except("manifest"), reclaimed_at: stage.reclaimed_at || Time.current)
      end
      PlaythroughAttemptService.finish(stage: stage, attempt: claim)
    end
  end
  private_class_method :complete
end
