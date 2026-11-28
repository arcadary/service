class PlaythroughStageDecorator
  VERSION = 5

  def self.version
    [ VERSION ]
  end

  def self.decorate(stage)
    new(stage)
  end

  def initialize(stage)
    @stage = stage
  end

  def as_json(*)
    if @stage.expired_at
      result = identity.merge(declaration: @stage.declaration, declaration_sha256: @stage.declaration_sha256,
        state: @stage.reclaimed_at ? "reclaimed" : "expired", expired_at: @stage.expired_at.iso8601(6))
      result[:reclaimed_at] = @stage.reclaimed_at.iso8601(6) if @stage.reclaimed_at
      return result
    end

    summary.merge(declaration: @stage.declaration).tap do |result|
      result[:state] = @stage.validation_state if @stage.validation_state
      result[:state] = @stage.promotion_state if @stage.promotion_state
      result[:validation_result] = @stage.validation_result if @stage.validation_result
      result[:validation_error] = @stage.validation_error if @stage.validation_error
    end
  end

  def summary
    identity.merge(
      state: @stage.objects.all?(&:received_at) ? "received" : "incomplete",
      objects: @stage.objects.map do |object|
        { object_id: object.public_id, path: object.path, received: object.received_at.present? }
      end
    )
  end

  private

  def identity
    {
      staging_id: @stage.public_id,
      release_id: @stage.declaration.fetch("release_id"),
      package_sha256: @stage.package_sha256,
      declared_at: @stage.declared_at.iso8601(6),
      stage_expires_at: (@stage.declared_at + PlaythroughLifecycleService::LIFETIME).iso8601(6)
    }
  end
end
