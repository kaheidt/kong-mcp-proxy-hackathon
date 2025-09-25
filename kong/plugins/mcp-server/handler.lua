-- Kong MCP Server Plugin
-- Route-scoped plugin that handles MCP protocol requests

local api = require "kong.plugins.mcp-server.lib.api"
local kong = kong

local MCPServerHandler = {
  PRIORITY = 1000,  -- High priority to run early
  VERSION = "1.0.0",
}

function MCPServerHandler:init_worker()
  -- Initialize shared state and tool registry
  kong.log.info("MCP Server Plugin initialized")
  
  -- Initialize global MCP session registry
  kong.cache:safe_set("mcp:sessions", {})
end

function MCPServerHandler:access(conf)
  -- Skip if plugin is disabled
  if conf and conf.enabled == false then
    kong.log.debug("MCP Server plugin is disabled, skipping")
    return
  end
  
  kong.log.info("MCP Server plugin access phase started")
  
  -- Check if this is an MCP request (POST to /mcp endpoint)
  local method = kong.request.get_method()
  local path = kong.request.get_path()
  
  kong.log.info("Request method: ", method, " path: ", path)
  
  -- Only handle requests to /mcp path (both GET and POST)
  if path == "/mcp" or path:match("^/mcp$") or path:match("^/mcp/") then
    kong.log.info("Processing MCP request")
    
    -- Handle the MCP request using our API module
    local body, status, headers = api.handle_mcp_request(conf)
    
    if headers then
      for k, v in pairs(headers) do
        kong.response.set_header(k, v)
      end
    end
    
    -- Return the response immediately
    return kong.response.exit(status or 200, body)
  else
    kong.log.debug("Not an MCP request, passing through")
  end
end

-- Note: Main MCP functionality now handled in access phase

return MCPServerHandler