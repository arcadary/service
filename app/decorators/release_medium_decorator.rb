class ReleaseMediumDecorator
  VERSION = 1

  def self.version
    [ VERSION ]
  end

  def self.decorate(medium)
    new(medium)
  end

  def initialize(medium)
    @medium = medium
  end

  def as_json(*)
    @medium.slice(:key, :position, :label, :role).merge(@medium.media_file.slice(:sha1, :size, :format))
  end
end
