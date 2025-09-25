-- OpenAPI Specification Parser
-- Parses inline OpenAPI specifications to extract API endpoint information

local cjson = require "cjson.safe"
local kong = kong

local _M = {}

--- Parse OpenAPI specification string
-- @param spec_string string JSON OpenAPI specification
-- @return table|nil Parsed spec data or nil on error
-- @return string|nil Error message if parsing failed
function _M.parse_openapi_spec(spec_string)
  if not spec_string or spec_string == "" then
    return nil, "OpenAPI specification cannot be empty"
  end
  
  -- Parse JSON
  local spec, parse_err = cjson.decode(spec_string)
  if not spec then
    return nil, "Invalid JSON in OpenAPI specification: " .. (parse_err or "unknown error")
  end
  
  -- Validate basic OpenAPI structure
  if not spec.openapi and not spec.swagger then
    return nil, "Invalid OpenAPI specification: missing 'openapi' or 'swagger' field"
  end
  
  -- Check for paths object
  if not spec.paths or type(spec.paths) ~= "table" then
    return nil, "OpenAPI specification must have a 'paths' object"
  end
  
  kong.log.debug("Successfully parsed OpenAPI spec with ", 
                 _M.count_operations(spec), " operations")
  
  return spec, nil
end

--- Extract all operations from OpenAPI paths
-- @param spec table Parsed OpenAPI specification
-- @return table List of operation objects with path and method info
function _M.extract_operations(spec)
  local operations = {}
  
  if not spec.paths then
    return operations
  end
  
  -- Iterate through all paths
  for path, path_obj in pairs(spec.paths) do
    if type(path_obj) == "table" then
      -- Iterate through HTTP methods for this path
      local http_methods = {"get", "post", "put", "patch", "delete", "head", "options"}
      
      for _, method in ipairs(http_methods) do
        local operation = path_obj[method]
        if operation and type(operation) == "table" then
          table.insert(operations, {
            path = path,
            method = method:upper(),
            operation = operation,
            -- Include common fields
            summary = operation.summary,
            description = operation.description,
            operationId = operation.operationId,
            parameters = operation.parameters or {},
            requestBody = operation.requestBody,
            responses = operation.responses or {},
            tags = operation.tags or {}
          })
        end
      end
    end
  end
  
  kong.log.debug("Extracted ", #operations, " operations from OpenAPI spec")
  return operations
end

--- Count total number of operations in spec
-- @param spec table Parsed OpenAPI specification  
-- @return number Total operation count
function _M.count_operations(spec)
  local count = 0
  
  if not spec.paths then
    return count
  end
  
  for path, path_obj in pairs(spec.paths) do
    if type(path_obj) == "table" then
      local http_methods = {"get", "post", "put", "patch", "delete", "head", "options"}
      for _, method in ipairs(http_methods) do
        if path_obj[method] then
          count = count + 1
        end
      end
    end
  end
  
  return count
end

--- Get OpenAPI version string
-- @param spec table Parsed OpenAPI specification
-- @return string Version (e.g., "3.0.1" or "2.0")
function _M.get_version(spec)
  return spec.openapi or spec.swagger or "unknown"
end

--- Get API info from OpenAPI spec
-- @param spec table Parsed OpenAPI specification
-- @return table API info (title, description, version)
function _M.get_api_info(spec)
  local info = spec.info or {}
  return {
    title = info.title or "API",
    description = info.description or "",
    version = info.version or "1.0.0"
  }
end

--- Validate OpenAPI specification structure
-- @param spec table Parsed OpenAPI specification
-- @return boolean true if valid
-- @return string|nil Error message if invalid
function _M.validate_spec(spec)
  -- Check required fields based on OpenAPI version
  if spec.openapi then
    -- OpenAPI 3.0+
    if not spec.info then
      return false, "OpenAPI 3.0+ spec must have 'info' object"
    end
  elseif spec.swagger then
    -- Swagger 2.0
    if spec.swagger ~= "2.0" then
      return false, "Only Swagger 2.0 is supported for legacy specs"
    end
    if not spec.info then
      return false, "Swagger 2.0 spec must have 'info' object"
    end
  else
    return false, "Specification must have 'openapi' or 'swagger' field"
  end
  
  -- Validate info object
  if not spec.info.title then
    return false, "API info must have a title"
  end
  
  return true, nil
end

return _M