#!/usr/bin/env pwsh
# =============================================================================
# Foundry Hosted Agent Quickstart - Tear-down
# -----------------------------------------------------------------------------
# Reads .deploy-state.json (produced by deploy.ps1) and deletes the resource
# group it created. If you supply -ResourceGroup explicitly, that wins and the
# state file is ignored.
#
# USAGE
#   .\cleanup.ps1                       # deletes the RG from .deploy-state.json
#   .\cleanup.ps1 -ResourceGroup rg-x   # delete a specific RG
#   .\cleanup.ps1 -Force                # don't ask for confirmation
# =============================================================================

[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$statePath = Join-Path $PSScriptRoot '.deploy-state.json'
if (-not $ResourceGroup) {
    if (-not (Test-Path $statePath)) {
        Write-Host "No -ResourceGroup supplied and no .deploy-state.json found - nothing to clean up." -ForegroundColor Yellow
        exit 0
    }
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    $ResourceGroup = $state.ResourceGroup
}

Write-Host "About to DELETE resource group: $ResourceGroup" -ForegroundColor Red
Write-Host "  This destroys: Foundry account, project, agent versions, container registry, App Insights, Log Analytics." -ForegroundColor Yellow

if (-not $Force) {
    $c = Read-Host "Type the RG name to confirm"
    if ($c -ne $ResourceGroup) { Write-Host 'Aborted - name did not match.' -ForegroundColor Yellow; exit 0 }
}

az group delete --name $ResourceGroup --yes --no-wait | Out-Null
Write-Host "Deletion initiated (running async). Check progress with:" -ForegroundColor Green
Write-Host "  az group show -n $ResourceGroup --query properties.provisioningState -o tsv" -ForegroundColor White

if (Test-Path $statePath) {
    Remove-Item $statePath
    Write-Host "Removed local .deploy-state.json" -ForegroundColor DarkGray
}
