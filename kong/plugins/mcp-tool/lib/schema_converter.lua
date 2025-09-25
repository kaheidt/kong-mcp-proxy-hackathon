-- OpenAPI to JSON Schema Converter
-- Converts OpenAPI parameter and schema definitions to JSON Schema format for MCP tools

local cjson = require "cjson.safe"
local kong = kong

local _M = {}

--- Convert OpenAPI parameter to JSON Schema property
-- @param parameter table OpenAPI parameter object
-- @return table JSON Schema property definition
function _M.convert_parameter_to_schema(parameter)
  local schema = {}
  
  -- Basic type mapping
  if parameter.schema then
    schema = _M.convert_openapi_schema(parameter.schema)
  elseif parameter.type then
    -- Swagger 2.0 style parameter
    schema = _M.convert_swagger_type(parameter)
  end
  
  -- Add description
  if parameter.description then
    schema.description = parameter.description
  end
  
  -- Handle required parameters
  if parameter.required then
    schema.required = true
  end
  
  -- Add parameter location as metadata
  schema["x-parameter-in"] = parameter["in"]
  
  return schema
end

--- Convert OpenAPI schema object to JSON Schema
-- @param openapi_schema table OpenAPI schema definition
-- @return table JSON Schema definition
function _M.convert_openapi_schema(openapi_schema)
  local schema = {}
  
  -- Copy basic properties
  local basic_props = {"type", "title", "description", "default", "example"}
  for _, prop in ipairs(basic_props) do
    if openapi_schema[prop] ~= nil then
      schema[prop] = openapi_schema[prop]
    end
  end
  
  -- Handle type-specific conversions
  if openapi_schema.type == "string" then
    _M.convert_string_schema(openapi_schema, schema)
  elseif openapi_schema.type == "number" or openapi_schema.type == "integer" then
    _M.convert_numeric_schema(openapi_schema, schema)
  elseif openapi_schema.type == "array" then
    _M.convert_array_schema(openapi_schema, schema)
  elseif openapi_schema.type == "object" then
    _M.convert_object_schema(openapi_schema, schema)
  end
  
  -- Handle enum
  if openapi_schema.enum then
    schema.enum = openapi_schema.enum
  end
  
  return schema
end

--- Convert string schema properties
-- @param openapi_schema table OpenAPI string schema
-- @param schema table Target JSON Schema
function _M.convert_string_schema(openapi_schema, schema)
  -- String constraints
  if openapi_schema.minLength then
    schema.minLength = openapi_schema.minLength
  end
  if openapi_schema.maxLength then
    schema.maxLength = openapi_schema.maxLength
  end
  if openapi_schema.pattern then
    schema.pattern = openapi_schema.pattern
  end
  
  -- String formats
  if openapi_schema.format then
    schema.format = openapi_schema.format
  end
end

--- Convert numeric schema properties
-- @param openapi_schema table OpenAPI numeric schema
-- @param schema table Target JSON Schema
function _M.convert_numeric_schema(openapi_schema, schema)
  -- Numeric constraints
  if openapi_schema.minimum then
    schema.minimum = openapi_schema.minimum
  end
  if openapi_schema.maximum then
    schema.maximum = openapi_schema.maximum
  end
  if openapi_schema.exclusiveMinimum then
    schema.exclusiveMinimum = openapi_schema.exclusiveMinimum
  end
  if openapi_schema.exclusiveMaximum then
    schema.exclusiveMaximum = openapi_schema.exclusiveMaximum
  end
  if openapi_schema.multipleOf then
    schema.multipleOf = openapi_schema.multipleOf
  end
end

--- Convert array schema properties
-- @param openapi_schema table OpenAPI array schema
-- @param schema table Target JSON Schema
function _M.convert_array_schema(openapi_schema, schema)
  -- Array constraints
  if openapi_schema.minItems then
    schema.minItems = openapi_schema.minItems
  end
  if openapi_schema.maxItems then
    schema.maxItems = openapi_schema.maxItems
  end
  if openapi_schema.uniqueItems then
    schema.uniqueItems = openapi_schema.uniqueItems
  end
  
  -- Array items schema
  if openapi_schema.items then
    schema.items = _M.convert_openapi_schema(openapi_schema.items)
  end
end

--- Convert object schema properties
-- @param openapi_schema table OpenAPI object schema
-- @param schema table Target JSON Schema
function _M.convert_object_schema(openapi_schema, schema)
  -- Object properties
  if openapi_schema.properties then
    schema.properties = {}
    for prop_name, prop_schema in pairs(openapi_schema.properties) do
      schema.properties[prop_name] = _M.convert_openapi_schema(prop_schema)
    end
  end
  
  -- Required properties
  if openapi_schema.required then
    schema.required = openapi_schema.required
  end
  
  -- Additional properties
  if openapi_schema.additionalProperties ~= nil then
    if type(openapi_schema.additionalProperties) == "table" then
      schema.additionalProperties = _M.convert_openapi_schema(openapi_schema.additionalProperties)
    else
      schema.additionalProperties = openapi_schema.additionalProperties
    end
  end
end

--- Convert Swagger 2.0 style parameter type
-- @param parameter table Swagger parameter with type/format
-- @return table JSON Schema definition
function _M.convert_swagger_type(parameter)
  local schema = {
    type = parameter.type
  }
  
  -- Handle format
  if parameter.format then
    schema.format = parameter.format
  end
  
  -- Handle constraints based on type
  if parameter.type == "string" then
    if parameter.minLength then schema.minLength = parameter.minLength end
    if parameter.maxLength then schema.maxLength = parameter.maxLength end
    if parameter.pattern then schema.pattern = parameter.pattern end
  elseif parameter.type == "number" or parameter.type == "integer" then
    if parameter.minimum then schema.minimum = parameter.minimum end
    if parameter.maximum then schema.maximum = parameter.maximum end
  elseif parameter.type == "array" then
    if parameter.items then
      schema.items = _M.convert_swagger_type(parameter.items)
    end
    if parameter.minItems then schema.minItems = parameter.minItems end
    if parameter.maxItems then schema.maxItems = parameter.maxItems end
  end
  
  -- Handle enum
  if parameter.enum then
    schema.enum = parameter.enum
  end
  
  return schema
end

--- Convert operation parameters to JSON Schema properties
-- @param parameters table List of OpenAPI parameters
-- @return table JSON Schema properties object
-- @return table List of required property names
function _M.convert_parameters_to_properties(parameters)
  local properties = {}
  local required = {}
  
  for _, param in ipairs(parameters or {}) do
    if param.name then
      properties[param.name] = _M.convert_parameter_to_schema(param)
      
      -- Track required parameters
      if param.required then
        table.insert(required, param.name)
      end
    end
  end
  
  return properties, required
end

--- Convert request body to JSON Schema property
-- @param request_body table OpenAPI requestBody object
-- @return table|nil JSON Schema for body or nil if no schema
function _M.convert_request_body_to_schema(request_body)
  if not request_body or not request_body.content then
    return nil
  end
  
  -- Look for JSON content types first
  local json_types = {
    "application/json",
    "application/vnd.api+json", 
    "text/json"
  }
  
  for _, content_type in ipairs(json_types) do
    local content = request_body.content[content_type]
    if content and content.schema then
      local schema = _M.convert_openapi_schema(content.schema)
      schema.description = request_body.description or "Request body"
      return schema
    end
  end
  
  -- Fallback to first available content type with schema
  for content_type, content in pairs(request_body.content) do
    if content.schema then
      local schema = _M.convert_openapi_schema(content.schema)
      schema.description = request_body.description or ("Request body (" .. content_type .. ")")
      schema["x-content-type"] = content_type
      return schema
    end
  end
  
  return nil
end

return _M