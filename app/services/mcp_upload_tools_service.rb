class McpUploadToolsService
  ERRORS = {
    Upload::InvalidInput => "invalid_input", Screenshot::InvalidKind => "invalid_input",
    Upload::NotFound => "not_found", Release::ReleaseNotFound => "not_found",
    Upload::Expired => "upload_expired", Upload::Conflict => "upload_conflict",
    Screenshot::InvalidImage => "upload_rejected", Screenshot::LimitReached => "screenshot_limit_reached", Playthrough::TargetMismatch => "target_mismatch",
    Upload::StorageDisabled => "uploads_disabled",
    Upload::StorageUnavailable => "storage_unavailable", Screenshot::StorageUnavailable => "storage_unavailable"
  }.freeze
  UPLOAD_ID = McpToolService::TEXT.merge(description: "upload_id returned by request_upload.").freeze
  FILE = McpToolService.object_schema(properties: {
    name: { type: "string" }, size: { type: "integer", minimum: 1 }, sha256: { type: "string", pattern: "^[0-9a-f]{64}$" }
  }).freeze
  UPLOAD = McpToolService.object_schema(properties: {
    upload_id: { type: "string" }, type: { type: "string", enum: Upload::LIMITS.keys }, state: { type: "string", enum: Upload::STATES },
    expires_at: { type: "string", format: "date-time" }, rejection_reason: { type: [ "string", "null" ] }, files: { type: "array", items: FILE }
  }).freeze
  TOOLS = {
    "request_upload" => {
      description: "Start an upload of a screenshot (one PNG) or a playthrough video (an HLS package: index.m3u8, optional " \
        "variant playlists, .ts segments and an optional chapters.vtt). PUT each file to upload_url followed by its " \
        "package-relative name, with the same Basic credentials, its Content-Type and its SHA-256 in Content-Digest " \
        "(sha-256=:BASE64:), within limits. Then call confirm_upload. Expires 24 hours after this call.",
      input: { type: { type: "string", enum: Upload::LIMITS.keys } },
      output: McpToolService.object_schema(properties: {
        upload_id: { type: "string" }, type: { type: "string" }, expires_at: { type: "string", format: "date-time" },
        upload_url: { type: "string", format: "uri" }, limits: { type: "object" }
      }),
      annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: false }
    },
    "confirm_upload" => {
      description: "Close an upload to further files and check it as a whole in the background: one PNG, or an HLS package " \
        "whose playlists, segments and chapters agree, which is then stored privately. Returns state checking; call it " \
        "again until it is confirmed, or rejected with rejection_reason (its files are deleted). Back at receiving means " \
        "the check could not finish: confirm again.",
      input: { upload_id: UPLOAD_ID },
      output: UPLOAD,
      annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true }
    },
    "upload_screenshot" => {
      description: "Add a confirmed screenshot upload to the release. kind title replaces the release's title screenshot; " \
        "gameplay goes after its last gameplay screenshot, at most 50 (screenshot_limit_reached). An image the release " \
        "already has, of either kind, returns that screenshot unchanged. The PNG must decode within the release system's " \
        "size limits. Uses the game's image licence; grants no new rights.",
      input: { upload_id: UPLOAD_ID, release_id: McpToolService::RELEASE_ID, kind: { type: "string", enum: Screenshot::KINDS } },
      output: McpToolService.object_schema(properties: { release_id: { type: "string" }, screenshot: McpScreenshotToolsService::SCREENSHOT }),
      annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: false }
    },
    "upload_video" => {
      description: "Make a confirmed video upload a private playthrough of the release. source_sha1 is the captured medium's " \
        "SHA-1 and must belong to the release, unless verification attests how it differs from a release medium. " \
        "Nothing is published.",
      input: { upload_id: UPLOAD_ID, release_id: McpToolService::RELEASE_ID, source_sha1: McpToolService::SHA1,
               capture: PlaythroughService::CAPTURE, verification: PlaythroughService::VERIFICATION },
      optional: %w[verification],
      output: { type: "object", required: %w[playthrough], properties: { playthrough: { type: "object" } } },
      annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: false }
    }
  }.freeze

  def self.tools
    McpToolService.tools(definitions: TOOLS, errors: ERRORS) { |name, arguments, context| perform(tool: name, arguments: arguments, context: context) }
  end

  def self.perform(tool:, arguments:, context:)
    case tool
    when "request_upload"
      upload = UploadService.create(kind: arguments.fetch(:type))
      UploadDecorator.decorate(upload).as_json.slice("upload_id", "type", "expires_at").merge(
        "upload_url" => "#{context.fetch(:base_url)}/v1/uploads/#{upload.public_id}/files/", "limits" => upload.limits)
    when "confirm_upload"
      UploadDecorator.decorate(UploadService.confirm(**arguments)).as_json
    when "upload_screenshot"
      screenshot = ScreenshotService.create(**arguments)
      { "release_id" => arguments.fetch(:release_id), "screenshot" => ScreenshotDecorator.decorate(screenshot).admin_json }
    when "upload_video"
      { "playthrough" => PlaythroughDecorator.decorate(PlaythroughService.create(**arguments, verifier: context.fetch(:admin))).as_json }
    end
  end
  private_class_method :perform
end
