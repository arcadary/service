class PlaythroughStageDecorator
  VERSION = 1

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
    {
      staging_id: @stage.public_id,
      package_sha256: @stage.package_sha256,
      declaration: @stage.declaration,
      state: @stage.objects.all?(&:received_at) ? "received" : "incomplete",
      objects: @stage.objects.map do |object|
        { object_id: object.public_id, path: object.path, received: object.received_at.present? }
      end
    }
  end
end
