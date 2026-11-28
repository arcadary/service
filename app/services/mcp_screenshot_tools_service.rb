class McpScreenshotToolsService
  ERRORS = {
    ScreenshotStage::InvalidInput => "invalid_input", Release::ReleaseNotFound => "not_found",
    ScreenshotStage::TargetMismatch => "target_mismatch", ScreenshotStage::Unavailable => "staged_image_unavailable",
    ScreenshotStage::Consumed => "staged_image_consumed", Screenshot::UploadsDisabled => "uploads_disabled",
    Screenshot::StorageUnavailable => "storage_unavailable"
  }.freeze

  def self.tools
    [ MCP::Tool.define(name: "publish_screenshot",
      description: "Publish a private PNG stage issued by authenticated HTTP screenshot ingest. Supply its exact stable release_id, source_sha1 (including secondary/shared media) and kind; the checksum must still belong to that release. Never resolve a shared checksum alone. First success atomically transfers the blob and consumes the stage. It expires exactly 24 hours after ingest, unchanged by reads or failures. Retry a failed publication with the same binding before expiry; successful retries return staged_image_consumed until expiry, then staged_image_unavailable. Replaces this release/kind, using the game's current image licence. Unknown/expired/missing/invalid stages and other blob IDs are unavailable; binding/membership changes return target_mismatch. Configuration and storage failures preserve the previous screenshot.",
      input_schema: input_schema, output_schema: output_schema,
      annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: false, open_world_hint: false }) do |server_context: nil, **arguments|
      McpScreenshotToolsService.call(arguments: arguments)
    end ]
  end

  def self.call(arguments:)
    raise ScreenshotStage::InvalidInput unless JSONSchemer.schema(input_schema).valid?(arguments.stringify_keys)

    screenshot = ScreenshotStagingService.publish(**arguments.symbolize_keys)
    response(result: { data: { release_id: screenshot.release.public_id, screenshot: ScreenshotDecorator.decorate(screenshot).as_json } })
  rescue *ERRORS.keys => error
    response(result: { error: { code: ERRORS.fetch(error.class) } }, error: true)
  end

  def self.input_schema
    {
      type: "object", additionalProperties: false, required: %w[staging_id release_id source_sha1 kind],
      properties: {
        staging_id: { type: "string", minLength: 1, maxLength: 200, pattern: "\\S", description: "Opaque staging_id issued by screenshot ingest, never a blob ID or hash." },
        release_id: { type: "string", minLength: 1, maxLength: 200, pattern: "\\S", description: "Stable release public id bound at ingest." },
        source_sha1: { type: "string", minLength: 40, maxLength: 40, pattern: "^[0-9a-fA-F]{40}$" },
        kind: { type: "string", enum: Screenshot::KINDS }
      }
    }
  end

  def self.output_schema
    {
      type: "object", additionalProperties: false,
      oneOf: [ { required: [ "data" ] }, { required: [ "error" ] } ],
      properties: {
        data: { type: "object", additionalProperties: false, required: %w[release_id screenshot], properties: {
          release_id: { type: "string" },
          screenshot: { type: "object", additionalProperties: false, required: %w[kind url width height licence], properties: {
            kind: { type: "string", enum: Screenshot::KINDS }, url: { type: "string", format: "uri" },
            width: { type: "integer", minimum: 1 }, height: { type: "integer", minimum: 1 }, licence: { type: "string" }
          } }
        } },
        error: { type: "object", additionalProperties: false, required: [ "code" ], properties: {
          code: { type: "string", enum: ERRORS.values }
        } }
      }
    }
  end

  def self.response(result:, error: false)
    MCP::Tool::Response.new([ { type: "text", text: JSON.generate(result) } ], error: error, structured_content: result)
  end
  private_class_method :response
end
