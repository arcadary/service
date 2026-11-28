class McpReleaseToolsService
  ERRORS = {
    CatalogAuthoringService::InvalidInput => "invalid_input", CatalogAuthoringService::Conflict => "conflict",
    CatalogAuthoringService::MissingAdminName => "admin_unavailable"
  }.freeze
  TEXT = McpToolService::TEXT
  REASON = TEXT.merge(maxLength: 2000, description: "Why, for the audit history.").freeze
  MEDIUM = {
    type: "object", additionalProperties: false, required: %w[sha1],
    properties: {
      sha1: PlaythroughService::SHA1, size: { type: "integer", minimum: 0 },
      crc32: { type: "string", pattern: "^[0-9a-f]{8}$" }, md5: { type: "string", pattern: "^[0-9a-f]{32}$" },
      format: { type: "string", pattern: "^[a-z0-9]+$" }, label: TEXT,
      key: { type: "string", pattern: "^[a-z0-9-]{1,32}$", description: "Defaults to medium-1, medium-2 and so on." },
      role: { type: "string", enum: %w[game save], description: "Defaults to game." }
    }
  }.freeze
  TOOLS = {
    "register_release" => {
      description: "Add a release to the catalog by its checksum metadata alone; no game file is ever sent. Name an existing " \
        "game_id, or new_game {id, title} to create the game too. Each medium's SHA-1 must be new to the catalog. " \
        "Returns the release as get_release does. Retrying with the same idempotency_key and arguments returns it again.",
      input: {
        reason: REASON, idempotency_key: TEXT, game_id: TEXT,
        new_game: { type: "object", additionalProperties: false, required: %w[id title], properties: {
          id: { type: "string", pattern: "^[a-z0-9-]{1,100}$", description: "Stable public game id, e.g. tobu-tobu-girl." }, title: TEXT } },
        system: { type: "string", enum: Release::SYSTEMS }, region: TEXT, revision: TEXT,
        media: { type: "array", minItems: 1, maxItems: 32, items: MEDIUM }
      },
      optional: %w[game_id new_game region revision],
      output: { type: "object" },
      annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true }
    }
  }.freeze

  def self.tools
    McpToolService.tools(definitions: TOOLS, errors: ERRORS) { |_name, arguments, _context| ReleaseRegistrationService.register(**arguments) }
  end
end
