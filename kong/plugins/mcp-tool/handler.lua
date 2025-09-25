-- Kong MCP Tool Plugin  
-- Route-level plugin that converts OpenAPI specs to MCP tools

local kong_meta = require "kong.meta"
local tool_generator = require "kong.plugins.mcp-tool.lib.tool_generator"
local tool_aggregator = require "kong.plugins.mcp-server.lib.tool_aggregator"

-- Kong global available in plugins
local kong = kong

local MCPToolHandler = {
  PRIORITY = 990,  -- Run after auth plugins but before most others
  VERSION = "1.0.0",
}

function MCPToolHandler:init_worker()
  -- Initialize OpenAPI parser and tool cache
  kong.log.info("MCP Tool Plugin initialized")
end

function MCPToolHandler:access(conf)
  -- Skip if plugin is disabled
  if not conf.enabled then
    kong.log.debug("MCP Tool Plugin: Plugin disabled, skipping")
    return
  end
  
  -- Get consumer and route from Kong context 
  -- Note: Consumer may be nil if no authentication plugin is active
  local consumer = kong.client.get_consumer()
  local route = kong.router.get_route()
  
  if not route then
    kong.log.debug("MCP Tool Plugin: No route found - skipping tool registration")
    return
  end
  
  -- Check if tools for this route are already registered (avoid re-registration on every request)
  local route_cache_key = "mcp:tools_registered:" .. route.id
  local tools_registered = kong.cache:get(route_cache_key)
  
  if tools_registered then
    kong.log.debug("MCP Tool Plugin: Tools already registered for route: " .. (route.name or route.id))
    return
  end
  
  kong.log.info("MCP Tool Plugin: Processing route: " .. (route.name or route.id))
  
  if not conf.api_specification or conf.api_specification == "" then
    kong.log.warn("MCP Tool Plugin: No API specification provided for route: " .. (route.name or route.id))
    return
  end
  
  kong.log.info("MCP Tool Plugin: Found API specification for route: " .. (route.name or route.id))
  
  -- Generate tools from OpenAPI specification
  local route_name = route.name or route.id
  local tools, error_msg = tool_generator.generate_tools_from_spec(
    conf.api_specification, 
    route_name, 
    conf.tool_prefix
  )
  
  if not tools then
    kong.log.err("Failed to generate tools for route ", route_name, ": ", error_msg)
    return
  end
  
  if #tools == 0 then
    kong.log.debug("No tools generated for route: ", route_name)
    return
  end
  
  -- Register each tool with the aggregator
  local route_info = {
    id = route.id,
    name = route_name,
    service = route.service,
    paths = route.paths,
    methods = route.methods
  }
  
  local registered_count = 0
  for _, tool_def in ipairs(tools) do
    -- Validate tool definition before registration
    local valid, validation_error = tool_generator.validate_tool_definition(tool_def)
    if valid then
      -- Extract operation data for execution (remove from MCP definition)
      local operation_data = tool_def._operation
      tool_def._operation = nil  -- Remove from MCP definition
      
      local success = tool_aggregator.register_tool(tool_def, route_info, consumer, operation_data)
      if success then
        registered_count = registered_count + 1
      else
        kong.log.warn("Failed to register tool: ", tool_def.name)
      end
    else
      kong.log.err("Invalid tool definition for ", tool_def.name or "unnamed", ": ", validation_error)
    end
  end
  
  kong.log.info("Registered ", registered_count, " MCP tools for route: ", route_name)
  
  -- Mark tools as registered for this route to avoid re-registration
  kong.cache:safe_set(route_cache_key, true, 300) -- Cache for 5 minutes
end

return MCPToolHandler