class McpCatalogReadService
  class InvalidInput < StandardError; end
  class NotFound < StandardError; end
  class AmbiguousRelease < StandardError
    attr_reader :candidates

    def initialize(candidates:)
      @candidates = candidates
      super("ambiguous_release")
    end
  end

  def self.call(tool:, **arguments)
    new(tool: tool, arguments: arguments.stringify_keys).call
  end

  def initialize(tool:, arguments:)
    @tool = tool
    @arguments = arguments
    @limit = arguments.fetch("limit", 20)
    raise InvalidInput unless @limit.is_a?(Integer) && @limit.between?(1, 50)
  end

  def call
    if @arguments["cursor"]
      continue(cursor: @arguments.fetch("cursor"))
    else
      case @tool
      when "search_games" then search
      when "get_game" then game
      when "get_release" then release
      when "get_catalog_history" then history
      when "get_compatibility" then compatibility
      else raise InvalidInput
      end
    end
  rescue ActiveRecord::RecordNotFound, Release::ReleaseNotFound
    raise NotFound
  end

  private
    def search(after: nil)
      query = @arguments.fetch("query", "")
      system = @arguments["system"]
      raise InvalidInput unless query.is_a?(String) && query.size <= 200
      raise InvalidInput if system && !Release::SYSTEMS.include?(system)

      pattern = "%#{Game.sanitize_sql_like(query.downcase)}%"
      games = Game.where("LOWER(title) LIKE :pattern ESCAPE '\\' OR EXISTS (SELECT 1 FROM json_each(games.title_aliases) WHERE LOWER(value) LIKE :pattern ESCAPE '\\')", pattern: pattern)
      games = games.where(id: Release.where(system: system).select(:game_id)) if system
      games = games.where("public_id > ?", after) if after
      relation_page(records: games.order(:public_id), kind: "search", key: "public_id") { |record| McpCatalogDecorator.game_summary(record) }
    end

    def game
      record = Game.find_by!(public_id: identifier!("id"))
      value = record_tree(record: record, kind: "game")
      value["releases"] = variants(game: record)
      value
    end

    def variants(game:, after: nil)
      releases = game.releases.includes(:game).order(:public_id)
      releases = releases.where("public_id > ?", after) if after
      relation_page(records: releases, kind: "variants", key: "public_id", owner: game.public_id) { |record| McpCatalogDecorator.release_summary(record) }
    end

    def release
      id, sha1 = @arguments.values_at("id", "sha1")
      raise InvalidInput unless id.present? ^ sha1.present?

      if id
        record = release_record(id: identifier!("id"))
      else
        raise InvalidInput unless sha1.is_a?(String) && ReleaseService::SHA1.match?(sha1)

        matches = Release.where(id: ReleaseMedium.joins(:media_file).where(media_files: { sha1: sha1.downcase }).select(:release_id))
        raise NotFound unless matches.exists?
        raise AmbiguousRelease.new(candidates: candidates(matches: matches)) if matches.limit(2).count > 1

        record = release_record(id: matches.pick(:public_id))
      end
      record_tree(record: record, kind: "release")
    end

    def candidates(matches:, after: nil)
      matches = matches.where("public_id > ?", after) if after
      relation_page(records: matches.includes(:game).order(:public_id), kind: "candidates", key: "public_id") { |record| McpCatalogDecorator.release_summary(record) }
    end

    def history(before: nil)
      entries = CatalogMutation.order(id: :desc)
      entries = entries.where("id < ?", before) if before
      relation_page(records: entries, kind: "history", key: "id") { |record| record_tree(record: record, kind: "audit") }
    end

    def compatibility
      release = CompatibilityService.find_release(release_id: identifier!("release_id"))
      { "release_id" => release.public_id, "startup_revision" => ReleaseStartupService.revision(release: release),
        "current" => CompatibilityResultDecorator.current(CompatibilityService.current(release: release)),
        "history" => compatibility_history(release: release) }
    end

    def compatibility_history(release:, before: nil)
      results = release.compatibility_results.includes(:playthroughs).reorder(id: :desc)
      results = results.where("id < ?", before) if before
      relation_page(records: results, kind: "compatibility", key: "id", owner: release.public_id) { |record| CompatibilityResultDecorator.decorate(record).history_json }
    end

    def relation_page(records:, kind:, key:, owner: nil)
      records = records.limit(@limit + 1).to_a
      more = records.size > @limit
      items = records.first(@limit)
      token = cursor(kind: kind, after: items.last.public_send(key), owner: owner) if more
      { "items" => items.map { |record| yield record }, "next_cursor" => token }
    end

    def record_tree(record:, kind:)
      raw = McpCatalogDecorator.decorate(record)
      owner = { "kind" => kind, "id" => kind == "audit" ? record.id : record.public_id,
        "revision" => Digest::SHA256.hexdigest(JSON.generate(raw)) }
      paginate(value: raw, owner: owner)
    end

    def paginate(value:, owner:, path: [])
      case value
      when Array
        array_page(value: value, owner: owner, path: path)
      when Hash
        value.to_h { |key, child| [ key, paginate(value: child, owner: owner, path: path + [ key ]) ] }
      else value
      end
    end

    def array_page(value:, owner:, path:, offset: 0)
      items = value.slice(offset, @limit) || []
      token = cursor(kind: "nested", owner: owner, path: path, offset: offset + @limit) if offset + @limit < value.size
      { "items" => items.each_with_index.map { |child, index| paginate(value: child, owner: owner, path: path + [ offset + index ]) }, "next_cursor" => token }
    end

    def cursor(**position)
      verifier.generate({ "tool" => @tool, "arguments" => @arguments.except("cursor"), "position" => position.stringify_keys }, expires_in: 1.hour, purpose: "mcp-catalog")
    end

    def continue(cursor:)
      raise InvalidInput unless cursor.is_a?(String) && cursor.bytesize <= 8192

      payload = verifier.verified(cursor, purpose: "mcp-catalog")
      raise InvalidInput unless payload && payload["tool"] == @tool && @arguments.except("cursor").empty?

      @arguments = payload.fetch("arguments")
      @limit = @arguments.fetch("limit", 20)
      position = payload.fetch("position")
      case position.fetch("kind")
      when "search" then search(after: position.fetch("after"))
      when "history" then history(before: position.fetch("after"))
      when "compatibility" then compatibility_history(release: Release.find_by!(public_id: position.fetch("owner")), before: position.fetch("after"))
      when "variants" then variants(game: Game.find_by!(public_id: position.fetch("owner")), after: position.fetch("after"))
      when "candidates"
        sha1 = @arguments.fetch("sha1").downcase
        matches = Release.where(id: ReleaseMedium.joins(:media_file).where(media_files: { sha1: sha1 }).select(:release_id))
        raise AmbiguousRelease.new(candidates: candidates(matches: matches, after: position.fetch("after")))
      when "nested" then continue_nested(position: position)
      else raise InvalidInput
      end
    end

    def continue_nested(position:)
      owner = position.fetch("owner")
      record = case owner.fetch("kind")
      when "game" then Game.find_by!(public_id: owner.fetch("id"))
      when "release" then release_record(id: owner.fetch("id"))
      when "audit" then CatalogMutation.find(owner.fetch("id"))
      end
      raw = McpCatalogDecorator.decorate(record)
      raise InvalidInput unless Digest::SHA256.hexdigest(JSON.generate(raw)) == owner.fetch("revision")

      path = position.fetch("path")
      value = raw.dig(*path)
      array_page(value: value, owner: owner, path: path, offset: position.fetch("offset"))
    end

    def release_record(id:)
      Release.includes(:game, release_media: :media_file).find_by!(public_id: id)
    end

    def identifier!(key)
      value = @arguments[key]
      raise InvalidInput unless value.is_a?(String) && value.present? && value.size <= 200

      value
    end

    def verifier
      Rails.application.message_verifier("mcp-catalog-cursor")
    end
end
