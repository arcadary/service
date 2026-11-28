class McpCatalogToolsService
  MAX_RESULT_BYTES = 1024 * 1024
  HELP = "Every collection is {items, next_cursor}; default 20, maximum 50. Pass only cursor to this same tool to read that collection's next page. Cursors expire after one hour; changed nested records require a fresh read."
  DESCRIPTIONS = {
    "search_games" => "Find games by case-insensitive title or alias substring and optional system. Returns game summaries with stable id, title and authoring_revision.",
    "get_game" => "Inspect a stable game id: canonical title and paginated title_aliases, source_title, authored_fields, authoring_revision, and releases (id, game_id, system, region, revision, authoring_revision).",
    "get_release" => "Inspect exactly one release by stable id or SHA-1. Returns canonical metadata, ordered media, source provenance, authored_fields, authoring_revision, effective startup and optional controller_profile with edition binding and text evidence. A shared SHA-1 raises ambiguous_release with paginated candidate summaries; select a candidate id.",
    "get_catalog_history" => "Read audit records newest first: id, operation, admin_name, created_at, reason and paginated record_changes with before/after authoring snapshots. Nested snapshot collections also have cursors."
  }.freeze

  def self.tools
    DESCRIPTIONS.map do |name, description|
      MCP::Tool.define(name: name, description: "#{description} #{HELP}",
        input_schema: input_schema(name: name), output_schema: output_schema(name: name),
        annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false }) do |server_context: nil, **arguments|
        McpCatalogToolsService.call(tool: name, arguments: arguments)
      end
    end + McpScreenshotToolsService.tools + McpPlaythroughToolsService.tools
  end

  def self.call(tool:, arguments:)
    raise McpCatalogReadService::InvalidInput unless JSONSchemer.schema(input_schema(name: tool)).valid?(arguments.stringify_keys)

    result = { "data" => McpCatalogReadService.call(tool: tool, **arguments) }
    response(result: result)
  rescue McpCatalogReadService::InvalidInput
    failure(code: "invalid_input")
  rescue McpCatalogReadService::NotFound
    failure(code: "not_found")
  rescue McpCatalogReadService::AmbiguousRelease => error
    failure(code: "ambiguous_release", candidates: error.candidates)
  end

  def self.failure(code:, candidates: nil)
    error = { "code" => code }
    error["candidates"] = candidates if candidates
    response(result: { "error" => error }, error: true)
  end
  private_class_method :failure

  def self.response(result:, error: false)
    serialized = JSON.generate(result)
    return failure(code: "invalid_input") if serialized.bytesize > MAX_RESULT_BYTES

    MCP::Tool::Response.new([ { type: "text", text: serialized } ], error: error, structured_content: result)
  end
  private_class_method :response

  def self.input_schema(name:)
    properties = {
      limit: { type: "integer", minimum: 1, maximum: 50, default: 20 },
      cursor: { type: "string", maxLength: 8192, description: "Opaque next_cursor from this tool; send without other arguments. Retains the original page size." }
    }
    case name
    when "search_games"
      properties.merge!(query: { type: "string", maxLength: 200, default: "" }, system: { type: "string", enum: Release::SYSTEMS })
    when "get_game"
      properties[:id] = { type: "string", maxLength: 200, description: "Stable game public id from search_games." }
    when "get_release"
      properties[:id] = { type: "string", maxLength: 200, description: "Stable release public id; selects one variant unambiguously." }
      properties[:sha1] = { type: "string", maxLength: 40, description: "40 hexadecimal characters. Shared media returns ambiguous_release and candidates." }
    end
    { type: "object", properties: properties, additionalProperties: false }
  end

  def self.output_schema(name:)
    {
      type: "object", additionalProperties: false,
      properties: {
        data: { anyOf: [ result_schema(name: name), { "$ref" => "#/$defs/page" } ] },
        error: { type: "object", additionalProperties: false, required: [ "code" ], properties: {
          code: { type: "string", enum: %w[invalid_input not_found ambiguous_release] },
          candidates: page_schema(items: release_summary_schema)
        } }
      },
      oneOf: [ { required: [ "data" ] }, { required: [ "error" ] } ],
      "$defs" => {
        page: { type: "object", additionalProperties: false, required: %w[items next_cursor], properties: {
          items: { type: "array", maxItems: 50, items: { "$ref" => "#/$defs/value" } },
          next_cursor: { type: [ "string", "null" ], description: "Opaque continuation for this collection, or null at its end." }
        } },
        value: { anyOf: [
          { type: [ "string", "number", "boolean", "null" ] },
          { "$ref" => "#/$defs/page" },
          { type: "object", additionalProperties: { "$ref" => "#/$defs/value" },
            not: { required: [ "items" ] } }
        ] }
      }
    }
  end

  def self.object_schema(properties:)
    { type: "object", additionalProperties: false, required: properties.keys.map(&:to_s), properties: properties }
  end
  private_class_method :object_schema

  def self.page_schema(items:)
    object_schema(properties: {
      items: { type: "array", maxItems: 50, items: items },
      next_cursor: { type: [ "string", "null" ], description: "Pass only this opaque cursor to the same tool; null means complete." }
    })
  end
  private_class_method :page_schema

  def self.release_summary_schema
    object_schema(properties: {
      id: { type: "string" }, game_id: { type: "string" }, system: { type: "string", enum: Release::SYSTEMS },
      region: { type: [ "string", "null" ] }, revision: { type: [ "string", "null" ] }, authoring_revision: { type: "integer" }
    })
  end
  private_class_method :release_summary_schema

  def self.result_schema(name:)
    case name
    when "search_games"
      page_schema(items: object_schema(properties: { id: { type: "string" }, title: { type: "string" }, authoring_revision: { type: "integer" } }))
    when "get_game"
      object_schema(properties: record_properties(type: "game").merge(
        canonical: object_schema(properties: { title: { type: "string" }, title_aliases: page_schema(items: { type: "string" }) }),
        source: object_schema(properties: { source_title: { type: [ "string", "null" ] } }),
        releases: page_schema(items: release_summary_schema)))
    when "get_release"
      object_schema(properties: record_properties(type: "release").merge(
        canonical: object_schema(properties: {
          game_id: { type: "string" }, system: { type: "string", enum: Release::SYSTEMS },
          region: { type: [ "string", "null" ] }, revision: { type: [ "string", "null" ] },
          controller_profile: { anyOf: [ { type: "null" }, controller_profile_schema ] },
          startup: object_schema(properties: {
            schema: { type: "integer", const: 1 }, boot: { type: "string" }, revision: { type: "string" },
            drives: { type: "object", additionalProperties: false, properties: { "8" => { type: "string" }, "9" => { type: "string" } } }
          }),
          media: page_schema(items: object_schema(properties: {
            key: { type: "string" }, position: { type: "integer" }, role: { type: "string", enum: %w[game save] },
            label: { type: [ "string", "null" ] }, sha1: { type: "string" }, size: { type: [ "integer", "null" ] },
            format: { type: [ "string", "null" ] }, crc32: { type: [ "string", "null" ] }, md5: { type: [ "string", "null" ] }
          }))
        }),
        source: object_schema(properties: %w[source_title source_system source_region source_revision].index_with { { type: [ "string", "null" ] } })))
    when "get_catalog_history"
      page_schema(items: object_schema(properties: {
        id: { type: "integer" }, operation: { type: "string" }, admin_name: { type: "string" },
        created_at: { type: "string" }, reason: { type: "string" }, record_changes: { "$ref" => "#/$defs/page" }
      }))
    end
  end
  private_class_method :result_schema

  def self.controller_profile_schema
    position = { type: "string", enum: ReleaseControllerProfileService::POSITIONS }
    evidence = page_schema(items: { type: "string", minLength: 1, maxLength: ReleaseControllerProfileService::MAX_CITATION_LENGTH })
    edition = { type: [ "string", "null" ], maxLength: ReleaseControllerProfileService::MAX_EDITION_LENGTH }
    object_schema(properties: {
      version: { type: "integer", const: 1 },
      binding: object_schema(properties: { system: { type: "string", const: "snes" }, region: edition, revision: edition }),
      layout: page_schema(items: object_schema(properties: {
        position: position, label: { type: "string", enum: ReleaseControllerProfileService::LABELS }, evidence: evidence
      })),
      prompts: page_schema(items: object_schema(properties: {
        letter: { type: "string", pattern: "^[A-Za-z]$", minLength: 1, maxLength: 1 }, position: position, evidence: evidence
      }))
    })
  end
  private_class_method :controller_profile_schema

  def self.record_properties(type:)
    { type: { type: "string", const: type }, id: { type: "string" }, authoring_revision: { type: "integer" },
      authored_fields: page_schema(items: { type: "string" }) }
  end
  private_class_method :record_properties
end
