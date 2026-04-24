#!/usr/bin/env pwsh
# =============================================================================
# Foundry Hosted Agent Quickstart - One-shot deployment
# -----------------------------------------------------------------------------
# Builds the .NET hosted agent into a container, pushes it to Azure Container
# Registry, and registers it as a Microsoft Foundry hosted agent in your
# project. Everything is idempotent: re-running the script reuses anything that
# already exists. The script does NOT use 'azd' or 'azd ai agent' - it talks
# directly to ARM and the Foundry data-plane API, which is the only path we
# have proven to work end-to-end as of April 2026.
#
# Region constraint: Hosted agents are only available in:
#   australiaeast, canadacentral, northcentralus, swedencentral
# This script defaults to swedencentral.
#
# USAGE
#   # Brand-new everything (interactive prompt for env name)
#   .\deploy.ps1
#
#   # Brand-new everything, fully scripted
#   .\deploy.ps1 -EnvName demo01
#
#   # Reuse an existing Foundry account / project
#   .\deploy.ps1 -EnvName demo01 `
#       -ResourceGroup rg-hostedagent-sc `
#       -AccountName    ai-account-bak4vs6hxbm3o `
#       -ProjectName    ai-project-hostedagent-sc
#
# =============================================================================

[CmdletBinding()]
param(
    # Short name used to derive resource names when -ResourceGroup etc. are not supplied.
    [string]$EnvName,

    # Azure context
    [string]$Subscription,
    [string]$Tenant,

    # ONLY swedencentral / canadacentral / northcentralus / australiaeast are supported.
    [ValidateSet('swedencentral','canadacentral','northcentralus','australiaeast')]
    [string]$Location = 'swedencentral',

    # Provide any of these to reuse existing infra; the script will skip creating them.
    [string]$ResourceGroup,
    [string]$AccountName,         # Microsoft.CognitiveServices/accounts (kind = AIServices)
    [string]$ProjectName,         # ...accounts/projects child resource
    [string]$ContainerRegistry,   # ACR name (no .azurecr.io)
    [string]$AppInsightsName,
    [string]$LogAnalyticsName,

    # Agent metadata
    [string]$AgentName    = 'foundry-hosted-agent',
    [string]$ModelName    = 'gpt-5-mini',
    [string]$ModelVersion = '2025-08-07',
    [int]   $ModelCapacity = 10,

    # Container resources
    [string]$Cpu    = '1',
    [string]$Memory = '2Gi',

    [switch]$SkipBuild,
    [switch]$Force      # don't ask for confirmations
)

# Use 'Continue' so external CLI stderr doesn't abort the script.
# We check $LASTEXITCODE explicitly after each external invocation.
$ErrorActionPreference = 'Continue'
$global:LASTEXITCODE = 0

# -----------------------------------------------------------------------------
# Pretty output helpers
# -----------------------------------------------------------------------------
function Write-Phase($n,$msg) { Write-Host ""; Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkCyan; Write-Host "  AGENT STEP $n - $msg" -ForegroundColor DarkCyan; Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkCyan }
function Write-Step($msg)     { Write-Host "  > $msg" -ForegroundColor White }
function Write-Ok($msg)       { Write-Host "    [OK]   $msg" -ForegroundColor Green }
function Write-Skip($msg)     { Write-Host "    [SKIP] $msg" -ForegroundColor DarkGray }
function Write-Warn2($msg)    { Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Err2($msg)     { Write-Host "    [ERR]  $msg" -ForegroundColor Red }
function Get-Random8           { -join ((48..57) + (97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ }) }

function Invoke-Az {
    # Wrap az CLI to fail fast and capture output cleanly
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Args)
    $output = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Args -join ' ') failed:`n$output" }
    return $output
}

function Read-PromptOrDefault($message, $default) {
    if ($Force -or [string]::IsNullOrEmpty($default)) {
        $v = Read-Host "$message [$default]"
        if ([string]::IsNullOrWhiteSpace($v)) { return $default } else { return $v }
    }
    return $default
}

# =============================================================================
# PHASE 0 - Prerequisites
# =============================================================================
Write-Phase 0 'Prerequisite check'
$prereqs = @{ az = $null; docker = $null; dotnet = $null }
foreach ($t in $prereqs.Keys.Clone()) {
    $cmd = Get-Command $t -ErrorAction SilentlyContinue
    if (-not $cmd) { Write-Err2 "$t not found on PATH"; exit 1 }
    $prereqs[$t] = $cmd.Source
    Write-Ok "$t -> $($cmd.Source)"
}

# Verify Docker daemon is running (only needed if we're going to build)
if (-not $SkipBuild) {
    & docker version --format '{{.Server.Version}}' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err2 "Docker Desktop is not running. Start it and re-run."; exit 1
    }
    Write-Ok "docker daemon is responsive"
}

# =============================================================================
# PHASE 1 - Azure login and subscription
# =============================================================================
Write-Phase 1 'Azure login and subscription'

$account = (& az account show 2>$null) | ConvertFrom-Json
if (-not $account) {
    Write-Step 'No active az session - launching az login'
    if ($Tenant) { Invoke-Az login --tenant $Tenant | Out-Null } else { Invoke-Az login | Out-Null }
    $account = (& az account show) | ConvertFrom-Json
}

if ($Subscription) {
    Invoke-Az account set --subscription $Subscription | Out-Null
    $account = (& az account show) | ConvertFrom-Json
}

Write-Ok "Subscription : $($account.name) ($($account.id))"
Write-Ok "Tenant       : $($account.tenantId)"
Write-Ok "Signed in as : $($account.user.name)"

$SubId = $account.id
$TenantId = $account.tenantId
$PrincipalId = (& az ad signed-in-user show --query id -o tsv)

# =============================================================================
# PHASE 2 - Resolve resource names
# =============================================================================
Write-Phase 2 'Resource names'

if (-not $EnvName -and -not $ResourceGroup) {
    $EnvName = Read-Host "Short env name (e.g. demo01) - used to derive resource names"
    if ([string]::IsNullOrWhiteSpace($EnvName)) { Write-Err2 'EnvName is required'; exit 1 }
}

# If EnvName supplied, derive defaults; explicit -ResourceGroup etc. wins.
$suffix = if ($EnvName) { $EnvName.ToLower() } else { Get-Random8 }
if (-not $ResourceGroup)     { $ResourceGroup     = "rg-foundry-agent-$suffix" }
if (-not $AccountName)       { $AccountName       = "ai-account-$suffix" }
if (-not $ProjectName)       { $ProjectName       = "ai-project-$suffix" }
if (-not $ContainerRegistry) { $ContainerRegistry = ("cr" + ($suffix -replace '[^a-z0-9]','')) }   # ACR: alphanumeric, 5-50
if (-not $AppInsightsName)   { $AppInsightsName   = "appi-$suffix" }
if (-not $LogAnalyticsName)  { $LogAnalyticsName  = "logs-$suffix" }

# ACR length check (5-50, alphanumeric only)
if ($ContainerRegistry.Length -lt 5 -or $ContainerRegistry.Length -gt 50 -or $ContainerRegistry -notmatch '^[a-z0-9]+$') {
    Write-Err2 "ACR name '$ContainerRegistry' invalid (need 5-50 alphanumeric lowercase chars)"; exit 1
}

Write-Ok "Resource group : $ResourceGroup"
Write-Ok "Foundry acct   : $AccountName"
Write-Ok "Foundry proj   : $ProjectName"
Write-Ok "ACR            : $ContainerRegistry"
Write-Ok "App Insights   : $AppInsightsName"
Write-Ok "Log Analytics  : $LogAnalyticsName"
Write-Ok "Region         : $Location"
Write-Ok "Agent name     : $AgentName"
Write-Ok "Model          : $ModelName ($ModelVersion, capacity $ModelCapacity)"

if (-not $Force) {
    $confirm = Read-Host "`nProceed? (y/N)"
    if ($confirm -notmatch '^[yY]') { Write-Host 'Aborted.' -ForegroundColor Yellow; exit 0 }
}

# =============================================================================
# PHASE 3 - Resource group
# =============================================================================
Write-Phase 3 'Resource group'
$rgExists = (& az group exists --name $ResourceGroup) -eq 'true'
if ($rgExists) {
    Write-Skip "$ResourceGroup already exists"
} else {
    Write-Step "Creating $ResourceGroup in $Location"
    Invoke-Az group create --name $ResourceGroup --location $Location | Out-Null
    Write-Ok 'Created'
}

# =============================================================================
# PHASE 4 - AI Foundry account (Microsoft.CognitiveServices/accounts kind=AIServices)
# =============================================================================
Write-Phase 4 'AI Foundry account'
$acctJson = (& az cognitiveservices account show --name $AccountName --resource-group $ResourceGroup 2>$null)
if ($acctJson) {
    Write-Skip "Foundry account $AccountName already exists"
} else {
    Write-Step "Creating Foundry account $AccountName"
    Invoke-Az cognitiveservices account create `
        --name $AccountName `
        --resource-group $ResourceGroup `
        --location $Location `
        --kind AIServices `
        --sku S0 `
        --custom-domain $AccountName `
        --assign-identity `
        --yes | Out-Null
    Write-Ok 'Created'
}
# Tag for azd compatibility (harmless if you ever want to attach azd later)
Invoke-Az resource tag --tags "azd-env-name=$suffix" "azd-service-name=$AgentName" `
    --ids "/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName" `
    --is-incremental | Out-Null

# =============================================================================
# PHASE 5 - AI Foundry project
# =============================================================================
Write-Phase 5 'AI Foundry project'
$projUrl = "https://management.azure.com/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName/projects/${ProjectName}?api-version=2025-04-01-preview"
$projExisting = & az rest --method GET --url $projUrl 2>$null
if ($projExisting) {
    Write-Skip "Project $ProjectName already exists"
} else {
    Write-Step "Creating project $ProjectName"
    $projBody = @{
        location = $Location
        identity = @{ type = 'SystemAssigned' }
        properties = @{
            description = "$AgentName quickstart project"
            displayName = "$AgentName quickstart"
        }
    } | ConvertTo-Json -Depth 5 -Compress
    $projBody | Out-File -FilePath proj.body.json -Encoding ascii -NoNewline
    Invoke-Az rest --method PUT --url $projUrl --body '@proj.body.json' --headers 'Content-Type=application/json' | Out-Null
    Remove-Item proj.body.json
    Write-Ok 'Project created'
}

# =============================================================================
# PHASE 6 - Container Registry
# =============================================================================
Write-Phase 6 'Container Registry'
$acr = & az acr show --name $ContainerRegistry --resource-group $ResourceGroup 2>$null
if ($acr) {
    Write-Skip "ACR $ContainerRegistry already exists"
} else {
    Write-Step "Creating ACR $ContainerRegistry (Standard)"
    Invoke-Az acr create --name $ContainerRegistry --resource-group $ResourceGroup --location $Location --sku Standard | Out-Null
    Write-Ok 'Created'
}
$AcrLoginServer = (& az acr show --name $ContainerRegistry --resource-group $ResourceGroup --query loginServer -o tsv)
$AcrResourceId  = (& az acr show --name $ContainerRegistry --resource-group $ResourceGroup --query id -o tsv)

# =============================================================================
# PHASE 7 - Log Analytics + Application Insights
# =============================================================================
Write-Phase 7 'Log Analytics + Application Insights'
$la = & az monitor log-analytics workspace show -n $LogAnalyticsName -g $ResourceGroup 2>$null
if ($la) { Write-Skip "Log Analytics $LogAnalyticsName already exists" }
else {
    Write-Step "Creating Log Analytics workspace $LogAnalyticsName"
    Invoke-Az monitor log-analytics workspace create -n $LogAnalyticsName -g $ResourceGroup -l $Location | Out-Null
    Write-Ok 'Created'
}
$LaResourceId = (& az monitor log-analytics workspace show -n $LogAnalyticsName -g $ResourceGroup --query id -o tsv)

$ai = & az monitor app-insights component show --app $AppInsightsName -g $ResourceGroup 2>$null
if ($ai) { Write-Skip "App Insights $AppInsightsName already exists" }
else {
    Write-Step "Creating App Insights $AppInsightsName"
    Invoke-Az monitor app-insights component create --app $AppInsightsName -g $ResourceGroup -l $Location --workspace $LaResourceId | Out-Null
    Write-Ok 'Created'
}
$AiResourceId       = (& az monitor app-insights component show --app $AppInsightsName -g $ResourceGroup --query id -o tsv)
$AiConnectionString = (& az monitor app-insights component show --app $AppInsightsName -g $ResourceGroup --query connectionString -o tsv)

# =============================================================================
# PHASE 8 - Project connections (ACR + Application Insights)
# =============================================================================
Write-Phase 8 'Project connections'

function Set-ProjectConnection {
    param([string]$Name,[string]$Body)
    $url = "https://management.azure.com/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName/projects/$ProjectName/connections/${Name}?api-version=2025-04-01-preview"
    $existing = & az rest --method GET --url $url 2>$null
    if ($existing) { Write-Skip "Connection $Name already exists" ; return }
    $Body | Out-File -FilePath conn.body.json -Encoding ascii -NoNewline
    Invoke-Az rest --method PUT --url $url --body '@conn.body.json' --headers 'Content-Type=application/json' | Out-Null
    Remove-Item conn.body.json
    Write-Ok "Connection $Name created"
}

# ACR connection - allows the capability host to pull our image
$acrConnBody = @{
    properties = @{
        category = 'ContainerRegistry'
        target = "https://$AcrLoginServer"
        authType = 'AAD'
        metadata = @{ ApiType = 'Azure'; ResourceId = $AcrResourceId }
    }
} | ConvertTo-Json -Depth 5 -Compress
Set-ProjectConnection -Name 'acr-connection' -Body $acrConnBody

# App Insights connection - enables the Foundry "Tracing" tab to read our telemetry
$aiConnBody = @{
    properties = @{
        category = 'AppInsights'
        target   = $AiResourceId
        authType = 'AAD'
        metadata = @{ ApiType = 'Azure'; ResourceId = $AiResourceId; ConnectionString = $AiConnectionString }
    }
} | ConvertTo-Json -Depth 5 -Compress
Set-ProjectConnection -Name 'appi-connection' -Body $aiConnBody

# =============================================================================
# PHASE 9 - Model deployment (gpt-5-mini)
# =============================================================================
Write-Phase 9 "Model deployment ($ModelName)"
$dep = & az cognitiveservices account deployment show --name $AccountName -g $ResourceGroup --deployment-name $ModelName 2>$null
if ($dep) { Write-Skip "Deployment $ModelName already exists" }
else {
    Write-Step "Creating deployment $ModelName ($ModelVersion, capacity $ModelCapacity, GlobalStandard)"
    Invoke-Az cognitiveservices account deployment create `
        --name $AccountName -g $ResourceGroup `
        --deployment-name $ModelName `
        --model-name $ModelName --model-version $ModelVersion --model-format OpenAI `
        --sku-capacity $ModelCapacity --sku-name GlobalStandard | Out-Null
    Write-Ok 'Deployed'
}

# =============================================================================
# PHASE 10 - Capability host (account-level, kind=Agents)
# =============================================================================
Write-Phase 10 'Capability host (account-level)'
$capUrl = "https://management.azure.com/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName/capabilityHosts/agents?api-version=2025-10-01-preview"
$capExisting = & az rest --method GET --url $capUrl 2>$null
if ($capExisting) {
    $cap = $capExisting | ConvertFrom-Json
    if ($cap.properties.provisioningState -eq 'Succeeded') {
        Write-Skip "Capability host already provisioned"
    } else {
        Write-Step "Capability host exists in state $($cap.properties.provisioningState) - waiting"
    }
} else {
    Write-Step 'Creating capability host'
    '{"properties":{"capabilityHostKind":"Agents","enablePublicHostingEnvironment":true}}' |
        Out-File -FilePath cap.body.json -Encoding ascii -NoNewline
    Invoke-Az rest --method PUT --url $capUrl --body '@cap.body.json' --headers 'Content-Type=application/json' | Out-Null
    Remove-Item cap.body.json
}

# Wait for capability host to reach Succeeded
Write-Step 'Waiting for capability host to reach Succeeded (this takes ~3 min on first creation)'
$tries = 0
do {
    Start-Sleep -Seconds 15
    $tries++
    $state = (& az rest --method GET --url $capUrl --query 'properties.provisioningState' -o tsv 2>$null)
    Write-Host "    state ($($tries*15)s): $state" -ForegroundColor DarkGray
    if ($tries -gt 40) { Write-Err2 'Timed out after 10 min'; exit 1 }
} while ($state -ne 'Succeeded' -and $state -ne 'Failed')
if ($state -eq 'Failed') { Write-Err2 'Capability host failed to provision'; exit 1 }
Write-Ok 'Capability host ready'

# =============================================================================
# PHASE 11 - Build & push container
# =============================================================================
Write-Phase 11 'Container build and push'
$srcDir = Join-Path $PSScriptRoot 'src/HostedAgent'
if (-not (Test-Path $srcDir)) { Write-Err2 "Cannot find $srcDir"; exit 1 }

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$imageTag  = "$AcrLoginServer/$($AgentName):$timestamp"

if ($SkipBuild) {
    Write-Skip 'Skipping build (-SkipBuild) - using latest existing image in ACR'
    $imageTag = (& az acr repository show-tags --name $ContainerRegistry --repository $AgentName --orderby time_desc --top 1 -o tsv) | ForEach-Object { "$AcrLoginServer/$($AgentName):$_" }
    if ([string]::IsNullOrEmpty($imageTag)) { Write-Err2 "No existing image found in ACR for $AgentName"; exit 1 }
    Write-Ok "Using $imageTag"
} else {
    Write-Step "docker build -> $imageTag"
    Push-Location $srcDir
    try {
        & docker build -t $imageTag . | Tee-Object -Variable null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'docker build failed' }
    } finally { Pop-Location }
    Write-Ok 'Build complete'

    Write-Step "az acr login --name $ContainerRegistry"
    Invoke-Az acr login --name $ContainerRegistry | Out-Null
    Write-Step 'docker push'
    & docker push $imageTag | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'docker push failed' }
    Write-Ok "Pushed $imageTag"
}

# =============================================================================
# PHASE 12 - Create hosted agent version (Foundry data plane)
# =============================================================================
Write-Phase 12 'Hosted agent version (Foundry data plane)'

$AzureOpenAIEndpoint = "https://$AccountName.openai.azure.com/"
$ProjectEndpoint     = "https://$AccountName.services.ai.azure.com/api/projects/$ProjectName"
$dataPlaneToken      = (& az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
if (-not $dataPlaneToken) { throw 'Could not acquire ai.azure.com bearer token' }

$envVars = @{
    AZURE_OPENAI_ENDPOINT        = $AzureOpenAIEndpoint
    AZURE_OPENAI_DEPLOYMENT_NAME = $ModelName
    AZURE_ENV_NAME               = $suffix
    OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = 'true'
    # Note: APPLICATIONINSIGHTS_CONNECTION_STRING is reserved/auto-injected by Foundry.
}

$createBody = @{
    definition = @{
        kind   = 'hosted'
        image  = $imageTag
        cpu    = $Cpu
        memory = $Memory
        container_protocol_versions = @(@{ protocol = 'responses'; version = '1.0.0' })
        environment_variables = $envVars
    }
} | ConvertTo-Json -Depth 6

Write-Step "POST $ProjectEndpoint/agents/$AgentName/versions"
$resp = $null
try {
    $resp = Invoke-RestMethod `
        -Uri "$ProjectEndpoint/agents/$AgentName/versions?api-version=v1" `
        -Method POST `
        -Headers @{
            'Content-Type'      = 'application/json'
            'Authorization'     = "Bearer $dataPlaneToken"
            'Foundry-Features'  = 'HostedAgents=V1Preview'
        } `
        -Body $createBody
} catch {
    if ($_.Exception.Response) {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $reader.BaseStream.Position = 0
        Write-Err2 ("Foundry returned: " + $reader.ReadToEnd())
    }
    throw
}

$AgentVersion = $resp.version
$AgentPrincipalId = $resp.instance_identity.principal_id
Write-Ok "Created agent $AgentName version $AgentVersion"
Write-Ok "  Identity (principal id): $AgentPrincipalId"

# =============================================================================
# PHASE 13 - Role assignment for the agent's managed identity
# =============================================================================
Write-Phase 13 'Role assignment (Cognitive Services OpenAI User)'
$openaiScope = "/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName"
$existing = & az role assignment list --assignee $AgentPrincipalId --scope $openaiScope --role 'Cognitive Services OpenAI User' --query '[0].id' -o tsv 2>$null
if ($existing) {
    Write-Skip 'Role assignment already exists'
} else {
    Write-Step 'Granting Cognitive Services OpenAI User on the AI account'
    Invoke-Az role assignment create --assignee-object-id $AgentPrincipalId --assignee-principal-type ServicePrincipal --role 'Cognitive Services OpenAI User' --scope $openaiScope | Out-Null
    Write-Ok 'Granted'
}

# =============================================================================
# PHASE 14 - Smoke test (best-effort - first cold start can take ~60-90s)
# =============================================================================
Write-Phase 14 'Smoke test (cold start may take up to 90s)'
$smokeBody = @{ model = 'FoundryHostedAgent'; input = 'Reply with exactly the word READY.' } | ConvertTo-Json
$smokeUrl  = "$ProjectEndpoint/agents/$AgentName/endpoint/protocols/openai/responses?api-version=2025-11-15-preview"
Write-Step "POST $smokeUrl"
try {
    $smoke = Invoke-RestMethod -Uri $smokeUrl -Method POST `
        -Headers @{ 'Content-Type'='application/json'; 'Authorization'="Bearer $dataPlaneToken" } `
        -Body $smokeBody -TimeoutSec 180
    $msg = ($smoke.output | Where-Object { $_.type -eq 'message' } | Select-Object -Last 1).content[0].text
    Write-Ok "Agent replied: $msg"
} catch {
    Write-Warn2 'Smoke test did not complete (cold start in progress is the most common cause).'
    Write-Warn2 'Re-test in 60s with:'
    Write-Host  "  Invoke-RestMethod -Uri '$smokeUrl' -Method POST -Headers @{ 'Authorization'='Bearer <token>'; 'Content-Type'='application/json' } -Body '$smokeBody'" -ForegroundColor DarkGray
}

# =============================================================================
# PHASE 15 - Summary
# =============================================================================
Write-Phase 15 'Done - summary'
Write-Host ""
Write-Host "  Resource Group   : $ResourceGroup"                               -ForegroundColor White
Write-Host "  Foundry Account  : $AccountName"                                  -ForegroundColor White
Write-Host "  Foundry Project  : $ProjectName"                                  -ForegroundColor White
Write-Host "  Agent name       : $AgentName  (version $AgentVersion)"           -ForegroundColor White
Write-Host "  Container image  : $imageTag"                                     -ForegroundColor White
Write-Host "  Project endpoint : $ProjectEndpoint"                              -ForegroundColor White
Write-Host ""
Write-Host "  Foundry portal:" -ForegroundColor Cyan
Write-Host "    https://ai.azure.com/build/agents?wsid=/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName/projects/$ProjectName" -ForegroundColor White
Write-Host ""
Write-Host "  App Insights (Tracing):" -ForegroundColor Cyan
Write-Host "    https://portal.azure.com/#@$TenantId/resource$AiResourceId/searchV1" -ForegroundColor White
Write-Host ""
Write-Host "  Test from CLI:" -ForegroundColor Cyan
Write-Host "    `$tok = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv" -ForegroundColor White
Write-Host "    `$body = @{ model='FoundryHostedAgent'; input='What is the capital of Japan?' } | ConvertTo-Json" -ForegroundColor White
Write-Host "    Invoke-RestMethod -Uri '$ProjectEndpoint/agents/$AgentName/endpoint/protocols/openai/responses?api-version=2025-11-15-preview' -Method POST -Headers @{ 'Authorization'=`"Bearer `$tok`"; 'Content-Type'='application/json' } -Body `$body" -ForegroundColor White
Write-Host ""

# Save state for cleanup.ps1
@{
    Subscription      = $SubId
    Tenant            = $TenantId
    ResourceGroup     = $ResourceGroup
    AccountName       = $AccountName
    ProjectName       = $ProjectName
    ContainerRegistry = $ContainerRegistry
    AgentName         = $AgentName
    AgentVersion      = $AgentVersion
    ProjectEndpoint   = $ProjectEndpoint
    DeployedAt        = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json | Out-File -FilePath (Join-Path $PSScriptRoot '.deploy-state.json') -Encoding utf8
Write-Ok 'Saved .deploy-state.json (used by cleanup.ps1)'
