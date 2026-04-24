#!/usr/bin/env pwsh
# =============================================================================
# Quick Setup Script - Deploy Hosted Agent Infrastructure
# =============================================================================
# This script sets up the infrastructure for your hosted agent using the
# bicep files in the infra/ folder. It enforces the 4 allowed locations
# for hosted agents.
#
# USAGE:
#   .\setup-infra.ps1
#   .\setup-infra.ps1 -Location swedencentral -EnvironmentName myagent
#
# =============================================================================

[CmdletBinding()]
param(
    # ONLY these 4 locations are supported for hosted agents
    [ValidateSet('swedencentral','canadacentral','northcentralus','australiaeast')]
    [string]$Location,

    [string]$EnvironmentName,

    [string]$ResourceGroup,

    [switch]$SkipConfirmation
)

# -----------------------------------------------------------------------------
# Interactive prompts for missing values
# -----------------------------------------------------------------------------
if (-not $Location) {
    Write-Host ""
    Write-Host "Hosted agents are only supported in 4 regions:" -ForegroundColor Yellow
    Write-Host "  1) swedencentral   (recommended)" -ForegroundColor White
    Write-Host "  2) canadacentral" -ForegroundColor White
    Write-Host "  3) northcentralus" -ForegroundColor White
    Write-Host "  4) australiaeast" -ForegroundColor White
    $loc = Read-Host "Choose location [swedencentral]"
    if ([string]::IsNullOrWhiteSpace($loc)) { $loc = 'swedencentral' }
    if ($loc -notin @('swedencentral','canadacentral','northcentralus','australiaeast')) {
        Write-Host "Invalid location '$loc'. Must be one of the 4 supported regions." -ForegroundColor Red
        exit 1
    }
    $Location = $loc
}

if (-not $EnvironmentName) {
    $envName = Read-Host "Enter environment name (short, e.g. demo01)"
    if ([string]::IsNullOrWhiteSpace($envName)) {
        Write-Host "Environment name is required." -ForegroundColor Red
        exit 1
    }
    $EnvironmentName = $envName
}

if (-not $ResourceGroup) {
    $defaultRg = "rg-$EnvironmentName"
    $rg = Read-Host "Enter resource group name [$defaultRg]"
    if ([string]::IsNullOrWhiteSpace($rg)) { $rg = $defaultRg }
    $ResourceGroup = $rg
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------
function Write-Title($msg) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Step($msg) {
    Write-Host "  > $msg" -ForegroundColor Yellow
}

function Write-Success($msg) {
    Write-Host "  ? $msg" -ForegroundColor Green
}

function Write-Info($msg) {
    Write-Host "  ? $msg" -ForegroundColor Blue
}

# -----------------------------------------------------------------------------
# Main Script
# -----------------------------------------------------------------------------
Write-Title "Hosted Agent Infrastructure Setup"

Write-Info "This script will deploy Azure AI Foundry infrastructure for hosted agents."
Write-Info "Location:       $Location  (hosted agents only work in 4 regions)"
Write-Info "Environment:    $EnvironmentName"
Write-Info "Resource Group: $ResourceGroup"
Write-Host ""

if (-not $SkipConfirmation) {
    $continue = Read-Host "Continue? (y/n)"
    if ($continue -ne 'y') {
        Write-Host "Deployment cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Step 1: Check prerequisites
Write-Title "STEP 1: Checking Prerequisites"

Write-Step "Checking Azure CLI..."
$azVersion = az version --query '\"azure-cli\"' -o tsv 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ? Azure CLI not found. Please install: https://aka.ms/install-azure-cli" -ForegroundColor Red
    exit 1
}
Write-Success "Azure CLI version $azVersion"

Write-Step "Checking Azure Developer CLI (azd)..."
$azdVersion = azd version 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Success "azd is installed"
    $useAzd = $true
} else {
    Write-Info "azd not found. Will use Azure CLI directly."
    $useAzd = $false
}

Write-Step "Checking Azure login..."
$account = az account show 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ? Not logged in to Azure. Please run: az login" -ForegroundColor Red
    exit 1
}
$accountInfo = $account | ConvertFrom-Json
Write-Success "Logged in as: $($accountInfo.user.name)"
Write-Success "Subscription: $($accountInfo.name)"

# Step 2: Deploy infrastructure
Write-Title "STEP 2: Deploying Infrastructure"

if ($useAzd) {
    Write-Step "Using Azure Developer CLI (azd) for deployment..."

    # Check if .azure folder exists
    if (-not (Test-Path ".azure")) {
        Write-Step "Initializing azd environment..."
        azd init --environment $EnvironmentName --no-prompt
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ? Failed to initialize azd environment" -ForegroundColor Red
            exit 1
        }
    }

    Write-Step "Setting environment variables..."
    azd env set AZURE_LOCATION $Location
    azd env set AZURE_ENV_NAME $EnvironmentName
    azd env set AZURE_RESOURCE_GROUP $ResourceGroup
    azd env set ENABLE_HOSTED_AGENTS true
    azd env set ENABLE_MONITORING true
    azd env set ENABLE_CAPABILITY_HOST true
    azd env set HOSTED_AGENT_SERVICE_NAME "HostedAgent"

    Write-Step "Provisioning Azure resources..."
    Write-Info "This may take 5-10 minutes..."
    azd provision

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ? Deployment failed. Check error messages above." -ForegroundColor Red
        exit 1
    }

    Write-Success "Infrastructure deployed successfully!"

    Write-Title "Deployment Complete!"
    Write-Info "Use 'azd env get-values' to see all environment variables."

} else {
    Write-Step "Using Azure CLI for deployment..."

    $subscriptionId = $accountInfo.id
    $principalId = az ad signed-in-user show --query id -o tsv
    $deploymentName = "hosted-agent-$EnvironmentName-$(Get-Date -Format 'yyyyMMddHHmmss')"

    Write-Step "Creating subscription-level deployment..."
    Write-Info "Deployment name: $deploymentName"
    Write-Info "This may take 5-10 minutes..."

    az deployment sub create `
        --name $deploymentName `
        --location $Location `
        --template-file "./infra/main.bicep" `
        --parameters `
            environmentName=$EnvironmentName `
            resourceGroupName=$ResourceGroup `
            location=$Location `
            aiDeploymentsLocation=$Location `
            principalId=$principalId `
            principalType="User" `
            enableHostedAgents=true `
            enableMonitoring=true `
            enableCapabilityHost=true `
            hostedAgentServiceName="HostedAgent"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ? Deployment failed. Check error messages above." -ForegroundColor Red
        exit 1
    }

    Write-Success "Infrastructure deployed successfully!"

    # Get outputs
    Write-Step "Retrieving deployment outputs..."
    $outputs = az deployment sub show `
        --name $deploymentName `
        --query properties.outputs `
        -o json | ConvertFrom-Json

    Write-Title "Deployment Complete!"
    Write-Host ""
    Write-Info "Resource Group: $($outputs.AZURE_RESOURCE_GROUP.value)"
    Write-Info "AI Project Name: $($outputs.AZURE_AI_PROJECT_NAME.value)"
    Write-Info "AI Account Name: $($outputs.AZURE_AI_ACCOUNT_NAME.value)"
    Write-Info "Container Registry: $($outputs.AZURE_CONTAINER_REGISTRY_ENDPOINT.value)"

    if ($outputs.APPLICATIONINSIGHTS_CONNECTION_STRING.value) {
        Write-Info "Application Insights: Enabled"
    }
}

Write-Host ""
Write-Title "Next Steps"
Write-Host "  1. Build your hosted agent container" -ForegroundColor White
Write-Host "  2. Deploy using the deploy.ps1 script" -ForegroundColor White
Write-Host "  3. Test in Azure AI Foundry portal: https://ai.azure.com" -ForegroundColor White
Write-Host ""
Write-Success "Setup complete!"
