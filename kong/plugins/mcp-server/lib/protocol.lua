-- MCP Protocol State Management
-- Handles MCP protocol lifecycle, sessions, and notifications

local cjson = require "cjson.safe"

-- Kong global for logging and cache access
local kong = kong

local _M = {}

-- MCP Protocol States
local PROTOCOL_STATES = {
  UNINITIALIZED = "uninitialized",
  INITIALIZING = "initializing", 
  INITIALIZED = "initialized",
  ERROR = "error"
}

--- Initialize MCP session state
-- Creates a new MCP session and stores it in Kong's shared cache
-- @param session_id string Unique session identifier
-- @param client_info table Client information from initialize request
-- @return boolean success
function _M.init_session(session_id, client_info)
  if not session_id then
    kong.log.err("Cannot initialize session: session_id is required")
    return false
  end
  
  local session = {
    id = session_id,
    state = PROTOCOL_STATES.INITIALIZING,
    client_info = client_info or {},
    created_at = ngx.time(),
    last_activity = ngx.time(),
    protocol_version = "2024-11-05"
  }
  
  -- Store session in Kong's cache with TTL (1 hour default)
  local ttl = 3600
  local cache_key = "mcp:session:" .. session_id
  local success, err = kong.cache:safe_set(cache_key, session, ttl)
  
  if not success then
    kong.log.err("Failed to store MCP session: ", err)
    return false
  end
  
  kong.log.debug("MCP session initialized: ", session_id)
  return true
end

--- Get MCP session state
-- @param session_id string Session identifier
-- @return table|nil session data
function _M.get_session(session_id)
  if not session_id then
    return nil
  end
  
  local cache_key = "mcp:session:" .. session_id
  local session, err = kong.cache:get(cache_key)
  
  if err then
    kong.log.err("Error retrieving MCP session: ", err)
    return nil
  end
  
  return session
end

--- Update session state
-- @param session_id string Session identifier
-- @param state string New state
-- @return boolean success
function _M.update_session_state(session_id, state)
  local session = _M.get_session(session_id)
  if not session then
    kong.log.warn("Cannot update state: session not found: ", session_id)
    return false
  end
  
  session.state = state
  session.last_activity = ngx.time()
  
  local cache_key = "mcp:session:" .. session_id
  local ttl = 3600
  local success, err = kong.cache:safe_set(cache_key, session, ttl)
  
  if not success then
    kong.log.err("Failed to update MCP session state: ", err)
    return false
  end
  
  kong.log.debug("MCP session state updated: ", session_id, " -> ", state)
  return true
end

--- Mark session as fully initialized
-- Called after receiving notifications/initialized
-- @param session_id string Session identifier
-- @return boolean success  
function _M.mark_initialized(session_id)
  return _M.update_session_state(session_id, PROTOCOL_STATES.INITIALIZED)
end

--- Check if session is initialized
-- @param session_id string Session identifier
-- @return boolean is_initialized
function _M.is_initialized(session_id)
  local session = _M.get_session(session_id)
  return session and session.state == PROTOCOL_STATES.INITIALIZED
end

--- Generate session ID from request context
-- Creates a unique session ID based on client IP and user agent
-- @return string session_id
function _M.generate_session_id()
  local remote_addr = kong.client.get_ip()
  local user_agent = kong.request.get_header("user-agent") or "unknown"
  local timestamp = ngx.time()
  
  -- Create deterministic but unique session ID
  local session_data = remote_addr .. ":" .. user_agent .. ":" .. timestamp
  local session_id = ngx.md5(session_data)
  
  return session_id
end

--- Handle MCP notifications/initialized message
-- This is called after a successful initialize to confirm the client is ready
-- @param request table JSON-RPC notification
-- @return boolean success
function _M.handle_initialized_notification(request)
  -- For notifications, there might not be a session ID in the standard way
  -- We'll use the request context to identify the session
  local session_id = _M.generate_session_id()
  
  if not _M.mark_initialized(session_id) then
    kong.log.err("Failed to mark session as initialized: ", session_id)
    return false
  end
  
  kong.log.info("MCP client completed initialization: ", session_id)
  return true
end

--- Cleanup expired sessions
-- Called periodically to remove old sessions
-- @param max_age_seconds number Maximum session age (default 3600)
function _M.cleanup_expired_sessions(max_age_seconds)
  max_age_seconds = max_age_seconds or 3600
  local current_time = ngx.time()
  
  -- TODO: Implement proper session cleanup
  -- For now, sessions auto-expire via TTL in cache
  kong.log.debug("Session cleanup would run here")
end

-- Export protocol states for external use
_M.STATES = PROTOCOL_STATES

return _M