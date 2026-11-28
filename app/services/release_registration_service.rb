class ReleaseRegistrationService
  def self.register(reason:, idempotency_key:, system:, media:, game_id: nil, new_game: nil, region: nil, revision: nil)
    raise CatalogAuthoringService::InvalidInput, "name either game_id or new_game" unless game_id.present? ^ new_game.present?

    media = media.each.with_index(1).map { |medium, position| { key: "medium-#{position}", role: "game" }.merge(medium, position: position) }
    ApplicationRecord.transaction do
      if new_game
        CatalogAuthoringService.call(operation: "create_game", attributes: new_game, expected_revisions: {},
          reason: reason, idempotency_key: "#{idempotency_key}:game")
      end
      CatalogAuthoringService.call(operation: "create_release", expected_revisions: :current, reason: reason,
        attributes: { game_id: game_id || new_game.fetch(:id), system: system, region: region, revision: revision, media: media }.compact,
        idempotency_key: "#{idempotency_key}:release")
    end
    McpCatalogReadService.call(tool: "get_release", sha1: media.first.fetch(:sha1))
  rescue ActiveRecord::RecordNotFound
    raise CatalogAuthoringService::InvalidInput, "unknown game"
  end
end
