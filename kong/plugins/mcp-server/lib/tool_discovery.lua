-- Tool Discovery Module
-- Discovers and aggregates tools from mcp-tool plugins across all routes

local cjson = require "cjson.safe"
local openapi_parser = require "kong.plugins.mcp-tool.lib.openapi_parser"
local tool_generator = require "kong.plugins.mcp-tool.lib.tool_generator"

local kong = kong
local ngx = ngx

local _M = {}

--- Check if user has required access based on JWT claims
-- @param jwt_payload table The decoded JWT payload
-- @param requirements table Array of requirement objects with claim_name, claim_values, match_type
-- @return boolean Whether user has access
local function check_access_requirements(jwt_payload, requirements)
  if not requirements or #requirements == 0 then
    return true -- No requirements means public access
  end
  
  for _, requirement in ipairs(requirements) do
    local claim_name = requirement.claim_name
    local required_values = requirement.claim_values or {}
    local match_type = requirement.match_type or "any"
    
    local user_claim_value = jwt_payload[claim_name]
    if not user_claim_value then
      kong.log.debug("User missing claim: ", claim_name)
      return false
    end
    
    -- Handle both string and array claims
    local user_values = {}
    if type(user_claim_value) == "string" then
      -- Split space-separated values (like OAuth scopes)
      for value in user_claim_value:gmatch("%S+") do
        user_values[value] = true
      end
    elseif type(user_claim_value) == "table" then
      -- Array of values (like permissions)
      for _, value in ipairs(user_claim_value) do
        user_values[value] = true
      end
    else
      user_values[tostring(user_claim_value)] = true
    end
    
    -- Check if user has required values
    local matches = 0
    for _, required_value in ipairs(required_values) do
      if user_values[required_value] then
        matches = matches + 1
      end
    end
    
    if match_type == "all" and matches ~= #required_values then
      kong.log.debug("User missing required values for ", claim_name, " (need all)")
      return false
    elseif match_type == "any" and matches == 0 then
      kong.log.debug("User missing required values for ", claim_name, " (need any)")
      return false
    end
  end
  
  return true
end

--- Discover all tools from mcp-tool plugins
-- @param jwt_payload table|nil The decoded JWT payload for access control (nil = no filtering)
-- @return table Array of MCP tool definitions
function _M.discover_tools(jwt_payload)
  local all_tools = {}
  
  kong.log.info("Starting tool discovery from mcp-tool plugins")
  
  -- Get all routes from Kong's DAO
  local routes, err = kong.db.routes:each()
  if not routes then
    kong.log.err("Failed to retrieve routes for tool discovery: ", err)
    return {}
  end
  
  local route_count = 0
  local plugin_count = 0
  local tool_count = 0
  
  for route in routes do
    route_count = route_count + 1
    
    -- Get plugins for this route
    local plugins, err = kong.db.plugins:each(nil, { route = { id = route.id } })
    if plugins then
      for plugin in plugins do
        if plugin.name == "mcp-tool" and plugin.enabled ~= false and (plugin.route and plugin.route.id == route.id) then
          plugin_count = plugin_count + 1
          kong.log.info("Found enabled mcp-tool plugin on route: ", route.name or route.id)
          
          local config = plugin.config
          if config and config.api_specification then
            -- Parse OpenAPI specification
            local spec, parse_err = cjson.decode(config.api_specification)
            if spec then
              -- Generate tools from OpenAPI spec
              local operations = openapi_parser.extract_operations(spec)
              local route_tools = tool_generator.generate_tools(operations, {
                prefix = config.tool_prefix or route.name or "tool",
                route_name = route.name,
                route_id = route.id
              })
              
              -- Apply access control filtering
              for _, tool in ipairs(route_tools) do
                local tool_accessible = true
                
                if jwt_payload and config.access_control then
                  local access_config = config.access_control
                  local requirements = access_config.default_requirements
                  
                  -- Check for per-operation requirements (UI-friendly array format)
                  if access_config.per_operation_requirements and tool.operation_id then
                    for _, op_req in ipairs(access_config.per_operation_requirements) do
                      if op_req.operation_id == tool.operation_id then
                        -- Convert single requirement to array format for consistency
                        requirements = { op_req }
                        break
                      end
                    end
                  end
                  
                  tool_accessible = check_access_requirements(jwt_payload, requirements)
                  
                  if tool_accessible then
                    kong.log.info("Tool '", tool.name, "' granted access")
                  else
                    kong.log.info("Tool '", tool.name, "' denied access - insufficient permissions")
                  end
                else
                  kong.log.debug("Tool '", tool.name, "' granted - no access control or no JWT")
                end
                
                if tool_accessible then
                  -- Add route context to tool
                  tool.route_name = route.name
                  tool.route_id = route.id
                  tool.route_path = route.paths and route.paths[1] or "/"
                  
                  table.insert(all_tools, tool)
                  tool_count = tool_count + 1
                end
              end
            else
              kong.log.err("Failed to parse OpenAPI spec for route ", route.name, ": ", parse_err)
            end
          end
        end
      end
    end
  end
  
  kong.log.info("Tool discovery complete - checked ", route_count, " routes, found ", plugin_count, " mcp-tool plugins, returning ", tool_count, " accessible tools")
  
  -- Deduplicate tools by name (in case same tool appears on multiple routes)
  local unique_tools = {}
  local seen_names = {}
  
  for _, tool in ipairs(all_tools) do
    if not seen_names[tool.name] then
      seen_names[tool.name] = true
      table.insert(unique_tools, tool)
    else
      kong.log.debug("Skipping duplicate tool: ", tool.name)
    end
  end
  
  kong.log.info("After deduplication: ", #unique_tools, " unique tools")
  
  return unique_tools
end

return _M