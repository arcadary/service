class ReleaseControllerProfileService
  POSITIONS = %w[top right bottom left].freeze
  LABELS = %w[X A B Y].freeze
  MAX_PROMPTS = 16
  MAX_CITATIONS = 8
  MAX_CITATION_LENGTH = 500
  MAX_EDITION_LENGTH = 128

  def self.errors(release:)
    return [] if release.controller_profile.nil?

    new(release: release).errors
  end

  def initialize(release:)
    @release = release
    @profile = release.controller_profile
  end

  def errors
    return [ "must use version 1 with binding, layout and prompts" ] unless object?(value: @profile, fields: %w[version binding layout prompts]) && @profile["version"].is_a?(Integer) && @profile["version"] == 1
    return [ "binding must match the exact SNES edition" ] unless binding_valid?
    return [ "layout must declare four distinct face positions and SNES labels with text citations" ] unless layout_valid?
    return [ "prompts must declare at most #{MAX_PROMPTS} distinct letters referencing face positions with text citations" ] unless prompts_valid?

    []
  end

  private
    def object?(value:, fields:)
      value.is_a?(Hash) && value.keys.sort == fields.sort
    end

    def binding_valid?
      binding = @profile["binding"]
      @release.system == "snes" && object?(value: binding, fields: %w[system region revision]) &&
        binding == @release.slice(:system, :region, :revision) &&
        binding.values.all? { |value| value.nil? || (value.is_a?(String) && value.size <= MAX_EDITION_LENGTH) }
    end

    def layout_valid?
      layout = @profile["layout"]
      layout.is_a?(Array) && layout.size == POSITIONS.size &&
        layout.all? { |fact| object?(value: fact, fields: %w[position label evidence]) && citations?(value: fact["evidence"]) } &&
        layout.map { |fact| fact["position"] }.sort_by(&:to_s) == POSITIONS.sort &&
        layout.map { |fact| fact["label"] }.sort_by(&:to_s) == LABELS.sort
    end

    def prompts_valid?
      prompts = @profile["prompts"]
      prompts.is_a?(Array) && prompts.size <= MAX_PROMPTS &&
        prompts.all? do |fact|
          object?(value: fact, fields: %w[letter position evidence]) &&
            fact["letter"].is_a?(String) && /\A[A-Za-z]\z/.match?(fact["letter"]) &&
            @profile["layout"].any? { |button| button["position"] == fact["position"] } && citations?(value: fact["evidence"])
        end && prompts.map { |fact| fact["letter"] }.uniq.size == prompts.size
    end

    def citations?(value:)
      value.is_a?(Array) && value.size.between?(1, MAX_CITATIONS) &&
        value.all? { |citation| citation.is_a?(String) && citation.present? && citation.size <= MAX_CITATION_LENGTH }
    end
end
