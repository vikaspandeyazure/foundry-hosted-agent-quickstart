#!/usr/bin/env pwsh
# =============================================================================
# Foundry Hosted Agent - Full Deployment Orchestrator
# -----------------------------------------------------------------------------
# Single script that runs the complete flow end-to-end with interactive prompts:
#   1. Azure login (az + azd)
#   2. Optional cleanup of previous deployment
#   3. Interactive infrastructure provisioning (bicep restricted to 4 regions)
#   4. Hosted agent deployment to Foundry (delegates to deploy-agent.ps1)
#   5. Verification + test command
#
# USAGE:
#   .\deploy.ps1
#
# All prompts are interactive. Subscription/Tenant are taken from your az login.
# =============================================================================

[CmdletBinding()]
param(
    [switch]$SkipCleanupPrompt
)

# Use 'Continue' so external CLIs (az, azd, docker) writing to stderr don't abort the script.
# We check $LASTEXITCODE explicitly after each external invocation.
$ErrorActionPreference = 'Continue'
# Don't enable StrictMode - PowerShell's interaction with native exit codes makes it brittle.
$global:LASTEXITCODE = 0

# -----------------------------------------------------------------------------
# Pretty output helpers
# -----------------------------------------------------------------------------
function Write-Phase($n, $msg) {
    Write-Host ""
    Write-Host "================================================================================" -ForegroundColor Cyan
    Write-Host "  PHASE $n - $msg" -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor Cyan
}
function Write-Step($msg) { Write-Host "  > $msg" -ForegroundColor Yellow }
function Write-Ok($msg)   { Write-Host "    [OK]   $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "    [SKIP] $msg" -ForegroundColor DarkGray }
function Write-Info($msg) { Write-Host "    [INFO] $msg" -ForegroundColor Blue }
function Write-Err2($msg) { Write-Host "    [ERR]  $msg" -ForegroundColor Red }

function Ask-YesNo($question, $defaultYes = $true) {
    $suffix = if ($defaultYes) { "[Y/n]" } else { "[y/N]" }
    $answer = Read-Host "$question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $defaultYes }
    return $answer -match '^[yY]'
}

function Ask-Default($question, $default) {
    $answer = Read-Host "$question [$default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    return $answer
}

# Safely run an external command and capture stdout. Returns $null if exit != 0.
# Stderr is suppressed unless $ShowErr is passed.
function Invoke-Safe {
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [switch]$ShowErr
    )
    $global:LASTEXITCODE = 0
    try {
        if ($ShowErr) {
            $out = & $Script
        } else {
            $out = & $Script 2>$null
        }
    } catch {
        return $null
    }
    if ($LASTEXITCODE -ne 0) { return $null }
    return $out
}

# -----------------------------------------------------------------------------
# PHASE 0 - Prerequisite check
# -----------------------------------------------------------------------------
Write-Phase 0 "Prerequisite check"
foreach ($t in @('az','azd','docker','dotnet')) {
    $cmd = Get-Command $t -ErrorAction SilentlyContinue
    if (-not $cmd) { Write-Err2 "$t not found on PATH"; exit 1 }
    Write-Ok "$t -> $($cmd.Source)"
}

Write-Step "Checking Docker daemon..."
& docker version --format '{{.Server.Version}}' 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "Docker Desktop is not running. Start it and re-run."
    exit 1
}
$global:LASTEXITCODE = 0
Write-Ok "Docker daemon is responsive"

# -----------------------------------------------------------------------------
# PHASE 1 - Azure login (az + azd)
# -----------------------------------------------------------------------------
Write-Phase 1 "Azure login"

# Helper: safely get current az account (returns $null when not logged in)
function Get-AzAccount {
    $raw = Invoke-Safe { az account show }
    if (-not $raw) { return $null }
    try { return ($raw | Out-String | ConvertFrom-Json) } catch { return $null }
}

Write-Step "Checking az login..."
$account = Get-AzAccount
if (-not $account) {
    Write-Info "No active az session - launching 'az login' (a browser will open)..."
    Write-Info "Please complete sign-in, then return here. The script will wait."
    az login
    if ($LASTEXITCODE -ne 0) {
        Write-Err2 "az login failed or was cancelled. Re-run the script when ready."
        exit 1
    }
    $global:LASTEXITCODE = 0
    $account = Get-AzAccount
    if (-not $account) {
        Write-Err2 "Still not logged in after az login. Aborting."
        exit 1
    }
}
Write-Ok "Subscription : $($account.name) ($($account.id))"
Write-Ok "Tenant       : $($account.tenantId)"
Write-Ok "Signed in as : $($account.user.name)"

if (-not (Ask-YesNo "Continue with this subscription?" $true)) {
    Write-Step "Listing all available subscriptions..."
    az account list --query "[].{Name:name, Id:id, IsDefault:isDefault}" -o table
    $subId = Read-Host "Enter the Subscription ID to use"
    az account set --subscription $subId
    if ($LASTEXITCODE -ne 0) {
        Write-Err2 "Failed to switch subscription."
        exit 1
    }
    $global:LASTEXITCODE = 0
    $account = Get-AzAccount
    Write-Ok "Now using : $($account.name) ($($account.id))"
}

$SubId       = $account.id
$TenantId    = $account.tenantId
$PrincipalId = Invoke-Safe { az ad signed-in-user show --query id -o tsv }
if ([string]::IsNullOrWhiteSpace($PrincipalId)) {
    Write-Err2 "Could not resolve your user principal id."
    exit 1
}

Write-Step "Checking azd auth..."
# azd auth login --check-status returns 0 when logged in, non-zero otherwise.
# Some older versions don't support --check-status; fall back to a safe probe.
& azd auth login --check-status 2>&1 | Out-Null
$azdLoggedIn = ($LASTEXITCODE -eq 0)
$global:LASTEXITCODE = 0

if (-not $azdLoggedIn) {
    Write-Info "Logging in to azd (a browser will open)..."
    Write-Info "Please complete sign-in, then return here. The script will wait."
    azd auth login --tenant-id $TenantId
    if ($LASTEXITCODE -ne 0) {
        Write-Err2 "azd auth login failed or was cancelled. Re-run the script when ready."
        exit 1
    }
    $global:LASTEXITCODE = 0
}
Write-Ok "azd authenticated"

# -----------------------------------------------------------------------------
# PHASE 2 - Optional cleanup of previous deployment
# -----------------------------------------------------------------------------
Write-Phase 2 "Cleanup previous deployment (optional)"

$projectRoot = $PSScriptRoot
Set-Location $projectRoot

$ReuseExisting = $false
$hasAzdState  = Test-Path (Join-Path $projectRoot ".azure")
$hasDeployState = Test-Path (Join-Path $projectRoot ".deploy-state.json")

if ($hasAzdState -or $hasDeployState) {
    Write-Info "Found previous deployment state in this folder."
    $doCleanup = $SkipCleanupPrompt -eq $false -and (Ask-YesNo "Clean up previous deployment first?" $false)

    if ($doCleanup) {
        # Try to read previous resource group from azd state (safely)
        $prevRg = $null
        if ($hasAzdState) {
            $prevValues = Invoke-Safe { azd env get-values }
            if ($prevValues) {
                $match = $prevValues | Select-String '^AZURE_RESOURCE_GROUP=' | Select-Object -First 1
                if ($match) {
                    $line = $match.Line
                    $eqIdx = $line.IndexOf('=')
                    if ($eqIdx -gt 0) {
                        $prevRg = $line.Substring($eqIdx + 1).Trim().Trim('"')
                    }
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($prevRg)) {
            $prevRg = Read-Host "Enter the resource group name to delete"
        }

        if (-not [string]::IsNullOrWhiteSpace($prevRg)) {
            Write-Step "Deleting resource group '$prevRg'..."
            $rgExistsRaw = Invoke-Safe { az group exists --name $prevRg }
            $rgExists = ($rgExistsRaw -eq 'true')
            if ($rgExists) {
                az group delete --name $prevRg --yes --no-wait
                $global:LASTEXITCODE = 0
                Write-Ok "Delete initiated (running in background)"

                Write-Step "Waiting for resource group to be fully deleted (this can take 5-10 min)..."
                $tries = 0
                do {
                    Start-Sleep -Seconds 15
                    $tries++
                    $existsRaw = Invoke-Safe { az group exists --name $prevRg }
                    $stillExists = ($existsRaw -eq 'true')
                    Write-Host "    waiting ($($tries*15)s)... exists=$stillExists" -ForegroundColor DarkGray
                    if ($tries -gt 60) { Write-Err2 "Timed out after 15 min"; break }
                } while ($stillExists)
                Write-Ok "Resource group deleted"
            } else {
                Write-Skip "Resource group '$prevRg' does not exist"
            }

            # Purge soft-deleted Cognitive Services accounts
            Write-Step "Purging any soft-deleted Cognitive Services accounts..."
            $deletedJson = Invoke-Safe { az cognitiveservices account list-deleted --query "[].{name:name, location:location, rg:resourceGroup}" -o json }
            if ($deletedJson) {
                try {
                    $deleted = $deletedJson | Out-String | ConvertFrom-Json
                    foreach ($d in $deleted) {
                        if ($d.rg -eq $prevRg) {
                            Write-Info "Purging $($d.name) in $($d.location)..."
                            Invoke-Safe { az cognitiveservices account purge --location $d.location --resource-group $d.rg --name $d.name } | Out-Null
                        }
                    }
                } catch {
                    Write-Skip "Could not parse deleted accounts list (non-fatal)"
                }
            }
            Write-Ok "Purge complete"
        }

        # Clean local state
        Write-Step "Removing local state files..."
        Remove-Item -Recurse -Force (Join-Path $projectRoot ".azure") -ErrorAction SilentlyContinue
        Remove-Item -Force (Join-Path $projectRoot ".deploy-state.json") -ErrorAction SilentlyContinue
        Write-Ok "Local state cleaned"
    } else {
        Write-Skip "Skipping cleanup - will reuse existing state"
        $ReuseExisting = $true
    }
} else {
    Write-Skip "No previous deployment state found in this folder"
}

# -----------------------------------------------------------------------------
# PHASE 3 - Collect deployment parameters (interactive, or auto-load if reusing)
# -----------------------------------------------------------------------------
Write-Phase 3 "Deployment parameters"

# Helper to read a single value from `azd env get-values` (handles values with '=')
function Get-AzdEnvValue($name) {
    $line = & azd env get-values 2>$null | Select-String -Pattern "^$name=" | Select-Object -First 1
    if (-not $line) { return $null }
    $eqIdx = $line.Line.IndexOf('=')
    if ($eqIdx -lt 0) { return $null }
    return $line.Line.Substring($eqIdx + 1).Trim().Trim('"')
}

$validLocs = @('swedencentral','canadacentral','northcentralus','australiaeast')

if ($ReuseExisting) {
    Write-Info "Auto-loading parameters from existing azd environment..."

    $Location        = Get-AzdEnvValue 'AZURE_LOCATION'
    $EnvironmentName = Get-AzdEnvValue 'AZURE_ENV_NAME'
    $ResourceGroup   = Get-AzdEnvValue 'AZURE_RESOURCE_GROUP'

    # Validate what we loaded; fall back to interactive for any missing pieces
    if ([string]::IsNullOrWhiteSpace($Location) -or $Location -notin $validLocs) {
        Write-Info "Location missing/invalid in azd env - asking interactively"
        $Location = $null
    }
    if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        Write-Info "Environment name missing in azd env - asking interactively"
    }
    if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
        $ResourceGroup = if ($EnvironmentName) { "rg-$EnvironmentName" } else { $null }
    }

    if ($Location -and $EnvironmentName -and $ResourceGroup) {
        Write-Ok "Loaded Location       : $Location"
        Write-Ok "Loaded Environment    : $EnvironmentName"
        Write-Ok "Loaded Resource Group : $ResourceGroup"
    }

    # Agent + model are not stored in azd env - use sensible defaults silently
    $AgentName     = 'foundry-hosted-agent'
    $ModelName     = 'gpt-5-mini'
    $ModelVersion  = '2025-08-07'
    $ModelCapacity = 10
    Write-Info "Agent/model defaults: $AgentName / $ModelName ($ModelVersion, capacity $ModelCapacity)"
}

# -- Location (prompt only if not auto-loaded) ---------------------------------
if (-not $Location) {
    Write-Host ""
    Write-Host "  Hosted agents are only supported in these 4 regions:" -ForegroundColor Yellow
    Write-Host "    1) swedencentral   (recommended)" -ForegroundColor White
    Write-Host "    2) canadacentral" -ForegroundColor White
    Write-Host "    3) northcentralus" -ForegroundColor White
    Write-Host "    4) australiaeast" -ForegroundColor White
    do {
        $Location = Ask-Default "  Choose location" "swedencentral"
        if ($Location -notin $validLocs) {
            Write-Err2 "Invalid. Must be one of: $($validLocs -join ', ')"
        }
    } while ($Location -notin $validLocs)
}

# -- Environment name (prompt only if not auto-loaded) -------------------------
if (-not $EnvironmentName) {
    Write-Host ""
    Write-Host "  About 'Environment name':" -ForegroundColor Yellow
    Write-Host "    A short LABEL for this deployment instance (NOT the resource group)." -ForegroundColor DarkGray
    Write-Host "    - Tagged on every resource as 'azd-env-name=<value>'" -ForegroundColor DarkGray
    Write-Host "    - Used as the default suffix when generating resource names" -ForegroundColor DarkGray
    Write-Host "    - Lets you run multiple deployments side-by-side (dev/test/prod, per-developer)" -ForegroundColor DarkGray
    Write-Host "    Examples: demo01, vikas-dev, prod-eu, agent-test" -ForegroundColor DarkGray
    do {
        $EnvironmentName = Read-Host "  Environment label (short, lowercase, e.g. demo01)"
        if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
            Write-Err2 "Environment label is required"
        } elseif ($EnvironmentName.Length -gt 30) {
            Write-Err2 "Keep it under 30 chars (used in resource names)"
            $EnvironmentName = ""
        } elseif ($EnvironmentName -notmatch '^[a-z0-9][a-z0-9-]*$') {
            Write-Err2 "Use only lowercase letters, digits, and hyphens (must start with letter/digit)"
            $EnvironmentName = ""
        }
    } while ([string]::IsNullOrWhiteSpace($EnvironmentName))
}

# -- Resource group (prompt only if not auto-loaded) ---------------------------
if (-not $ResourceGroup) {
    Write-Host ""
    Write-Host "  About 'Resource group':" -ForegroundColor Yellow
    Write-Host "    The Azure container that holds all resources for this deployment." -ForegroundColor DarkGray
    Write-Host "    If it doesn't exist, it will be created. If it exists, resources are added to it." -ForegroundColor DarkGray
    $ResourceGroup = Ask-Default "  Resource group name" "rg-$EnvironmentName"
}

# -- Agent + model (prompt only if not auto-loaded) ----------------------------
if (-not $AgentName)     { $AgentName     = Ask-Default "  Hosted agent name" "foundry-hosted-agent" }
if (-not $ModelName)     { $ModelName     = Ask-Default "  Model name" "gpt-5-mini" }
if (-not $ModelVersion)  { $ModelVersion  = Ask-Default "  Model version" "2025-08-07" }
if (-not $ModelCapacity) { $ModelCapacity = [int](Ask-Default "  Model capacity" "10") }

Write-Host ""
Write-Host "  Summary:" -ForegroundColor Cyan
Write-Host "    Subscription      : $($account.name)" -ForegroundColor White
Write-Host "    Location          : $Location" -ForegroundColor White
Write-Host "    Environment label : $EnvironmentName    (tag: azd-env-name)" -ForegroundColor White
Write-Host "    Resource group    : $ResourceGroup    (Azure container)" -ForegroundColor White
Write-Host "    Agent name        : $AgentName" -ForegroundColor White
Write-Host "    Model             : $ModelName ($ModelVersion, capacity $ModelCapacity)" -ForegroundColor White
if ($ReuseExisting) {
    Write-Host "    Mode              : REUSE existing infrastructure (no re-prompt)" -ForegroundColor Green
}
Write-Host ""

if (-not (Ask-YesNo "Proceed with deployment?" $true)) {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

# -----------------------------------------------------------------------------
# PHASE 4 - Provision infrastructure (azd + bicep)
# -----------------------------------------------------------------------------
Write-Phase 4 "Provision infrastructure (azd + bicep)"

# Initialize azd environment if needed
if (-not (Test-Path (Join-Path $projectRoot ".azure"))) {
    Write-Step "Initializing azd environment '$EnvironmentName'..."
    azd init --environment $EnvironmentName --no-prompt
    if ($LASTEXITCODE -ne 0) { Write-Err2 "azd init failed"; exit 1 }
}

Write-Step "Setting azd environment variables..."
azd env set AZURE_SUBSCRIPTION_ID    $SubId
azd env set AZURE_LOCATION           $Location
azd env set AZURE_ENV_NAME           $EnvironmentName
azd env set AZURE_RESOURCE_GROUP     $ResourceGroup
azd env set ENABLE_HOSTED_AGENTS     true
azd env set ENABLE_MONITORING        true
azd env set ENABLE_CAPABILITY_HOST   false
azd env set HOSTED_AGENT_SERVICE_NAME "HostedAgent"
Write-Ok "azd environment configured"

Write-Step "Provisioning Azure resources (this can take 3-5 minutes)..."
azd provision --no-prompt
if ($LASTEXITCODE -ne 0) {
    Write-Err2 "azd provision failed. Check the error above."
    exit 1
}
Write-Ok "Infrastructure provisioned"

# -----------------------------------------------------------------------------
# PHASE 5 - Read provisioned values for the agent deployment
# -----------------------------------------------------------------------------
Write-Phase 5 "Reading provisioned resource names"

# (Get-AzdEnvValue helper is defined above in PHASE 3)
$rg     = Get-AzdEnvValue 'AZURE_RESOURCE_GROUP'
$acct   = Get-AzdEnvValue 'AZURE_AI_ACCOUNT_NAME'
$proj   = Get-AzdEnvValue 'AZURE_AI_PROJECT_NAME'
$acrEp  = Get-AzdEnvValue 'AZURE_CONTAINER_REGISTRY_ENDPOINT'
$acr    = if ($acrEp) { $acrEp -replace '\.azurecr\.io','' } else { $null }
$token  = if ($acct) { $acct -replace 'ai-account-','' } else { $null }
$appi   = if ($token) { "appi-$token" } else { $null }
$logs   = if ($token) { "logs-$token" } else { $null }

if (-not $rg -or -not $acct -or -not $proj -or -not $acr) {
    Write-Err2 "Could not read provisioned resource names from azd env. Aborting."
    Write-Info "Run 'azd env get-values' to inspect."
    exit 1
}

Write-Ok "Resource Group : $rg"
Write-Ok "AI Account     : $acct"
Write-Ok "AI Project     : $proj"
Write-Ok "Container Reg  : $acr"
Write-Ok "App Insights   : $appi"
Write-Ok "Log Analytics  : $logs"

# -----------------------------------------------------------------------------
# PHASE 6 - Deploy hosted agent (build, push, register in Foundry)
# -----------------------------------------------------------------------------
Write-Phase 6 "Deploy hosted agent to Foundry"

if (-not (Ask-YesNo "Build and deploy the hosted agent now?" $true)) {
    Write-Host "Stopping here. To deploy later, run:" -ForegroundColor Yellow
    Write-Host "  .\deploy-agent.ps1 -EnvName $EnvironmentName -Location $Location -ResourceGroup $rg -AccountName $acct -ProjectName $proj -ContainerRegistry $acr -AppInsightsName $appi -LogAnalyticsName $logs -AgentName $AgentName -ModelName $ModelName -ModelVersion $ModelVersion -ModelCapacity $ModelCapacity -Force" -ForegroundColor White
    exit 0
}

Write-Step "Invoking deploy-agent.ps1 with provisioned resources..."
Write-Host ""
Write-Host "  --------------------------------------------------------------------------------" -ForegroundColor DarkCyan
Write-Host "  >>> Handing off to deploy-agent.ps1 (10 internal AGENT STEPs)" -ForegroundColor DarkCyan
Write-Host "  >>> Slow steps to expect (NOT stuck - just waiting):" -ForegroundColor DarkCyan
Write-Host "       AGENT STEP 3  : model deployment (~30 sec, skip if exists)" -ForegroundColor DarkGray
Write-Host "       AGENT STEP 4  : capability host provisioning (~3 minutes if new)" -ForegroundColor DarkGray
Write-Host "       AGENT STEP 5  : create 3 Foundry sub-agents (~10 sec)" -ForegroundColor DarkGray
Write-Host "       AGENT STEP 6  : docker build + push (~2-5 minutes)" -ForegroundColor DarkGray
Write-Host "       AGENT STEP 9  : smoke test cold start (up to 90 sec + sub-agent calls)" -ForegroundColor DarkGray
Write-Host "  --------------------------------------------------------------------------------" -ForegroundColor DarkCyan
Write-Host ""

& (Join-Path $projectRoot "deploy-agent.ps1") `
    -EnvName           $EnvironmentName `
    -Location          $Location `
    -ResourceGroup     $rg `
    -AccountName       $acct `
    -ProjectName       $proj `
    -ContainerRegistry $acr `
    -AppInsightsName   $appi `
    -LogAnalyticsName  $logs `
    -AgentName         $AgentName `
    -ModelName         $ModelName `
    -ModelVersion      $ModelVersion `
    -ModelCapacity     $ModelCapacity `
    -Force

if ($LASTEXITCODE -ne 0) {
    Write-Err2 "Agent deployment failed. Check error messages above."
    exit 1
}

# -----------------------------------------------------------------------------
# PHASE 7 - Final summary
# -----------------------------------------------------------------------------
Write-Phase 7 "All done!"

$portalUrl = "https://ai.azure.com/build/agents?wsid=/subscriptions/$SubId/resourceGroups/$rg/providers/Microsoft.CognitiveServices/accounts/$acct/projects/$proj"
$endpoint  = "https://$acct.services.ai.azure.com/api/projects/$proj/agents/$AgentName/endpoint/protocols/openai/responses?api-version=2025-11-15-preview"

Write-Host ""
Write-Host "  Azure AI Foundry Portal:" -ForegroundColor Cyan
Write-Host "  $portalUrl" -ForegroundColor White
Write-Host ""
Write-Host "  Test from CLI:" -ForegroundColor Cyan
Write-Host "    `$tok  = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv" -ForegroundColor DarkGray
Write-Host "    `$body = @{ model='FoundryHostedAgent'; input='What is the capital of Japan?' } | ConvertTo-Json" -ForegroundColor DarkGray
Write-Host "    Invoke-RestMethod -Uri '$endpoint' -Method POST -Headers @{ 'Authorization'=`"Bearer `$tok`"; 'Content-Type'='application/json' } -Body `$body" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To clean up everything later:" -ForegroundColor Cyan
Write-Host "    azd down --force --purge" -ForegroundColor White
Write-Host "    # or: az group delete --name $rg --yes --no-wait" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Tip: open the portal manually with the URL above, or run:" -ForegroundColor DarkGray
Write-Host "    Start-Process '$portalUrl'" -ForegroundColor DarkGray
Write-Host ""
Write-Ok "Deployment complete. Script finished."
