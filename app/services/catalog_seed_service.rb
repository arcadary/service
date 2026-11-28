class CatalogSeedService
  SEEDS = [
    { public_id: "ucity", title: "µCity", system: "gbc", sha1: "5f026649611c9606ce0bf70dc1552e054e7df5bc", screenshot_licence: "CC-BY-SA-4.0" },
    { public_id: "tobu-tobu-girl", title: "Tobu Tobu Girl", system: "gb", sha1: "8a8f3c1f21f903ea5a7df8fc8b0a6aa5a602e150", screenshot_licence: "CC-BY-4.0" }
  ].freeze

  def self.call
    ApplicationRecord.transaction do
      SEEDS.map { |seed| new(seed: seed).apply }
    end
  end

  def initialize(seed:)
    @seed = seed
    @divergences = []
  end

  def apply
    file = MediaFile.find_by(sha1: @seed[:sha1])
    if file
      releases = file.releases.includes(:game).to_a
      if releases.empty?
        difference(type: "media", id: file.sha1, field: "membership", source: "single release", effective: [])
      end
      releases.each do |release|
        difference(type: "release", id: release.public_id, field: "game_id", source: @seed[:public_id], effective: release.game.public_id)
        difference(type: "release", id: release.public_id, field: "system", source: @seed[:system], effective: release.system)
        difference(type: "game", id: release.game.public_id, field: "title", source: @seed[:title], effective: release.game.title)
      end
      game = Game.find_by(public_id: @seed[:public_id])
      set_licence(game: game) if game && releases.any? { |release| release.game_id == game.id }
    else
      game = Game.find_or_initialize_by(public_id: @seed[:public_id])
      if game.new_record?
        game.assign_attributes(title: @seed[:title], screenshot_licence: @seed[:screenshot_licence])
        game.save!
      end
      target = CatalogGameIdentityService.resolve(game: game)
      release = Release.create!(sha1: @seed[:sha1], game: target, system: @seed[:system])
      difference(type: "release", id: release.public_id, field: "game_id", source: game.public_id, effective: target.public_id)
      set_licence(game: game) if target == game
    end
    { seed: @seed[:public_id], divergences: @divergences }
  end

  private
    def set_licence(game:)
      if game.screenshot_licence.empty? && game.authored_fields.empty? && game.retired_into_game_id.nil?
        game.update!(screenshot_licence: @seed[:screenshot_licence], authoring_revision: game.authoring_revision + 1)
      end
      difference(type: "game", id: game.public_id, field: "screenshot_licence", source: @seed[:screenshot_licence], effective: game.screenshot_licence)
    end

    def difference(type:, id:, field:, source:, effective:)
      return if source == effective

      @divergences << { type: type, id: id, field: field, source_value: source, effective_value: effective }
    end
end
