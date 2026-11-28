class McpVideoToolsService
  ERRORS = {
    Release::ReleaseNotFound => "not_found", Video::NotFound => "not_found", Video::StorageUnavailable => "storage_unavailable"
  }.freeze
  CHAPTER = {
    type: "object", additionalProperties: false, required: %w[start end title],
    properties: { start: { type: "number", minimum: 0 }, end: { type: "number", minimum: 0 }, title: { type: "string", minLength: 1 } }
  }.freeze
  PUBLIC_VIDEO = {
    type: "object", additionalProperties: false, required: %w[kind url duration chapters],
    properties: {
      kind: { type: "string", enum: Video::KINDS }, url: { type: "string", format: "uri", pattern: "^https://.*/index\\.m3u8$" },
      duration: { type: "number", minimum: 0 }, chapters: { type: "array", maxItems: 256, items: CHAPTER }
    }
  }.freeze
  VIDEO = McpToolService.object_schema(properties: PUBLIC_VIDEO.fetch(:properties).merge(
    id: { type: "string" }, format: { type: "string", enum: %w[ts fmp4] }, audio: { type: [ "boolean", "null" ] },
    source_sha1: { type: "string" }, capture: { type: "object" }, verification: { type: [ "object", "null" ] },
    files: { type: "integer" }, created_at: { type: "string", format: "date-time" },
    compatibility_result_ids: { type: "array", items: { type: "integer" } }
  )).freeze
  LISTING = McpToolService.object_schema(properties: { release_id: { type: "string" }, videos: { type: "array", items: VIDEO } }).freeze
  TOOLS = {
    "list_videos" => {
      description: "List the release's videos, one per kind, as its public JSON links them, with the internal source_sha1, " \
        "capture, verification and the ids of the compatibility results each is attached to.",
      input: { release_id: McpToolService::RELEASE_ID },
      output: LISTING,
      annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
    },
    "remove_video" => {
      description: "Withdraw a video: delete its files from the public media bucket, detach it from compatibility results (the results " \
        "stay) and drop it from the release's public JSON. Returns the release's remaining videos. CDN copies stay until they expire.",
      input: { video_id: McpToolService::TEXT.merge(description: "The video's id from upload_video or list_videos.") },
      output: LISTING,
      annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: true }
    }
  }.freeze

  def self.tools
    McpToolService.tools(definitions: TOOLS, errors: ERRORS) { |name, arguments, _context| perform(tool: name, arguments: arguments) }
  end

  def self.perform(tool:, arguments:)
    case tool
    when "list_videos" then listing(release: ReleaseService.find(public_id: arguments.fetch(:release_id)))
    when "remove_video" then listing(release: VideoService.remove(**arguments))
    end
  end
  private_class_method :perform

  def self.listing(release:)
    { "release_id" => release.public_id,
      "videos" => release.videos.includes(:compatibility_results).map { |video| VideoDecorator.decorate(video).internal_json } }
  end
  private_class_method :listing
end
