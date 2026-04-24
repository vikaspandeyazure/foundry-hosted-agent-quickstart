# ?? Deployment Guide — Foundry Multi-Agent Plant Advisor

This guide walks you through deploying the accelerator from a clean machine to a fully working multi-agent system in the Foundry portal.

> ?? **Preview notice:** Foundry Hosted Agents are in **Preview**. APIs and behavior may change.

---

## ?? Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Sign in to Azure (`az login` + `azd auth login`)](#2-sign-in-to-azure)
3. [Pick a subscription & resource group](#3-pick-a-subscription--resource-group)
4. [Run `deploy.ps1`](#4-run-deployps1)
5. [What happens during the deploy](#5-what-happens-during-the-deploy)
6. [Test in the Foundry playground](#6-test-in-the-foundry-playground)
7. [Re-deploy after code changes](#7-re-deploy-after-code-changes)
8. [Cleanup](#8-cleanup)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Prerequisites

| Tool | Min version | Verify |
|------|-------------|--------|
| Azure CLI | **2.85+** | `az --version` |
| Azure Developer CLI (`azd`) | **1.24+** | `azd version` |
| Docker Desktop *(must be running)* | **27+** | `docker version --format '{{.Server.Version}}'` |
| .NET SDK | **10.0+** (preview OK) | `dotnet --version` |
| PowerShell 7 | **7.4+** | `$PSVersionTable.PSVersion` |

### Azure permissions

You need **one** of:
- **Owner** on the subscription, OR
- **Contributor + User Access Administrator** on the subscription / resource group

(The script creates RBAC role assignments for the agent's managed identity.)

### Region constraint

Hosted Agents are **only** available in:
- `swedencentral` *(recommended)*
- `canadacentral`
- `northcentralus`
- `australiaeast`

The script blocks anything else with a friendly error.

---

## 2. Sign in to Azure

You need **two** sign-ins — `az` (for ARM operations + REST) and `azd` (for the bicep deployment).

### 2.1 Azure CLI

```powershell
az login
```

A browser opens — sign in. Then verify you're on the right tenant:

```powershell
az account show --query "{Subscription:name, SubscriptionId:id, Tenant:tenantId, User:user.name}" -o table
```

If you have multiple subscriptions, list them and switch:

```powershell
az account list --query "[].{Name:name, Id:id, IsDefault:isDefault}" -o table
az account set --subscription "<your-sub-name-or-id>"
```

### 2.2 Azure Developer CLI

```powershell
azd auth login
```

Same browser flow. The script auto-detects if `azd` is logged out and prompts you to sign in mid-deploy if needed — but doing it up front saves time.

> ?? The `deploy.ps1` script will **detect missing logins and prompt you interactively** — you don't have to do these manually if you forget. They're listed here for reference.

---

## 3. Pick a subscription & resource group

The script asks for these interactively. Decide ahead of time:

| Parameter | What it is | Suggested value |
|-----------|------------|-----------------|
| **Subscription** | Where Azure resources go | Auto-picked from `az login`; you can switch in the script |
| **Location** | Region for everything | `swedencentral` |
| **Environment label** | Short tag (NOT a resource group). Stamped on all resources as `azd-env-name=<label>`. Used as default suffix for resource names. | e.g. `demo01`, `vikas-dev`, `prod-eu` |
| **Resource group name** | Azure container for resources. Created if missing, reused if exists. | Defaults to `rg-<env-label>` |
| **Agent name** | Hosted agent identifier in Foundry | `foundry-hosted-agent` (default) |
| **Model** | Azure OpenAI deployment | `gpt-5-mini`, version `2025-08-07`, capacity `10` |

### About "Environment label" vs "Resource group" ??

| | Environment label | Resource group |
|---|-------------------|----------------|
| What it is | A logical **tag** (`azd-env-name`) | An Azure **container** for resources |
| Where it lives | Tags on resources + `.azure/<label>/.env` locally | Azure subscription |
| Example | `demo01` | `rg-demo01` |
| Constraints | Lowercase alphanumeric + hyphens, ?30 chars | Standard Azure RG naming |

Think: **environment label = sticker, resource group = box**. The script defaults the RG to `rg-<env-label>` so you don't have to think about it.

---

## 4. Run `deploy.ps1`

```powershell
git clone https://github.com/<your-username>/foundry-hosted-agent-quickstart
cd foundry-hosted-agent-quickstart
.\deploy.ps1
```

### What you'll be asked

```
PHASE 1 - Azure login
    [OK] Subscription : <your sub>
    Continue with this subscription? [Y/n]: y

PHASE 2 - Cleanup previous deployment (optional)
    [SKIP] No previous deployment state found in this folder

PHASE 3 - Deployment parameters
  Choose location [swedencentral]:                        ? Enter
  Environment label (short, lowercase, e.g. demo01): demo01
  Resource group name [rg-demo01]:                        ? Enter

  Summary:
    Subscription      : <your sub>
    Location          : swedencentral
    Environment label : demo01
    Resource group    : rg-demo01
    Agent name        : foundry-hosted-agent
    Model             : gpt-5-mini

  Proceed with deployment? [Y/n]: y
```

That's it for input. The next ~10 minutes run automatically.

### If you're re-running

If `.azure/` exists from a previous deploy, you'll see:

```
PHASE 2 - Cleanup previous deployment (optional)
  [INFO] Found previous deployment state in this folder.
  Clean up previous deployment first? [y/N]:
```

- Answer **`n`** to **reuse the existing infra** (faster — auto-loads location, env label, RG from azd state)
- Answer **`y`** to **delete the resource group + purge soft-deleted accounts** and start fresh

---

## 5. What happens during the deploy

### Outer phases (`deploy.ps1`)

| Phase | What | Time |
|-------|------|------|
| 0 | Prereq check (az, azd, docker, dotnet) | <5s |
| 1 | Verify `az` + `azd` login (prompts if missing) | <5s |
| 2 | Optional cleanup of previous deployment | varies |
| 3 | Collect deployment parameters | interactive |
| 4 | **`azd provision`** — runs Bicep to create RG, AI Foundry account + project, ACR, App Insights, Log Analytics, RBAC | **~3 min** |
| 5 | Read provisioned values from azd env | <5s |
| 6 | **Hand off to `deploy-agent.ps1`** (10 inner AGENT STEPs) | **~5-7 min** |
| 7 | Final summary + portal URL | <1s |

### Inner agent steps (`deploy-agent.ps1` invoked by Phase 6)

| Step | What | Time |
|------|------|------|
| 0 | Prereq check | <1s |
| 1 | Read `az` context (no fresh login) | <1s |
| 2 | Verify RG, AI account, ACR exist (fail-fast) | ~3s |
| 3 | Deploy `gpt-5-mini` model on the AI account (skip if exists) | ~30s or skip |
| 4 | Provision **Capability Host** (Agent Service runtime) | ~3 min on first run, skip on re-runs |
| **5** | **Bootstrap 3 `kind=prompt` sub-agents** (Botany / Toxicity / Summary) via REST. **Visible in Foundry portal HERE.** | **~10s** |
| 6 | `docker build` orchestrator ? `docker push` to ACR | ~3-5 min |
| 7 | Register hosted agent version (POST `/agents/{name}/versions`) | ~10s |
| 8 | Grant `Cognitive Services OpenAI User` + `Azure AI Developer` to agent's MI | ~5s |
| 9 | Smoke test — POST a Pothos query | ~60-90s |
| 10 | Save `.deploy-state.json` for cleanup | <1s |

### Look for these "OK" lines to confirm STEP 5 worked

```
AGENT STEP 5 - Bootstrap Foundry sub-agents (Botany / Toxicity / Summary)
  > Listing existing agents on project...
    [OK]   Found 0 existing agent(s)
  > Creating sub-agent: Botany-Expert (kind=prompt)
    [OK]   Botany-Expert version 1 ready
  > Creating sub-agent: Toxicity-Detector (kind=prompt)
    [OK]   Toxicity-Detector version 1 ready
  > Creating sub-agent: Summary-Generator (kind=prompt)
    [OK]   Summary-Generator version 1 ready
```

---

## 6. Test in the Foundry playground

After Phase 7 prints `All done!`, open the Foundry portal:

```
https://ai.azure.com/build/agents
```

? Pick your project ? you'll see **4 agents**:

```
??  foundry-hosted-agent   (hosted)   ? your orchestrator
??  Botany-Expert          (prompt)
?   Toxicity-Detector      (prompt)
??  Summary-Generator      (prompt)
```

> If you only see 1 agent, **hard-refresh** with **Ctrl+F5** — Foundry caches the agents list.

### 6.1 Open the orchestrator playground

Click `foundry-hosted-agent` ? **Playground** tab.

### 6.2 Try these prompts

```
Tell me about Pothos plant
Is Aloe Vera safe for cats?
I have a toddler — should I get a Philodendron?
Compare Snake Plant and Pothos for low-light apartments.
Tell me about Lily of the Valley.
```

Each query takes ~60-90 seconds (3 sub-agent calls + summarisation). The first one is slowest due to container cold-start.

Off-topic prompts get politely refused:

```
What's the weather today?       ? "I'm a plant advisor — ..."
Write me a sorting algorithm.   ? refused
```

### 6.3 Playground UI quirk

If you see this banner **after** the response renders:

> *Service did not return a valid conversation id when using an AgentSession with service managed chat history.*

That's a **UI session issue**, not an agent failure. Your response was already delivered. To silence it:

1. Open the playground **settings panel** (top-right gear icon)
2. Find **Chat history** / **Session mode**
3. Switch to **Client managed**

### 6.4 Test from REST (for CI/automation)

```powershell
$tok  = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
$body = @{ model = 'FoundryHostedAgent'; input = 'Tell me about Aloe Vera.' } | ConvertTo-Json
$ep   = "https://<your-account>.services.ai.azure.com/api/projects/<your-project>/agents/foundry-hosted-agent/endpoint/protocols/openai/responses?api-version=2025-11-15-preview"
$r    = Invoke-RestMethod -Uri $ep -Method POST `
            -Headers @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' } `
            -Body $body -TimeoutSec 180
($r.output | Where-Object type -eq 'message' | Select-Object -Last 1).content[0].text
```

Replace `<your-account>` and `<your-project>` with the names from `azd env get-values`.

---

## 7. Re-deploy after code changes

You **don't** need to re-provision infra for code changes. Use `deploy-agent.ps1` directly:

```powershell
.\deploy-agent.ps1 `
    -EnvName demo01 `
    -Location swedencentral `
    -ResourceGroup rg-demo01 `
    -AccountName <your-ai-account> `
    -ProjectName <your-ai-project> `
    -ContainerRegistry <your-acr> `
    -Force
```

(Get the actual names from `azd env get-values`.)

This re-runs steps 0-10 but skips infra-creation steps.

---

## 8. Cleanup

When you're done with the demo:

```powershell
azd down --force --purge
```

This:
- Deletes the resource group
- **Purges** the soft-deleted Cognitive Services account (so you can reuse the name immediately)
- Removes local `.azure/` state

Or manually:

```powershell
az group delete --name <your-rg> --yes --no-wait
az cognitiveservices account purge --location <region> --resource-group <rg> --name <ai-account>
```

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Script errors *"az not found"* | Azure CLI not installed | `winget install Microsoft.AzureCLI` |
| `az login` fails | Wrong tenant | `az login --tenant <your-tenant-id>` |
| `azd provision` fails: *"location not supported"* | Region isn't one of the 4 hosted-agent regions | Re-run, choose `swedencentral` |
| AGENT STEP 5 fails with HTTP 401/403 | RBAC propagation delay | Wait 60s, re-run (script is idempotent) |
| AGENT STEP 6 fails: *"docker build failed"* | Stale `bin/obj` or Docker Desktop not running | Script auto-cleans `bin/obj`; ensure Docker Desktop is running |
| AGENT STEP 9 returns `[WARN]` | Container cold start | Normal — wait 60s, test in playground |
| Playground returns *"Network error"* | Cold-start timeout on first call | Wait 90s, retry — subsequent calls are fast |
| Playground: *"Service did not return a valid conversation id..."* | UI session quirk | Switch *Chat history* to **Client managed** in settings |
| Sub-agents not visible in portal | Browser cache | **Ctrl+F5** to hard-refresh |
| `dotnet build` fails: *"package not found"* | NuGet restore issue | `dotnet restore --force-evaluate` then retry |

### See live container logs (Application Insights KQL)

Open the Azure Portal ? your App Insights ? **Logs** tab ? run:

```kql
union traces, exceptions
| where timestamp > ago(15m)
| where message contains "orchestrator"
    or message contains "Sub-agent"
    or message contains "startup-test"
    or message contains "GetPlantReport"
| project timestamp, severityLevel, message
| order by timestamp desc
```

You'll see exactly where requests fail — token acquisition, sub-agent call, model response, etc.

---

## ?? You're done!

If you got a markdown summary in the playground, congratulations — you've deployed a working multi-agent system on Microsoft Foundry. ??

To extend it for your domain or contribute new specialist agents, see **[CONTRIBUTING.md](CONTRIBUTING.md)**.
