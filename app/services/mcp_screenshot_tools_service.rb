class McpScreenshotToolsService
  ERRORS = { Release::ReleaseNotFound => "not_found", Screenshot::NotFound => "not_found" }.freeze
  SCREENSHOT = McpToolService.object_schema(properties: {
    id: { type: "string" }, kind: { type: "string", enum: Screenshot::KINDS },
    url: { type: "string", format: "uri" }, width: { type: "integer", minimum: 1 }, height: { type: "integer", minimum: 1 },
    licence: { type: "string" }, sha256: { type: "string", pattern: "^[0-9a-f]{64}$" }, created_at: { type: "string", format: "date-time" }
  }).freeze
  SCREENSHOTS = McpToolService.object_schema(properties: {
    release_id: { type: "string" }, screenshots: { type: "array", maxItems: Screenshot::GAMEPLAY_LIMIT + 1, items: SCREENSHOT }
  }).freeze
  TOOLS = {
    "list_screenshots" => {
      description: "List every screenshot of one release in the order its public JSON shows them: the title screenshot " \
        "first, then up to #{Screenshot::GAMEPLAY_LIMIT} gameplay screenshots in the order they were added. Each has the " \
        "id remove_screenshot takes, its kind, public url, width, height, licence, sha256 and created_at.",
      input: { release_id: McpToolService::RELEASE_ID },
      output: SCREENSHOTS,
      annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
    },
    "remove_screenshot" => {
      description: "Remove one screenshot by the id list_screenshots or upload_screenshot returned. The release's public " \
        "JSON changes at once, and so does the game's picture when it was this screenshot. The image leaves the media " \
        "bucket once no release uses it; copies the CDN already holds are not purged. Returns the release's remaining screenshots.",
      input: { screenshot_id: McpToolService::TEXT.merge(description: "The screenshot's id from list_screenshots or upload_screenshot.") },
      output: SCREENSHOTS,
      annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: true }
    }
  }.freeze

  def self.tools
    McpToolService.tools(definitions: TOOLS, errors: ERRORS) { |name, arguments, _context| perform(tool: name, arguments: arguments) }
  end

  def self.perform(tool:, arguments:)
    case tool
    when "list_screenshots"
      listing(release_id: arguments.fetch(:release_id), screenshots: ScreenshotService.list(**arguments))
    when "remove_screenshot"
      release = ScreenshotService.remove(**arguments).release
      listing(release_id: release.public_id, screenshots: release.screenshots)
    end
  end
  private_class_method :perform

  def self.listing(release_id:, screenshots:)
    { "release_id" => release_id, "screenshots" => screenshots.map { |screenshot| ScreenshotDecorator.decorate(screenshot).admin_json } }
  end
  private_class_method :listing
end
