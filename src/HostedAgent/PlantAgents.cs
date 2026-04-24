// =============================================================================
// PlantAgents.cs
// -----------------------------------------------------------------------------
// Thin REST client that lets the orchestrator call the three Foundry "prompt"
// sub-agents (Botany-Expert, Toxicity-Detector, Summary-Generator) that were
// pre-created by deploy-agent.ps1 (AGENT STEP 5).
//
// Each sub-agent exposes a Foundry Responses API endpoint at:
//   POST {projectEndpoint}/agents/{name}/endpoint/protocols/openai/responses
//        ?api-version=2025-11-15-preview
//
// Auth = bearer token from DefaultAzureCredential / AzureCliCredential
//        (same identity that runs the orchestrator container).
// =============================================================================

using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Azure.Core;
using Microsoft.Extensions.Logging;

namespace FoundryHostedAgent;

public sealed class PlantAgentClient
{
    public const string BotanyAgentName    = "Botany-Expert";
    public const string ToxicityAgentName  = "Toxicity-Detector";
    public const string SummaryAgentName   = "Summary-Generator";

    private const string ResponsesApiVersion = "2025-11-15-preview";
    private const string AiAzureScope        = "https://ai.azure.com/.default";

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromMinutes(3) };
    private readonly TokenCredential _credential;
    private readonly string _projectEndpoint;
    private readonly string _modelDeployment;
    private readonly ILogger _logger;

    public PlantAgentClient(string projectEndpoint, string modelDeployment, TokenCredential credential, ILogger logger)
    {
        _projectEndpoint = projectEndpoint.TrimEnd('/');
        _modelDeployment = modelDeployment;
        _credential      = credential;
        _logger          = logger;
    }

    /// <summary>
    /// Send a single user prompt to the named sub-agent and return its assistant text.
    /// </summary>
    public async Task<string> AskAsync(string agentName, string userInput, CancellationToken ct = default)
    {
        var token = (await _credential.GetTokenAsync(
            new TokenRequestContext(new[] { AiAzureScope }), ct)).Token;

        var url = $"{_projectEndpoint}/agents/{agentName}/endpoint/protocols/openai/responses?api-version={ResponsesApiVersion}";

        // The 'model' field MUST match the sub-agent's underlying model deployment
        // (the API rejects mismatched model names).
        var body = new
        {
            model = _modelDeployment,
            input = userInput
        };

        using var req = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = JsonContent.Create(body)
        };
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var sw = System.Diagnostics.Stopwatch.StartNew();
        using var resp = await _http.SendAsync(req, ct);
        var raw = await resp.Content.ReadAsStringAsync(ct);
        sw.Stop();

        if (!resp.IsSuccessStatusCode)
        {
            _logger.LogError("Sub-agent {Name} returned HTTP {Status} in {Ms}ms: {Body}",
                agentName, (int)resp.StatusCode, sw.ElapsedMilliseconds, raw);
            return $"(sub-agent {agentName} returned HTTP {(int)resp.StatusCode})";
        }

        // Responses API output: { output: [ { type: 'message', content: [ { text: '...' } ] }, ... ] }
        try
        {
            using var doc = JsonDocument.Parse(raw);
            if (doc.RootElement.TryGetProperty("output", out var outputArr))
            {
                string? lastText = null;
                foreach (var item in outputArr.EnumerateArray())
                {
                    if (item.TryGetProperty("type", out var t) && t.GetString() == "message" &&
                        item.TryGetProperty("content", out var contentArr))
                    {
                        foreach (var c in contentArr.EnumerateArray())
                        {
                            if (c.TryGetProperty("text", out var tx))
                            {
                                lastText = tx.GetString();
                            }
                        }
                    }
                }
                if (!string.IsNullOrWhiteSpace(lastText))
                {
                    _logger.LogInformation("Sub-agent {Name} replied in {Ms}ms ({Chars} chars)",
                        agentName, sw.ElapsedMilliseconds, lastText.Length);
                    return lastText;
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to parse response from sub-agent {Name}", agentName);
        }
        return raw;
    }
}
