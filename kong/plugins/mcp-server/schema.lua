-- MCP Server Plugin Schema
-- Configuration schema for the global MCP server plugin

return {
  name = "mcp-server",
  fields = {
    { protocols = { type = "set", elements = { type = "string", one_of = { "http", "https" } }, default = { "http", "https" } } },
    { config = {
        type = "record",
        fields = {
          { server_name = { 
              type = "string", 
              default = "kong-mcp",
              description = "Name of the MCP server returned in protocol responses"
          }},
          { server_version = { 
              type = "string", 
              default = "1.0.0",
              description = "Version of the MCP server"
          }},
          { max_tools = { 
              type = "integer", 
              default = 1000,
              description = "Maximum number of tools that can be registered"
          }},
          { oauth = {
              type = "record",
              required = false,
              description = "Optional OAuth 2.1 configuration for MCP server",
              fields = {
                { enabled = { 
                    type = "boolean", 
                    default = false, 
                    description = "Enable OAuth 2.1 authentication for MCP server" 
                }},
                { authorization_servers = {
                    type = "array",
                    required = false,
                    elements = { type = "string" },
                    description = "List of OAuth 2.1 authorization server discovery endpoints"
                }},
                { audience = { 
                    type = "string", 
                    required = false, 
                    description = "Expected audience for access tokens" 
                }},
                { required_scopes = {
                    type = "array",
                    required = false,
                    elements = { type = "string" },
                    description = "List of required OAuth scopes for access"
                }},
                { tool_scope_filtering = {
                    type = "boolean",
                    default = false,
                    description = "If true, only show tools to users with matching scopes"
                }},
                { token_validation = {
                    type = "string",
                    required = false,
                    one_of = { "jwt", "introspection" },
                    default = "jwt",
                    description = "Token validation method"
                }}
              }
          }},
        }
    }}
  }
}