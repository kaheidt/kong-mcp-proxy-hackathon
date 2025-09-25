-- MCP Error Definitions
-- Standard JSON-RPC 2.0 and MCP-specific error codes and messages

local _M = {}

-- Standard JSON-RPC 2.0 error codes
local JSONRPC_ERRORS = {
  PARSE_ERROR = {
    code = -32700,
    message = "Parse error"
  },
  INVALID_REQUEST = {
    code = -32600,
    message = "Invalid Request"
  },
  METHOD_NOT_FOUND = {
    code = -32601,
    message = "Method not found"
  },
  INVALID_PARAMS = {
    code = -32602,
    message = "Invalid params"
  },
  INTERNAL_ERROR = {
    code = -32603,
    message = "Internal error"
  }
}

-- MCP-specific error codes (using -32000 to -32099 range)
local MCP_ERRORS = {
  TOOL_NOT_FOUND = {
    code = -32001,
    message = "Tool not found"
  },
  TOOL_UNAUTHORIZED = {
    code = -32002,
    message = "Unauthorized access to tool"
  },
  TOOL_EXECUTION_ERROR = {
    code = -32003,
    message = "Tool execution failed"
  },
  INVALID_TOOL_ARGUMENTS = {
    code = -32004,
    message = "Invalid tool arguments"
  },
  MCP_NOT_INITIALIZED = {
    code = -32005,
    message = "MCP connection not initialized"
  },
  UNSUPPORTED_CAPABILITY = {
    code = -32006,
    message = "Unsupported capability"
  }
}

-- Combine all errors
local ALL_ERRORS = {}
for k, v in pairs(JSONRPC_ERRORS) do
  ALL_ERRORS[k] = v
end
for k, v in pairs(MCP_ERRORS) do
  ALL_ERRORS[k] = v
end

--- Get error definition by type
-- @param error_type string Error type constant
-- @return table Error definition with code and message
function _M.get_error(error_type)
  local error_def = ALL_ERRORS[error_type]
  if not error_def then
    -- Fallback to internal error
    return ALL_ERRORS.INTERNAL_ERROR
  end
  return error_def
end

--- Get all error definitions
-- @return table All error definitions
function _M.get_all_errors()
  return ALL_ERRORS
end

-- Export error type constants
_M.PARSE_ERROR = "PARSE_ERROR"
_M.INVALID_REQUEST = "INVALID_REQUEST"
_M.METHOD_NOT_FOUND = "METHOD_NOT_FOUND"
_M.INVALID_PARAMS = "INVALID_PARAMS"
_M.INTERNAL_ERROR = "INTERNAL_ERROR"
_M.TOOL_NOT_FOUND = "TOOL_NOT_FOUND"
_M.TOOL_UNAUTHORIZED = "TOOL_UNAUTHORIZED"
_M.TOOL_EXECUTION_ERROR = "TOOL_EXECUTION_ERROR"
_M.INVALID_TOOL_ARGUMENTS = "INVALID_TOOL_ARGUMENTS"
_M.MCP_NOT_INITIALIZED = "MCP_NOT_INITIALIZED"
_M.UNSUPPORTED_CAPABILITY = "UNSUPPORTED_CAPABILITY"

return _M