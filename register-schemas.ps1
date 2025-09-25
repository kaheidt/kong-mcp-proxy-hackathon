# Kong MCP Plugin Schema Registration
# Single source of truth for registering both MCP plugin schemas with Konnect
# Uses local schema.lua files as the authoritative source

param(
    [string]$ControlPlaneName,
    [string]$ControlPlaneId
)

# Function to load environment variables from .env file
function Load-EnvFile {
    param([string]$EnvFile = ".env")
    
    if (Test-Path $EnvFile) {
        Write-Host "Loading environment from $EnvFile" -ForegroundColor Gray
        Get-Content $EnvFile | ForEach-Object {
            if ($_ -match "^\s*([^#][^=]*)\s*=\s*(.*)\s*$") {
                $name = $matches[1].Trim()
                $value = $matches[2].Trim()
                # Remove quotes if present
                $value = $value -replace '^["'']|["'']$', ''
                [Environment]::SetEnvironmentVariable($name, $value, "Process")
                Write-Host "  $name = $value" -ForegroundColor DarkGray
            }
        }
    } else {
        Write-Host "Warning: $EnvFile not found. Using environment variables or defaults." -ForegroundColor Yellow
    }
}

# Load environment variables from .env file
Load-EnvFile

# Set defaults from .env or parameters
if (-not $ControlPlaneName) {
    $ControlPlaneName = $env:CONTROL_PLANE_NAME
    if (-not $ControlPlaneName) {
        $ControlPlaneName = "mcp-test-local"
    }
}

if (-not $ControlPlaneId) {
    $ControlPlaneId = $env:CONTROL_PLANE_ID
    if (-not $ControlPlaneId) {
        Write-Host "❌ CONTROL_PLANE_ID not set in .env file or parameter" -ForegroundColor Red
        exit 1
    }
}

# Check for Konnect token
$konnectToken = $env:KONNECT_TOKEN
if (-not $konnectToken) {
    $konnectToken = $env:DECK_KONNECT_TOKEN
}

if (-not $konnectToken) {
    Write-Host "❌ KONNECT_TOKEN not set in .env file or environment" -ForegroundColor Red
    Write-Host "Please set your Konnect Personal Access Token in .env file:" -ForegroundColor Yellow
    Write-Host "  KONNECT_TOKEN=your-token-here" -ForegroundColor Gray
    Write-Host "Or set environment variable:" -ForegroundColor Yellow
    Write-Host "  `$env:KONNECT_TOKEN = 'your-token-here'" -ForegroundColor Gray
    exit 1
}

Write-Host "Kong MCP Plugin Schema Registration" -ForegroundColor Green
Write-Host "Control Plane: $ControlPlaneName" -ForegroundColor Cyan
Write-Host ""

$headers = @{
    'Authorization' = "Bearer $konnectToken"
    'Content-Type' = 'application/json'
}

$uri = "https://us.api.konghq.com/v2/control-planes/$ControlPlaneId/core-entities/plugin-schemas"

# Function to register a schema from local .lua file
function Register-PluginSchema {
    param($PluginName, $SchemaPath)
    
    Write-Host "Registering $PluginName schema..." -ForegroundColor Yellow
    
    if (-not (Test-Path $SchemaPath)) {
        Write-Host "❌ Schema file not found: $SchemaPath" -ForegroundColor Red
        return $false
    }
    
    Write-Host "Getting content $SchemaPath"
    # Read the Lua schema file content
    $luaSchema = Get-Content $SchemaPath -Raw
    #$luaSchema = $luaSchema.Replace('"', '\"').Replace("`r", "").Replace("`n", "")
    #$luaSchema = $luaSchema.Replace('"', '\"')
$luaSchema = $luaSchema -replace "`r`n", "`n" -replace "`r", "`n"  # Normalize line endings
$luaSchema = $luaSchema -replace '\\', '\\'                        # Escape backslashes first
$luaSchema = $luaSchema -replace '"', '\"'                         # Escape quotes for JSON
$luaSchema = $luaSchema.Trim()  
    Write-Host "Got Content $SchemaPath"
    $payload = @{
        name = $PluginName
        lua_schema = $luaSchema
    } | ConvertTo-Json -Depth 10  -Compress:$false

    $payload = $payload.Replace('\\', '')
    #Write-Host "Payload $payload"
    try {
        Write-Host "Starting rest call"
        $response = Invoke-RestMethod -Uri "$uri/$PluginName" -Method PUT -Headers $headers -Body $payload
        Write-Host "✅ $PluginName schema registered successfully!" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "❌ Failed to register $PluginName schema:" -ForegroundColor Red
        Write-Host "   $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) {
            Write-Host "   Details: $($_.ErrorDetails.Message)" -ForegroundColor Red
        }
        return $false
    }
}

# Register both plugin schemas
$mcpServerSuccess = Register-PluginSchema -PluginName "mcp-server" -SchemaPath "kong\plugins\mcp-server\schema.lua"
$mcpToolSuccess = Register-PluginSchema -PluginName "mcp-tool" -SchemaPath "kong\plugins\mcp-tool\schema.lua"

Write-Host ""
if ($mcpServerSuccess -and $mcpToolSuccess) {
    Write-Host "🎉 All MCP plugin schemas registered successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Deploy plugin code: .\deploy.ps1" -ForegroundColor Gray
    Write-Host "  2. Sync configuration: deck sync --konnect-control-plane-name $ControlPlaneName --konnect-token `$env:KONNECT_TOKEN" -ForegroundColor Gray
} else {
    Write-Host "❌ Schema registration failed. Check errors above." -ForegroundColor Red
    exit 1
}