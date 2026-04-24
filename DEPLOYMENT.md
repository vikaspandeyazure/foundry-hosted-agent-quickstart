# ?? Deployment Guide for Hosted Agent Quickstart

This guide will help you deploy your hosted agent to Azure using the new infrastructure setup.

## ?? Prerequisites

Before deploying, ensure you have:

1. **Azure CLI** installed and logged in
   ```powershell
   az login
   az account set --subscription <your-subscription-id>
   ```

2. **Azure Developer CLI (azd)** installed (optional, but recommended)
   ```powershell
   winget install microsoft.azd
   ```

3. **.NET SDK** (for building the hosted agent)
4. **Docker** (if building container locally)
5. **Necessary Azure permissions**:
   - Contributor role on subscription or resource group
   - User Access Administrator (for RBAC assignments)

## ?? Quick Start Deployment

### Step 1: Choose Your Region

**IMPORTANT:** Hosted agents are only supported in 4 regions:
- `swedencentral` (recommended)
- `canadacentral`
- `northcentralus`
- `australiaeast`

### Step 2: Deploy Using azd (Recommended)

```powershell
# Navigate to the quickstart directory
cd foundry-hosted-agent-quickstart

# Initialize azd environment
azd init

# Set the location to one of the 4 allowed regions
azd env set AZURE_LOCATION swedencentral

# Optional: Set custom environment name
azd env set AZURE_ENV_NAME myhostedagent

# Provision Azure resources
azd provision

# This will:
# - Create resource group
# - Deploy AI Foundry project
# - Create Azure Container Registry
# - Set up monitoring (Application Insights)
# - Configure all necessary role assignments
```

### Step 3: Deploy Your Agent

After infrastructure is provisioned, deploy your agent code:

```powershell
# Option A: Use the existing deploy.ps1 script
.\deploy.ps1

# Option B: Use azd deploy (if configured in azure.yaml)
azd deploy
```

## ?? Alternative: Manual Deployment with Azure CLI

If you prefer not to use azd, you can deploy manually:

```powershell
# Set variables
$location = "swedencentral"
$envName = "hostedagent"
$subscriptionId = (az account show --query id -o tsv)
$principalId = (az ad signed-in-user show --query id -o tsv)

# Deploy infrastructure
az deployment sub create `
  --name "hosted-agent-infra-$(Get-Date -Format 'yyyyMMddHHmmss')" `
  --location $location `
  --template-file "./infra/main.bicep" `
  --parameters `
    environmentName=$envName `
    location=$location `
    aiDeploymentsLocation=$location `
    principalId=$principalId `
    principalType="User" `
    enableHostedAgents=true `
    enableMonitoring=true `
    enableCapabilityHost=true `
    hostedAgentServiceName="HostedAgent" `
    aiProjectDeploymentsJson='[]' `
    aiProjectConnectionsJson='[]' `
    aiProjectConnectionCredentialsJson='{}' `
    aiProjectDependentResourcesJson='[]'

# Get outputs
$deployment = az deployment sub show `
  --name "hosted-agent-infra-$(Get-Date -Format 'yyyyMMddHHmmss')" `
  --query properties.outputs -o json | ConvertFrom-Json

# Save outputs for later use
$deployment.AZURE_RESOURCE_GROUP.value
$deployment.AZURE_AI_PROJECT_NAME.value
$deployment.AZURE_CONTAINER_REGISTRY_ENDPOINT.value
```

## ??? Infrastructure Components Created

After deployment, you'll have:

1. **Resource Group**: `rg-{environmentName}`
2. **AI Services Account**: `ai-account-{uniqueString}`
3. **AI Foundry Project**: `ai-project-{environmentName}`
4. **Azure Container Registry**: `cr{uniqueString}`
5. **Application Insights**: `appi-{uniqueString}` (if monitoring enabled)
6. **Log Analytics Workspace**: `logs-{uniqueString}` (if monitoring enabled)
7. **Capability Host**: Enabled for hosted agents

## ?? Verify Deployment

### Check Infrastructure

```powershell
# List all resources in the resource group
az resource list --resource-group rg-{environmentName} --output table

# Check AI Foundry project
az cognitiveservices account show `
  --name {ai-account-name} `
  --resource-group rg-{environmentName}

# Verify Container Registry
az acr list --resource-group rg-{environmentName} --output table
```

### Test in Azure Portal

1. Go to [Azure AI Foundry Portal](https://ai.azure.com)
2. Navigate to your project
3. Check that resources are connected:
   - Container Registry connection
   - Application Insights connection (if enabled)

## ?? Troubleshooting

### Location Error

**Error**: `Location 'westus' is not in the allowed values`

**Solution**: Ensure you're using one of the 4 supported regions:
```powershell
azd env set AZURE_LOCATION swedencentral
```

### Permission Errors

**Error**: `Authorization failed` or `Missing role assignments`

**Solution**: Ensure you have:
- Contributor role on the subscription/resource group
- User Access Administrator role (for RBAC assignments)

```powershell
# Grant necessary permissions (requires subscription admin)
az role assignment create `
  --assignee {your-user-principal-id} `
  --role "Contributor" `
  --scope /subscriptions/{subscription-id}

az role assignment create `
  --assignee {your-user-principal-id} `
  --role "User Access Administrator" `
  --scope /subscriptions/{subscription-id}
```

### Bicep Compilation Errors

**Error**: Module or template not found

**Solution**: Ensure you're running commands from the `foundry-hosted-agent-quickstart` directory and the `infra` folder structure is correct.

## ?? Cleanup

To remove all resources:

```powershell
# Using azd
azd down

# Or manually delete resource group
az group delete --name rg-{environmentName} --yes --no-wait
```

## ?? Environment Variables

After deployment, these environment variables will be available in your azd environment:

- `AZURE_RESOURCE_GROUP`
- `AZURE_AI_ACCOUNT_NAME`
- `AZURE_AI_PROJECT_NAME`
- `AZURE_AI_PROJECT_ID`
- `AZURE_AI_PROJECT_ENDPOINT`
- `AZURE_OPENAI_ENDPOINT`
- `AZURE_CONTAINER_REGISTRY_ENDPOINT`
- `AZURE_AI_PROJECT_ACR_CONNECTION_NAME`
- `APPLICATIONINSIGHTS_CONNECTION_STRING`

Access them using:
```powershell
azd env get-values
```

## ?? Updating Infrastructure

To update the infrastructure after making changes to bicep files:

```powershell
# Using azd
azd provision

# Or manually
az deployment sub create `
  --name "hosted-agent-infra-update" `
  --location swedencentral `
  --template-file "./infra/main.bicep" `
  --parameters "@./infra/main.parameters.json"
```

## ?? Next Steps

1. ? Infrastructure deployed
2. ?? Build your hosted agent container
3. ?? Push container to ACR
4. ?? Deploy agent using `az cognitiveservices agent create`
5. ?? Test in Azure AI Foundry playground

Refer to the main README.md for detailed agent development instructions.

## ?? Additional Resources

- [Azure AI Foundry Documentation](https://learn.microsoft.com/en-us/azure/ai-foundry/)
- [Hosted Agents Documentation](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/deploy-hosted-agent)
- [Azure Developer CLI](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/)
- [Bicep Documentation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/)
