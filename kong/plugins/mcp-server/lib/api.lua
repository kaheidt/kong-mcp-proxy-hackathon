-- MCP Server API Module
-- Handles MCP protocol requests with optional OAuth authentication

local cjson = require "cjson.safe"
local oauth = require "kong.plugins.mcp-server.lib.oauth"

-- Kong and Nginx globals are available in plugins
local kong = kong
local ngx = ngx

local _M = {}

-- Helper function to extract Bearer token from Authorization header
local function extract_bearer_token()
  local auth_header = ngx.var.http_authorization
  if not auth_header then
    return nil
  end
  
  local token = auth_header:match("^Bearer%s+(.+)$")
  return token
end

-- Helper function to validate OAuth if enabled
local function validate_oauth_if_enabled(conf)
  -- If OAuth is not configured or disabled, allow request
  if not conf.oauth or not conf.oauth.enabled then
    kong.log.debug("OAuth not enabled, allowing request")
    return true, nil
  end
  
  kong.log.debug("OAuth enabled, validating token")
  
  local token = extract_bearer_token()
  if not token then
    kong.log.info("OAuth enabled but no Bearer token provided")
    return false, "Missing authorization token"
  end
  
  local valid, payload_or_error = oauth.validate_jwt(token, conf)
  if not valid then
    kong.log.info("OAuth token validation failed: ", payload_or_error)
    return false, payload_or_error
  end
  
  kong.log.debug("OAuth token validated successfully")
  return true, payload_or_error -- payload_or_error is actually payload when valid=true
end

--- Handle MCP endpoint request with optional OAuth support
-- @param conf table|nil Plugin configuration (optional, retrieved from cache if not provided)
-- @return response body, status code, headers  
function _M.handle_mcp_request(conf)
  kong.log.info("MCP handler started")
  
  -- Try to get configuration from cache if not provided
  if not conf then
    kong.log.debug("No configuration provided, trying to retrieve from cache")
    local cached_conf, err = kong.cache:get("mcp:server:config")
    if cached_conf then
      conf = cached_conf
      kong.log.debug("Retrieved configuration from cache")
    else
      kong.log.debug("No cached configuration found, using defaults")
      conf = {} -- Default empty configuration (no OAuth)
    end
  end
  
  local method = ngx.var.request_method
  kong.log.info("Request method: " .. method)
  
  -- Parse request to check method before OAuth validation
  local request = nil
  if method == "POST" then
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if body then
      local parsed_request, err = cjson.decode(body)
      if parsed_request then
        request = parsed_request
      end
    end
  end
  
  -- Validate OAuth for all requests when enabled
  local oauth_valid, oauth_payload_or_error = validate_oauth_if_enabled(conf)
  if not oauth_valid then
    local headers = { ["Content-Type"] = "application/json" }
    
    -- Add WWW-Authenticate header for OAuth discovery (MCP spec)
    if conf and conf.oauth and conf.oauth.enabled then
      local scheme = ngx.var.scheme or "http"
      local host = ngx.var.host or "localhost"
      local port = ngx.var.server_port or "8000"
      
      -- Construct full host:port if port is not standard
      local full_host = host
      if (scheme == "http" and port ~= "80") or (scheme == "https" and port ~= "443") then
        full_host = host .. ":" .. port
      end
      
      local resource_metadata_url = scheme .. "://" .. full_host .. "/.well-known/oauth-protected-resource"
      headers["WWW-Authenticate"] = 'Bearer resource_metadata="' .. resource_metadata_url .. '"'
    end
    
    local error_response = {
      jsonrpc = "2.0",
      id = request and request.id or nil,
      error = {
        code = -32001,
        message = "Authentication failed",
        data = { detail = oauth_payload_or_error }
      }
    }
    return cjson.encode(error_response), 401, headers
  end
  
  -- Handle GET requests for capability discovery
  if method == "GET" then
    local response = {
      jsonrpc = "2.0",
      result = {
        capabilities = {
          tools = {}
        },
        serverInfo = {
          name = "kong-mcp",
          version = "1.0.0"
        }
      }
    }
    return cjson.encode(response), 200, { ["Content-Type"] = "application/json" }
  end
  
  -- Handle POST requests
  if method ~= "POST" then
    return cjson.encode({ error = "Method not allowed" }), 405, { ["Content-Type"] = "application/json" }
  end
  
  -- Read request body
  ngx.req.read_body()
  local body = ngx.req.get_body_data()
  if not body then
    return cjson.encode({ error = "Empty request body" }), 400, { ["Content-Type"] = "application/json" }
  end
  
  -- Parse JSON
  local request, err = cjson.decode(body)
  if not request then
    return cjson.encode({ error = "Invalid JSON: " .. (err or "unknown") }), 400, { ["Content-Type"] = "application/json" }
  end
  
  -- Handle MCP initialize method
  if request.method == "initialize" then
    local response = {
      jsonrpc = "2.0",
      id = request.id,
      result = {
        protocolVersion = "2024-11-05",
        capabilities = {
          tools = {
            listChanged = false
          }
        },
        serverInfo = {
          name = "kong-mcp",
          version = "1.0.0"
        }
      }
    }
    
    return cjson.encode(response), 200, { ["Content-Type"] = "application/json" }
  end
  
  -- Handle tools/list method
  if request.method == "tools/list" then
    kong.log.debug("Processing tools/list request")
    
    -- Discover tools from mcp-tool plugins with access control
    local tool_discovery = require "kong.plugins.mcp-server.lib.tool_discovery"
    local jwt_payload = (conf.oauth and conf.oauth.enabled and oauth_payload_or_error) and oauth_payload_or_error or nil
    local filtered_tools = tool_discovery.discover_tools(jwt_payload)
    
    kong.log.debug("Tool discovery complete - returning ", #filtered_tools, " tools")
    
    local response = {
      jsonrpc = "2.0",
      id = request.id,
      result = {
        tools = filtered_tools
      }
    }
    return cjson.encode(response), 200, { ["Content-Type"] = "application/json" }
  end
  
  -- Handle tools/call method
  if request.method == "tools/call" then
    kong.log.debug("Processing tools/call request for tool: ", request.params and request.params.name or "unknown")
    
    if not request.params or not request.params.name then
      local error_response = {
        jsonrpc = "2.0",
        id = request.id,
        error = {
          code = -32602,
          message = "Invalid params",
          data = { detail = "Missing tool name" }
        }
      }
      return cjson.encode(error_response), 400, { ["Content-Type"] = "application/json" }
    end
    
    -- Discover tools to find the requested tool and verify access
    local tool_discovery = require "kong.plugins.mcp-server.lib.tool_discovery"
    local jwt_payload = (conf.oauth and conf.oauth.enabled and oauth_payload_or_error) and oauth_payload_or_error or nil
    local available_tools = tool_discovery.discover_tools(jwt_payload)
    
    local target_tool = nil
    for _, tool in ipairs(available_tools) do
      if tool.name == request.params.name then
        target_tool = tool
        break
      end
    end
    
    if not target_tool then
      local error_response = {
        jsonrpc = "2.0",
        id = request.id,
        error = {
          code = -32601,
          message = "Tool not found or access denied",
          data = { detail = "Tool '" .. request.params.name .. "' not found or you don't have permission to access it" }
        }
      }
      return cjson.encode(error_response), 404, { ["Content-Type"] = "application/json" }
    end
    
    -- Execute the tool by making a subrequest to the target route
    kong.log.debug("Executing tool '", target_tool.name, "' via route '", target_tool.route_name, "'")
    
    -- Prepare the subrequest
    local subrequest_method = target_tool.http_method or "GET"
    
    -- Construct the full path for the subrequest through Kong
    -- Each route has its own path pattern that we need to respect
    local subrequest_path
    local route_base = target_tool.route_path or "/"
    
    -- Route-specific path construction
    -- Fix: Use tool prefix to determine correct route path instead of just route_name
    if target_tool.name and target_tool.name:match("^kong_admin_") then
      -- Kong Admin tools should always go through admin-tools path
      subrequest_path = "/admin-tools" .. (target_tool.endpoint_path or "")
    elseif target_tool.name and target_tool.name:match("^requestcatcher_") then
      -- RequestCatcher tools should go through route-test path  
      subrequest_path = "/route-test" .. (target_tool.endpoint_path or "")
    elseif target_tool.name and target_tool.name:match("^public_") then
      -- Public tools should go through public-tools path
      subrequest_path = "/public-tools" .. (target_tool.endpoint_path or "")
    elseif target_tool.route_name == "route-test" then
      subrequest_path = "/route-test" .. (target_tool.endpoint_path or "")
    elseif target_tool.route_name == "admin-route" then
      subrequest_path = "/admin-tools" .. (target_tool.endpoint_path or "")
    elseif target_tool.route_name == "public-route" then
      subrequest_path = "/public-tools" .. (target_tool.endpoint_path or "")
    else
      -- Fallback for any other routes
      subrequest_path = route_base
      if target_tool.endpoint_path and target_tool.endpoint_path ~= "/" then
        subrequest_path = subrequest_path .. target_tool.endpoint_path
      end
    end
    
    local subrequest_body = nil
    local subrequest_headers = { ["Content-Type"] = "application/json" }
    
    if request.params.arguments and (subrequest_method == "POST" or subrequest_method == "PUT" or subrequest_method == "PATCH") then
      subrequest_body = cjson.encode(request.params.arguments)
    end
    
    -- Make the subrequest to execute the tool
    local httpc = require("resty.http").new()
    local scheme = ngx.var.scheme or "http"
    local host = ngx.var.host or "localhost"
    local port = ngx.var.server_port or "8000"
    local base_url = scheme .. "://" .. host .. ":" .. port
    
    kong.log.debug("Making subrequest: ", subrequest_method, " ", base_url .. subrequest_path)
    
    local res, err = httpc:request_uri(base_url .. subrequest_path, {
      method = subrequest_method,
      body = subrequest_body,
      headers = subrequest_headers,
      timeout = 10000, -- 10 second timeout
    })
    
    if not res then
      kong.log.err("Tool execution failed: ", err)
      local error_response = {
        jsonrpc = "2.0",
        id = request.id,
        error = {
          code = -32603,
          message = "Tool execution failed",
          data = { detail = err or "Unknown error" }
        }
      }
      return cjson.encode(error_response), 500, { ["Content-Type"] = "application/json" }
    end
    
    -- Return the tool execution result in MCP format
    -- MCP expects specific format: { content: [{ type: "text", text: "..." }] }
    local tool_result
    
    -- Handle error responses (4xx, 5xx) differently
    if res.status >= 400 then
      tool_result = {
        content = {{
          type = "text",
          text = "HTTP " .. tostring(res.status) .. " Error: " .. (res.body or "No response body")
        }}
      }
    elseif res.headers["content-type"] and res.headers["content-type"]:match("application/json") then
      -- Try to parse JSON response and format for MCP
      local parsed_body, parse_err = cjson.decode(res.body)
      if parsed_body then
        -- Format successful JSON response for MCP
        tool_result = {
          content = {{
            type = "text", 
            text = cjson.encode(parsed_body)
          }}
        }
      else
        tool_result = {
          content = {{
            type = "text",
            text = "Invalid JSON response: " .. (res.body or "")
          }}
        }
      end
    else
      -- Handle non-JSON responses
      tool_result = {
        content = {{
          type = "text",
          text = res.body or ""
        }}
      }
    end
    
    local response = {
      jsonrpc = "2.0",
      id = request.id,
      result = tool_result
    }
    
    kong.log.debug("Tool '", target_tool.name, "' executed successfully with status: ", res.status)
    
    return cjson.encode(response), 200, { ["Content-Type"] = "application/json" }
  end
  
  -- Handle other methods with a generic response for now
  local response = {
    jsonrpc = "2.0",
    id = request.id,
    result = {
      status = "ok",
      message = "Method " .. (request.method or "unknown") .. " received"
    }
  }
  
  return cjson.encode(response), 200, { ["Content-Type"] = "application/json" }
end

return _M
