#!/usr/bin/env pwsh
# =============================================================================
# Foundry Hosted Agent - LEAN Deployer
# -----------------------------------------------------------------------------
# Assumes infrastructure (RG, AI account, project, ACR, AppInsights) was
# ALREADY provisioned by deploy.ps1 / bicep. This script only:
#   1. Verifies az login + required infra exists (fail-fast)
#   2. Ensures the model deployment exists
#   3. Ensures the capability host exists (creates if missing)
#   4. Builds + pushes the Docker image to ACR
#   5. Registers the hosted agent version in Foundry (data-plane API)
#   6. Grants the agent's managed identity OpenAI access
#   7. Smoke-tests the agent
#
# A backup of the original full deployer is at deploy-agent.full.ps1
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$EnvName,
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$AccountName,
    [Parameter(Mandatory)] [string]$ProjectName,
    [Parameter(Mandatory)] [string]$ContainerRegistry,

    # Accepted for back-compat with deploy.ps1; not required by lean flow.
    [string]$AppInsightsName,
    [string]$LogAnalyticsName,

    [ValidateSet('swedencentral','canadacentral','northcentralus','australiaeast')]
    [string]$Location = 'swedencentral',

    [string]$Subscription,
    [string]$Tenant,

    [string]$AgentName     = 'foundry-hosted-agent',
    [string]$ModelName     = 'gpt-5-mini',
    [string]$ModelVersion  = '2025-08-07',
    [int]   $ModelCapacity = 10,

    [string]$Cpu    = '1',
    [string]$Memory = '2Gi',

    [switch]$SkipBuild,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
$global:LASTEXITCODE = 0

function Write-Phase($n, $msg) {
    Write-Host ""
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "  AGENT STEP $n - $msg" -ForegroundColor DarkCyan
    Write-Host "--------------------------------------------------------------------------------" -ForegroundColor DarkCyan
}
function Write-Step($msg) { Write-Host "  > $msg" -ForegroundColor White }
function Write-Ok($msg)   { Write-Host "    [OK]   $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "    [SKIP] $msg" -ForegroundColor DarkGray }
function Write-Warn2($msg){ Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Err2($msg) { Write-Host "    [ERR]  $msg" -ForegroundColor Red }

# =============================================================================
# AGENT STEP 0 - Prerequisite check
# =============================================================================
Write-Phase 0 "Prerequisite check"
foreach ($t in @('az','docker','dotnet')) {
    $cmd = Get-Command $t -ErrorAction SilentlyContinue
    if (-not $cmd) { Write-Err2 "$t not found on PATH"; exit 1 }
    Write-Ok "$t -> $($cmd.Source)"
}
if (-not $SkipBuild) {
    & docker version --format '{{.Server.Version}}' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Err2 "Docker Desktop is not running."; exit 1 }
    $global:LASTEXITCODE = 0
    Write-Ok "docker daemon is responsive"
}

# =============================================================================
# AGENT STEP 1 - Azure context
# =============================================================================
Write-Phase 1 "Azure context"
$accountJson = & az account show 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accountJson)) {
    Write-Err2 "Not logged in to az. Run 'az login' first."
    exit 1
}
$global:LASTEXITCODE = 0
$account  = $accountJson | Out-String | ConvertFrom-Json
$SubId    = if ($Subscription) { $Subscription } else { $account.id }
$TenantId = $account.tenantId
if ($Subscription -and $Subscription -ne $account.id) {
    & az account set --subscription $SubId | Out-Null
    $account = (& az account show) | Out-String | ConvertFrom-Json
}
Write-Ok "Subscription : $($account.name) ($SubId)"
Write-Ok "Tenant       : $TenantId"
Write-Ok "Signed in as : $($account.user.name)"

# =============================================================================
# AGENT STEP 2 - Verify required infra exists (fail-fast)
# =============================================================================
Write-Phase 2 "Verify infrastructure exists"

Write-Step "Resource group $ResourceGroup"
$rgExists = (& az group exists --name $ResourceGroup 2>$null) -eq 'true'
$global:LASTEXITCODE = 0
if (-not $rgExists) { Write-Err2 "Resource group '$ResourceGroup' not found. Run deploy.ps1 first."; exit 1 }
Write-Ok "exists"

Write-Step "AI Foundry account $AccountName"
$acctRaw = & az cognitiveservices account show --name $AccountName --resource-group $ResourceGroup -o json 2>$null
$global:LASTEXITCODE = 0
if ([string]::IsNullOrWhiteSpace($acctRaw)) { Write-Err2 "Foundry account '$AccountName' not found."; exit 1 }
Write-Ok "exists"

Write-Step "Container registry $ContainerRegistry"
$acrRaw = & az acr show --name $ContainerRegistry --resource-group $ResourceGroup -o json 2>$null
$global:LASTEXITCODE = 0
if ([string]::IsNullOrWhiteSpace($acrRaw)) { Write-Err2 "ACR '$ContainerRegistry' not found."; exit 1 }
$acrInfo = $acrRaw | Out-String | ConvertFrom-Json
$AcrLoginServer = $acrInfo.loginServer
$AcrResourceId  = $acrInfo.id
Write-Ok "exists - $AcrLoginServer"

# =============================================================================
# AGENT STEP 3 - Model deployment (idempotent)
# =============================================================================
Write-Phase 3 "Model deployment ($ModelName)"
$dep = & az cognitiveservices account deployment show --name $AccountName -g $ResourceGroup --deployment-name $ModelName 2>$null
$global:LASTEXITCODE = 0
if (-not [string]::IsNullOrWhiteSpace($dep)) {
    Write-Skip "Deployment '$ModelName' already exists"
} else {
    Write-Step "Creating deployment $ModelName ($ModelVersion, capacity $ModelCapacity, GlobalStandard)..."
    & az cognitiveservices account deployment create `
        --name $AccountName -g $ResourceGroup `
        --deployment-name $ModelName `
        --model-name $ModelName --model-version $ModelVersion --model-format OpenAI `
        --sku-capacity $ModelCapacity --sku-name GlobalStandard | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Err2 "Model deployment failed"; exit 1 }
    $global:LASTEXITCODE = 0
    Write-Ok "Deployed"
}

# =============================================================================
# AGENT STEP 4 - Capability host (account-level, kind=Agents)
# =============================================================================
Write-Phase 4 "Capability host"
$capUrl = "https://management.azure.com/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName/capabilityHosts/agents?api-version=2025-10-01-preview"
$capExisting = & az rest --method GET --url $capUrl 2>$null
$global:LASTEXITCODE = 0
$mustWait = $false
if (-not [string]::IsNullOrWhiteSpace($capExisting)) {
    $cap = $capExisting | Out-String | ConvertFrom-Json
    if ($cap.properties.provisioningState -eq 'Succeeded') {
        Write-Skip "Capability host already provisioned"
    } else {
        Write-Step "Capability host exists in state $($cap.properties.provisioningState) - waiting"
        $mustWait = $true
    }
} else {
    Write-Step "Creating capability host..."
    '{"properties":{"capabilityHostKind":"Agents","enablePublicHostingEnvironment":true}}' | Out-File -FilePath cap.body.json -Encoding ascii -NoNewline
    & az rest --method PUT --url $capUrl --body '@cap.body.json' --headers 'Content-Type=application/json' | Out-Null
    Remove-Item cap.body.json -ErrorAction SilentlyContinue
    $global:LASTEXITCODE = 0
    $mustWait = $true
}

if ($mustWait) {
    Write-Step "Waiting for capability host to reach Succeeded (up to 5 min)..."
    $tries = 0
    do {
        Start-Sleep -Seconds 15
        $tries++
        $state = (& az rest --method GET --url $capUrl --query 'properties.provisioningState' -o tsv 2>$null)
        $global:LASTEXITCODE = 0
        Write-Host "    state ($($tries*15)s): $state" -ForegroundColor DarkGray
        if ($tries -gt 20) { Write-Err2 "Timed out after 5 min"; exit 1 }
    } while ($state -ne 'Succeeded' -and $state -ne 'Failed')
    if ($state -eq 'Failed') { Write-Err2 "Capability host failed to provision"; exit 1 }
    Write-Ok "Capability host ready"
}

# =============================================================================
# AGENT STEP 5 - Bootstrap Foundry sub-agents via REST (Botany / Toxicity / Summary)
# These are PERSISTENT agents on the project, visible immediately in the
# Foundry portal under Agents. The hosted orchestrator will then call them
# at runtime as tools. Idempotent: re-uses existing agents on re-run.
# =============================================================================
Write-Phase 5 "Bootstrap Foundry sub-agents (Botany / Toxicity / Summary)"
$projectEndpoint = "https://$AccountName.services.ai.azure.com/api/projects/$ProjectName"
$bootstrapToken  = (& az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv 2>$null)
$global:LASTEXITCODE = 0
if ([string]::IsNullOrWhiteSpace($bootstrapToken)) { Write-Err2 "Could not acquire ai.azure.com bearer token for sub-agent bootstrap"; exit 1 }

$bootstrapHeaders = @{
    'Authorization' = "Bearer $bootstrapToken"
    'Content-Type'  = 'application/json'
}

# --- Sub-agent system instructions (kept in sync with PlantAgents.cs) --------
$BotanyInstructions = @'
You are BOTANY-EXPERT, a world-class botanist with encyclopaedic knowledge of every indoor and outdoor plant: trees, shrubs, herbs, succulents, ferns, mosses, flowering plants, vegetables, fruits, ornamentals - wild and cultivated.

For every plant question return:
  - Common name(s)
  - Scientific name (binomial: Genus species)
  - Family
  - Native region / habitat
  - Indoor vs. outdoor suitability
  - Light, water, soil, temperature requirements
  - Propagation method(s)
  - Notable cultivars (if any)

STRICT RULES:
  - You ONLY answer botany / horticulture questions.
  - If the user asks anything outside botany, reply: "I can only answer botany and plant-care questions. Please ask me about a plant."
  - Do NOT discuss toxicity / poisoning - that is Toxicity-Detector's job.
  - Be factual and concise. No marketing fluff.
'@

$ToxicityInstructions = @'
You are TOXICITY-DETECTOR, a botanical toxicologist. For any plant identified by the user, report:
  - Toxic compounds present (e.g., calcium oxalate raphides, solanine, cardiac glycosides, alkaloids, saponins, etc.)
  - Which parts of the plant contain them (leaves, sap, berries, roots, ...)
  - Risk to HUMANS (skin contact, ingestion, allergic reaction)
  - Risk to PETS (cats, dogs, horses, rabbits, birds)
  - Severity rating: NON-TOXIC / MILDLY TOXIC / MODERATELY TOXIC / HIGHLY TOXIC
  - Recommended first aid if exposure occurs

STRICT RULES:
  - You ONLY answer plant-toxicity questions.
  - If a plant is non-toxic, say so clearly with "NON-TOXIC".
  - If asked anything outside plant toxicity, reply: "I can only answer plant toxicity questions. Please ask me about a specific plant."
  - Never give general medical advice - only first-aid for plant exposure.
  - Be factual and concise. Use bullet points.
'@

$SummaryInstructions = @'
You are SUMMARY-GENERATOR. You receive raw findings from two upstream specialists (Botany-Expert and Toxicity-Detector) about a plant the end-user asked about. Produce a SHORT, USER-FRIENDLY summary.

OUTPUT FORMAT (markdown):
  ## <Plant common name> (<Scientific name>)

  **Quick facts**
  - <one-liner about family + native region>
  - <indoor/outdoor + key care need>
  - <one notable feature>

  **Care essentials**
  - Light: ...
  - Water: ...
  - Soil: ...

  **Safety**
  - Toxicity: <NON-TOXIC | MILDLY | MODERATELY | HIGHLY TOXIC>
  - Risk to pets: <one line>
  - Risk to humans: <one line>

  **Bottom line**
  <one friendly sentence: should they get this plant? any caveat?>

STRICT RULES:
  - Only summarise what the upstream agents reported. Do NOT invent facts.
  - If upstream content is missing or off-topic, say so honestly.
  - Keep it under 200 words total.
  - Never answer questions yourself - you only summarise.
'@

# --- List existing agents on the project (NEW Foundry /agents API) ----------
Write-Step "Listing existing agents on project..."
$listUrl = "$projectEndpoint/agents?api-version=v1"
$existingByName = @{}
try {
    $existingResp = Invoke-RestMethod -Uri $listUrl -Method GET -Headers $bootstrapHeaders -TimeoutSec 30
    foreach ($a in $existingResp.data) {
        if ($a.name) { $existingByName[$a.name] = $a.id }
    }
    Write-Ok "Found $($existingByName.Count) existing agent(s)"
} catch {
    Write-Warn2 "Could not list existing agents (will attempt to create): $($_.Exception.Message)"
}

function Ensure-SubAgent {
    param([string]$Name, [string]$Instructions)
    if ($existingByName.ContainsKey($Name)) {
        Write-Skip "$Name already exists - creating new version with updated instructions"
    } else {
        Write-Step "Creating sub-agent: $Name (kind=prompt)"
    }
    # New Foundry /agents API: PUT /agents/{name}/versions creates a new version.
    # Definition uses kind=prompt for non-hosted (model + instructions) agents.
    $body = @{
        definition = @{
            kind         = 'prompt'
            model        = $ModelName
            instructions = $Instructions
        }
    } | ConvertTo-Json -Depth 6
    try {
        $resp = Invoke-RestMethod -Uri "$projectEndpoint/agents/$Name/versions?api-version=v1" -Method POST `
            -Headers $bootstrapHeaders -Body $body -TimeoutSec 60
        Write-Ok "$Name version $($resp.version) ready (id: $($resp.id))"
        return $resp.id
    } catch {
        $errBody = ""
        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $reader.BaseStream.Position = 0
                $errBody = $reader.ReadToEnd()
            } catch { }
        }
        Write-Err2 "Failed to create $Name : $($_.Exception.Message)"
        if ($errBody) { Write-Err2 "Response: $errBody" }
        exit 1
    }
}

$BotanyId   = Ensure-SubAgent -Name 'Botany-Expert'      -Instructions $BotanyInstructions
$ToxicityId = Ensure-SubAgent -Name 'Toxicity-Detector'  -Instructions $ToxicityInstructions
$SummaryId  = Ensure-SubAgent -Name 'Summary-Generator'  -Instructions $SummaryInstructions

Write-Host ""
Write-Host "  Visible in Foundry portal at:" -ForegroundColor Cyan
Write-Host "  https://ai.azure.com/build/agents?wsid=/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName/projects/$ProjectName" -ForegroundColor White
Write-Host ""

# =============================================================================
# AGENT STEP 6 - Build & push container
# =============================================================================
Write-Phase 6 "Container build and push"
$srcDir = Join-Path $PSScriptRoot 'src/HostedAgent'
if (-not (Test-Path $srcDir)) { Write-Err2 "Cannot find $srcDir"; exit 1 }

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$imageTag  = "$AcrLoginServer/$($AgentName):$timestamp"

if ($SkipBuild) {
    Write-Skip "Skipping build (-SkipBuild). Looking up latest image..."
    $latestTag = (& az acr repository show-tags --name $ContainerRegistry --repository $AgentName --orderby time_desc --top 1 -o tsv 2>$null)
    $global:LASTEXITCODE = 0
    if ([string]::IsNullOrWhiteSpace($latestTag)) { Write-Err2 "No existing image found in ACR for $AgentName"; exit 1 }
    $imageTag = "$AcrLoginServer/$($AgentName):$latestTag"
    Write-Ok "Using $imageTag"
} else {
    # Ensure .dockerignore exists (skip bin/obj/log files)
    $dockerIgnore = Join-Path $srcDir '.dockerignore'
    if (-not (Test-Path $dockerIgnore)) {
        Write-Step "Creating .dockerignore (excludes bin/obj/log files)..."
        @(
            '**/bin/'
            '**/obj/'
            '**/.vs/'
            'agent.log'
            'agent.err.log'
            'agent.pid'
            '.azure/'
            '.deploy-state.json'
            '.git/'
            '*.md'
            'Dockerfile'
            '.dockerignore'
        ) -join "`n" | Out-File -FilePath $dockerIgnore -Encoding ascii -NoNewline
    }

    # Clean stale build artifacts that can cause docker build failures
    Write-Step "Cleaning stale bin/obj folders before build..."
    Remove-Item -Recurse -Force (Join-Path $srcDir 'bin') -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force (Join-Path $srcDir 'obj') -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $srcDir 'agent.pid') -ErrorAction SilentlyContinue

    # Make sure BuildKit is enabled (cleaner output, better caching)
    $env:DOCKER_BUILDKIT = '1'

    Write-Step "docker build -> $imageTag (this may take 2-5 min)"
    Write-Host "    (live build output below - watch for any 'ERROR:' lines)" -ForegroundColor DarkGray
    Write-Host ""
    Push-Location $srcDir
    try {
        # Stream docker output directly (don't pipe - lets us see progress live)
        & docker build --progress=plain -t $imageTag .
        $buildExit = $LASTEXITCODE
    } finally { Pop-Location }
    Write-Host ""
    if ($buildExit -ne 0) {
        Write-Err2 "docker build failed (exit code $buildExit)"
        Write-Err2 "Common causes:"
        Write-Err2 "  - Missing base image (check internet / proxy)"
        Write-Err2 "  - Locked files in src/HostedAgent (close any running agent.exe)"
        Write-Err2 "  - .NET SDK version mismatch (Dockerfile expects dotnet/sdk:10.0-alpine)"
        exit 1
    }
    $global:LASTEXITCODE = 0
    Write-Ok "Build complete"

    Write-Step "az acr login --name $ContainerRegistry"
    & az acr login --name $ContainerRegistry
    $loginExit = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($loginExit -ne 0) {
        Write-Err2 "az acr login failed (exit code $loginExit)"
        Write-Err2 "Make sure your user has AcrPush role on $ContainerRegistry"
        Write-Err2 "Or: az role assignment create --role AcrPush --assignee <yourId> --scope <acrId>"
        exit 1
    }
    Write-Ok "ACR login successful"

    Write-Step "docker push $imageTag"
    & docker push $imageTag
    $pushExit = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($pushExit -ne 0) {
        Write-Err2 "docker push failed (exit code $pushExit)"
        Write-Err2 "Common causes:"
        Write-Err2 "  - Network/firewall blocking $AcrLoginServer"
        Write-Err2 "  - Token expired (re-run script to refresh)"
        Write-Err2 "  - Missing AcrPush role on registry"
        exit 1
    }
    Write-Ok "Pushed $imageTag"
}

# =============================================================================
# AGENT STEP 7 - Create hosted agent version (Foundry data plane)
# =============================================================================
Write-Phase 7 "Hosted agent version (Foundry data plane)"

$AzureOpenAIEndpoint = "https://$AccountName.openai.azure.com/"
$ProjectEndpoint     = "https://$AccountName.services.ai.azure.com/api/projects/$ProjectName"
$dataPlaneToken      = (& az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv 2>$null)
$global:LASTEXITCODE = 0
if ([string]::IsNullOrWhiteSpace($dataPlaneToken)) { Write-Err2 "Could not acquire ai.azure.com bearer token"; exit 1 }

$envVars = @{
    AZURE_OPENAI_ENDPOINT        = $AzureOpenAIEndpoint
    AZURE_OPENAI_DEPLOYMENT_NAME = $ModelName
    AZURE_AI_PROJECT_ENDPOINT    = $ProjectEndpoint
    AZURE_ENV_NAME               = $EnvName
    OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT = 'true'
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
    } else {
        Write-Err2 $_.Exception.Message
    }
    exit 1
}

$AgentVersion     = $resp.version
$AgentPrincipalId = $resp.instance_identity.principal_id
Write-Ok "Created agent $AgentName version $AgentVersion"
Write-Ok "  Identity (principal id): $AgentPrincipalId"

# =============================================================================
# AGENT STEP 8 - Role assignments for the agent's managed identity
#   - Cognitive Services OpenAI User : call gpt-5-mini chat completions
#   - Azure AI Developer             : create/run sub-agents on the project
# =============================================================================
Write-Phase 8 "Role assignments for hosted agent identity"
$accountScope = "/subscriptions/$SubId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$AccountName"

function Grant-Role($roleName) {
    $existing = & az role assignment list --assignee $AgentPrincipalId --scope $accountScope --role $roleName --query '[0].id' -o tsv 2>$null
    $global:LASTEXITCODE = 0
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Skip "$roleName already granted"
    } else {
        Write-Step "Granting '$roleName' on the AI account..."
        & az role assignment create --assignee-object-id $AgentPrincipalId --assignee-principal-type ServicePrincipal --role $roleName --scope $accountScope | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn2 "'$roleName' grant returned non-zero (may already exist)" }
        $global:LASTEXITCODE = 0
        Write-Ok "Granted $roleName"
    }
}

Grant-Role 'Cognitive Services OpenAI User'   # for gpt-5-mini chat completions
Grant-Role 'Azure AI Developer'                # for managing the 3 sub-agents (Botany/Toxicity/Summary)

# =============================================================================
# AGENT STEP 8 - Smoke test (best-effort)
# =============================================================================
Write-Phase 9 "Smoke test (cold start may take up to 90s + multi-agent calls)"
$smokeBody = @{ model = 'FoundryHostedAgent'; input = 'Tell me about Pothos plant.' } | ConvertTo-Json
$smokeUrl  = "$ProjectEndpoint/agents/$AgentName/endpoint/protocols/openai/responses?api-version=2025-11-15-preview"
Write-Step "POST $smokeUrl"
Write-Step "(asking about Pothos - orchestrator will call Botany + Toxicity + Summary sub-agents)"
try {
    $smoke = Invoke-RestMethod -Uri $smokeUrl -Method POST `
        -Headers @{ 'Content-Type'='application/json'; 'Authorization'="Bearer $dataPlaneToken" } `
        -Body $smokeBody -TimeoutSec 240
    $msg = ($smoke.output | Where-Object { $_.type -eq 'message' } | Select-Object -Last 1).content[0].text
    Write-Ok "Agent replied:"
    Write-Host ""
    Write-Host $msg -ForegroundColor White
    Write-Host ""
} catch {
    Write-Warn2 "Smoke test did not complete (cold start in progress is the most common cause)."
    Write-Warn2 "Re-test in 60s in the Foundry portal playground."
}

# =============================================================================
# AGENT STEP 10 - Summary
# =============================================================================
Write-Phase 10 "Done - agent summary"
Write-Host ""
Write-Host "  Resource Group   : $ResourceGroup"                          -ForegroundColor White
Write-Host "  Foundry Account  : $AccountName"                             -ForegroundColor White
Write-Host "  Foundry Project  : $ProjectName"                             -ForegroundColor White
Write-Host "  Agent name       : $AgentName  (version $AgentVersion)"      -ForegroundColor White
Write-Host "  Container image  : $imageTag"                                -ForegroundColor White
Write-Host "  Project endpoint : $ProjectEndpoint"                         -ForegroundColor White
Write-Host ""

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
Write-Ok "Saved .deploy-state.json (used by cleanup.ps1)"
