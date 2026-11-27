class CatalogGameIdentityService
  def self.resolve(game:, games: {})
    seen = []
    while game.retired_into_game_id
      raise CatalogAuthoringService::Conflict, "cyclic game identity" if seen.include?(game.id)

      seen << game.id
      game = games.fetch(game.retired_into_game_id) { game.retired_into_game }
    end
    game
  end

  def self.identities(game:)
    canonical = resolve(game: game)
    records = [ canonical ]
    frontier = [ canonical.id ]
    while frontier.any?
      children = Game.where(retired_into_game_id: frontier).order(:public_id).to_a
      records.concat(children)
      frontier = children.map(&:id)
    end
    records.sort_by(&:public_id)
  end
end
