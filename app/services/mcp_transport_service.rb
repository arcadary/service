class McpTransportService
  MAX_REQUEST_BYTES = 2.megabytes
  HOSTS = %w[api.arcadary.org localhost 127.0.0.1 [::1]].freeze
  ORIGINS = %w[https://api.arcadary.org].freeze

  def self.call(env:)
    return error(status: 404, code: "not_found") unless [ "", "/" ].include?(env.fetch("PATH_INFO"))
    return error(status: 403, code: "forbidden") unless allowed_request?(env: env)

    server = MCP::Server.new(name: "arcadary-catalog", version: "1", tools: McpCatalogToolsService.tools + McpUploadToolsService.tools + McpReleaseToolsService.tools,
      server_context: { base_url: Rack::Request.new(env).base_url, admin: env.fetch(PrivateServiceAuthentication::ADMIN) },
      configuration: MCP::Configuration.new(validate_tool_call_arguments: false, validate_tool_call_results: true))
    MCP::Server::Transports::StreamableHTTPTransport.new(server,
      stateless: true, enable_json_response: true, serve_subscriptions_listen: false,
      max_request_bytes: MAX_REQUEST_BYTES, allowed_hosts: HOSTS, allowed_origins: ORIGINS).call(env)
  rescue StandardError
    error(status: 500, code: "internal_error")
  end

  def self.allowed_request?(env:)
    host = env.fetch("HTTP_HOST", "").downcase
    hostname = host.sub(/:\d+\z/, "")
    origin = env["HTTP_ORIGIN"]
    HOSTS.include?(hostname) && (origin.nil? || ORIGINS.include?(origin))
  end
  private_class_method :allowed_request?

  def self.error(status:, code:)
    [ status, { "content-type" => "application/json", "cache-control" => "no-store" }, [ { error: code }.to_json ] ]
  end
  private_class_method :error
end
