module McpHelpers
  def stub_admin_credentials
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_USERNAME").and_return("synthetic-admin")
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return("synthetic-password")
  end

  def admin_authorization
    ActionController::HttpAuthentication::Basic.encode_credentials("synthetic-admin", "synthetic-password")
  end

  def mcp_tool(name:, **arguments)
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json,
      headers: { "Authorization" => admin_authorization, "CONTENT_TYPE" => "application/json", "Accept" => "application/json", "MCP-Protocol-Version" => "2025-11-25" }
    expect(response.headers["Cache-Control"]).to eq("no-store")
    result = response.parsed_body.fetch("result")
    result.fetch("structuredContent").fetch(result.fetch("isError") ? "error" : "data")
  end
end
