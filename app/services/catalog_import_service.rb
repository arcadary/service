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
    @existing_releases = Release.includes(release_media: :media_file).to_a
    @releases = @existing_releases.each_with_object({}) do |release, files|
      release.release_media.each { |medium| files[medium.media_file.sha1] = release }
    end
    @media_files = MediaFile.all.index_by(&:sha1)
    @detached = (@media_files.keys - @releases.keys).to_set
    @aliases = GameIdentity.all.index_by(&:key)
    @new_aliases = {}
    @assignments = {}
    @release_sources = {}
    @divergences = []
  end

  def import
    refuse_set_imports
    assign_curated
    assign_fallback
    prepare_changes
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ApplicationRecord.transaction do
      write_games
      write_aliases
      write_releases
      write_media
    end
    @counts.merge(transaction_seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started,
      skipped_reasons: @skipped[:reasons], divergences: @divergences.uniq)
  end

  private
    def resolve(game:)
      CatalogGameIdentityService.resolve(game: game, games: @games_by_id)
    end

    def refuse_set_imports
      checksums = @rows.map { |row| row[:sha1] }.to_set
      memberships = ReleaseMedium.group(:media_file_id).count
      @existing_releases.each do |release|
        matched = release.release_media.select { |medium| checksums.include?(medium.media_file.sha1) }
        next if matched.empty?

        if release.release_media.size != 1 || memberships.fetch(matched.first.media_file_id) > 1
          raise IdentityConflict, "release #{release.public_id}: importing media #{matched.map { |medium| medium.media_file.sha1 }.join(', ')} already in a multi-disk or shared release is not supported"
        end
      end
    end

    def assign_curated
      @rows.each do |row|
        existing = @releases[row[:sha1]]
        if existing && existing.system != row[:system] && !existing.authored_fields.include?("system")
          raise IdentityConflict, "#{row[:sha1]} already belongs to system #{existing.system}; source #{row[:system]}"
        end

        mapping = @mappings[row[:sha1]]
        next unless mapping
        next if @detached.include?(row[:sha1])
        if SEEDS.key?(row[:sha1]) && SEEDS[row[:sha1]] != mapping[:public_id]
          raise IdentityConflict, "curated mapping conflicts with seed #{SEEDS[row[:sha1]]}"
        end

        game = @games[mapping[:public_id]]
        if existing && resolve(game: @games_by_id.fetch(existing.game_id)) != (game && resolve(game: game)) && !existing.authored_fields.include?("game_id")
          raise IdentityConflict, "release #{existing.public_id} checksum #{row[:sha1]} cannot move to #{mapping[:public_id]} (#{mapping[:title]})"
        end
        if game && !game.catalog_curated && !game.authored_fields.include?("grouping") && @existing_releases.any? { |release| release.game_id == game.id && !mapping[:checksums].include?(release.sha1) }
          raise IdentityConflict, "curated ID #{game.public_id} belongs to a fallback identity"
        end
        game ||= add_game(public_id: mapping[:public_id], title: mapping[:title])
        game.catalog_curated = true
        @assignments[row[:sha1]] = game
      end
    end

    def assign_fallback
      rows = @rows.reject { |row| @assignments.key?(row[:sha1]) || @detached.include?(row[:sha1]) }
      rows = rows.reject do |row|
        existing = @releases[row[:sha1]]
        owner = existing && @games_by_id[existing.source_game_id || existing.game_id]
        @assignments[row[:sha1]] = owner if owner&.catalog_curated
      end
      rows.group_by { |row| row[:key] }.each do |key, group|
        owners = group.filter_map do |row|
          release = @releases[row[:sha1]]
          @games_by_id[release.source_game_id || release.game_id] if release
        end
        key_owner = @games_by_id.fetch(@aliases[key].game_id) if @aliases.key?(key)
        owners << key_owner if key_owner
        canonical = owners.map { |game| resolve(game: game) }.uniq
        if canonical.size > 1
          raise IdentityConflict, "fallback alias #{key} points to multiple games #{owners.map(&:public_id).join(', ')}; source checksums #{group.map { |row| row[:sha1] }.join(', ')}"
        end

        seed_ids = group.filter_map { |row| SEEDS[row[:sha1]] }.uniq
        raise IdentityConflict, "fallback alias #{key} conflicts with seed IDs" if seed_ids.size > 1

        game = key_owner || owners.first
        if game && seed_ids.any? && game.public_id != seed_ids.first && !game.authored_fields.include?("grouping")
          raise IdentityConflict, "seed checksum already belongs to #{game.public_id}"
        end
        game ||= fallback_game(key: key, row: group.first, seed_id: seed_ids.first)
        if game.catalog_curated && !game.authored_fields.include?("grouping")
          raise IdentityConflict, "fallback alias #{key} belongs to curated game #{game.public_id}"
        end

        @new_aliases[key] = game unless @aliases.key?(key)
        group.each do |row|
          release = @releases[row[:sha1]]
          owner = release && @games_by_id[release.source_game_id]
          @assignments[row[:sha1]] = owner || game
        end
      end
    end

    def fallback_game(key:, row:, seed_id:)
      public_id = seed_id || CatalogNameService.public_id(key: key, title: row[:title], system: row[:system])
      raise IdentityConflict, "new identity #{key} conflicts with public ID #{public_id}" if @games.key?(public_id)

      add_game(public_id: public_id, title: row[:title])
    end

    def add_game(public_id:, title:)
      @games[public_id] = Game.new(public_id: public_id, title: title)
    end

    def prepare_changes
      prepare_titles
      @release_changes = []
      @rows.each do |row|
        prepare_media(row: row)
        if @detached.include?(row[:sha1])
          divergence(record: @media_files.fetch(row[:sha1]), field: "membership", source: "single release", effective: [])
          next
        end

        release = @releases[row[:sha1]] || Release.new(sha1: row[:sha1])
        file = @media_files.fetch(row[:sha1])
        release.release_media.each { |medium| medium.media_file = file if medium.media_file.sha1 == file.sha1 }
        release.release_media.build(key: "main", position: 1, role: "game", media_file: file) if release.new_record?
        owner = @assignments.fetch(row[:sha1])
        game = resolve(game: owner)
        if release.persisted? && release.authored_fields.include?("game_id")
          divergence(record: release, field: "game_id", source: owner.public_id, effective: @games_by_id.fetch(release.game_id).public_id)
          game = @games_by_id.fetch(release.game_id)
        elsif owner != game
          divergence(record: release, field: "game_id", source: owner.public_id, effective: game.public_id)
        end
        release.game = game
        release.source_game_id = owner.id
        @release_sources[release.public_id] = owner
        apply_source(record: release, attributes: row.slice(:system, :region, :revision))
        release.source_title = row[:source_title]
        release.validate!
        release.authoring_revision += 1 if release.persisted? && file.changed?
        @release_changes << release
      end
      @affected_games = (@assignments.values + @release_changes.map(&:game)).uniq
      @new_aliases.each_value { |game| game.authoring_revision += 1 unless game.changed? }
      [ *@affected_games, *@release_changes, *@media_files.values ].each do |record|
        record.authoring_revision += 1 if record.persisted? && record.changed? && !record.authoring_revision_changed?
      end
      @counts = {
        games: counts(records: @affected_games).merge(skipped: @skipped[:games]),
        releases: counts(records: @release_changes).merge(skipped: @skipped[:releases])
      }
    end

    def prepare_titles
      titles = Hash.new { |hash, key| hash[key] = {} }
      @existing_releases.each do |release|
        owner = @games_by_id[release.source_game_id || release.game_id]
        titles[owner][release.sha1] = release.source_title ? CatalogNameService.display_title(title: release.source_title) : owner.title
      end
      @rows.each do |row|
        owner = @assignments[row[:sha1]]
        titles[owner][row[:sha1]] = row[:title] if owner
      end
      @assignments.values.uniq.each do |game|
        mapping = @rows.filter_map { |row| @mappings[row[:sha1]] if @assignments[row[:sha1]] == game }.first
        source = mapping ? mapping[:title] : titles[game].values.min_by(&:b)
        game.source_title = source
        if game.retired_into_game_id || (game.authored_fields & %w[title grouping]).any?
          divergence(record: game, field: "title", source: source, effective: game.title)
        else
          game.title = source
        end
        game.validate!
      end
      @changed_titles = @assignments.values.uniq.select { |game| game.persisted? && game.title_changed? }.map(&:id)
    end

    def prepare_media(row:)
      file = @media_files[row[:sha1]] || MediaFile.new(sha1: row[:sha1])
      apply_source(record: file, attributes: row.slice(:size, :format, :crc32, :md5))
      file.validate!
      @media_files[row[:sha1]] = file
    end

    def apply_source(record:, attributes:)
      attributes.each do |field, value|
        record["source_#{field}"] = value
        if record.authored_fields.include?(field.to_s)
          divergence(record: record, field: field.to_s, source: value, effective: record[field])
        else
          record[field] = value
        end
      end
    end

    def divergence(record:, field:, source:, effective:)
      return if source == effective

      type, id = case record
      when Game then [ "game", record.public_id ]
      when Release then [ "release", record.public_id ]
      when MediaFile then [ "media", record.sha1 ]
      end
      @divergences << { type: type, id: id, field: field, source_value: source, effective_value: effective }
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
          release.attributes.except("id").merge("game_id" => @game_ids.fetch(release.game.public_id),
            "source_game_id" => @game_ids.fetch(@release_sources.fetch(release.public_id).public_id),
            "created_at" => release.created_at || now, "updated_at" => now)
        end, unique_by: :public_id)
      end
      Release.where(game_id: @changed_titles).touch_all(time: now) if @changed_titles.any?
    end

    def write_media
      now = Time.current
      changed = @rows.map { |row| @media_files.fetch(row[:sha1]) }.select { |file| file.new_record? || file.changed? }
      changed.each_slice(500) do |files|
        MediaFile.upsert_all(files.map { |file| file.attributes.except("id").merge("created_at" => file.created_at || now, "updated_at" => now) }, unique_by: :sha1)
      end
      media_ids = MediaFile.where(sha1: @rows.map { |row| row[:sha1] }).pluck(:sha1, :id).to_h
      release_ids = Release.where(public_id: @release_changes.map(&:public_id)).pluck(:public_id, :id).to_h
      @release_changes.select(&:new_record?).each_slice(500) do |releases|
        ReleaseMedium.insert_all!(releases.map do |release|
          { release_id: release_ids.fetch(release.public_id), media_file_id: media_ids.fetch(release.sha1), key: "main", position: 1, role: "game", created_at: now, updated_at: now }
        end)
      end
      public_changes = changed.select { |file| (file.changed - %w[authoring_revision source_size source_format source_crc32 source_md5]).any? }
      Release.joins(:media_files).where(media_files: { sha1: public_changes.map(&:sha1) }).touch_all(time: now) if public_changes.any?
    end
end
