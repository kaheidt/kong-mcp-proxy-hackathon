# Kong MCP Plugin Docker Deployment Script
# Builds and runs Kong Gateway with MCP plugins for Phase 1 testing

param(
    [string]$Action = "start",
    [string]$ImageName,
    [string]$ContainerName,
    [string]$ControlPlaneName
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

# Set defaults from .env or use provided parameters
if (-not $ImageName) {
    $ImageName = $env:IMAGE_NAME
    if (-not $ImageName) {
        $ImageName = "kong-mcp-plugin"
    }
}

if (-not $ContainerName) {
    $ContainerName = $env:CONTAINER_NAME
    if (-not $ContainerName) {
        $ContainerName = "kong-mcp"
    }
}

if (-not $ControlPlaneName) {
    $ControlPlaneName = $env:CONTROL_PLANE_NAME
    if (-not $ControlPlaneName) {
        $ControlPlaneName = "mcp-test-local"
    }
}

# Get other config from environment
$konnectToken = $env:KONNECT_TOKEN
if (-not $konnectToken) {
    $konnectToken = $env:DECK_KONNECT_TOKEN
}

$kongClusterId = $env:KONG_CLUSTER_ID
if (-not $kongClusterControlPlane) {
    $kongClusterControlPlane = "abcd123456"
}

Write-Host "Kong MCP Plugin Docker Management" -ForegroundColor Green
Write-Host "Action: $Action" -ForegroundColor Yellow
Write-Host ""

switch ($Action.ToLower()) {
    "build" {
        Write-Host "Building Kong MCP Plugin Docker image..." -ForegroundColor Yellow
        docker build -t $ImageName .
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Build completed successfully!" -ForegroundColor Green
        } else {
            Write-Host "Build failed!" -ForegroundColor Red
            exit 1
        }
    }
    
    "start" {
        Write-Host "Starting Kong MCP Plugin container..." -ForegroundColor Yellow
        
        # Stop and remove existing container if it exists
        docker stop $ContainerName 2>$null
        docker rm $ContainerName 2>$null
        
        # Build the image first
        Write-Host "Building image..." -ForegroundColor Gray
        docker build -t $ImageName .
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Build failed!" -ForegroundColor Red
            exit 1
        }
        
        # Create network if it doesn't exist
        docker network create kong-net 2>$null
        
        Write-Host "Starting Kong Data Plane (connected to Konnect)..." -ForegroundColor Cyan
        # Start Kong container connected to Konnect
        docker run -d --name $ContainerName `
            --network=kong-net `
            -e "KONG_ROLE=data_plane" `
            -e "KONG_TRACING_SAMPLING_RATE=1.0" `
            -e "KONG_DATABASE=off" `
            -e "KONG_VITALS=off" `
            -e "KONG_CLUSTER_MTLS=pki" `
            -e "KONG_CLUSTER_CONTROL_PLANE=${kongClusterId}.us.cp.konghq.com:443" `
            -e "KONG_CLUSTER_SERVER_NAME=${kongClusterId}.us.cp.konghq.com" `
            -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=${kongClusterId}.us.tp.konghq.com:443" `
            -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=${kongClusterId}.us.tp.konghq.com" `
            -e "KONG_LUA_SSL_TRUSTED_CERTIFICATE=system" `
            -e "KONG_KONNECT_MODE=on" `
            -e "KONG_CLUSTER_DP_LABELS=type:docker-linuxdockerOS" `
            -e "KONG_ROUTER_FLAVOR=expressions" `
            -e "KONG_UNTRUSTED_LUA_SANDBOX_REQUIRES=ngx.base64, cjson.safe" `
            -e "KONG_TRACING_INSTRUMENTATIONS=all" `
            -e "KONG_STATUS_LISTEN=0.0.0.0:8100" `
            -e "KONG_LOG_LEVEL=info" `
            -p 8000:8000 `
            -p 8001:8001 `
            -p 8100:8100 `
            -p 8443:8443 `
            $ImageName
            
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Container started successfully!" -ForegroundColor Green
            Write-Host ""
            Write-Host "Waiting for Kong to be ready..." -ForegroundColor Yellow
            
            # Wait for Kong to be ready
            $maxAttempts = 30
            $attempt = 0
            do {
                Start-Sleep -Seconds 2
                $attempt++
                try {
                    $response = Invoke-RestMethod -Uri "http://localhost:8100/status/ready" -Method GET -TimeoutSec 5
                    # If we get here without exception, Kong is ready (200 response)
                    Write-Host "Kong is ready!" -ForegroundColor Green
                    break
                } catch {
                    Write-Host "." -NoNewline -ForegroundColor Gray
                }
            } while ($attempt -lt $maxAttempts)
            
            if ($attempt -ge $maxAttempts) {
                Write-Host ""
                Write-Host "Kong did not become ready within timeout period" -ForegroundColor Red
                Write-Host "Check logs with: docker logs $ContainerName" -ForegroundColor Yellow
            } else {
                Write-Host ""
                Write-Host "Kong Data Plane connected to Konnect!" -ForegroundColor Cyan
                Write-Host "  Proxy:         http://localhost:8000" -ForegroundColor Gray
                Write-Host "  Status:        http://localhost:8100" -ForegroundColor Gray
                Write-Host ""
                Write-Host "Deploy configuration with deck:" -ForegroundColor Green
                Write-Host "  deck sync -s mcp-test-local.deck.yaml --konnect-control-plane-name $ControlPlaneName --konnect-token `$env:KONNECT_TOKEN" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Ready for MCP testing!" -ForegroundColor Green
            }
        } else {
            Write-Host "Failed to start container!" -ForegroundColor Red
            exit 1
        }
    }
    
    "stop" {
        Write-Host "Stopping Kong MCP Plugin container..." -ForegroundColor Yellow
        docker stop $ContainerName
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Container stopped successfully!" -ForegroundColor Green
        } else {
            Write-Host "Failed to stop container or container not running" -ForegroundColor Yellow
        }
    }
    
    "restart" {
        Write-Host "Restarting Kong MCP Plugin container..." -ForegroundColor Yellow
        & $MyInvocation.MyCommand.Path -Action stop -ImageName $ImageName -ContainerName $ContainerName
        Start-Sleep -Seconds 2
        & $MyInvocation.MyCommand.Path -Action start -ImageName $ImageName -ContainerName $ContainerName
    }
    
    "logs" {
        Write-Host "Showing Kong container logs..." -ForegroundColor Yellow
        docker logs -f $ContainerName
    }
    
    "status" {
        Write-Host "Checking Kong Data Plane status..." -ForegroundColor Yellow
        try {
            # Check if Kong data plane is ready
            $null = Invoke-RestMethod -Uri "http://localhost:8100/status/ready" -Method GET -TimeoutSec 5
            Write-Host "Kong Data Plane is running and ready!" -ForegroundColor Green
            
            # Check deck connectivity to Konnect
            Write-Host "Checking Konnect connectivity..." -ForegroundColor Yellow
            try {
                if ($konnectToken) {
                    $env:KONNECT_TOKEN = $konnectToken
                }
                $deckOutput = deck ping --konnect-control-plane-name $ControlPlaneName --konnect-token $konnectToken 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Konnect connectivity: OK" -ForegroundColor Green
                } else {
                    Write-Host "Konnect connectivity: Failed" -ForegroundColor Red
                    if ($konnectToken -eq "your-actual-token-here") {
                        Write-Host "Please update KONNECT_TOKEN in .env file with your actual token" -ForegroundColor Yellow
                    } else {
                        Write-Host "Make sure KONNECT_TOKEN is valid in .env file" -ForegroundColor Yellow
                    }
                }
            } catch {
                Write-Host "deck command not found or Konnect connection failed" -ForegroundColor Yellow
                Write-Host "Install deck CLI: https://docs.konghq.com/deck/latest/installation/" -ForegroundColor Gray
            }
            
            # Show current configuration status
            Write-Host ""
            Write-Host "Local deck file: mcp-test-local.deck.yaml" -ForegroundColor Gray
            Write-Host ""
            Write-Host "Available deck commands:" -ForegroundColor Yellow
            Write-Host "  deck sync -s mcp-test-local.deck.yaml --konnect-control-plane-name $ControlPlaneName --konnect-token `$env:KONNECT_TOKEN    # Deploy configuration" -ForegroundColor Gray
            Write-Host "  deck dump --output-file temp.yaml --konnect-control-plane-name $ControlPlaneName --konnect-token `$env:KONNECT_TOKEN          # Pull current config" -ForegroundColor Gray
            Write-Host "  deck diff -s mcp-test-local.deck.yaml --konnect-control-plane-name $ControlPlaneName --konnect-token `$env:KONNECT_TOKEN    # Show config differences" -ForegroundColor Gray
            
        } catch {
            Write-Host "Kong Data Plane is not accessible or not running" -ForegroundColor Red
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Try running: .\deploy.ps1 -Action start" -ForegroundColor Yellow
        }
    }
    
    "register-schemas" {
        Write-Host "Registering MCP plugin schemas with Konnect..." -ForegroundColor Yellow
        try {
            & ".\register-schemas.ps1" -ControlPlaneName $ControlPlaneName
        } catch {
            Write-Host "Schema registration failed" -ForegroundColor Red
            Write-Host "Make sure KONNECT_TOKEN is set in .env file" -ForegroundColor Yellow
        }
    }
    
    "sync" {
        Write-Host "Syncing configuration to Konnect..." -ForegroundColor Yellow
        try {
            if ($konnectToken) {
                $env:KONNECT_TOKEN = $konnectToken
            }
            deck sync -s mcp-test-local.deck.yaml --konnect-control-plane-name $ControlPlaneName --konnect-token $konnectToken
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Configuration synced successfully!" -ForegroundColor Green
                Write-Host "MCP plugins should now be available in mcp-test-local control plane" -ForegroundColor Gray
            } else {
                Write-Host "Configuration sync failed!" -ForegroundColor Red
                Write-Host "You may need to register plugin schemas first:" -ForegroundColor Yellow
                Write-Host "  .\deploy.ps1 -Action register-schemas" -ForegroundColor Gray
            }
        } catch {
            Write-Host "deck command failed" -ForegroundColor Red
            Write-Host "Make sure deck CLI is installed and KONNECT_TOKEN is set in .env file" -ForegroundColor Yellow
        }
    }
    
    "dump" {
        Write-Host "Dumping current Konnect configuration..." -ForegroundColor Yellow
        try {
            if ($konnectToken) {
                $env:KONNECT_TOKEN = $konnectToken
            }
            deck dump --output-file mcp-test-local.deck.yaml --konnect-control-plane-name $ControlPlaneName --konnect-token $konnectToken
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Configuration dumped to mcp-test-local.deck.yaml" -ForegroundColor Green
            } else {
                Write-Host "Configuration dump failed!" -ForegroundColor Red
            }
        } catch {
            Write-Host "deck command failed" -ForegroundColor Red
            Write-Host "Make sure deck CLI is installed and KONNECT_TOKEN is set in .env file" -ForegroundColor Yellow
        }
    }
    
    "diff" {
        Write-Host "Checking configuration differences..." -ForegroundColor Yellow
        try {
            if ($konnectToken) {
                $env:KONNECT_TOKEN = $konnectToken
            }
            deck diff -s mcp-test-local.deck.yaml --konnect-control-plane-name $ControlPlaneName --konnect-token $konnectToken
        } catch {
            Write-Host "deck command failed" -ForegroundColor Red
            Write-Host "Make sure deck CLI is installed and KONNECT_TOKEN is set in .env file" -ForegroundColor Yellow
        }
    }
    
    "clean" {
        Write-Host "Cleaning up Kong MCP Plugin resources..." -ForegroundColor Yellow
        docker stop $ContainerName 2>$null
        docker rm $ContainerName 2>$null
        docker rmi $ImageName 2>$null
        Write-Host "Cleanup completed!" -ForegroundColor Green
    }
    
    default {
        Write-Host "Usage: .\deploy.ps1 -Action <action>" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Available actions:" -ForegroundColor Yellow
        Write-Host "  build           - Build the Docker image" -ForegroundColor Gray
        Write-Host "  start           - Build and start Kong container (default)" -ForegroundColor Gray
        Write-Host "  stop            - Stop the Kong container" -ForegroundColor Gray
        Write-Host "  restart         - Restart the Kong container" -ForegroundColor Gray
        Write-Host "  logs            - Show container logs" -ForegroundColor Gray
        Write-Host "  status          - Check Kong and connectivity" -ForegroundColor Gray
        Write-Host "  register-schemas- Register MCP plugin schemas with Konnect" -ForegroundColor Gray
        Write-Host "  sync            - Deploy configuration to Konnect" -ForegroundColor Gray
        Write-Host "  dump            - Pull current Konnect configuration" -ForegroundColor Gray
        Write-Host "  diff            - Show configuration differences" -ForegroundColor Gray
        Write-Host "  clean           - Remove container and image" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Available modes (-Mode parameter):" -ForegroundColor Yellow
        Write-Host "  konnect - Connect to Konnect control plane (default)" -ForegroundColor Gray
        Write-Host "  local   - Run standalone with Admin API" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Examples:" -ForegroundColor Yellow
        Write-Host "  .\deploy.ps1                              # Start Kong data plane (Konnect)" -ForegroundColor Gray
        Write-Host "  .\deploy.ps1 -Action register-schemas     # Register MCP plugin schemas" -ForegroundColor Gray
        Write-Host "  .\deploy.ps1 -Action sync                 # Deploy configuration to Konnect" -ForegroundColor Gray
        Write-Host "  .\deploy.ps1 -Action status               # Check connectivity" -ForegroundColor Gray
        Write-Host "  .\deploy.ps1 -Action dump                 # Pull current Konnect configuration" -ForegroundColor Gray
        Write-Host ""
        Write-Host "Configuration:" -ForegroundColor Yellow
        Write-Host "  Copy .env-template to .env and configure your tokens" -ForegroundColor Gray
    }
}