class McpCatalogDecorator
  VERSION = 2

  def self.version
    [ VERSION ]
  end

  def self.decorate(record)
    case record
    when Game, Release
      CatalogAuthoringReadService.record(record).tap do |value|
        value.fetch("canonical")["title_aliases"]&.sort!
      end
    when CatalogMutation
      record.slice(:id, :operation, :admin_name, :created_at, :reason, :record_changes).as_json
    end
  end

  def self.game_summary(game)
    game.slice(:title, :authoring_revision).merge("id" => game.public_id)
  end

  def self.release_summary(release)
    release.slice(:system, :region, :revision, :authoring_revision).merge("id" => release.public_id, "game_id" => release.game.public_id)
  end
end
