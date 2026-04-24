// =============================================================================
// Foundry Hosted Agent - Quickstart (Step 1)
// =============================================================================
// A minimal hosted agent for Microsoft Foundry that:
//   1. Reads its configuration from environment variables (or user secrets locally).
//   2. Creates an IChatClient against an Azure OpenAI deployment using managed
//      identity in containers, AzureCliCredential locally.
//   3. Wraps the chat client with OpenTelemetry so prompts/completions appear in
//      the Foundry Tracing tab when APPLICATIONINSIGHTS_CONNECTION_STRING is
//      injected (Foundry auto-injects it for hosted agents).
//   4. Exposes the agent over the Foundry Responses API on port 8088 via the
//      `RunAIAgentAsync` hosting adapter.
//
// No function tools yet - this is the bare-minimum LLM Q&A agent.
// =============================================================================

using Azure.AI.AgentServer.AgentFramework.Extensions;
using Azure.AI.OpenAI;
using Azure.Core;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.Exporter;
using FoundryHostedAgent;
using Microsoft.Agents.AI;
using Microsoft.Extensions.AI;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using OpenTelemetry;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using System.ComponentModel;

// -----------------------------------------------------------------------------
// 1. Configuration
// -----------------------------------------------------------------------------
var config = new ConfigurationBuilder()
    .AddEnvironmentVariables()
    .AddUserSecrets<Program>(optional: true)
    .Build();

string endpoint = config["AZURE_OPENAI_ENDPOINT"]
    ?? throw new InvalidOperationException(
        "AZURE_OPENAI_ENDPOINT is not set. " +
        "Locally: dotnet user-secrets set AZURE_OPENAI_ENDPOINT https://<your-account>.openai.azure.com/");

string deploymentName = config["AZURE_OPENAI_DEPLOYMENT_NAME"] ?? "gpt-5-mini";
string? appInsightsConnectionString = config["APPLICATIONINSIGHTS_CONNECTION_STRING"];

// Foundry project endpoint - used by the persistent-agents SDK to host the 3 sub-agents.
// Format: https://<account>.services.ai.azure.com/api/projects/<project-name>
// Foundry auto-injects this into hosted agents as AZURE_AI_PROJECT_ENDPOINT.
string projectEndpoint = config["AZURE_AI_PROJECT_ENDPOINT"]
    ?? throw new InvalidOperationException(
        "AZURE_AI_PROJECT_ENDPOINT is not set. " +
        "Locally: dotnet user-secrets set AZURE_AI_PROJECT_ENDPOINT https://<acct>.services.ai.azure.com/api/projects/<proj>");

// -----------------------------------------------------------------------------
// 2. OpenTelemetry -> Application Insights (Foundry Tracing)
// -----------------------------------------------------------------------------
// Capture LLM input/output content in spans so the question and answer show up
// in the Foundry "Tracing" tab.
AppContext.SetSwitch("Microsoft.Extensions.AI.OpenTelemetry.CaptureMessageContent", true);
Environment.SetEnvironmentVariable("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT", "true");

const string ServiceName = "foundry-hosted-agent";
const string AgentTelemetrySource = "Agents";
const string GenAITelemetrySource = "Microsoft.Extensions.AI";

var resourceBuilder = ResourceBuilder.CreateDefault()
    .AddService(serviceName: ServiceName, serviceVersion: "0.1.0")
    .AddAttributes(new Dictionary<string, object>
    {
        ["deployment.environment"] = Environment.GetEnvironmentVariable("AZURE_ENV_NAME") ?? "local"
    });

using var loggerFactory = LoggerFactory.Create(builder =>
{
    builder.AddConsole();
    if (!string.IsNullOrEmpty(appInsightsConnectionString))
    {
        builder.AddOpenTelemetry(opt =>
        {
            opt.SetResourceBuilder(resourceBuilder);
            opt.IncludeFormattedMessage = true;
            opt.IncludeScopes = true;
            opt.AddAzureMonitorLogExporter(o => o.ConnectionString = appInsightsConnectionString);
        });
    }
});
var logger = loggerFactory.CreateLogger("FoundryHostedAgent");

TracerProvider? tracerProvider = null;
MeterProvider? meterProvider = null;
if (!string.IsNullOrEmpty(appInsightsConnectionString))
{
    tracerProvider = Sdk.CreateTracerProviderBuilder()
        .SetResourceBuilder(resourceBuilder)
        .AddSource(AgentTelemetrySource)
        .AddSource(GenAITelemetrySource)
        .AddSource("Azure.*")
        .AddHttpClientInstrumentation()
        .AddAzureMonitorTraceExporter(o => o.ConnectionString = appInsightsConnectionString)
        .Build();

    meterProvider = Sdk.CreateMeterProviderBuilder()
        .SetResourceBuilder(resourceBuilder)
        .AddMeter(GenAITelemetrySource)
        .AddAzureMonitorMetricExporter(o => o.ConnectionString = appInsightsConnectionString)
        .Build();

    logger.LogInformation("OpenTelemetry -> Application Insights enabled (LLM content capture: ON)");
}
else
{
    logger.LogWarning("APPLICATIONINSIGHTS_CONNECTION_STRING is not set - telemetry export disabled.");
}

// -----------------------------------------------------------------------------
// 3. Azure credential
//    - In a Foundry-hosted container: managed identity (DefaultAzureCredential).
//    - Locally: AzureCliCredential, so `az login --tenant <id>` is honoured.
// -----------------------------------------------------------------------------
TokenCredential credential =
    Environment.GetEnvironmentVariable("DOTNET_RUNNING_IN_CONTAINER") == "true"
        ? new DefaultAzureCredential()
        : new AzureCliCredential();

logger.LogInformation("Endpoint:        {Endpoint}", endpoint);
logger.LogInformation("Deployment:      {Deployment}", deploymentName);
logger.LogInformation("Credential:      {Credential}", credential.GetType().Name);

// -----------------------------------------------------------------------------
// 4. Build the IChatClient pipeline
//    - AzureOpenAIClient -> ChatClient -> IChatClient
//    - .UseOpenTelemetry() emits gen_ai.* spans for every LLM call.
// -----------------------------------------------------------------------------
IChatClient chatClient = new AzureOpenAIClient(new Uri(endpoint), credential)
    .GetChatClient(deploymentName)
    .AsIChatClient()
    .AsBuilder()
    .UseOpenTelemetry(loggerFactory: loggerFactory, sourceName: GenAITelemetrySource)
    .Build();

// -----------------------------------------------------------------------------
// 5. Build a thin REST client for the 3 Foundry sub-agents.
//    (They were pre-created by deploy-agent.ps1 STEP 5 as kind=prompt agents.)
// -----------------------------------------------------------------------------
var plants = new PlantAgentClient(projectEndpoint, deploymentName, credential, logger);

// Startup self-test - confirms (a) MI can get an ai.azure.com token and
// (b) the orchestrator can reach a sub-agent. Failures here are LOGGED but
// NOT fatal so the container still comes up to serve later requests.
_ = Task.Run(async () =>
{
    try
    {
        logger.LogInformation("[startup-test] Calling Botany-Expert with a tiny prompt...");
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var reply = await plants.AskAsync(PlantAgentClient.BotanyAgentName, "One word: are you online?");
        logger.LogInformation("[startup-test] Botany-Expert reply in {Ms}ms: {Reply}",
            sw.ElapsedMilliseconds, reply.Length > 200 ? reply.Substring(0, 200) + "..." : reply);
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "[startup-test] Sub-agent self-test FAILED. Orchestrator may return 408.");
    }
});

// -----------------------------------------------------------------------------
// 6. Define ONE consolidated tool that runs the whole 3-agent pipeline.
//    Inside the tool we call Botany + Toxicity in PARALLEL, then Summary.
//    This avoids:
//      - Sequential model round-trips between 3 separate tools (slow)
//      - The model having to re-transcribe large sub-agent outputs as
//        arguments to a follow-up tool call (token waste + timeout risk)
// -----------------------------------------------------------------------------

[Description("Generate a complete plant report. Call this for ANY plant question. " +
             "Internally queries Botany-Expert and Toxicity-Detector in parallel, " +
             "then asks Summary-Generator to produce a user-friendly bulleted summary.")]
async Task<string> GetPlantReport(
    [Description("Common or scientific name of the plant the user asked about")] string plantName)
{
    logger.LogInformation("[orchestrator] GetPlantReport: {Plant}", plantName);
    var sw = System.Diagnostics.Stopwatch.StartNew();

    // 1. Botany + Toxicity in PARALLEL (cuts wall-clock time roughly in half).
    var botanyTask   = plants.AskAsync(PlantAgentClient.BotanyAgentName,
        $"Tell me everything you know about: {plantName}");
    var toxicityTask = plants.AskAsync(PlantAgentClient.ToxicityAgentName,
        $"Analyse the toxicity of: {plantName}");
    await Task.WhenAll(botanyTask, toxicityTask);
    logger.LogInformation("[orchestrator] Botany+Toxicity done in {Ms}ms", sw.ElapsedMilliseconds);

    // 2. Summary on top of both findings.
    var combined = $"""
        Plant the user asked about: {plantName}

        --- BOTANY-EXPERT REPORT ---
        {botanyTask.Result}

        --- TOXICITY-DETECTOR REPORT ---
        {toxicityTask.Result}

        Please summarise for the end user using your defined output format.
        """;
    var summary = await plants.AskAsync(PlantAgentClient.SummaryAgentName, combined);
    logger.LogInformation("[orchestrator] Total pipeline {Ms}ms", sw.ElapsedMilliseconds);
    return summary;
}

// -----------------------------------------------------------------------------
// 7. Create the orchestrator agent (the user-facing hosted agent)
// -----------------------------------------------------------------------------
var agent = new ChatClientAgent(
    chatClient,
    name: "PlantAdvisorOrchestrator",
    instructions: """
        You are PLANT-ADVISOR, an orchestrator agent.

        For every plant question (indoor or outdoor plants, plant care, plant
        toxicity, identification, etc.):
          1. Call GetPlantReport(plantName) ONCE with the plant name.
          2. Return the tool's output verbatim as your answer. Do not modify,
             expand, or shorten it.

        SCOPE:
          - You only handle plant / botany / horticulture / plant-toxicity questions.
          - If a user asks anything else (weather, code, sports, history, ...), reply:
            "I'm a plant advisor — I can only help with questions about plants."
          - If the user asks about multiple plants in one message, call
            GetPlantReport once per plant and concatenate the results.

        Be concise. Do not narrate workflow steps to the user.
        """,
    tools: [AIFunctionFactory.Create(GetPlantReport)])
    .AsBuilder()
    .Build();

// -----------------------------------------------------------------------------
// 8. Run the Foundry hosting adapter
//    - Starts an HTTP server on port 8088
//    - Translates Foundry Responses Protocol <-> Microsoft Agent Framework
//    - Emits activity spans on the "Agents" telemetry source
// -----------------------------------------------------------------------------
logger.LogInformation("{ServiceName} listening on http://0.0.0.0:8088 (Foundry Responses Protocol)", ServiceName);

try
{
    await agent.RunAIAgentAsync(telemetrySourceName: AgentTelemetrySource);
}
finally
{
    tracerProvider?.Dispose();
    meterProvider?.Dispose();
}
