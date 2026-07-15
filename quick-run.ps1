# Quick one-file runner (UTF-8 safe) with assignee + Estimate + RM Log1
$ErrorActionPreference = 'Stop'
Write-Host 'QUICK-RUN version 2026-07-15b' -ForegroundColor Cyan

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$pat = $env:AZURE_DEVOPS_PAT
if (-not $pat) { throw 'Set AZURE_DEVOPS_PAT first' }

$parentId = 58200
$collectionUrl = 'https://azure.okco.ir/Ofoq%20Kourosh'
$baseUrl = "$collectionUrl/ImprovementOfInfrastructure"
$iteration = 'ImprovementOfInfrastructure\sprint 9-1405'
$assignee = 'OKCO\Farhangian.Mohsen'

$headers = @{
    Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    Accept = 'application/json'
}

function Invoke-TfsJson {
    param(
        [string]$Method = 'GET',
        [string]$Uri,
        $Body = $null,
        [string]$ContentType = 'application/json; charset=utf-8'
    )

    $params = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
        TimeoutSec = 30
    }

    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { ($Body | ConvertTo-Json -Depth 10 -Compress) }
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
        $params.ContentType = $ContentType
    }

    return Invoke-RestMethod @params
}

Write-Host 'Resolving Estimate / RM Log1 fields...'
$taskFields = @(Invoke-TfsJson -Uri "$baseUrl/_apis/wit/workitemtypes/Task/fields?api-version=6.0").value
$estimateField = (
    $taskFields |
    Where-Object { $_.referenceName -eq 'Microsoft.VSTS.Scheduling.OriginalEstimate' -or $_.name -match 'Estimate' } |
    Select-Object -First 1
).referenceName
$rmLog1Field = (
    $taskFields |
    Where-Object { $_.name -match 'RM\s*Log\s*1' -or $_.referenceName -match 'RMLog1' } |
    Select-Object -First 1
).referenceName

if (-not $estimateField) { throw 'Estimate field not found' }
if (-not $rmLog1Field) { throw 'RM Log1 field not found - run .\discover-fields.ps1' }

Write-Host "1/3 Fetching PBI $parentId ..."
$parent = Invoke-TfsJson -Uri "$baseUrl/_apis/wit/workitems/$parentId`?api-version=6.0"
$title = [string]$parent.fields.'System.Title'
Write-Host "    Title: $title"

Write-Host '2/3 Creating Task ...'
$patch = @(
    @{ op = 'add'; path = '/fields/System.Title'; value = $title }
    @{ op = 'add'; path = '/fields/System.AssignedTo'; value = $assignee }
    @{ op = 'add'; path = '/fields/System.IterationPath'; value = $iteration }
    @{ op = 'add'; path = '/fields/System.AreaPath'; value = $parent.fields.'System.AreaPath' }
    @{ op = 'add'; path = "/fields/$estimateField"; value = 2 }
    @{ op = 'add'; path = "/fields/$rmLog1Field"; value = 2 }
    @{
        op = 'add'
        path = '/relations/-'
        value = @{
            rel = 'System.LinkTypes.Hierarchy-Reverse'
            url = $parent.url
        }
    }
)

$created = Invoke-TfsJson `
    -Method POST `
    -Uri "$baseUrl/_apis/wit/workitems/`$Task?api-version=6.0" `
    -Body $patch `
    -ContentType 'application/json-patch+json; charset=utf-8'

Write-Host "3/3 DONE - Task $($created.id)" -ForegroundColor Green
Write-Host "AssignedTo=$assignee | Estimate=2 | RM Log1=2"
Write-Host $created.url
