class PlaythroughStageObjectDecorator
  VERSION = 1

  def self.version
    [ VERSION ]
  end

  def self.decorate(object)
    new(object)
  end

  def initialize(object)
    @object = object
  end

  def as_json(*)
    { object_id: @object.public_id, received_at: @object.received_at.iso8601(6) }
  end
end
