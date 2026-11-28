class McpCompatibilityToolsService
  ERRORS = {
    CompatibilityResult::InvalidInput => "invalid_input", Release::ReleaseNotFound => "not_found",
    CompatibilityResult::TargetMismatch => "target_mismatch", CompatibilityResult::RetryConflict => "retry_conflict"
  }.freeze
  DESCRIPTION = "Record what a named reviewer saw after playing one exact file of one stable release on one device class " \
    "(steam_machine or steam_deck) with one core and version, under the release's current startup_revision (from get_release or get_compatibility). " \
    "status is works, attention (a recorded problem such as performance, explained in a required one-sentence reason), does_not_work (reason optional), or unknown to withdraw an earlier result for that device without claiming the opposite. " \
    "owns_file must be true: the reviewer owns that exact file. Optional requires_input lists input devices besides the controller " \
    "(keyboard, mouse) the release needs to be playable on that device class; it is separate from status, and the launcher shows attention while one is not connected. Results are append-only history; the newest result per device " \
    "whose startup_revision is still current is what the public release JSON shows as release.compatibility, and anything else is unknown. " \
    "playthrough_ids attach this release's private playthroughs as evidence; they stay internal. A result never applies to the other device class. Recording refreshes the release's public ETag. Identical retries with the same " \
    "retry_key return the original result; changed arguments with a used key return retry_conflict. A file outside the release or a stale " \
    "startup_revision returns target_mismatch."

  def self.tools
    [ MCP::Tool.define(name: "record_compatibility_result", description: DESCRIPTION,
      input_schema: input_schema, output_schema: output_schema,
      annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false }) do |server_context: nil, **arguments|
      McpCompatibilityToolsService.call(arguments: arguments)
    end ]
  end

  def self.call(arguments:)
    raise CompatibilityResult::InvalidInput unless JSONSchemer.schema(input_schema).valid?(arguments.stringify_keys)

    result = CompatibilityService.record(**arguments.symbolize_keys)
    release = CompatibilityService.find_release(release_id: result.release.public_id)
    McpToolService.response(result: { data: { release_id: release.public_id, result: CompatibilityResultDecorator.decorate(result).history_json,
      current: CompatibilityResultDecorator.current(CompatibilityService.current(release: release)) } })
  rescue *ERRORS.keys => error
    McpToolService.response(result: { error: { code: ERRORS.fetch(error.class) } }, error: true)
  end

  def self.input_schema
    text = ->(maximum) { { type: "string", minLength: 1, maxLength: maximum, pattern: "\\S" } }
    {
      type: "object", additionalProperties: false, required: CompatibilityService::FIELDS,
      properties: {
        release_id: text.(200).merge(description: "Stable release public id; a shared checksum never selects a release."),
        sha1: { type: "string", minLength: 40, maxLength: 40, pattern: "^[0-9a-fA-F]{40}$", description: "The exact file played; must be a medium of the release." },
        device: { type: "string", enum: CompatibilityResult::DEVICES },
        status: { type: "string", enum: CompatibilityResult::STATUSES },
        core: { type: "string", pattern: "^[a-z0-9][a-z0-9_.-]{0,63}$", description: "Core identifier, for example mesen." },
        core_version: text.(CompatibilityResult::SHORT_LENGTH).merge(description: "The core's version or build as the launcher reports it."),
        startup_revision: { type: "string", pattern: "^[0-9a-f]{64}$", description: "The release's current startup.revision, the launch configuration tested." },
        tested_at: { type: "string", format: "date-time", maxLength: 64, description: "When it was played, ISO 8601 with a time zone, not in the future." },
        observed: text.(CompatibilityResult::TEXT_LENGTH).merge(description: "What the reviewer saw, one paragraph without control characters. Public."),
        limits: text.(CompatibilityResult::TEXT_LENGTH).merge(description: "What the test did not cover. Public."),
        reviewer: text.(CompatibilityResult::SHORT_LENGTH).merge(description: "The reviewer's display name. Internal, never public."),
        owns_file: { type: "boolean", enum: [ true ], description: "The reviewer owns this exact file." },
        reason: text.(CompatibilityResult::REASON_LENGTH).merge(description: "One short public sentence on why: required for attention (for example a performance problem), optional for does_not_work, absent for works and unknown."),
        requires_input: { type: "array", uniqueItems: true, maxItems: CompatibilityResult::INPUTS.size, items: { type: "string", enum: CompatibilityResult::INPUTS },
          description: "Optional, default none: input devices besides the controller that the release needs to be playable on this device class. Public." },
        playthrough_ids: { type: "array", uniqueItems: true, maxItems: 20, items: text.(200),
          description: "Optional: ids of this release's private playthroughs (from upload_video) that show the result. Internal, never public." },
        retry_key: text.(200)
      }
    }
  end

  def self.output_schema
    {
      type: "object", additionalProperties: false,
      oneOf: [ { required: [ "data" ] }, { required: [ "error" ] } ],
      properties: {
        data: McpToolService.object_schema(properties: { release_id: { type: "string" }, result: history_item_schema, current: current_schema }),
        error: McpToolService.object_schema(properties: { code: { type: "string", enum: ERRORS.values } })
      }
    }
  end

  def self.current_schema
    result = McpToolService.object_schema(properties: {
      status: { type: "string", enum: %w[works attention does_not_work] }, reason: { type: [ "string", "null" ] }, core: { type: "string" }, core_version: { type: "string" },
      startup_revision: { type: "string" }, tested_at: { type: "string", format: "date-time" }, observed: { type: "string" }, limits: { type: "string" },
      requires_input: inputs_schema
    })
    device = { oneOf: [ McpToolService.object_schema(properties: { status: { type: "string", enum: [ "unknown" ] } }), result ] }
    McpToolService.object_schema(properties: CompatibilityResult::DEVICES.index_with { device })
  end

  def self.history_item_schema
    McpToolService.object_schema(properties: {
      id: { type: "integer" }, device: { type: "string", enum: CompatibilityResult::DEVICES }, status: { type: "string", enum: CompatibilityResult::STATUSES },
      sha1: { type: "string" }, reason: { type: [ "string", "null" ] }, core: { type: "string" }, core_version: { type: "string" }, startup_revision: { type: "string" },
      observed: { type: "string" }, limits: { type: "string" }, requires_input: inputs_schema, reviewer: { type: "string" },
      playthrough_ids: { type: "array", items: { type: "string" } },
      tested_at: { type: "string", format: "date-time" }, recorded_at: { type: "string", format: "date-time" }
    })
  end

  def self.inputs_schema
    { type: "array", uniqueItems: true, items: { type: "string", enum: CompatibilityResult::INPUTS } }
  end
  private_class_method :inputs_schema

end
