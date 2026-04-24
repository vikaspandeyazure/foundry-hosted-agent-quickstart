# ?? Build a Multi-Agent Plant Advisor on Microsoft Foundry with .NET 10

> A hands-on accelerator that takes you from zero to a working multi-agent system on **Azure AI Foundry Hosted Agents** in under 30 minutes — with code, scripts, and a cute Pothos plant as the hero of the demo.

---

## ?? What you'll build

A **Plant Advisor** that answers any plant question by orchestrating three specialist agents in Foundry:

1. ?? **Botany-Expert** — knows every indoor & outdoor plant in the world
2. ? **Toxicity-Detector** — flags toxic compounds and risks to humans & pets
3. ?? **Summary-Generator** — turns the raw findings into a friendly bulleted summary

A fourth agent — the **Plant-Advisor Orchestrator** — runs as a **Hosted Agent** (a .NET container running inside Foundry's compute) and delegates to the three specialists in parallel.

User asks *"Tell me about Pothos plant"* ? in ~60 seconds they get a beautifully formatted markdown brief with quick facts, care tips, and a safety verdict for cats and toddlers.

---

## ??? Architecture

```
???????????????????????????????????????????????????????????????????????????
?                              ??  USER                                   ?
?            "Tell me about Pothos plant"  /  "Is Aloe safe for cats?"    ?
???????????????????????????????????????????????????????????????????????????
                                   ? HTTPS
                                   ?
???????????????????????????????????????????????????????????????????????????
?  ??  AZURE AI FOUNDRY  (https://ai.azure.com)                           ?
?                                                                         ?
?  ????????????????????????????????????????????????????????????????????   ?
?  ?  ??  Plant-Advisor Orchestrator   (kind=hosted, .NET container)  ?   ?
?  ?       • Receives request via Foundry Responses API on :8088      ?   ?
?  ?       • Calls Botany ? Toxicity in PARALLEL                      ?   ?
?  ?       • Pipes both into Summary-Generator                        ?   ?
?  ?       • Returns the markdown summary to the user                 ?   ?
?  ????????????????????????????????????????????????????????????????????   ?
?       ?               ?                        ?                        ?
?       ? REST          ? REST  (parallel)       ? REST                   ?
?  ????????????   ??????????????????????   ??????????????????????         ?
?  ? ?? Botany?   ? ?  Toxicity        ?   ? ?? Summary         ?         ?
?  ?  Expert  ?   ?   Detector         ?   ?   Generator        ?         ?
?  ? (prompt) ?   ?  (prompt)          ?   ?  (prompt)          ?         ?
?  ?          ?   ?                    ?   ?                    ?         ?
?  ?   gpt-5-mini deployment shared by all 3 specialists                  ?
?  ????????????   ??????????????????????   ??????????????????????         ?
?                                                                         ?
?  Telemetry ? Application Insights ? Foundry "Tracing" tab               ?
???????????????????????????????????????????????????????????????????????????
                                   ?
                                   ?
???????????????????????????????????????????????????????????????????????????
?  ??  AZURE CONTAINER REGISTRY                                           ?
?      Stores the Docker image of the orchestrator (built locally)        ?
???????????????????????????????????????????????????????????????????????????
```

**Why this design?**

- **One tool call from the model** — the orchestrator only calls one tool (`GetPlantReport`); the parallel sub-agent calls happen inside that tool in pure C#. This avoids the classic *"model re-transcribes every tool output as parameters to the next tool"* problem that wastes tokens and timeouts.
- **Three Foundry Agent Service "prompt" agents** — visible in the new Foundry portal, can be reused by other apps, easy to update instructions without redeploying the container.
- **One Hosted Agent** — runs your custom .NET orchestration code inside Foundry's managed compute; has its own managed identity, telemetry, and rolling-version deployment.

---

## ?? Prerequisites

| What | Why | Min version |
|------|-----|-------------|
| **Azure subscription** | All the things | any |
| **Azure CLI** (`az`) | Provisioning + role assignments | **2.85+** |
| **Azure Developer CLI** (`azd`) | Bicep orchestration | **1.24+** |
| **Docker Desktop** | Build the orchestrator image | **27+** (BuildKit-enabled) |
| **.NET SDK** | The orchestrator is a .NET 10 console app | **10.0+** (preview OK) |
| **PowerShell 7** | The deploy scripts | **7.4+** |
| **A modern browser** | Foundry portal & playground | Edge/Chrome/Safari |

### Verify everything in 1 command

```powershell
az --version    | Select-String "azure-cli "
azd version
docker --version
dotnet --version
$PSVersionTable.PSVersion
```

### ?? Azure region limitation (read this!)

**Foundry Hosted Agents are only available in 4 regions** as of writing:

| ? Supported regions |
|----------------------|
| `swedencentral` *(recommended)* |
| `canadacentral` |
| `northcentralus` |
| `australiaeast` |

If you pick anything else, the bicep deployment will succeed but the hosted-agent registration will fail with `Location not supported`. The deployment scripts hard-validate this.

### ?? Azure permissions you need

You must have **Owner** or **Contributor + User Access Administrator** on the subscription (or at least the resource group), because the scripts create RBAC role assignments for:
- The hosted agent's managed identity ? `Cognitive Services OpenAI User` + `Azure AI Developer`
- The container registry ? `AcrPull` for the agent

---

## ?? Step-by-step deployment

The accelerator ships with **two scripts**, both interactive and idempotent:

| Script | Purpose | When to run |
|--------|---------|-------------|
| `deploy.ps1` | The orchestrator — handles login, cleanup prompt, infra, and agent deploy in one flow | **Use this.** First-time setup AND re-runs |
| `deploy-agent.ps1` | Just the agent steps (build container, register hosted agent, create sub-agents) | Re-deploy only the code without re-touching infra |

### Step 1 — Clone the accelerator

```powershell
git clone https://github.com/<your-fork>/foundry-hosted-agent-quickstart
cd foundry-hosted-agent-quickstart
```

### Step 2 — Run the orchestrator script

```powershell
.\deploy.ps1
```

You'll be prompted for **only what's necessary**:

```
PHASE 1 - Azure login
    [OK] Subscription : <your sub>
    Continue with this subscription? [Y/n]: y

PHASE 2 - Cleanup previous deployment (optional)
    [SKIP] No previous deployment state found in this folder

PHASE 3 - Deployment parameters
  Hosted agents are only supported in these 4 regions:
    1) swedencentral   (recommended)
    2) canadacentral
    3) northcentralus
    4) australiaeast
  Choose location [swedencentral]:                 ? Enter

  About 'Environment name':
    A short LABEL for this deployment instance (NOT the resource group).
  Environment label (short, lowercase, e.g. demo01): demo01

  About 'Resource group':
    The Azure container that holds all resources for this deployment.
  Resource group name [rg-demo01]:                 ? Enter

  Summary:
    Subscription      : <your sub>
    Location          : swedencentral
    Environment label : demo01
    Resource group    : rg-demo01
    Agent name        : foundry-hosted-agent
    Model             : gpt-5-mini

  Proceed with deployment? [Y/n]: y
```

### Step 3 — What happens next (~10 minutes total)

| Outer phase | What's provisioned | Time |
|------------|--------------------|------|
| 4 — Provision infrastructure (azd + bicep) | Resource group, AI Foundry account + project, Container Registry, Application Insights, Log Analytics, RBAC | ~3 min |
| 5 — Read provisioned values | — | <5s |
| 6 — Hand off to `deploy-agent.ps1` | (10 inner AGENT STEPs) | ~5-7 min |
| 7 — Final summary + portal link | — | <1s |

### Step 4 — The 10 inner AGENT STEPs

Inside outer Phase 6, you'll see:

```
AGENT STEP 0  - Prerequisite check               (<1s)
AGENT STEP 1  - Azure context                    (<1s)
AGENT STEP 2  - Verify infrastructure exists     (~3s)
AGENT STEP 3  - Model deployment (gpt-5-mini)    (~30s, skip if exists)
AGENT STEP 4  - Capability host                  (~3 min if new, skip if exists)
AGENT STEP 5  - Bootstrap 3 Foundry sub-agents   (~10s) ? visible in portal HERE
AGENT STEP 6  - Container build + push to ACR    (~3-5 min, live output)
AGENT STEP 7  - Register hosted agent version    (~10s)
AGENT STEP 8  - Role assignments                 (~5s)
AGENT STEP 9  - Smoke test (asks about Pothos)   (~60-90s)
AGENT STEP 10 - Done summary                     (<1s)
```

**Look for these "OK" lines** to know Step 5 worked:

```
[OK] Botany-Expert       version 1 ready (id: foundry-hosted-agent_Botany-Expert)
[OK] Toxicity-Detector   version 1 ready (id: foundry-hosted-agent_Toxicity-Detector)
[OK] Summary-Generator   version 1 ready (id: foundry-hosted-agent_Summary-Generator)
```

---

## ?? Testing in Foundry Playground

After deployment, open the Foundry portal:

```
https://ai.azure.com/build/agents
```

? Pick your project ? you'll see **4 agents**:

```
??  foundry-hosted-agent  (hosted)   ? your orchestrator
??  Botany-Expert         (prompt)
?   Toxicity-Detector     (prompt)
??  Summary-Generator     (prompt)
```

Click `foundry-hosted-agent` ? **Playground** ? ask:

```
Tell me about Pothos plant
```

> ?? **Heads-up about a playground quirk:** the new Foundry playground may show the response and then a banner *"Service did not return a valid conversation id when using an AgentSession with service managed chat history."* — that's a **UI session issue**, not an agent failure. Switch *Chat history* to **Client managed** in the playground settings panel. Your response was already delivered.

### Sample output for "Tell me about Pothos plant"

```markdown
## Pothos (Epipremnum aureum)

**Quick facts**
• Family Araceae; native to the South Pacific (Solomon Islands); understory climber/epiphyte
• Excellent indoor houseplant; outdoors only in frost-free tropical/subtropical regions
• Vigorous climber with many popular variegated cultivars

**Care essentials**
• Light: Bright indirect light ideal; tolerates low light
• Water: Let the top 2–5 cm dry between waterings
• Soil: Fast-draining, well-aerated mix with perlite + orchid bark

**Safety**
• Toxicity: MODERATELY TOXIC
• Risk to pets: Chewing causes oral irritation, drooling, vomiting in cats and dogs
• Risk to humans: Ingestion causes immediate oral pain/swelling; sap irritates skin

**Bottom line**
Great, easy houseplant for most homes — but keep out of reach of pets and children.
```

### More demo prompts to wow your audience

```
Is Aloe Vera safe for cats?
Tell me about Lily of the Valley.
I have a toddler — should I get a Philodendron?
Compare Snake Plant and Pothos for low-light apartments.
```

Off-topic prompts get politely refused (the orchestrator is strictly scoped to plants):

```
What's the weather today?       ? "I'm a plant advisor — I can only help with questions about plants."
Write me a sorting algorithm.   ? refused
```

### Verify via REST (for CI/automation)

```powershell
$tok = az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv
$body = @{ model = 'FoundryHostedAgent'; input = 'Tell me about Aloe Vera.' } | ConvertTo-Json
$ep = "https://<your-account>.services.ai.azure.com/api/projects/<your-project>/agents/foundry-hosted-agent/endpoint/protocols/openai/responses?api-version=2025-11-15-preview"
$r = Invoke-RestMethod -Uri $ep -Method POST `
    -Headers @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' } `
    -Body $body -TimeoutSec 180
($r.output | Where-Object type -eq 'message' | Select-Object -Last 1).content[0].text
```

---

## ?? What's happening under the hood

### The new `/agents` API (vs. legacy `/assistants`)

Foundry's **new agents API** uses these endpoints (different from the legacy OpenAI Assistants API):

| Operation | URL |
|-----------|-----|
| Create/version a sub-agent | `POST {endpoint}/agents/{name}/versions?api-version=v1` |
| Call a sub-agent | `POST {endpoint}/agents/{name}/endpoint/protocols/openai/responses?api-version=2025-11-15-preview` |
| List all agents | `GET {endpoint}/agents?api-version=v1` |

The valid `definition.kind` values are:

- **`prompt`** — model + instructions only (our 3 specialists)
- **`hosted`** — your container (our orchestrator)
- **`container_app`** — Azure Container Apps integration
- **`workflow`** — workflow-based

### The orchestrator's secret sauce

Inside the .NET container (`Program.cs`), one tool does all the work:

```csharp
[Description("Generate a complete plant report. Call this for ANY plant question.")]
async Task<string> GetPlantReport(string plantName)
{
    // 1. Botany + Toxicity in PARALLEL (cuts wall-clock time in half)
    var botanyTask   = plants.AskAsync("Botany-Expert",     $"Tell me about: {plantName}");
    var toxicityTask = plants.AskAsync("Toxicity-Detector", $"Toxicity of: {plantName}");
    await Task.WhenAll(botanyTask, toxicityTask);

    // 2. Pipe both into the Summary specialist
    var combined = $"{botanyTask.Result}\n\n{toxicityTask.Result}";
    return await plants.AskAsync("Summary-Generator", combined);
}
```

The `PlantAgentClient` is just a tiny `HttpClient` wrapper around the Responses API — no SDK dependencies needed.

---

## ??? Troubleshooting cheat sheet

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `azd provision` fails with *"location not supported"* | You picked a region that isn't one of the 4 hosted-agent regions | Re-run, pick `swedencentral` |
| AGENT STEP 5 fails with HTTP 401/403 | RBAC propagation delay | Wait 60s, re-run (the script is idempotent) |
| AGENT STEP 6 (docker build) fails | Stale `bin/`/`obj/` from previous build, or locked file | Script auto-cleans before build; close any local `dotnet run` first |
| AGENT STEP 9 (smoke test) shows `[WARN]` | Container cold start in progress | Wait 60s, test in playground |
| Playground returns *"Service did not return a valid conversation id..."* | Foundry playground UI session quirk | Switch *Chat history* to **Client managed** in settings |
| Orchestrator returns 408 timeout | Sub-agent calls timed out | Check Application Insights logs for the `[startup-test]` entry |
| Sub-agents not visible in portal | You're looking at the legacy `/assistants` view | Refresh portal (Ctrl+F5); they live under `/agents` now |

### See live container logs (Application Insights)

```kql
union traces, exceptions
| where timestamp > ago(15m)
| where message contains "orchestrator" or message contains "Sub-agent" or message contains "startup-test"
| project timestamp, severityLevel, message
| order by timestamp desc
```

---

## ?? Cleanup

When you're done, blow it all away with one command:

```powershell
azd down --force --purge
```

This deletes the resource group, purges the soft-deleted Cognitive Services account (so you can reuse the name), and removes the local azd state. Total cost of the demo, end-to-end: **a few cents** if you tear down within an hour.

---

## ?? What's in the repo

```
foundry-hosted-agent-quickstart/
??? deploy.ps1              ? THE main entry point (interactive orchestrator)
??? deploy-agent.ps1        ? Just the agent steps (called by deploy.ps1)
??? setup-infra.ps1         ? Just the infra (alternative entry point)
??? azure.yaml              ? azd configuration
??? infra/                  ? Bicep modules (RG, Foundry, ACR, AppInsights, ...)
??? src/HostedAgent/
    ??? Program.cs          ? Orchestrator (this is where the magic is)
    ??? PlantAgents.cs      ? REST client for the 3 sub-agents
    ??? HostedAgent.csproj  ? .NET 10 project
    ??? Dockerfile          ? Multi-stage Alpine build
    ??? .dockerignore       ? Keeps the build context lean
```

---

## ?? Key takeaways

1. **Foundry's new `/agents` API is different from the legacy `/assistants` API** — make sure you're using the right one or your sub-agents won't show in the new portal.
2. **`kind=prompt` agents are the lightweight workhorses** for multi-agent systems — no container, no compute to manage, just model + instructions.
3. **Hosted agents** are perfect for orchestration logic — your code, your dependencies, Foundry-managed compute and identity.
4. **Run sub-agent calls in parallel inside one tool** — model-driven sequential tool calls are slow and waste tokens re-transcribing intermediate outputs.
5. **The bicep + scripts are fully idempotent** — re-run `deploy.ps1` whenever you change code; it'll skip what's already there.
6. **Region matters** — only 4 regions support hosted agents (today). Stick to `swedencentral` unless you have a hard latency requirement.

---

## ?? Where to go next

Try extending the orchestrator with:

- ?? **Bing grounding tool** for real-time plant pest/disease alerts
- ?? **Vision tool** so users can upload a leaf photo for ID
- ?? **Shopping integration** that links to a nursery for suggested plants
- ?? **RAG over a botanical PDF library** for advanced research
- ?? **A workflow agent** (`kind=workflow`) for multi-step plant care reminders

The accelerator is intentionally small — fork it, swap *plants* for your domain (legal docs, medical guidelines, financial reports, recipes...), and you've got a production-shaped multi-agent template.

---

## ?? Credits & links

- ?? **Microsoft AI Foundry** — https://ai.azure.com
- ?? **Hosted agents docs** — https://learn.microsoft.com/azure/ai-foundry/agents
- ?? **Original quickstart** — https://github.com/Azure-Samples/foundry-hosted-agents-dotnet-demo
- ?? **Microsoft Agent Framework** — https://github.com/microsoft/agent-framework

If this helped, give the repo a ? and tag me when you ship your version!

---

*Happy plant-advising! ?? Built with .NET 10, Azure AI Foundry hosted agents, gpt-5-mini, and a healthy obsession with not killing my pothos.*
