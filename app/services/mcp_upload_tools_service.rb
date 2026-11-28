class McpUploadToolsService
  ERRORS = {
    Upload::InvalidInput => "invalid_input", Screenshot::InvalidKind => "invalid_input",
    Upload::NotFound => "not_found", Release::ReleaseNotFound => "not_found",
    Upload::Expired => "upload_expired", Upload::Conflict => "upload_conflict",
    Screenshot::InvalidImage => "upload_rejected", Video::TargetMismatch => "target_mismatch",
    Upload::StorageDisabled => "uploads_disabled",
    Upload::StorageUnavailable => "storage_unavailable", Screenshot::StorageUnavailable => "storage_unavailable",
    Video::StorageUnavailable => "storage_unavailable"
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
      description: "Start an upload of a screenshot (one PNG) or a video (an HLS package: index.m3u8 with MPEG-TS or " \
        "fragmented MP4 media and an optional chapters.vtt, see " \
        "https://github.com/arcadary/service/blob/main/docs/mcp.md#video-packages). PUT each file to upload_url followed " \
        "by its package-relative name, with the same Basic credentials, its Content-Type and its SHA-256 in Content-Digest " \
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
        "whose playlists, segments and chapters agree, which is then copied to the public media bucket, not yet linked from " \
        "any release. Returns state checking; call it again until it is confirmed, or rejected with rejection_reason (its " \
        "files are deleted). Back at receiving means the check could not finish: confirm again.",
      input: { upload_id: UPLOAD_ID },
      output: UPLOAD,
      annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true }
    },
    "upload_screenshot" => {
      description: "Make a confirmed screenshot upload the release's title or gameplay screenshot, replacing the previous one. " \
        "The PNG must decode within the release system's size limits. Uses the game's image licence; grants no new rights.",
      input: { upload_id: UPLOAD_ID, release_id: McpToolService::RELEASE_ID, kind: { type: "string", enum: Screenshot::KINDS } },
      output: { type: "object", required: %w[release_id screenshot], properties: { release_id: { type: "string" }, screenshot: { type: "object" } } },
      annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: false }
    },
    "upload_video" => {
      description: "Link a confirmed video upload to the release as its video of the given kind (playthrough: a complete " \
        "playthrough), replacing and deleting the previous one of that kind. The release's public JSON links it for anyone to " \
        "watch. source_sha1 is the captured medium's SHA-1 and must belong to the release, unless verification attests how it " \
        "differs from a release medium.",
      input: { upload_id: UPLOAD_ID, release_id: McpToolService::RELEASE_ID, kind: { type: "string", enum: Video::KINDS },
               source_sha1: McpToolService::SHA1, capture: VideoService::CAPTURE, verification: VideoService::VERIFICATION },
      optional: %w[verification],
      output: McpToolService.object_schema(properties: { release_id: { type: "string" }, video: McpVideoToolsService::VIDEO }),
      annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: false }
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
      { "release_id" => arguments.fetch(:release_id), "screenshot" => ScreenshotDecorator.decorate(screenshot).as_json }
    when "upload_video"
      video = VideoService.create(**arguments, verifier: context.fetch(:admin))
      { "release_id" => arguments.fetch(:release_id), "video" => VideoDecorator.decorate(video).internal_json }
    end
  end
  private_class_method :perform
end
