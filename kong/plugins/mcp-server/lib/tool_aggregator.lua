-- MCP Tool Aggregation System
-- Collects and manages MCP tools from all configured routes

local cjson = require "cjson.safe"

-- Kong and nginx globals (available at runtime)
local kong = kong
local ngx = ngx

local _M = {}

--- Get all tools available to a specific consumer
-- Aggregates tools from all mcp-tool plugins the consumer has access to
-- @param consumer table|nil Kong consumer (nil for anonymous)
-- @return table List of MCP tool definitions
function _M.get_tools_for_consumer(consumer)
  local tools = {}
  
  kong.log.info("[mcp-server] Aggregating tools for consumer: ", consumer and consumer.username or "anonymous")
  
  -- Get all cached tools for this consumer
  local consumer_id = consumer and consumer.id or "anonymous"
  local cache_pattern = "mcp:tool:*:" .. consumer_id
  
  kong.log.info("[mcp-server] Consumer ID: ", consumer_id)
  
  -- For Kong cache, we need to iterate through known tool names
  -- Since Kong cache doesn't support pattern matching, we'll collect tools differently
  
  -- Alternative approach: collect from known tool registrations
  tools = _M.collect_registered_tools(consumer)
  
  kong.log.info("[mcp-server] Tool aggregation complete: ", #tools, " tools found")
  return tools
end

--- Get all tools (for administrative purposes)
-- Returns all available tools regardless of consumer permissions
-- @return table List of all MCP tool definitions
function _M.get_all_tools()
  local tools = {}
  
  kong.log.debug("Retrieving all available tools")
  
  -- TODO: Implement in Phase 3
  -- This will iterate through all routes and collect tools
  
  return tools
end

--- Register a tool from an mcp-tool plugin
-- Called by mcp-tool plugin handlers during route processing
-- @param tool_definition table MCP tool definition
-- @param route_info table Route information
-- @param consumer table|nil Associated consumer (for scoping)
-- @param openapi_operation table|nil OpenAPI operation data for execution
-- @return boolean success
function _M.register_tool(tool_definition, route_info, consumer, openapi_operation)
  if not tool_definition or not tool_definition.name then
    kong.log.err("Cannot register tool: invalid tool definition")
    return false
  end
  
  local consumer_id = consumer and consumer.id or "anonymous"
  local cache_key = "mcp:tool:" .. tool_definition.name .. ":" .. consumer_id
  
  kong.log.info("Registering MCP tool: ", tool_definition.name, " with cache key: ", cache_key)
  kong.log.debug("Tool definition: ", require("cjson.safe").encode(tool_definition))
  
  -- Store tool definition in Kong's cache
  local ttl = 3600  -- 1 hour TTL
  local tool_data = {
    definition = tool_definition,
    route_info = route_info,
    consumer = consumer,
    openapi_operation = openapi_operation,  -- Store for execution
    registered_at = ngx.time()
  }
  local success, err = kong.cache:safe_set(cache_key, tool_data, ttl)
  
  kong.log.info("Tool cache set result: success=", success, " err=", err)
  
  if not success then
    kong.log.err("Failed to register tool in cache: ", err)
    return false
  end
  
  -- Update tool registry for easy tool discovery
  local registry_updated = _M.update_tool_registry(tool_definition.name, consumer, true)
  if not registry_updated then
    kong.log.warn("Tool registered but registry update failed for: ", tool_definition.name)
  end
  
  kong.log.info("Tool registration complete: ", tool_definition.name, " for route: ", route_info.name or route_info.id)
  return true
end

--- Unregister a tool
-- @param tool_name string Tool name to remove
-- @param consumer table|nil Consumer scope
-- @return boolean success
function _M.unregister_tool(tool_name, consumer)
  local cache_key = "mcp:tool:" .. tool_name
  if consumer then
    cache_key = cache_key .. ":" .. (consumer.id or "anonymous")
  end
  
  local success, err = kong.cache:delete(cache_key)
  if not success then
    kong.log.err("Failed to unregister tool: ", err)
    return false
  end
  
  -- Update tool registry to remove tool
  local registry_updated = _M.update_tool_registry(tool_name, consumer, false)
  if not registry_updated then
    kong.log.warn("Tool unregistered but registry update failed for: ", tool_name)
  end
  
  kong.log.debug("Tool unregistered: ", tool_name)
  return true
end

--- Get tool definition by name
-- @param tool_name string Tool name
-- @param consumer table|nil Consumer for scoped lookup
-- @return table|nil Tool definition
function _M.get_tool(tool_name, consumer)
  local cache_key = "mcp:tool:" .. tool_name
  if consumer then
    cache_key = cache_key .. ":" .. (consumer.id or "anonymous")
  end
  
  local tool_data, err = kong.cache:get(cache_key)
  if err then
    kong.log.err("Error retrieving tool: ", err)
    return nil
  end
  
  return tool_data and tool_data.definition or nil
end

--- Check if a tool exists for a consumer
-- @param tool_name string Tool name
-- @param consumer table|nil Consumer for scoped lookup  
-- @return boolean exists
function _M.tool_exists(tool_name, consumer)
  local tool = _M.get_tool(tool_name, consumer)
  return tool ~= nil
end

--- Filter tools based on consumer permissions
-- This is a placeholder for future ACL integration
-- @param tools table List of tools
-- @param consumer table|nil Consumer
-- @return table Filtered tools list
function _M.filter_tools_by_permissions(tools, consumer)
  -- TODO: Implement proper ACL filtering in Phase 5
  -- For now, return all tools (no filtering)
  return tools
end

--- Generate tool name using naming convention
-- Creates tool names following the {prefix}.{method}_{path} pattern
-- @param method string HTTP method
-- @param path string API path
-- @param prefix string|nil Optional prefix (defaults to route name)
-- @return string Generated tool name
function _M.generate_tool_name(method, path, prefix)
  if not method or not path then
    return nil
  end
  
  -- Normalize method to lowercase
  method = string.lower(method)
  
  -- Simplify path by removing parameters and special chars
  local simplified_path = path
  simplified_path = string.gsub(simplified_path, "^/", "")  -- Remove leading slash
  simplified_path = string.gsub(simplified_path, "/", "_")  -- Replace slashes with underscores
  simplified_path = string.gsub(simplified_path, "{[^}]+}", "param")  -- Replace {param} with param
  simplified_path = string.gsub(simplified_path, "[^a-zA-Z0-9_]", "")  -- Remove special chars
  
  -- Build tool name
  local tool_name = method .. "_" .. simplified_path
  
  if prefix and prefix ~= "" then
    tool_name = prefix .. "." .. tool_name
  end
  
  return tool_name
end

--- Collect tools registered for a specific consumer
-- @param consumer table|nil Kong consumer
-- @return table List of MCP tool definitions
function _M.collect_registered_tools(consumer)
  local tools = {}
  local consumer_id = consumer and consumer.id or "anonymous"
  
  -- Since Kong cache doesn't support pattern iteration, we'll use a registry approach
  -- Get the tool registry for this consumer
  local registry_key = "mcp:tool_registry:" .. consumer_id
  kong.log.info("[mcp-server] Looking for tool registry with key: ", registry_key)
  local tool_registry, err = kong.cache:get(registry_key)
  
  if not tool_registry then
    -- No tools registered for this consumer yet
    kong.log.info("[mcp-server] No tool registry found for consumer: ", consumer_id)
    return tools
  end
  
  kong.log.info("[mcp-server] Found tool registry with ", type(tool_registry) == "table" and (#tool_registry > 0 and #tool_registry or "unknown count") or 0, " entries")
  
  -- Retrieve each registered tool
  for tool_name, _ in pairs(tool_registry) do
    local tool_cache_key = "mcp:tool:" .. tool_name .. ":" .. consumer_id
    kong.log.info("[mcp-server] Looking for tool with cache key: ", tool_cache_key)
    local tool_entry, cache_err = kong.cache:get(tool_cache_key)
    
    if tool_entry and tool_entry.definition then
      table.insert(tools, tool_entry.definition)
      kong.log.info("[mcp-server] Retrieved tool from cache: ", tool_name)
    else
      kong.log.warn("[mcp-server] Failed to retrieve tool from cache: ", tool_name, " - ", cache_err or "not found")
      -- Remove stale entry from registry
      tool_registry[tool_name] = nil
    end
  end
  
  -- Update registry if we removed stale entries
  if next(tool_registry) == nil then
    -- Registry is empty, remove it
    kong.cache:invalidate(registry_key)
  else
    -- Update registry with clean entries
    kong.cache:safe_set(registry_key, tool_registry, 3600)
  end
  
  kong.log.info("[mcp-server] Collected ", #tools, " tools for consumer: ", consumer_id)
  return tools
end

--- Update tool registry for consumer
-- @param tool_name string Name of the tool
-- @param consumer table|nil Kong consumer
-- @param add boolean true to add, false to remove
-- @return boolean success
function _M.update_tool_registry(tool_name, consumer, add)
  local consumer_id = consumer and consumer.id or "anonymous"
  local registry_key = "mcp:tool_registry:" .. consumer_id
  
  kong.log.info("Updating tool registry with key: ", registry_key, " tool: ", tool_name, " add: ", add)
  
  -- Get existing registry
  local tool_registry, err = kong.cache:get(registry_key)
  if not tool_registry then
    tool_registry = {}
    kong.log.debug("Created new tool registry for consumer: ", consumer_id)
  else
    kong.log.debug("Found existing tool registry with ", type(tool_registry) == "table" and #tool_registry or 0, " entries")
  end
  
  -- Update registry
  if add then
    tool_registry[tool_name] = true
  else
    tool_registry[tool_name] = nil
  end
  
  -- Save updated registry
  local ttl = 3600  -- 1 hour TTL
  local success, set_err = kong.cache:safe_set(registry_key, tool_registry, ttl)
  
  kong.log.info("Registry save result: success=", success, " err=", set_err)
  
  if not success then
    kong.log.err("Failed to update tool registry: ", set_err)
    return false
  end
  
  kong.log.info("Tool registry updated for consumer: ", consumer_id, " tool: ", tool_name, " add: ", add)
  return true
end

--- Clear all cached tools
-- Used for testing and debugging
function _M.clear_cache()
  -- TODO: Implement cache pattern matching to clear mcp:tool:* keys
  kong.log.debug("Tool cache cleared")
end

return _M