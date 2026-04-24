# ?? Quick Reference - Hosted Agent Deployment

## ?? Important: Region Restrictions

Hosted agents **ONLY** work in these 4 regions:
```
? swedencentral     (Recommended)
? canadacentral
? northcentralus
? australiaeast
```

Any other region will **fail** with location validation error.

---

## ?? Three Ways to Deploy

### Method 1: Quick Setup Script (Fastest) ?
```powershell
cd foundry-hosted-agent-quickstart
.\setup-infra.ps1
```

### Method 2: Azure Developer CLI ??
```powershell
azd init
azd env set AZURE_LOCATION swedencentral
azd provision
azd deploy
```

### Method 3: Azure CLI Manual ???
```powershell
az deployment sub create `
  --location swedencentral `
  --template-file ./infra/main.bicep `
  --parameters environmentName=myagent location=swedencentral
```

---

## ?? What Gets Created

```
Resource Group: rg-{environmentName}
??? AI Services Account
??? AI Foundry Project
??? Container Registry (ACR)
??? Application Insights
??? Log Analytics Workspace
??? Capability Host (Agents)
```

---

## ?? Key Files

| File | Purpose |
|------|---------|
| `setup-infra.ps1` | Quick deployment script |
| `infra/main.bicep` | Main infrastructure template |
| `azure.yaml` | Azure Developer CLI config |
| `deploy.ps1` | Deploy agent after infra |
| `DEPLOYMENT.md` | Detailed deployment guide |

---

## ? Quick Commands

### Deploy Infrastructure
```powershell
.\setup-infra.ps1 -Location swedencentral -EnvironmentName myagent
```

### Check Status
```powershell
azd env get-values
# or
az resource list --resource-group rg-myagent
```

### Deploy Agent
```powershell
.\deploy.ps1
```

### View Logs
```powershell
az cognitiveservices agent show `
  --account-name {account-name} `
  --project-name {project-name} `
  --name {agent-name}
```

### Cleanup
```powershell
azd down
# or
az group delete --name rg-myagent
```

---

## ?? Verify Deployment

1. **Check Azure Portal**: https://portal.azure.com
2. **Check AI Foundry**: https://ai.azure.com
3. **List Resources**:
   ```powershell
   az resource list --resource-group rg-{env} --output table
   ```

---

## ?? Common Issues

| Error | Solution |
|-------|----------|
| Location not allowed | Use one of 4 supported regions |
| Authorization failed | Need Contributor + User Access Admin roles |
| ACR not found | Ensure `enableHostedAgents=true` |
| Deployment timeout | Check Azure Portal for specific errors |

---

## ?? Learning Path

1. ? Deploy infrastructure (`setup-infra.ps1`)
2. ? Review resources in Azure Portal
3. ? Build your agent code
4. ? Deploy agent (`deploy.ps1`)
5. ? Test in AI Foundry playground

---

## ?? Cost Estimate (Monthly)

| Resource | Tier | Est. Cost |
|----------|------|-----------|
| AI Services | S0 | ~$1-5 |
| Container Registry | Basic | ~$5 |
| Application Insights | Basic | ~$0-5 |
| Hosted Agent Runtime | Standard | ~$10-50* |

*Varies by usage

---

## ?? Quick Links

- **Documentation**: See `DEPLOYMENT.md`
- **Infrastructure Details**: See `infra/README.md`
- **Azure Portal**: https://portal.azure.com
- **AI Foundry**: https://ai.azure.com
- **Docs**: https://learn.microsoft.com/azure/ai-foundry/

---

## ?? Pro Tips

? Use `swedencentral` for best availability  
? Enable monitoring for production  
? Keep environment names short  
? Use `azd` for easier management  
? Review `azd env get-values` for all settings

---

**Ready to start?** 
```powershell
.\setup-infra.ps1
```
