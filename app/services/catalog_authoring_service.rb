require "digest"

class CatalogAuthoringService
  class InvalidInput < StandardError; end
  class Conflict < StandardError; end
  class MissingAdminName < StandardError; end

  GAME_FIELDS = %w[title title_aliases].freeze
  RELEASE_FIELDS = %w[system region revision startup].freeze
  MEDIA_FIELDS = %w[sha1 size format crc32 md5].freeze
  MEDIUM_FIELDS = (MEDIA_FIELDS + %w[key position label role]).freeze
  OPERATIONS = %w[create_game create_media create_release correct_game correct_release].freeze

  def self.call(operation:, attributes:, expected_revisions:, reason:, idempotency_key:)
    new(operation: operation, attributes: attributes, expected_revisions: expected_revisions, reason: reason, idempotency_key: idempotency_key).call
  end

  def initialize(operation:, attributes:, expected_revisions:, reason:, idempotency_key:)
    @operation = operation.to_s
    @attributes = attributes.deep_stringify_keys
    @expected = expected_revisions.deep_stringify_keys
    @reason = reason
    @key = idempotency_key
    @before = {}
    @affected = []
  end

  def call
    admin_name = ENV["CATALOG_ADMIN_NAME"].to_s.strip
    raise MissingAdminName, "CATALOG_ADMIN_NAME must be configured" if admin_name.empty?
    raise InvalidInput, "unknown operation" unless OPERATIONS.include?(@operation)
    raise InvalidInput, "reason and idempotency key are required" unless @reason.is_a?(String) && @reason.present? && @key.is_a?(String) && @key.present?

    @fingerprint = Digest::SHA256.hexdigest(JSON.generate(canonical(value: [ @operation, @attributes, @expected, @reason ])))
    ApplicationRecord.transaction(requires_new: true) do
      entry = CatalogMutation.create!(idempotency_key: @key, fingerprint: @fingerprint, operation: @operation, admin_name: admin_name, reason: @reason)
      perform
      states = @affected.map { |record| CatalogAuthoringReadService.record(record.reload) }
      changes = states.map { |state| { "before" => @before[reference(state: state)], "after" => state } }
      result = { "audit_id" => entry.id, "records" => states }
      entry.update!(record_changes: changes, result: result)
      entry.result
    end
  rescue ActiveRecord::RecordNotUnique
    saved = CatalogMutation.find_by(idempotency_key: @key)
    raise Conflict, "identity already exists" unless saved
    raise Conflict, "idempotency key was used for a different request" unless saved.fingerprint == @fingerprint

    saved.result
  end

  private
    def perform
      case @operation
      when "create_game"
        allow!(attributes: @attributes, fields: GAME_FIELDS + %w[id])
        no_extra_revisions!(references: [])
        game = Game.new(@attributes.except("id").merge("public_id" => @attributes.fetch("id")))
        save_authored(record: game, fields: @attributes.keys & GAME_FIELDS)
      when "create_media"
        allow!(attributes: @attributes, fields: MEDIA_FIELDS)
        no_extra_revisions!(references: [])
        save_authored(record: MediaFile.new(@attributes), fields: @attributes.keys)
      when "create_release"
        create_release
      when "correct_game"
        correct(record: Game.find_by!(public_id: @attributes.fetch("id")), fields: GAME_FIELDS)
      when "correct_release"
        correct(record: Release.includes(release_media: :media_file).find_by!(public_id: @attributes.fetch("id")), fields: RELEASE_FIELDS)
      end
    end

    def create_release
      allow!(attributes: @attributes, fields: RELEASE_FIELDS + %w[game_id media])
      game = Game.find_by!(public_id: @attributes.fetch("game_id"))
      expect_current!(record: game)
      media = @attributes.fetch("media")
      raise InvalidInput, "media must be a nonempty ordered array" unless media.is_a?(Array) && media.any?

      release = Release.new(@attributes.slice(*RELEASE_FIELDS).merge("game" => game))
      media.each do |attributes|
        allow!(attributes: attributes, fields: MEDIUM_FIELDS)
        file = MediaFile.new(attributes.slice(*MEDIA_FIELDS))
        raise Conflict, "existing media attachment belongs to relationship authoring" if MediaFile.exists?(sha1: file.sha1)

        file.authoring_revision = 1
        file.authored_fields = attributes.keys & MEDIA_FIELDS
        release.release_media.build(attributes.except(*MEDIA_FIELDS).merge("media_file" => file))
      end
      no_extra_revisions!(references: [ "game:#{game.public_id}" ])
      save_authored(record: release, fields: @attributes.keys & RELEASE_FIELDS)
      release.release_media.each { |medium| @affected << medium.media_file }
      save_authored(record: game, fields: [])
    end

    def correct(record:, fields:)
      allow!(attributes: @attributes, fields: fields + %w[id])
      changes = @attributes.except("id")
      raise InvalidInput, "a correction needs at least one field" if changes.empty?

      expect_current!(record: record)
      state = CatalogAuthoringReadService.record(record)
      no_extra_revisions!(references: [ reference(state: state) ])
      record.assign_attributes(changes)
      save_authored(record: record, fields: changes.keys)
    end

    def expect_current!(record:)
      state = CatalogAuthoringReadService.record(record)
      key = reference(state: state)
      expected = @expected[key]
      raise Conflict, "missing or stale authoring revision for #{key}" unless expected.is_a?(Integer) && expected == record.authoring_revision

      @before[key] = state
    end

    def save_authored(record:, fields:)
      record.authoring_revision += 1
      record.authored_fields = (record.authored_fields + fields).uniq.sort
      record.save!
      @affected << record
    end

    def no_extra_revisions!(references:)
      raise InvalidInput, "unexpected revision targets" unless (@expected.keys - references).empty?
    end

    def allow!(attributes:, fields:)
      raise InvalidInput, "unsupported fields" unless attributes.is_a?(Hash) && (attributes.keys - fields).empty?
    end

    def reference(state:)
      "#{state.fetch('type')}:#{state.fetch('id')}"
    end

    def canonical(value:)
      case value
      when Hash then value.keys.sort.to_h { |key| [ key, canonical(value: value.fetch(key)) ] }
      when Array then value.map { |item| canonical(value: item) }
      else value
      end
    end
end
