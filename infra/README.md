# Hosted Agent Infrastructure Setup

This folder contains Azure Bicep infrastructure-as-code files for deploying Azure AI Foundry resources with hosted agents support.

## ?? Folder Structure

```
infra/
??? main.bicep                      # Main deployment template (restricted to 4 hosted agent locations)
??? main.parameters.json            # Parameter file for azd deployment
??? abbreviations.json              # Resource naming abbreviations
??? core/
    ??? ai/
    ?   ??? ai-project.bicep        # AI Foundry project and AI Services account
    ?   ??? connection.bicep        # Generic connection module
    ?   ??? acr-role-assignment.bicep # ACR role assignments
    ??? host/
    ?   ??? acr.bicep               # Azure Container Registry
    ??? monitor/
    ?   ??? loganalytics.bicep      # Log Analytics workspace
    ?   ??? applicationinsights.bicep # Application Insights
    ?   ??? applicationinsights-dashboard.bicep # App Insights dashboard
    ??? search/
    ?   ??? azure_ai_search.bicep   # Azure AI Search
    ?   ??? bing_grounding.bicep    # Bing Search grounding
    ?   ??? bing_custom_grounding.bicep # Bing Custom Search grounding
    ??? storage/
        ??? storage.bicep           # Azure Storage Account
```

## ?? Location Restrictions

**IMPORTANT:** The main.bicep file restricts deployments to only the 4 regions where Azure AI Foundry hosted agents are supported:

- `australiaeast`
- `canadacentral`
- `northcentralus`
- `swedencentral`

This is enforced through the `@allowed` decorator on the `location` parameter in main.bicep.

## ?? Deployment Options

### Option 1: Using Azure Developer CLI (azd)

If you have an `azure.yaml` file configured:

```powershell
# Initialize azd environment (first time only)
azd init

# Set the location to one of the 4 allowed regions
azd env set AZURE_LOCATION swedencentral

# Deploy infrastructure
azd provision

# Deploy code
azd deploy
```

### Option 2: Using Azure CLI Directly

```powershell
# Set variables
$location = "swedencentral"  # Must be one of: australiaeast, canadacentral, northcentralus, swedencentral
$environmentName = "hostedagent"
$subscriptionId = "<your-subscription-id>"

# Login to Azure
az login
az account set --subscription $subscriptionId

# Get your user principal ID
$principalId = az ad signed-in-user show --query id -o tsv

# Create deployment
az deployment sub create `
  --name "hosted-agent-deployment" `
  --location $location `
  --template-file "./infra/main.bicep" `
  --parameters `
    environmentName=$environmentName `
    location=$location `
    principalId=$principalId `
    principalType="User" `
    enableHostedAgents=true `
    enableMonitoring=true `
    enableCapabilityHost=true `
    hostedAgentServiceName="HostedAgent"
```

### Option 3: Using the Existing deploy.ps1 Script

The existing `deploy.ps1` script in the root of the foundry-hosted-agent-quickstart project already handles deployment. You can continue using it as it directly provisions resources using Azure CLI.

## ?? Key Features

1. **Location Enforcement**: Only the 4 hosted agent-supported regions are allowed
2. **Container Registry**: Automatically provisions ACR for hosted agent images
3. **AI Foundry Project**: Creates AI Services account and AI Foundry project
4. **Monitoring**: Optional Application Insights and Log Analytics
5. **Capability Host**: Enables hosted agents with public hosting environment
6. **Role Assignments**: Automatically configures necessary RBAC roles

## ?? Configuration Parameters

Key parameters you can customize in `main.parameters.json` or via command line:

- `environmentName`: Name prefix for all resources
- `location`: Deployment region (restricted to 4 locations)
- `enableHostedAgents`: Enable hosted agent deployment (default: true)
- `enableMonitoring`: Enable Application Insights monitoring (default: true)
- `enableCapabilityHost`: Enable capability host for agents (default: true)
- `hostedAgentServiceName`: Service name for azd integration (default: "HostedAgent")

## ?? Outputs

After deployment, the following outputs are available:

- `AZURE_RESOURCE_GROUP`: Resource group name
- `AZURE_AI_ACCOUNT_NAME`: AI Services account name
- `AZURE_AI_PROJECT_NAME`: AI Foundry project name
- `AZURE_AI_PROJECT_ENDPOINT`: AI Foundry project endpoint
- `AZURE_OPENAI_ENDPOINT`: OpenAI endpoint
- `AZURE_CONTAINER_REGISTRY_ENDPOINT`: ACR login server
- `APPLICATIONINSIGHTS_CONNECTION_STRING`: App Insights connection string

## ?? Next Steps

After provisioning infrastructure:

1. Build your hosted agent container
2. Push to the created Azure Container Registry
3. Deploy using `az cognitiveservices agent create` command
4. Test in Azure AI Foundry portal

## ?? References

- [Azure AI Foundry Hosted Agents Documentation](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/deploy-hosted-agent)
- [Hosted Agent Region Availability](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/deploy-hosted-agent#region-availability)
