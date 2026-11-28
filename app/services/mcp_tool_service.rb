class McpToolService
  MAX_RESULT_BYTES = 1024 * 1024
  TEXT = { type: "string", minLength: 1, maxLength: 200, pattern: "\\S" }.freeze
  RELEASE_ID = TEXT.merge(description: "The release's stable id, never its title or a checksum.").freeze

  def self.tools(definitions:, errors:, &perform)
    definitions.map do |name, tool|
      MCP::Tool.define(name: name, description: tool.fetch(:description), input_schema: input_schema(tool: tool),
        output_schema: output_schema(data: tool.fetch(:output), codes: [ "invalid_input", *errors.values ].uniq),
        annotations: tool.fetch(:annotations).merge(open_world_hint: false)) do |server_context: nil, **arguments|
        McpToolService.respond(tool: tool, arguments: arguments, errors: errors) { |input| perform.call(name, input, server_context) }
      end
    end
  end

  def self.respond(tool:, arguments:, errors:)
    return failure(code: "invalid_input") unless JSONSchemer.schema(input_schema(tool: tool)).valid?(arguments.deep_stringify_keys)

    response(result: { "data" => yield(arguments.deep_symbolize_keys) })
  rescue *errors.keys => error
    failure(code: errors.fetch(error.class))
  end

  def self.response(result:, error: false)
    serialized = JSON.generate(result)
    return failure(code: "invalid_input") if serialized.bytesize > MAX_RESULT_BYTES

    MCP::Tool::Response.new([ { type: "text", text: serialized } ], error: error, structured_content: result)
  end

  def self.failure(code:, **details)
    response(result: { "error" => { "code" => code }.merge(details.stringify_keys) }, error: true)
  end

  def self.object_schema(properties:)
    { type: "object", additionalProperties: false, required: properties.keys.map(&:to_s), properties: properties }
  end

  def self.input_schema(tool:)
    input = tool.fetch(:input)
    { type: "object", additionalProperties: false, required: input.keys.map(&:to_s) - tool.fetch(:optional, []), properties: input }
  end
  private_class_method :input_schema

  def self.output_schema(data:, codes:)
    {
      type: "object", additionalProperties: false, oneOf: [ { required: [ "data" ] }, { required: [ "error" ] } ],
      properties: {
        data: data,
        error: { type: "object", additionalProperties: false, required: [ "code" ], properties: { code: { type: "string", enum: codes } } }
      }
    }
  end
  private_class_method :output_schema
end
