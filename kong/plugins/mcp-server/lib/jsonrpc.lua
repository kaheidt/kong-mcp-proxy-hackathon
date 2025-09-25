-- JSON-RPC 2.0 Message Handling Library
-- Handles parsing, validation, and generation of JSON-RPC 2.0 messages for MCP

local cjson = require("cjson.safe")
local mcp_errors = require "kong.plugins.mcp-server.lib.mcp_errors"

local _M = {}

-- JSON-RPC 2.0 constants
local JSONRPC_VERSION = "2.0"

--- Parse and validate a JSON-RPC 2.0 request
-- @param body string Raw request body
-- @return table|nil Parsed request object or nil on error
-- @return string|nil Error message if parsing failed
function _M.parse_request(body)
  if not body or body == "" then
    return nil, "Empty request body"
  end
  
  -- Parse JSON
  local request, err = cjson.decode(body)
  if not request then
    return nil, "Invalid JSON: " .. (err or "unknown error")
  end
  
  -- Validate JSON-RPC 2.0 structure
  if request.jsonrpc ~= JSONRPC_VERSION then
    return nil, "Invalid JSON-RPC version, expected '2.0'"
  end
  
  if not request.method or type(request.method) ~= "string" then
    return nil, "Missing or invalid 'method' field"
  end
  
  -- ID is optional for notifications, but if present must be string, number, or null
  if request.id ~= nil then
    local id_type = type(request.id)
    if id_type ~= "string" and id_type ~= "number" then
      return nil, "Invalid 'id' field type"
    end
  end
  
  -- Params is optional, but if present must be object or array
  if request.params ~= nil then
    local params_type = type(request.params)
    if params_type ~= "table" then
      return nil, "Invalid 'params' field type"
    end
  end
  
  return request, nil
end

--- Create a JSON-RPC 2.0 success response
-- @param id string|number Request ID
-- @param result table Result data
-- @return table JSON-RPC response object (not encoded)
function _M.create_success_response(id, result)
  local response = {
    jsonrpc = JSONRPC_VERSION,
    id = id,
    result = result
  }
  
  return response
end

--- Create a JSON-RPC 2.0 error response
-- @param id string|number|nil Request ID (nil for parse errors)
-- @param code number Error code
-- @param message string Error message
-- @param data table|nil Optional error data
-- @return table JSON-RPC error response object (not encoded)
function _M.create_error_response(id, code, message, data)
  local error_obj = {
    code = code,
    message = message
  }
  
  if data then
    error_obj.data = data
  end
  
  local response = {
    jsonrpc = JSONRPC_VERSION,
    id = id,
    error = error_obj
  }
  
  return response
end

--- Create a pre-defined error response using MCP error codes
-- @param id string|number|nil Request ID
-- @param error_type string Error type from mcp_errors
-- @param data table|nil Optional error data
-- @return string JSON-RPC error response
function _M.create_mcp_error_response(id, error_type, data)
  local error_def = mcp_errors.get_error(error_type)
  return _M.create_error_response(id, error_def.code, error_def.message, data)
end

--- Validate that a method is supported
-- @param method string Method name
-- @return boolean True if method is supported
function _M.is_supported_method(method)
  local supported_methods = {
    "initialize",
    "tools/list", 
    "tools/call",
    "notifications/initialized"
  }
  
  for _, supported in ipairs(supported_methods) do
    if method == supported then
      return true
    end
  end
  
  return false
end

--- Check if request is a notification (no response expected)
-- @param request table Parsed JSON-RPC request
-- @return boolean True if notification
function _M.is_notification(request)
  return request.id == nil
end

return _M