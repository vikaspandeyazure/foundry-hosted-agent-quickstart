# ?? Infrastructure Setup Summary

## ? What Has Been Created

I've created a complete infrastructure-as-code setup for your hosted agent project with the following structure:

### ?? File Structure

```
foundry-hosted-agent-quickstart/
??? infra/
?   ??? main.bicep                          ? Main deployment (4 location restriction)
?   ??? main.parameters.json                 Parameters for azd
?   ??? abbreviations.json                   Resource naming conventions
?   ??? README.md                            Infrastructure documentation
?   ??? core/
?       ??? ai/
?       ?   ??? ai-project.bicep            AI Foundry project
?       ?   ??? connection.bicep            Generic connection module
?       ?   ??? acr-role-assignment.bicep   ACR role assignments
?       ??? host/
?       ?   ??? acr.bicep                   Azure Container Registry
?       ??? monitor/
?       ?   ??? loganalytics.bicep          Log Analytics
?       ?   ??? applicationinsights.bicep   Application Insights
?       ?   ??? applicationinsights-dashboard.bicep
?       ??? search/
?       ?   ??? azure_ai_search.bicep       Azure AI Search
?       ?   ??? bing_grounding.bicep        Bing Search
?       ?   ??? bing_custom_grounding.bicep Custom Bing Search
?       ??? storage/
?           ??? storage.bicep               Azure Storage
??? azure.yaml                               ? Azure Developer CLI config
??? setup-infra.ps1                          ? Quick setup script
??? DEPLOYMENT.md                            ? Detailed deployment guide
??? deploy.ps1                               (existing) Deploy agent script
```

## ?? Key Features

### 1. **Location Restriction** ??
The `main.bicep` file enforces deployment to only 4 regions where hosted agents are supported:
- `australiaeast`
- `canadacentral` 
- `northcentralus`
- `swedencentral` (default)

```bicep
@allowed([
  'australiaeast'
  'canadacentral'
  'northcentralus'
  'swedencentral'
])
param location string
```

### 2. **Complete Infrastructure** ???
All necessary Azure resources for hosted agents:
- ? AI Services Account
- ? AI Foundry Project
- ? Azure Container Registry (for agent images)
- ? Application Insights (monitoring)
- ? Log Analytics Workspace
- ? Capability Host (for hosted agents)
- ? Role assignments (RBAC)

### 3. **Flexible Deployment Options** ??
Three ways to deploy:

#### Option A: Quick Setup Script (Easiest)
```powershell
.\setup-infra.ps1 -Location swedencentral -EnvironmentName myagent
```

#### Option B: Azure Developer CLI
```powershell
azd init
azd env set AZURE_LOCATION swedencentral
azd provision
```

#### Option C: Azure CLI Direct
```powershell
az deployment sub create \
  --location swedencentral \
  --template-file ./infra/main.bicep \
  --parameters environmentName=myagent location=swedencentral
```

## ?? Quick Start

### Step 1: Deploy Infrastructure
```powershell
cd foundry-hosted-agent-quickstart
.\setup-infra.ps1
```

### Step 2: Deploy Your Agent
```powershell
.\deploy.ps1
```

### Step 3: Test
Go to [Azure AI Foundry Portal](https://ai.azure.com) and test your agent!

## ?? What Gets Deployed

| Resource Type | Purpose | Required |
|--------------|---------|----------|
| Resource Group | Container for all resources | ? Yes |
| AI Services Account | AI capabilities | ? Yes |
| AI Foundry Project | Project workspace | ? Yes |
| Container Registry | Store agent images | ? Yes (for hosted agents) |
| Capability Host | Enable hosted agents | ? Yes (for hosted agents) |
| Application Insights | Monitoring & telemetry | ?? Optional (default: yes) |
| Log Analytics | Log storage | ?? Optional (default: yes) |

## ?? Security & RBAC

Automatic role assignments:
- **Your user**: AI Developer + Cognitive Services User + Storage Blob Data Contributor
- **AI Project identity**: Cognitive Services User + ACR Pull + Storage access
- **Search (if used)**: Storage Blob Data Reader + OpenAI User

## ?? Configuration

Key parameters in `main.bicep`:

```bicep
param enableHostedAgents bool       // Default: true
param enableMonitoring bool         // Default: true  
param enableCapabilityHost bool     // Default: true
param hostedAgentServiceName string // Default: "HostedAgent"
```

## ?? Update Infrastructure

To modify and redeploy:

```powershell
# Edit bicep files in infra/
# Then redeploy:
azd provision
# or
.\setup-infra.ps1
```

## ?? Cleanup

Remove all resources:

```powershell
# Using azd
azd down

# Or delete resource group
az group delete --name rg-{environmentName}
```

## ? Troubleshooting

### Error: Location not allowed
**Cause**: Trying to deploy to unsupported region  
**Fix**: Use one of: `australiaeast`, `canadacentral`, `northcentralus`, `swedencentral`

### Error: Authorization failed
**Cause**: Missing permissions  
**Fix**: Need Contributor + User Access Administrator roles

### Error: ACR not found
**Cause**: ACR connection not created  
**Fix**: Ensure `enableHostedAgents=true` in parameters

## ?? Documentation Files

- **`infra/README.md`**: Infrastructure details
- **`DEPLOYMENT.md`**: Step-by-step deployment guide
- **`setup-infra.ps1`**: Automated setup script
- **`azure.yaml`**: Azure Developer CLI configuration

## ?? Next Steps

1. ? Infrastructure is ready
2. ?? Review `DEPLOYMENT.md` for detailed instructions
3. ??? Build your agent (`dotnet build`)
4. ?? Deploy your agent (`.\deploy.ps1`)
5. ?? Test in AI Foundry portal

## ?? Tips

- **Region Selection**: `swedencentral` is recommended for best availability
- **Naming**: Use short environment names (max 64 chars)
- **Monitoring**: Enable Application Insights for production deployments
- **Cost**: Basic tier is used by default for cost efficiency

## ?? Helpful Links

- [Azure AI Foundry Docs](https://learn.microsoft.com/en-us/azure/ai-foundry/)
- [Hosted Agents Guide](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/deploy-hosted-agent)
- [Azure Developer CLI](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/)
- [Bicep Documentation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/)

---

## ?? Summary

You now have a complete, production-ready infrastructure setup that:
- ? Enforces the 4 allowed hosted agent regions
- ? Provisions all necessary Azure resources
- ? Configures security and RBAC automatically
- ? Supports multiple deployment methods
- ? Includes monitoring and logging
- ? Follows Azure best practices

**Ready to deploy? Run `.\setup-infra.ps1` to get started!**
