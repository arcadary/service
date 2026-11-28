class CatalogAuthoringReadService
  MAX_HISTORY = 100
  MAX_SEARCH = 100

  def self.game(id:)
    game = CatalogGameIdentityService.resolve(game: Game.find_by!(public_id: id))
    record(game).merge("requested_id" => id)
  end

  def self.release(id:)
    record(Release.includes(release_media: :media_file).find_by!(public_id: id))
  end

  def self.media(sha1:)
    record(MediaFile.find_by!(sha1: sha1))
  end

  def self.scope(game_id:)
    game = CatalogGameIdentityService.resolve(game: Game.find_by!(public_id: game_id))
    [ *CatalogGameIdentityService.identities(game: game), *game.releases.includes(release_media: :media_file).order(:public_id) ].map { |record| self.record(record) }
  end

  def self.search(query:, limit: 25)
    bounded_limit!(limit: limit, maximum: MAX_SEARCH)
    pattern = "%#{Game.sanitize_sql_like(query.to_s.downcase)}%"
    Game.where("LOWER(title) LIKE :pattern ESCAPE '\\' OR EXISTS (SELECT 1 FROM json_each(games.title_aliases) WHERE LOWER(value) LIKE :pattern ESCAPE '\\')", pattern: pattern)
      .map { |game| CatalogGameIdentityService.resolve(game: game) }.uniq(&:id).sort_by(&:public_id).first(limit).map { |game| record(game) }
  end

  def self.history(limit: 25, before_id: nil)
    bounded_limit!(limit: limit, maximum: MAX_HISTORY)
    entries = CatalogMutation.order(id: :desc)
    entries = entries.where("id < ?", before_id) if before_id
    entries.limit(limit).map do |entry|
      entry.attributes.slice("id", "operation", "admin_name", "created_at", "reason", "record_changes").as_json
    end
  end

  def self.record(record, games: {})
    type, id, canonical, source = case record
    when Game
      [ "game", record.public_id, record.slice(:title, :title_aliases), record.slice(:source_title) ]
    when Release
      canonical = record.slice(:system, :region, :revision, :controller_profile).merge("game_id" => record.game.public_id,
        "startup" => ReleaseStartupService.for_release(release: record),
        "media" => record.release_media.reject(&:marked_for_destruction?).sort_by(&:position).map { |medium| medium.slice(:key, :position, :role, :label).merge(medium.media_file.slice(:sha1, :size, :format, :crc32, :md5)) })
      [ "release", record.public_id, canonical, record.slice(:source_title, :source_system, :source_region, :source_revision) ]
    when MediaFile
      [ "media", record.sha1, record.slice(:sha1, :size, :format, :crc32, :md5), record.slice(:source_size, :source_format, :source_crc32, :source_md5) ]
    else
      raise ArgumentError, "unknown authoring record"
    end
    state = { "type" => type, "id" => id, "authoring_revision" => record.authoring_revision,
      "canonical" => canonical, "authored_fields" => record.authored_fields, "source" => source }
    if record.is_a?(Game)
      state["identity"] = { "state" => record.retired_into_game_id ? "retired" : "active",
        "retired_into_game_id" => record.retired_into_game_id && games.fetch(record.retired_into_game_id) { record.retired_into_game }.public_id,
        "canonical_game_id" => CatalogGameIdentityService.resolve(game: record, games: games).public_id,
        "screenshot_licence" => record.screenshot_licence, "catalog_curated" => record.catalog_curated,
        "importer_keys" => record.game_identities.map(&:key).sort }
    end
    state.as_json
  end

  def self.bounded_limit!(limit:, maximum:)
    raise ArgumentError, "limit must be between 1 and #{maximum}" unless limit.is_a?(Integer) && limit.between?(1, maximum)
  end
  private_class_method :bounded_limit!
end
