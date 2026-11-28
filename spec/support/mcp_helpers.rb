module McpHelpers
  def stub_admin_credentials
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_USERNAME").and_return("synthetic-admin")
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return("synthetic-password")
  end

  def admin_authorization
    ActionController::HttpAuthentication::Basic.encode_credentials("synthetic-admin", "synthetic-password")
  end

  def mcp_headers
    { "Authorization" => admin_authorization, "CONTENT_TYPE" => "application/json", "Accept" => "application/json", "MCP-Protocol-Version" => "2025-11-25" }
  end

  def mcp_rpc(method:, params: {}, headers: {})
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json, headers: mcp_headers.merge(headers)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.headers["Set-Cookie"]).to be_nil
    response.parsed_body
  end

  def mcp_result(name:, **arguments)
    result = mcp_rpc(method: "tools/call", params: { name: name, arguments: arguments }).fetch("result")
    expect(JSON.parse(result.fetch("content").sole.fetch("text"))).to eq(result.fetch("structuredContent"))
    result
  end

  def mcp_tool(name:, **arguments)
    result = mcp_result(name: name, **arguments)
    result.fetch("structuredContent").fetch(result.fetch("isError") ? "error" : "data")
  end
end
