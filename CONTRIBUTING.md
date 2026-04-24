# ?? Contributing

Thanks for your interest in improving this accelerator! This guide will get you set up to contribute fixes, new features, or new specialist agents.

---

## ?? Reporting bugs

Open an [issue](../../issues/new) with:

1. **Environment** — OS, PowerShell version, Azure CLI version, region used
2. **Reproduction steps** — exact commands you ran
3. **Expected vs actual** — what should have happened, what did happen
4. **Logs** — paste the relevant `[ERR]` / `[WARN]` lines from the script output, or App Insights query results

Bonus points for a minimal `.deploy-state.json` redacted of secrets.

---

## ?? Suggesting features

Open an issue with the `enhancement` label. Easy wins to consider:

- **A new specialist agent** (clone Botany/Toxicity/Summary pattern) — see *Adding a new specialist* below
- **A new orchestration pattern** (sequential, conditional, recursive)
- **CI/CD workflow** (GitHub Actions, Azure DevOps Pipelines)
- **Additional `kind` examples** (`workflow`, `container_app`)
- **Localised agent instructions** (non-English)

---

## ?? Adding a new specialist agent

The 3-specialist pattern is easy to extend. Example: add a **Pricing-Estimator** that says how much the plant typically costs at a nursery.

### 1. Add the system instruction in `deploy-agent.ps1` (STEP 5)

Find the `$BotanyInstructions = @'...'@` block and add a new one:

```powershell
$PricingInstructions = @'
You are PRICING-ESTIMATOR. Given a plant name, estimate the typical
retail price range in USD for a small (4-inch pot) and a large (10-inch pot)
specimen at an average North American garden centre. Note any rare cultivars
that command higher prices.

OUTPUT FORMAT:
  - Small (4"): $X-$Y
  - Large (10"): $X-$Y
  - Notable expensive cultivars: ...

STRICT RULES:
  - Only answer plant pricing questions.
  - All prices in USD as ranges. Note that prices vary by region.
'@
```

### 2. Bootstrap it

Below the existing `Ensure-SubAgent` calls:

```powershell
$PricingId = Ensure-SubAgent -Name 'Pricing-Estimator' -Instructions $PricingInstructions
```

### 3. Wire it into the orchestrator (`src/HostedAgent/PlantAgents.cs`)

Add a constant:

```csharp
public const string PricingAgentName = "Pricing-Estimator";
```

### 4. Call it from the orchestrator (`Program.cs` `GetPlantReport`)

Inside the parallel block:

```csharp
var botanyTask   = plants.AskAsync(PlantAgentClient.BotanyAgentName,    $"Tell me about: {plantName}");
var toxicityTask = plants.AskAsync(PlantAgentClient.ToxicityAgentName,  $"Toxicity of: {plantName}");
var pricingTask  = plants.AskAsync(PlantAgentClient.PricingAgentName,   $"Pricing for: {plantName}");
await Task.WhenAll(botanyTask, toxicityTask, pricingTask);

var combined = $"""
    {botanyTask.Result}

    {toxicityTask.Result}

    {pricingTask.Result}
    """;
```

### 5. Update Summary-Generator instructions

In `deploy-agent.ps1`, add a `**Price range**` section to the `$SummaryInstructions` output format.

### 6. Redeploy

```powershell
.\deploy.ps1            # answer 'n' to cleanup, reuses infra
```

You'll see the new agent appear in the Foundry portal and orchestrator output.

---

## ??? Local development tips

### Run the orchestrator locally without re-deploying

```powershell
cd src\HostedAgent
dotnet user-secrets set "AZURE_OPENAI_ENDPOINT"      "https://<acct>.openai.azure.com/"
dotnet user-secrets set "AZURE_AI_PROJECT_ENDPOINT"  "https://<acct>.services.ai.azure.com/api/projects/<proj>"
dotnet user-secrets set "AZURE_OPENAI_DEPLOYMENT_NAME" "gpt-5-mini"
dotnet run
```

The orchestrator binds to `http://localhost:8088`. Test with:

```powershell
$body = @{ model = 'FoundryHostedAgent'; input = 'Tell me about Aloe Vera.' } | ConvertTo-Json
Invoke-RestMethod -Uri "http://localhost:8088/v1/responses" -Method POST `
    -Headers @{ 'Content-Type' = 'application/json' } -Body $body -TimeoutSec 180
```

> Locally, `AzureCliCredential` is used (so you need `az login` against the right tenant). Inside the container, `DefaultAzureCredential` picks up the managed identity automatically.

### Iterate on Bicep without rebuilding the container

```powershell
.\setup-infra.ps1   # infra-only entry point
```

### Iterate on container code without re-touching infra

```powershell
.\deploy-agent.ps1 -EnvName <env> -ResourceGroup <rg> -AccountName <acct> `
    -ProjectName <proj> -ContainerRegistry <acr> -Force
```

---

## ? PR checklist

Before opening a pull request, please:

- [ ] **Build locally** — `dotnet build` returns 0 errors
- [ ] **Verify scripts run end-to-end** at least once (`.\deploy.ps1` then test in playground)
- [ ] **Update README/docs** for any new params, files, or behaviour
- [ ] **Don't commit secrets** — check `.deploy-state.json`, `.azure/`, and any `*.env` are in `.gitignore`
- [ ] **Match existing style** — PowerShell uses `Write-Step` / `Write-Ok` helpers; C# uses top-level statements + `[Description]` on tools
- [ ] **Keep diffs small** — one feature per PR

---

## ?? Coding conventions

### PowerShell

- Use `Write-Phase` / `Write-Step` / `Write-Ok` / `Write-Skip` / `Write-Warn2` / `Write-Err2` helpers — keep output consistent
- Always set `$global:LASTEXITCODE = 0` after external CLI calls when the result was checked, so subsequent calls aren't confused
- Use `Invoke-Safe { ... }` for probe/check operations that may legitimately fail
- Never use `$ErrorActionPreference = 'Stop'` at the top of a script — it makes external CLI stderr fatal

### C#

- Top-level statements in `Program.cs` (no Main method)
- `[Description]` on every tool function and parameter — the model uses these to decide when to call
- One tool per workflow when possible (avoid sequential tool round-trips)
- Run independent sub-agent calls with `Task.WhenAll` (parallel)
- Log every sub-agent call entry+exit with timing — invaluable when debugging

### Bicep

- One module per Azure resource type under `infra/core/`
- Pass the project endpoint and account name as `output`s — `deploy-agent.ps1` reads them via `azd env get-values`
- Use `existing` for cross-references rather than recreating

---

## ?? Security & responsible AI

- **Never commit credentials** — the `.gitignore` covers the obvious ones, but double-check
- **Sub-agent instructions ship in the deploy script** — keep them factual, avoid PII or proprietary content
- **Model choice matters** — `gpt-5-mini` is fine for this POC; for production move to `gpt-5` or larger and add content filters
- **The orchestrator uses managed identity** — never hard-code keys or tokens

---

## ?? Thanks!

By contributing you agree your changes are licensed under the [MIT License](LICENSE).
