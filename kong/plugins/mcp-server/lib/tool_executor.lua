-- MCP Tool Execution Engine
-- Handles execution of MCP tools by routing to Kong-proxied APIs

local cjson = require "cjson.safe"
local http = require "resty.http"

-- Kong and nginx globals (available at runtime in Kong environment)
local kong = kong
local ngx = ngx

local _M = {}

--- Execute an MCP tool by making HTTP request to Kong route
-- @param tool_name string Name of the tool to execute
-- @param arguments table MCP tool arguments
-- @param consumer table|nil Kong consumer for authentication context
-- @return table|nil Success result with content
-- @return string|nil Error message
function _M.execute_tool(tool_name, arguments, consumer)
  kong.log.info("Executing tool: ", tool_name, " with args: ", cjson.encode(arguments or {}))
  
  -- Get tool definition and route information
  local tool_info, err = _M.get_tool_execution_info(tool_name, consumer)
  if not tool_info then
    return nil, err or "Tool not found"
  end
  
  -- Transform MCP arguments to HTTP request
  local http_request, transform_err = _M.transform_mcp_to_http(tool_info, arguments)
  if not http_request then
    return nil, transform_err or "Failed to transform arguments"
  end
  
  -- Execute HTTP request via Kong's internal routing
  local response, exec_err = _M.execute_http_request(http_request, consumer, tool_info)
  if not response then
    return nil, exec_err or "Failed to execute request"
  end
  
  -- Transform HTTP response to MCP content format
  local mcp_result = _M.transform_http_to_mcp(response, tool_info)
  
  kong.log.info("Tool execution completed: ", tool_name)
  return mcp_result, nil
end

--- Get tool execution information from cache
-- @param tool_name string Tool name
-- @param consumer table|nil Consumer context
-- @return table|nil Tool execution info
-- @return string|nil Error message
function _M.get_tool_execution_info(tool_name, consumer)
  local consumer_id = consumer and consumer.id or "anonymous"
  local cache_key = "mcp:tool:" .. tool_name .. ":" .. consumer_id
  
  local tool_data, err = kong.cache:get(cache_key)
  if err then
    kong.log.err("Error retrieving tool execution info: ", err)
    return nil, "Cache error: " .. err
  end
  
  if not tool_data or not tool_data.definition then
    return nil, "Tool not found: " .. tool_name
  end
  
  return {
    definition = tool_data.definition,
    route_info = tool_data.route_info,
    consumer = tool_data.consumer,
    openapi_operation = tool_data.openapi_operation -- Added by mcp-tool plugin
  }, nil
end

--- Transform MCP arguments to HTTP request format
-- @param tool_info table Tool execution information
-- @param arguments table MCP tool arguments
-- @return table|nil HTTP request specification
-- @return string|nil Error message
function _M.transform_mcp_to_http(tool_info, arguments)
  arguments = arguments or {}
  
  local operation = tool_info.openapi_operation
  if not operation then
    return nil, "No OpenAPI operation information available"
  end
  
  local http_request = {
    method = operation.method:upper(),
    path = operation.path,
    headers = {
      ["Content-Type"] = "application/json",
      ["User-Agent"] = "Kong-MCP-Plugin/1.0.0"
    },
    query_params = {},
    body = nil
  }
  
  -- Process path parameters
  if operation.parameters then
    for _, param in ipairs(operation.parameters) do
      if param["in"] == "path" and arguments[param.name] then
        -- Replace {param} in path with actual value
        local param_pattern = "{" .. param.name .. "}"
        http_request.path = string.gsub(http_request.path, param_pattern, tostring(arguments[param.name]))
      elseif param["in"] == "query" and arguments[param.name] then
        -- Add query parameter
        http_request.query_params[param.name] = tostring(arguments[param.name])
      elseif param["in"] == "header" and arguments[param.name] then
        -- Add header
        http_request.headers[param.name] = tostring(arguments[param.name])
      end
    end
  end
  
  -- Process request body for POST/PUT/PATCH
  if operation.method:upper() == "POST" or operation.method:upper() == "PUT" or operation.method:upper() == "PATCH" then
    if operation.requestBody and next(arguments) then
      -- For now, pass all remaining arguments as JSON body
      local body_args = {}
      for key, value in pairs(arguments) do
        -- Skip parameters that were already processed
        local is_param = false
        if operation.parameters then
          for _, param in ipairs(operation.parameters) do
            if param.name == key then
              is_param = true
              break
            end
          end
        end
        if not is_param then
          body_args[key] = value
        end
      end
      
      if next(body_args) then
        local json_body, encode_err = cjson.encode(body_args)
        if not json_body then
          return nil, "Failed to encode request body: " .. (encode_err or "unknown error")
        end
        http_request.body = json_body
      end
    end
  end
  
  kong.log.debug("HTTP request transformed: ", cjson.encode(http_request))
  return http_request, nil
end

--- Execute HTTP request using Kong's service resolution
-- @param http_request table HTTP request specification  
-- @param consumer table|nil Consumer context
-- @param tool_info table Tool information including route_info
-- @return table|nil HTTP response
-- @return string|nil Error message
function _M.execute_http_request(http_request, consumer, tool_info)
  -- For now, use a simplified approach with resty.http
  -- Later we can enhance this to use Kong's internal routing
  
  -- Build query string
  local query_string = ""
  if next(http_request.query_params) then
    local query_parts = {}
    for key, value in pairs(http_request.query_params) do
      table.insert(query_parts, ngx.escape_uri(key) .. "=" .. ngx.escape_uri(value))
    end
    query_string = "?" .. table.concat(query_parts, "&")
  end
  
  -- Use Kong route path instead of OpenAPI path
  -- This ensures we hit the actual Kong route that will proxy to the service
  local kong_proxy_url = "http://127.0.0.1:8000"
  local route_path = tool_info and tool_info.route_info and tool_info.route_info.name
  if not route_path then
    return nil, "No route information available for tool execution"
  end
  
  -- Build the full URL using the Kong route name
  local full_url = kong_proxy_url .. "/" .. route_path .. query_string
  
  kong.log.debug("Executing HTTP request: ", http_request.method, " ", full_url)
  
  -- Create HTTP client
  local httpc = http.new()
  httpc:set_timeout(30000)  -- 30 second timeout
  
  -- Prepare request options
  local request_options = {
    method = http_request.method,
    headers = http_request.headers or {},
    body = http_request.body
  }
  
  -- Add consumer context headers if available
  if consumer then
    request_options.headers["X-Consumer-ID"] = consumer.id
    if consumer.username then
      request_options.headers["X-Consumer-Username"] = consumer.username
    end
  end
  
  -- Execute request
  local res, err = httpc:request_uri(full_url, request_options)
  
  if not res then
    kong.log.err("HTTP request failed: ", err or "unknown error")
    return nil, "HTTP request failed: " .. (err or "unknown error")
  end
  
  -- Parse response
  local response = {
    status = res.status,
    headers = res.headers or {},
    body = res.body
  }
  
  kong.log.debug("HTTP request completed with status: ", res.status)
  return response, nil
end--- Transform HTTP response to MCP content format
-- @param response table HTTP response
-- @param tool_info table Tool execution information
-- @return table MCP content result
function _M.transform_http_to_mcp(response, tool_info)
  local content = {}
  
  -- Determine content type from response
  local content_type = response.headers["content-type"] or response.headers["Content-Type"] or "text/plain"
  
  if response.status >= 200 and response.status < 300 then
    -- Success response
    if string.find(content_type, "application/json") then
      -- Try to parse JSON response
      local json_data, parse_err = cjson.decode(response.body or "{}")
      if json_data then
        table.insert(content, {
          type = "text",
          text = "Request successful. Response data:\n" .. cjson.encode(json_data)
        })
      else
        table.insert(content, {
          type = "text", 
          text = "Request successful but response JSON parse failed: " .. (parse_err or "unknown error") .. "\nRaw response: " .. (response.body or "")
        })
      end
    else
      -- Non-JSON response
      table.insert(content, {
        type = "text",
        text = "Request successful. Response (" .. content_type .. "):\n" .. (response.body or "")
      })
    end
  else
    -- Error response
    table.insert(content, {
      type = "text",
      text = "Request failed with status " .. response.status .. ".\nResponse: " .. (response.body or "No response body")
    })
  end
  
  -- Add metadata
  table.insert(content, {
    type = "text",
    text = "\n--- Request Details ---\nStatus: " .. response.status .. "\nContent-Type: " .. content_type
  })
  
  return {
    content = content,
    isError = response.status >= 400
  }
end

return _M