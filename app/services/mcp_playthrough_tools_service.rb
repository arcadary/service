class McpPlaythroughToolsService
  ERRORS = {
    PlaythroughStage::Expired => "stage_expired",
    PlaythroughStage::InvalidDeclaration => "invalid_declaration", PlaythroughStage::TooLarge => "stage_too_large",
    PlaythroughStage::TargetMismatch => "target_mismatch", PlaythroughStage::Conflict => "stage_conflict",
    Release::ReleaseNotFound => "not_found"
  }.freeze

  def self.tools
    [ MCP::Tool.define(name: "begin_playthrough_staging",
      description: "Begin private HLS staging for one stable release_id and exact source_sha1, capture provenance, retry_key and immutable manifest. The source or explicitly verified payload must belong to that release; mismatch evidence must name both checksums and the authenticated verifier. Limits together: 1 MiB UTF-8 compact argument JSON before normalization (excluding the RPC envelope), 4096 objects, 8 MiB each, 4 GiB total. Returns incomplete/received object progress, declared_at, stage_expires_at (declaration plus 24 hours), and a capability with expires_at exactly 900 seconds after issuance, even beyond the stage deadline. Identical normalized replay renews before the deadline, preserving the deadline, progress and older capabilities; at the deadline it returns stage_expired without a capability. Changed declarations return stage_conflict, including after pruning; retry keys stay reserved. PUT raw objects with current Basic credentials plus X-Arcadary-Upload-Capability, never in a URL. Invalid capability or unknown object returns 403 before stage expiry is checked; valid declared-object authorization on expired/reclaimed stages returns 410 before body/storage reads. Metadata GET never renews; it reports validation and expired/reclaimed receipts. Concurrent attempts use renewable fenced 15-minute leases. Hourly bounded cleanup retains identity/evidence and permanent attempt tombstones, pruning manifests and bytes after absence checks; late writes reopen expired receipts until reclaimed again. No publication.",
      input_schema: input_schema, output_schema: output_schema,
      annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: false }) do |server_context: nil, **arguments|
      McpPlaythroughToolsService.call(arguments: arguments)
    end ]
  end

  def self.call(arguments:)
    stage = PlaythroughStagingService.create(declaration: arguments, verifier: ENV["VALIDATION_REVIEWER_USERNAME"])
    result = PlaythroughStageDecorator.decorate(stage).summary.merge(PlaythroughUploadAuthorizationService.issue(stage: stage))
    response(result: { data: result })
  rescue *ERRORS.keys => error
    response(result: { error: { code: ERRORS.fetch(error.class) } }, error: true)
  end

  def self.input_schema
    checksum = { type: "string", pattern: "^[0-9a-f]{40}$", minLength: 40, maxLength: 40 }
    {
      type: "object", additionalProperties: false, required: %w[retry_key release_id source_sha1 capture manifest],
      properties: {
        retry_key: { type: "string", minLength: 1, maxLength: 200 },
        release_id: { type: "string", minLength: 1, maxLength: 200, description: "Stable release public_id, never a title or checksum selector." },
        source_sha1: checksum,
        capture: object_schema(properties: {
          tool: { type: "string", minLength: 1, maxLength: 200 }, version: { type: "string", minLength: 1, maxLength: 200 },
          captured_at: { type: "string", format: "date-time", maxLength: 64 }
        }),
        verification: {
          type: "object", additionalProperties: false, required: %w[source_sha1 payload_sha1 relationship method result verifier verified_at evidence],
          properties: {
            source_sha1: checksum, payload_sha1: checksum,
            relationship: { type: "string", enum: %w[trailing_padding verified_equivalence] }, removed_bytes: { type: "integer", minimum: 1 },
            method: { type: "string", minLength: 1, maxLength: 8000 }, result: { type: "string", enum: [ "success" ] },
            verifier: { type: "string", minLength: 1, maxLength: 8000 }, verified_at: { type: "string", format: "date-time", maxLength: 64 },
            evidence: { type: "string", minLength: 1, maxLength: 8000 }
          }
        },
        manifest: { type: "array", minItems: 1, maxItems: PlaythroughStageInputService::OBJECT_COUNT, items: object_schema(properties: {
          path: { type: "string", minLength: 1, maxLength: 1024 },
          byte_size: { type: "integer", minimum: 1, maximum: PlaythroughStageInputService::OBJECT_BYTES },
          sha256: { type: "string", pattern: "^[0-9a-f]{64}$", minLength: 64, maxLength: 64 },
          content_type: { type: "string", minLength: 1, maxLength: 200 }
        }) }
      }
    }
  end

  def self.output_schema
    {
      type: "object", additionalProperties: false,
      oneOf: [ { required: [ "data" ] }, { required: [ "error" ] } ],
      properties: {
        data: object_schema(properties: {
          staging_id: { type: "string" }, release_id: { type: "string" }, package_sha256: { type: "string", pattern: "^[0-9a-f]{64}$" },
          state: { type: "string", enum: %w[incomplete received] },
          objects: { type: "array", maxItems: PlaythroughStageInputService::OBJECT_COUNT, items: object_schema(properties: {
            object_id: { type: "string" }, path: { type: "string" }, received: { type: "boolean" }
          }) },
          capability: { type: "string" }, expires_at: { type: "string", format: "date-time" },
          declared_at: { type: "string", format: "date-time" }, stage_expires_at: { type: "string", format: "date-time" }
        }),
        error: object_schema(properties: { code: { type: "string", enum: ERRORS.values } })
      }
    }
  end

  def self.object_schema(properties:)
    { type: "object", additionalProperties: false, required: properties.keys.map(&:to_s), properties: properties }
  end
  private_class_method :object_schema

  def self.response(result:, error: false)
    serialized = JSON.generate(result)
    raise PlaythroughStage::TooLarge if serialized.bytesize > McpCatalogToolsService::MAX_RESULT_BYTES

    MCP::Tool::Response.new([ { type: "text", text: serialized } ], error: error, structured_content: result)
  end
  private_class_method :response
end
