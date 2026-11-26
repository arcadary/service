class CatalogImportService
  class IdentityConflict < StandardError; end

  SEEDS = {
    "5f026649611c9606ce0bf70dc1552e054e7df5bc" => "ucity",
    "8a8f3c1f21f903ea5a7df8fc8b0a6aa5a602e150" => "tobu-tobu-girl"
  }.freeze

  def self.import(path:, system:, mappings: CatalogMappingService.load)
    raise ArgumentError, "unknown system" unless Release::SYSTEMS.include?(system)

    parsed = CatalogDatService.parse(path: path, system: system)
    new(rows: parsed[:rows], skipped: parsed[:skipped], mappings: mappings).import
  end

  def initialize(rows:, skipped:, mappings:)
    @rows, @skipped, @mappings = rows, skipped, mappings
    @games = Game.all.index_by(&:public_id)
    @games_by_id = @games.values.index_by(&:id)
    @releases = Release.all.index_by(&:sha1)
    @aliases = GameIdentity.all.index_by(&:key)
    @new_aliases = {}
    @assignments = {}
  end

  def import
    assign_curated
    assign_fallback
    prepare_changes
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ApplicationRecord.transaction do
      write_games
      write_aliases
      write_releases
    end
    @counts.merge(transaction_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, skipped_reasons: @skipped[:reasons])
  end

  private
    def assign_curated
      @rows.each do |row|
        existing = @releases[row[:sha1]]
        raise IdentityConflict, "#{row[:sha1]} already belongs to system #{existing.system}" if existing && existing.system != row[:system]

        mapping = @mappings[row[:sha1]]
        next unless mapping
        if SEEDS.key?(row[:sha1]) && SEEDS[row[:sha1]] != mapping[:public_id]
          raise IdentityConflict, "curated mapping conflicts with seed #{SEEDS[row[:sha1]]}"
        end
        if existing && existing.game_id != @games[mapping[:public_id]]&.id
          raise IdentityConflict, "#{row[:sha1]} cannot move to #{mapping[:public_id]}"
        end

        game = @games[mapping[:public_id]]
        if game && !game.catalog_curated && @releases.values.any? { |release| release.game_id == game.id && !mapping[:checksums].include?(release.sha1) }
          raise IdentityConflict, "curated ID #{game.public_id} belongs to a fallback identity"
        end
        game ||= add_game(public_id: mapping[:public_id], title: mapping[:title])
        game.title = mapping[:title]
        game.catalog_curated = true
        @assignments[row[:sha1]] = game
      end
    end

    def assign_fallback
      rows = @rows.reject { |row| @assignments.key?(row[:sha1]) }
      rows = rows.reject do |row|
        existing = @releases[row[:sha1]]
        game = existing && @games_by_id[existing.game_id]
        @assignments[row[:sha1]] = game if game&.catalog_curated
      end
      rows.group_by { |row| row[:key] }.each do |key, group|
        owners = group.filter_map { |row| @releases[row[:sha1]]&.game_id }
        owners << @aliases[key].game_id if @aliases.key?(key)
        owners.uniq!
        raise IdentityConflict, "fallback alias #{key} points to multiple games" if owners.size > 1

        seed_ids = group.filter_map { |row| SEEDS[row[:sha1]] }.uniq
        raise IdentityConflict, "fallback alias #{key} conflicts with seed IDs" if seed_ids.size > 1

        game = @games_by_id[owners.first] if owners.any?
        if game && seed_ids.any? && game.public_id != seed_ids.first
          raise IdentityConflict, "seed checksum already belongs to #{game.public_id}"
        end
        game ||= fallback_game(key: key, row: group.first, seed_id: seed_ids.first)
        raise IdentityConflict, "fallback alias #{key} belongs to curated game #{game.public_id}" if game.catalog_curated

        @new_aliases[key] = game unless @aliases.key?(key)
        group.each { |row| @assignments[row[:sha1]] = game }
      end
    end

    def fallback_game(key:, row:, seed_id:)
      public_id = seed_id || CatalogNameService.public_id(key: key, title: row[:title], system: row[:system])
      raise IdentityConflict, "new identity conflicts with public ID #{public_id}" if @games.key?(public_id)

      add_game(public_id: public_id, title: row[:title])
    end

    def add_game(public_id:, title:)
      @games[public_id] = Game.new(public_id: public_id, title: title)
    end

    def prepare_changes
      @affected_games = @assignments.values.uniq
      titles = Hash.new { |hash, key| hash[key] = {} }
      games_by_id = @affected_games.select(&:persisted?).index_by(&:id)
      @releases.each_value do |release|
        game = games_by_id[release.game_id]
        next unless game && !game.catalog_curated

        titles[game.public_id][release.sha1] = release.source_title ? CatalogNameService.display_title(title: release.source_title) : game.title
      end
      @rows.each do |row|
        game = @assignments.fetch(row[:sha1])
        titles[game.public_id][row[:sha1]] = row[:title] unless game.catalog_curated
      end
      @affected_games.each do |game|
        game.title = titles[game.public_id].values.min_by(&:b) unless game.catalog_curated
        game.validate!
      end
      @changed_titles = @affected_games.select { |game| game.persisted? && game.title_changed? }.map(&:id)
      @release_changes = @rows.map do |row|
        release = @releases[row[:sha1]] || Release.new(sha1: row[:sha1])
        release.assign_attributes(row.slice(:system, :region, :revision, :source_title))
        release.game = @assignments.fetch(row[:sha1])
        release.validate!
        release
      end
      @counts = {
        games: counts(records: @affected_games).merge(skipped: @skipped[:games]),
        releases: counts(records: @release_changes).merge(skipped: @skipped[:releases])
      }
    end

    def counts(records:)
      created = records.count(&:new_record?)
      updated = records.count { |record| record.persisted? && record.changed? }
      { created: created, updated: updated, unchanged: records.size - created - updated, skipped: 0 }
    end

    def write_games
      now = Time.current
      @affected_games.select(&:new_record?).each_slice(500) do |games|
        Game.insert_all!(games.map { |game| game.attributes.except("id", "created_at", "updated_at").merge("created_at" => now, "updated_at" => now) })
      end
      @affected_games.select { |game| game.persisted? && game.changed? }.each_slice(500) do |games|
        Game.upsert_all(games.map { |game| game.attributes.merge("updated_at" => now) }, unique_by: :id)
      end
      @game_ids = Game.where(public_id: @affected_games.map(&:public_id)).pluck(:public_id, :id).to_h
    end

    def write_aliases
      @new_aliases.to_a.each_slice(500) do |aliases|
        GameIdentity.insert_all!(aliases.map { |key, game| { key: key, game_id: @game_ids.fetch(game.public_id) } })
      end
    end

    def write_releases
      now = Time.current
      @release_changes.select { |release| release.new_record? || release.changed? }.each_slice(500) do |releases|
        Release.upsert_all(releases.map do |release|
          release.attributes.except("id").merge("game_id" => @game_ids.fetch(release.game.public_id), "created_at" => release.created_at || now, "updated_at" => now)
        end, unique_by: :sha1)
      end
      Release.where(game_id: @changed_titles).touch_all(time: now) if @changed_titles.any?
    end
end
