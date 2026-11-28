class McpReleaseToolsService
  ERRORS = {
    CatalogAuthoringService::InvalidInput => "invalid_input", CompatibilityVerdict::InvalidInput => "invalid_input",
    Release::ReleaseNotFound => "not_found", CatalogAuthoringService::Conflict => "conflict",
    CatalogAuthoringService::MissingAdminName => "admin_unavailable"
  }.freeze
  TEXT = McpToolService::TEXT
  REASON = TEXT.merge(maxLength: 2000, description: "Why, for the audit history.").freeze
  LONG_TEXT = { type: "string", minLength: 1, maxLength: CompatibilityVerdict::TEXT_LENGTH }.freeze
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
  VERDICT = McpToolService.object_schema(properties: {
    id: { type: "integer" }, device_class: { type: "string" }, core: { type: "string" }, core_version: { type: "string" },
    startup_revision: { type: "string" }, state: { type: "string" }, tested_at: { type: "string" },
    evidence: { type: [ "string", "null" ] }, limitations: { type: [ "string", "null" ] }, reviewer: { type: "string" },
    reason: { type: "string" }, playthrough_ids: { type: "array", items: { type: "string" } }, recorded_at: { type: "string" }
  }).freeze
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
    },
    "record_verdict" => {
      description: "Record a compatibility verdict for one release in one environment: device_class, core and core_version, " \
        "tested on the release's current launch configuration. works and works_with_issues need gameplay evidence, " \
        "works_with_issues also its limitations, does_not_work the failure evidence with the controls and configuration " \
        "checked. Any state but unknown needs attested: true, meaning you own that exact file and played it yourself. " \
        "unknown withdraws the environment's verdict. Earlier verdicts stay in the history. playthrough_ids attach this " \
        "release's private playthroughs as evidence.",
      input: {
        release_id: McpToolService::RELEASE_ID, device_class: { type: "string", enum: CompatibilityVerdict::DEVICE_CLASSES },
        core: TEXT.merge(maxLength: 100, description: "The emulator core, e.g. mesen."), core_version: TEXT.merge(maxLength: 100),
        state: { type: "string", enum: CompatibilityVerdict::STATES }, tested_at: PlaythroughService::TIMESTAMP,
        evidence: LONG_TEXT, limitations: LONG_TEXT, attested: { type: "boolean" },
        playthrough_ids: { type: "array", maxItems: 20, uniqueItems: true, items: TEXT }, reason: REASON
      },
      optional: %w[evidence limitations attested playthrough_ids],
      output: { type: "object", required: %w[verdict], properties: { verdict: VERDICT } },
      annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: false }
    },
    "get_compatibility" => {
      description: "Read a release's compatibility: its current launch-configuration revision, the verdict in force per " \
        "environment (as the public release JSON shows it) and the full history, newest first, with reviewer, reason " \
        "and attached playthroughs.",
      input: { release_id: McpToolService::RELEASE_ID },
      output: McpToolService.object_schema(properties: {
        release_id: { type: "string" }, startup_revision: { type: "string" },
        current: { type: "array", items: { type: "object" } }, history: { type: "array", items: VERDICT }
      }),
      annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
    }
  }.freeze

  def self.tools
    McpToolService.tools(definitions: TOOLS, errors: ERRORS) { |name, arguments, _context| perform(tool: name, arguments: arguments) }
  end

  def self.perform(tool:, arguments:)
    case tool
    when "register_release"
      ReleaseRegistrationService.register(**arguments)
    when "record_verdict"
      { "verdict" => CompatibilityVerdictDecorator.decorate(CompatibilityService.record(**arguments)).as_record }
    when "get_compatibility"
      release = ReleaseService.find(public_id: arguments.fetch(:release_id), includes: [ { compatibility_verdicts: :playthroughs }, { release_media: :media_file } ])
      { "release_id" => release.public_id, "startup_revision" => ReleaseStartupService.revision(release: release),
        "current" => CompatibilityVerdictDecorator.current(release: release),
        "history" => release.compatibility_verdicts.reverse.map { |verdict| CompatibilityVerdictDecorator.decorate(verdict).as_record } }
    end
  end
  private_class_method :perform
end
