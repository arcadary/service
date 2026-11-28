class ReleaseControllerProfileDecorator
  VERSION = 1

  def self.version
    [ VERSION ]
  end

  def self.decorate(profile)
    new(profile)
  end

  def initialize(profile)
    @profile = profile
  end

  def as_json(*)
    {
      "version" => @profile.fetch("version"),
      "layout" => @profile.fetch("layout").map { |fact| fact.slice("position", "label") },
      "prompts" => @profile.fetch("prompts").map { |fact| fact.slice("letter", "position") }
    }
  end
end
