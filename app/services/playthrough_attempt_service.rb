class PlaythroughAttemptService
  LEASE = 15.minutes
  RENEW_INTERVAL = 60

  def self.register(stage:, kind:, blob: nil)
    PlaythroughLifecycleService.require_open!(stage: stage)
    stage.attempts.create!(kind: kind, token: SecureRandom.hex(24), lease_expires_at: Time.current + LEASE,
      blob_identity: blob&.id, private_key: blob&.key, service_name: blob&.service_name)
  end

  def self.require_live!(stage:, attempt:, allow_finished: false)
    PlaythroughLifecycleService.require_open!(stage: stage) unless attempt.kind == "cleanup"
    current = stage.attempts.find(attempt.id)
    owned = current.state == "active" || (allow_finished && current.state == "finished")
    unless owned && current.generation == attempt.generation && current.token == attempt.token && Time.current < current.lease_expires_at
      raise PlaythroughStage::Conflict, "stage_conflict"
    end
    current
  end

  def self.renew(attempt:)
    PlaythroughLifecycleService.synchronize(stage_id: attempt.playthrough_stage_id) do |stage|
      current = require_live!(stage: stage, attempt: attempt)
      current.update!(lease_expires_at: Time.current + LEASE)
    end
  end

  def self.finish(stage:, attempt:)
    require_live!(stage: stage, attempt: attempt).update!(state: "finished")
  end

  def self.relinquish(attempt:)
    PlaythroughLifecycleService.synchronize(stage_id: attempt.playthrough_stage_id) do |stage|
      current = stage.attempts.find(attempt.id)
      current.update!(state: "finished") if current.generation == attempt.generation && current.state == "active"
    end
  end

  def self.fence_stale(stage:)
    stage.attempts.where(state: "active", lease_expires_at: ..Time.current).each do |attempt|
      attempt.update!(state: "fenced", generation: attempt.generation + 1)
    end
  end

  def self.during(attempt:)
    mutex = Mutex.new
    wake = ConditionVariable.new
    stopped = false
    renewal_error = nil
    thread = Thread.new do
      Rails.logger.silence(Logger::UNKNOWN) do
        loop do
          break if mutex.synchronize { wake.wait(mutex, RENEW_INTERVAL) unless stopped; stopped }

          ActiveRecord::Base.connection_pool.with_connection { renew(attempt: attempt) }
        end
      rescue StandardError => error
        current = ActiveRecord::Base.connection_pool.with_connection { PlaythroughStageAttempt.find(attempt.id) }
        renewal_error = error unless current.state == "finished" && current.generation == attempt.generation
      end
    end
    result = yield
    raise renewal_error if renewal_error

    result
  ensure
    mutex&.synchronize { stopped = true; wake.broadcast }
    thread&.join
  end
end
