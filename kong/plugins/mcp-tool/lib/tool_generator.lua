-- MCP Tool Definition Generator
-- Converts OpenAPI operations to MCP tool definitions

local cjson = require "cjson.safe"
local kong = kong
local openapi_parser = require "kong.plugins.mcp-tool.lib.openapi_parser"
local schema_converter = require "kong.plugins.mcp-tool.lib.schema_converter"

local _M = {}

--- Generate MCP tool definition from OpenAPI operation
-- @param operation table OpenAPI operation from parser
-- @param route_name string Kong route name for tool naming
-- @param tool_prefix string|nil Optional tool name prefix
-- @return table MCP tool definition
function _M.generate_tool_definition(operation, route_name, tool_prefix)
  local tool_name = _M.generate_tool_name(operation.method, operation.path, route_name, tool_prefix)
  
  -- Create base tool definition following MCP protocol
  local tool_def = {
    name = tool_name,
    description = _M.generate_description(operation),
    inputSchema = _M.generate_input_schema(operation),
    -- Store metadata for tool execution (not part of MCP spec)
    operation_id = operation.operationId,
    http_method = operation.method:upper(),
    endpoint_path = operation.path,
    _operation = operation
  }
  
  kong.log.debug("Generated MCP tool definition: ", tool_name)
  return tool_def
end

--- Generate tool name following naming convention  
-- @param method string HTTP method (GET, POST, etc.)
-- @param path string OpenAPI path (e.g., "/users/{id}")
-- @param route_name string Kong route name
-- @param tool_prefix string|nil Optional prefix
-- @return string Generated tool name
function _M.generate_tool_name(method, path, route_name, tool_prefix)
  local prefix = tool_prefix or route_name or "api"
  
  -- Simplify path for tool name
  local simplified_path = _M.simplify_path(path)
  
  -- Create tool name: {prefix}_{method}_{path} (MCP requires [a-z0-9_-] only)
  local tool_name = string.format("%s_%s_%s", 
                                  prefix, 
                                  method:lower(), 
                                  simplified_path)
  
  -- Clean up tool name (remove invalid characters)
  tool_name = _M.sanitize_tool_name(tool_name)
  
  return tool_name
end

--- Simplify OpenAPI path for tool naming
-- @param path string OpenAPI path (e.g., "/users/{id}/posts")
-- @return string Simplified path (e.g., "users_id_posts")
function _M.simplify_path(path)
  if not path then
    return "root"
  end
  
  -- Remove leading slash
  path = path:gsub("^/", "")
  
  -- Replace path separators with underscores
  path = path:gsub("/", "_")
  
  -- Remove parameter braces but keep parameter names
  path = path:gsub("{([^}]+)}", "%1")
  
  -- Replace special characters with underscores
  path = path:gsub("[^a-zA-Z0-9_]", "_")
  
  -- Remove multiple consecutive underscores
  path = path:gsub("_+", "_")
  
  -- Remove leading/trailing underscores
  path = path:gsub("^_", ""):gsub("_$", "")
  
  -- Handle empty path
  if path == "" then
    return "root"
  end
  
  return path
end

--- Sanitize tool name for MCP compliance
-- @param name string Raw tool name
-- @return string Sanitized tool name
function _M.sanitize_tool_name(name)
  -- MCP tool names must only contain [a-z0-9_-] (no dots allowed)
  name = name:lower():gsub("[^a-z0-9_-]", "_")
  
  -- Remove multiple consecutive underscores/hyphens
  name = name:gsub("[_-]+", function(match)
    return string.sub(match, 1, 1)
  end)
  
  -- Ensure name doesn't start or end with special chars
  name = name:gsub("^[_-]+", ""):gsub("[_-]+$", "")
  
  return name
end

--- Generate tool description from OpenAPI operation
-- @param operation table OpenAPI operation
-- @return string Tool description
function _M.generate_description(operation)
  -- Use summary first, then description, then generate from method/path
  if operation.summary and operation.summary ~= "" then
    return operation.summary
  end
  
  if operation.description and operation.description ~= "" then
    return operation.description
  end
  
  -- Generate description from method and path
  local method_desc = _M.get_method_description(operation.method)
  local path_desc = operation.path:gsub("{([^}]+)}", "by %1")
  
  return string.format("%s %s", method_desc, path_desc)
end

--- Get descriptive text for HTTP method
-- @param method string HTTP method
-- @return string Method description
function _M.get_method_description(method)
  local descriptions = {
    GET = "Retrieve",
    POST = "Create",
    PUT = "Update", 
    PATCH = "Partially update",
    DELETE = "Delete",
    HEAD = "Get headers for",
    OPTIONS = "Get options for"
  }
  
  return descriptions[method:upper()] or ("Execute " .. method:upper() .. " on")
end

--- Generate JSON Schema for tool input
-- @param operation table OpenAPI operation
-- @return table JSON Schema for tool input parameters
function _M.generate_input_schema(operation)
  local schema = {
    type = "object",
    properties = {},
    required = {}
  }
  
  -- Add path parameters, query parameters, and headers
  if operation.parameters then
    local param_props, param_required = schema_converter.convert_parameters_to_properties(operation.parameters)
    
    -- Merge parameter properties into schema
    for prop_name, prop_schema in pairs(param_props) do
      schema.properties[prop_name] = prop_schema
    end
    
    -- Add required parameters
    for _, req_param in ipairs(param_required) do
      table.insert(schema.required, req_param)
    end
  end
  
  -- Add request body if present
  if operation.requestBody then
    local body_schema = schema_converter.convert_request_body_to_schema(operation.requestBody)
    if body_schema then
      schema.properties.body = body_schema
      
      -- Mark body as required if specified
      if operation.requestBody.required then
        table.insert(schema.required, "body")
      end
    end
  end
  
  -- Ensure required is an array (not object) for JSON serialization
  if #schema.required == 0 then
    schema.required = cjson.empty_array
  end
  
  return schema
end

--- Generate multiple tools from parsed operations
-- @param operations table List of OpenAPI operations from parser
-- @param options table Options with prefix, route_name, route_id
-- @return table List of MCP tool definitions
function _M.generate_tools(operations, options)
  local tools = {}
  local route_name = options.route_name or "api"
  local tool_prefix = options.prefix or route_name
  
  for _, operation in ipairs(operations) do
    local tool_def = _M.generate_tool_definition(operation, route_name, tool_prefix)
    table.insert(tools, tool_def)
  end
  
  kong.log.info("Generated ", #tools, " MCP tools from operations")
  return tools
end

--- Generate multiple tools from OpenAPI specification
-- @param spec_string string OpenAPI specification JSON
-- @param route_name string Kong route name
-- @param tool_prefix string|nil Optional tool prefix
-- @return table List of MCP tool definitions
-- @return string|nil Error message if generation failed
function _M.generate_tools_from_spec(spec_string, route_name, tool_prefix)
  -- Parse OpenAPI specification
  local spec, parse_error = openapi_parser.parse_openapi_spec(spec_string)
  if not spec then
    return nil, "Failed to parse OpenAPI spec: " .. parse_error
  end
  
  -- Validate specification
  local valid, validation_error = openapi_parser.validate_spec(spec)
  if not valid then
    return nil, "Invalid OpenAPI spec: " .. validation_error
  end
  
  -- Extract operations
  local operations = openapi_parser.extract_operations(spec)
  if #operations == 0 then
    kong.log.warn("No operations found in OpenAPI specification")
    return {}, nil
  end
  
  -- Generate tool definitions
  local tools = {}
  for _, operation in ipairs(operations) do
    local tool_def = _M.generate_tool_definition(operation, route_name, tool_prefix)
    table.insert(tools, tool_def)
  end
  
  kong.log.info("Generated ", #tools, " MCP tools from OpenAPI specification")
  return tools, nil
end

--- Validate generated tool definition
-- @param tool_def table MCP tool definition
-- @return boolean true if valid
-- @return string|nil Error message if invalid
function _M.validate_tool_definition(tool_def)
  -- Check required fields
  if not tool_def.name or tool_def.name == "" then
    return false, "Tool definition must have a name"
  end
  
  if not tool_def.description then
    return false, "Tool definition must have a description"
  end
  
  if not tool_def.inputSchema then
    return false, "Tool definition must have an inputSchema"
  end
  
  -- Validate inputSchema is a proper object
  if type(tool_def.inputSchema) ~= "table" then
    return false, "inputSchema must be a table/object"
  end
  
  if tool_def.inputSchema.type ~= "object" then
    return false, "inputSchema must have type 'object'"
  end
  
  return true, nil
end

return _M