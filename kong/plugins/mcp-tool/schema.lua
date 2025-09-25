-- MCP Tool Plugin Schema
-- Configuration schema for the route-level MCP tool plugin

return {
  name = "mcp-tool",
  fields = {
    { protocols = { type = "set", elements = { type = "string", one_of = { "http", "https" } }, default = { "http", "https" } } },
    { config = {
        type = "record",
        fields = {
          { api_specification = {
              type = "string",
              required = true,
              len_min = 50,
              description = "OpenAPI specification as JSON string. This will be parsed to generate MCP tool definitions. Copy and paste the full OpenAPI spec content here.",
          }},
          { tool_prefix = {
              type = "string",
              required = false,
              description = "Optional prefix for generated tool names. If not specified, uses route name.",
          }},
          { enabled = {
              type = "boolean",
              default = true,
              description = "Whether MCP tool generation is enabled for this route",
          }},
          { access_control = {
              type = "record",
              required = false,
              description = "Access control configuration for tools generated from this route",
              fields = {
                { default_requirements = {
                    type = "array",
                    required = false,
                    description = "Default access requirements applied to all tools from this route",
                    elements = {
                      type = "record",
                      fields = {
                        { claim_name = { type = "string", required = true, description = "JWT claim name to check (e.g., 'permissions', 'scope', 'roles')" }},
                        { claim_values = { 
                            type = "array", 
                            required = true,
                            description = "Required values that must be present in the claim",
                            elements = { type = "string" }
                        }},
                        { match_type = { 
                            type = "string", 
                            default = "any",
                            one_of = { "any", "all" },
                            description = "Whether user needs ANY or ALL of the claim_values"
                        }},
                      }
                    }
                }},
                { per_operation_requirements = {
                    type = "array",
                    required = false,
                    description = "Per-operation access requirements with specific operationId targeting",
                    elements = {
                      type = "record",
                      fields = {
                        { operation_id = { type = "string", required = true, description = "OpenAPI operationId to apply these requirements to" }},
                        { claim_name = { type = "string", required = true, description = "JWT claim name to check (e.g., 'permissions', 'scope', 'roles')" }},
                        { claim_values = { type = "array", required = true, description = "Required values that must be present in the claim", elements = { type = "string" }}},
                        { match_type = { type = "string", default = "any", one_of = { "any", "all" }, description = "Whether user needs ANY or ALL of the claim_values" }},
                      }
                    }
                }},
              }
          }},
        }
    }}
  }
}