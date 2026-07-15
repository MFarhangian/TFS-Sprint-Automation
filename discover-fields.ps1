# Discover Task field reference names (useful for Estimate / RM Log1)
$ErrorActionPreference = 'Stop'
Write-Host 'DISCOVER-FIELDS version 2026-07-15b' -ForegroundColor Cyan

$pat = $env:AZURE_DEVOPS_PAT
if (-not $pat) { throw 'Set AZURE_DEVOPS_PAT first' }

$config = Get-Content -Path (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$collection = [uri]::EscapeDataString($config.collection)
$project = [uri]::EscapeDataString($config.project)
$baseUrl = "$($config.serverUrl.TrimEnd('/'))/$collection/$project"
$headers = @{
    Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    Accept = 'application/json'
}

$fields = Invoke-RestMethod -Uri "$baseUrl/_apis/wit/workitemtypes/Task/fields?api-version=6.0" -Headers $headers -TimeoutSec 30
$matches = @($fields.value) | Where-Object {
    $_.name -match 'Estimate|RM\s*Log|Log1|Original Estimate' -or
    $_.referenceName -match 'Estimate|RMLog|Log1|OriginalEstimate'
} | Sort-Object name

Write-Host ''
Write-Host 'Matching Task fields:' -ForegroundColor Cyan
$matches | ForEach-Object {
    Write-Host ("{0,-45} => {1}" -f $_.name, $_.referenceName)
}

Write-Host ''
Write-Host 'Copy the correct referenceName into config.json (estimateField / rmLog1Field).'
