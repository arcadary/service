class PlaythroughLifecycleService
  LIFETIME = 24.hours

  def self.synchronize(stage_id:)
    PlaythroughStage.uncached do
      PlaythroughStage.transaction do
        stage = PlaythroughStage.lock.find(stage_id)
        expire(stage: stage)
        yield stage
      end
    end
  rescue PlaythroughStage::Expired
    PlaythroughStage.transaction { expire(stage: PlaythroughStage.lock.find(stage_id)) }
    raise
  end

  def self.expire(stage:)
    deadline = stage.declared_at + LIFETIME
    stage.update!(expired_at: deadline) if Time.current >= deadline && !stage.expired_at
    stage
  end

  def self.require_open!(stage:)
    raise PlaythroughStage::Expired, "stage_expired" if stage.expired_at || Time.current >= stage.declared_at + LIFETIME
  end
end
