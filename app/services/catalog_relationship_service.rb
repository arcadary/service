class CatalogRelationshipService
  MAX_ITEMS = 100
  OPERATIONS = %w[reassign_release merge_games restore_game correct_media].freeze

  attr_reader :records, :before, :preview

  def initialize(operation:, attributes:)
    @operation = operation
    @attributes = attributes
    @records = []
    @fields = Hash.new { |hash, key| hash[key] = [] }
    @requested = {}
  end

  def build
    prepare
    @records = @records.uniq.sort_by { |record| reference(record: record) }
    @games = @records.grep(Game).index_by(&:id)
    @media = @records.grep(MediaFile).index_by(&:sha1)
    @records.grep(Release).each do |release|
      release.game = @games.fetch(release.game_id)
      release.release_media.each { |medium| medium.media_file = @media.fetch(medium.media_file.sha1) }
    end
    @before = states
    before_resolutions = resolutions
    check_bound!(items: items_for(states: @before))
    yield @before if block_given?
    change
    @records.each do |record|
      record.authoring_revision += 1
      record.authored_fields = (record.authored_fields + @fields[record]).uniq.sort
      raise ActiveRecord::RecordInvalid, record unless record.valid?
    end
    after = states
    items = (items_for(states: @before) + items_for(states: after)).uniq.sort_by { |item| JSON.generate(item) }
    check_bound!(items: items)

    @preview = { "operation" => @operation, "attributes" => @attributes, "requested_ids" => @requested,
      "resolutions" => { "before" => before_resolutions, "after" => resolutions },
      "before" => @before, "after" => after, "affected_items" => items,
      "expected_revisions" => @before.to_h { |state| [ "#{state.fetch('type')}:#{state.fetch('id')}", state.fetch("authoring_revision") ] } }.deep_dup
    self
  rescue KeyError => error
    raise CatalogAuthoringService::InvalidInput, error.message
  end

  def persist!
    if @edited_release
      ReleaseMedium.where(release_id: @edited_release.id).update_all([ "position = -position, updated_at = ?", Time.current ])
      @edited_release.release_media.reject(&:new_record?).each(&:position_will_change!)
    end
    [ Game, MediaFile, Release ].each do |type|
      @records.grep(type).each(&:save!)
    end
  end

  private
    def prepare
      case @operation
      when "reassign_release"
        allow!(fields: %w[id game_id])
        @release = Release.find_by!(public_id: @attributes.fetch("id"))
        @requested["id"] = @release.public_id
        @source = add_scope(game: @release.game)
        @target = requested_game(field: "game_id")
        grouping_allowed!
      when "merge_games"
        allow!(fields: %w[id into_game_id])
        @source = requested_game(field: "id")
        @target = requested_game(field: "into_game_id")
        grouping_allowed!
      when "restore_game"
        allow!(fields: %w[id canonical_game_id release_ids title title_aliases canonical_title_aliases])
        @original = Game.find_by!(public_id: @attributes.fetch("id"))
        @target = Game.find_by!(public_id: @attributes.fetch("canonical_game_id"))
        unless @original.retired_into_game_id == @target.id && @target.retired_into_game_id.nil?
          raise CatalogAuthoringService::Conflict, "restore requires a direct retirement into the specified active game"
        end
        ids = @attributes.fetch("release_ids")
        unless ids.is_a?(Array) && ids.all?(String) && ids.uniq == ids
          raise CatalogAuthoringService::InvalidInput, "release_ids must be an explicit array of distinct IDs"
        end
        @selected = @target.releases.where(public_id: ids).to_a
        raise CatalogAuthoringService::Conflict, "selected releases must belong to the specified canonical game" unless @selected.size == ids.size

        @requested = @attributes.slice("id", "canonical_game_id", "release_ids")
        add_scope(game: @target)
      when "correct_release"
        allow!(fields: CatalogAuthoringService::RELEASE_FIELDS + %w[id media])
        @release = Release.find_by!(public_id: @attributes.fetch("id"))
        @requested["id"] = @release.public_id
        add_scope(game: @release.game)
        @release.media_files.each do |file|
          file.releases.each { |release| add_scope(game: release.game) }
        end
        media = @attributes.fetch("media")
        raise CatalogAuthoringService::InvalidInput, "media must be a nonempty ordered array" unless media.is_a?(Array) && media.any?

        media.each do |attributes|
          allow_medium!(attributes: attributes)
          file = MediaFile.find_by!(sha1: attributes.fetch("sha1"))
          @records << file
          file.releases.each { |release| add_scope(game: release.game) }
        end
      when "correct_media"
        allow!(fields: CatalogAuthoringService::MEDIA_FIELDS)
        @file = MediaFile.find_by!(sha1: @attributes.fetch("sha1"))
        raise CatalogAuthoringService::InvalidInput, "a correction needs at least one field" if @attributes.except("sha1").empty?

        @requested["sha1"] = @file.sha1
        @records << @file
        @file.releases.each { |release| add_scope(game: release.game) }
      else
        raise CatalogAuthoringService::InvalidInput, "operation does not support relationship preview"
      end
    end

    def requested_game(field:)
      id = @attributes.fetch(field)
      @requested[field] = id
      add_scope(game: Game.find_by!(public_id: id))
    end

    def add_scope(game:)
      canonical = CatalogGameIdentityService.resolve(game: game)
      return @records.find { |record| record.is_a?(Game) && record.id == canonical.id } if @records.include?(canonical)

      @records.concat(CatalogGameIdentityService.identities(game: canonical))
      canonical.releases.includes(release_media: :media_file).order(:public_id).each do |release|
        @records << release
        @records.concat(release.release_media.map(&:media_file))
      end
      @records.find { |record| record.is_a?(Game) && record.id == canonical.id }
    end

    def grouping_allowed!
      raise CatalogAuthoringService::Conflict, "grouping resolves to the same game" if @source == @target
      raise CatalogAuthoringService::Conflict, "screenshot licences differ" unless @source.screenshot_licence == @target.screenshot_licence
    end

    def change
      case @operation
      when "reassign_release"
        move(release: @records.find { |record| record == @release }, game: @target)
      when "merge_games"
        @records.grep(Release).select { |release| release.game_id == @source.id }.each { |release| move(release: release, game: @target) }
        assign(record: @target, attributes: { "title_aliases" => (@target.title_aliases + [ @source.title ] + @source.title_aliases).uniq - [ @target.title ] })
        assign(record: @source, attributes: { "retired_into_game" => @target })
      when "restore_game"
        original = @games.fetch(@original.id)
        assign(record: original, attributes: @attributes.slice("title", "title_aliases").merge("retired_into_game" => nil))
        assign(record: @games.fetch(@target.id), attributes: { "title_aliases" => @attributes.fetch("canonical_title_aliases") }) if @attributes.key?("canonical_title_aliases")
        @records.grep(Release).select { |release| @selected.include?(release) }.each { |release| move(release: release, game: original) }
      when "correct_release"
        @edited_release = @records.find { |record| record == @release }
        assign(record: @edited_release, attributes: @attributes.slice(*CatalogAuthoringService::RELEASE_FIELDS))
        replace_media
      when "correct_media"
        assign(record: @media.fetch(@file.sha1), attributes: @attributes.except("sha1"))
      end
    end

    def move(release:, game:)
      assign(record: release, attributes: { "game" => @games.fetch(game.id) })
    end

    def replace_media
      existing = @edited_release.release_media.index_by(&:key)
      metadata = {}
      media = @attributes.fetch("media").map do |attributes|
        file = @media.fetch(attributes.fetch("sha1"))
        values = attributes.slice(*CatalogAuthoringService::MEDIA_FIELDS).except("sha1")
        if metadata.key?(file.sha1) && metadata[file.sha1] != values
          raise CatalogAuthoringService::Conflict, "shared checksum metadata differs within request"
        end
        metadata[file.sha1] = values
        assign(record: file, attributes: values)
        medium = existing[attributes.fetch("key")]
        if medium && medium.media_file != file
          raise CatalogAuthoringService::Conflict, "a surviving medium key cannot change checksum"
        end
        medium ||= @edited_release.release_media.build
        medium.assign_attributes(attributes.slice("key", "position", "label", "role").merge("media_file" => file))
        medium
      end
      raise CatalogAuthoringService::InvalidInput, "media keys must be distinct" unless media.uniq.size == media.size

      @edited_release.release_media.each { |medium| medium.mark_for_destruction unless media.include?(medium) }
      @fields[@edited_release] << "media"
    end

    def assign(record:, attributes:)
      record.assign_attributes(attributes)
      @fields[record].concat(attributes.keys.map { |field| { "game" => "game_id", "retired_into_game" => "retired_into_game_id" }.fetch(field, field) })
    end

    def states
      @records.map { |record| CatalogAuthoringReadService.record(record, games: @games) }.deep_dup
    end

    def resolutions
      @games.values.sort_by(&:public_id).to_h do |game|
        [ game.public_id, CatalogGameIdentityService.resolve(game: game, games: @games).public_id ]
      end
    end

    def items_for(states:)
      states.flat_map do |state|
        items = [ { "type" => state.fetch("type"), "id" => state.fetch("id") } ]
        if state.fetch("type") == "game"
          items.concat(state.dig("canonical", "title_aliases").map { |title| { "type" => "alias", "id" => [ state.fetch("id"), title ] } })
          items.concat(state.dig("identity", "importer_keys").map { |key| { "type" => "importer_key", "id" => key } })
        elsif state.fetch("type") == "release"
          items.concat(state.dig("canonical", "media").map { |medium| { "type" => "membership", "id" => [ state.fetch("id"), medium.fetch("key") ] } })
        end
        items
      end
    end

    def reference(record:)
      case record
      when Game then "game:#{record.public_id}"
      when Release then "release:#{record.public_id}"
      when MediaFile then "media:#{record.sha1}"
      end
    end

    def check_bound!(items:)
      raise CatalogAuthoringService::InvalidInput, "preview exceeds #{MAX_ITEMS} distinct affected items" if items.uniq.size > MAX_ITEMS
    end

    def allow!(fields:)
      raise CatalogAuthoringService::InvalidInput, "unsupported fields" unless (@attributes.keys - fields).empty?
    end

    def allow_medium!(attributes:)
      unless attributes.is_a?(Hash) && (attributes.keys - CatalogAuthoringService::MEDIUM_FIELDS).empty?
        raise CatalogAuthoringService::InvalidInput, "unsupported medium fields"
      end
      %w[key position role sha1].each { |field| attributes.fetch(field) }
    end
end
