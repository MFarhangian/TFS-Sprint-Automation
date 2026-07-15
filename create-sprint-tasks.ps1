#Requires -Version 5.1
<#
.SYNOPSIS
    Create sprint Tasks under recurring Product Backlog Items in Azure DevOps Server (TFS).

.EXAMPLE
    $env:AZURE_DEVOPS_PAT = 'your-personal-access-token'
    .\create-sprint-tasks.ps1 -RequestedParentId 58200
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [Alias('ParentId')]
    [int]$RequestedParentId = 0,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$Script:RequestTimeoutSec = 30

Write-Host 'Script version: 2026-07-15b'
Write-Host 'Starting...'

# Ensure Persian titles survive HTTP serialization.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Get-Config {
    param([string]$Path)
    Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-ItemCount {
    param($Value)
    if ($null -eq $Value) { return 0 }
    return @($Value).Count
}

function Invoke-TfsRequest {
    param(
        [string]$Method,
        [string]$Uri,
        [string]$Pat,
        $Body = $null,
        [string]$ContentType = 'application/json'
    )

    $headers = @{
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
        Accept = 'application/json'
    }

    $params = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
    }

    if ($null -ne $Body) {
        if ($ContentType -notmatch 'charset=') {
            $ContentType = "$ContentType; charset=utf-8"
        }
        $params.ContentType = $ContentType

        # Always send UTF-8 bytes. Passing a .NET string can corrupt Persian titles.
        $json = if ($Body -is [string]) { $Body } else { ($Body | ConvertTo-Json -Depth 20 -Compress) }
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
    }

    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            return Invoke-RestMethod @params -TimeoutSec $Script:RequestTimeoutSec
        }
        return Invoke-RestMethod @params
    }
    catch {
        $response = $_.Exception.Response
        if ($response) {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $details = $reader.ReadToEnd()
            $reader.Close()
            if ([string]::IsNullOrWhiteSpace($details)) {
                $details = $_.Exception.Message
            }
            throw "Request failed ($($response.StatusCode.value__)) $details"
        }
        throw
    }
}

function Get-WorkItem {
    param(
        [string]$BaseUrl,
        [string]$Pat,
        [int]$WorkItemId,
        [switch]$IncludeRelations
    )

    $expand = ''
    if ($IncludeRelations) {
        $expand = '&$expand=relations'
    }

    $uri = "$BaseUrl/_apis/wit/workitems/$WorkItemId`?api-version=6.0$expand"
    Invoke-TfsRequest -Method GET -Uri $uri -Pat $Pat
}

function Get-ChildWorkItemIds {
    param($ParentWorkItem)

    $childIds = @()
    foreach ($relation in @($ParentWorkItem.relations)) {
        if ($relation.rel -ne 'System.LinkTypes.Hierarchy-Forward') {
            continue
        }
        if ($relation.url -match '/workitems/(\d+)(?:\?.*)?$') {
            $childIds += [int]$Matches[1]
        }
    }
    return $childIds
}

function Find-ExistingChildTask {
    param(
        [string]$BaseUrl,
        [string]$Pat,
        [object]$ParentWorkItem,
        [string]$IterationPath,
        [string]$ChildType
    )

    $childIds = Get-ChildWorkItemIds -ParentWorkItem $ParentWorkItem
    if ((Get-ItemCount $childIds) -eq 0) {
        return $null
    }

    $ids = ($childIds | Sort-Object -Unique) -join ','
    $fields = [uri]::EscapeDataString('System.Id,System.WorkItemType,System.IterationPath,System.Title')
    $uri = "$BaseUrl/_apis/wit/workitems?ids=$ids&fields=$fields&api-version=6.0"
    $children = Invoke-TfsRequest -Method GET -Uri $uri -Pat $Pat

    foreach ($child in @($children.value)) {
        $type = [string]$child.fields.'System.WorkItemType'
        $iteration = [string]$child.fields.'System.IterationPath'
        $matchesType = ($type -eq $ChildType)
        $matchesIteration = ($iteration -eq $IterationPath) -or ($iteration -like "*$IterationPath*")

        if ($matchesType -and $matchesIteration) {
            return [pscustomobject]@{
                Id = [int]$child.id
                Title = [string]$child.fields.'System.Title'
                AlreadyExists = $true
            }
        }
    }

    return $null
}

function Get-IterationCandidates {
    param(
        [string]$Project,
        [string]$ConfiguredPath
    )

    return @(
        $ConfiguredPath
        "$Project\$ConfiguredPath"
        "$Project\Iteration\$ConfiguredPath"
        "Ofoq Kourosh\$Project\$ConfiguredPath"
        "Ofoq Kourosh\$Project\Iteration\$ConfiguredPath"
    ) | Select-Object -Unique
}

function Resolve-TfsIdentity {
    param(
        [string]$CollectionUrl,
        [string]$Pat,
        [string]$SearchValue
    )

    if ([string]::IsNullOrWhiteSpace($SearchValue)) {
        return $null
    }

    $search = [uri]::EscapeDataString($SearchValue)
    $uri = "$CollectionUrl/_apis/identities?searchFilter=General&filterValue=$search&api-version=5.0"
    try {
        $result = Invoke-TfsRequest -Method GET -Uri $uri -Pat $Pat
        $identity = @($result.value) | Select-Object -First 1
        if ($identity) {
            if ($identity.uniqueName) { return [string]$identity.uniqueName }
            if ($identity.displayName) { return [string]$identity.displayName }
        }
    }
    catch {
        Write-Host "  -> warning: identity lookup failed for '$SearchValue'"
    }

    return $null
}

function Get-AssigneeValue {
    param(
        [string]$CollectionUrl,
        [string]$Pat,
        [string]$ConfiguredAssignee,
        $ParentWorkItem
    )

    if ($ParentWorkItem.fields.'System.AssignedTo') {
        if ($ParentWorkItem.fields.'System.AssignedTo'.uniqueName) {
            return [string]$ParentWorkItem.fields.'System.AssignedTo'.uniqueName
        }
        if ($ParentWorkItem.fields.'System.AssignedTo'.displayName) {
            return [string]$ParentWorkItem.fields.'System.AssignedTo'.displayName
        }
    }

    $candidates = @(
        $ConfiguredAssignee
        ($ConfiguredAssignee -replace '@.*$', '')
        ($ConfiguredAssignee -replace '@okco\.ir$', '')
        'Farhangian.Mohsen'
        'Mohsen Farhangian'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($candidate in $candidates) {
        $resolved = Resolve-TfsIdentity -CollectionUrl $CollectionUrl -Pat $Pat -SearchValue $candidate
        if ($resolved) {
            Write-Host "  -> assignee resolved: $resolved"
            return $resolved
        }
    }

    Write-Host '  -> warning: could not resolve assignee, task will be created without Assigned To'
    return $null
}

function New-ChildTask {
    param(
        [string]$BaseUrl,
        [string]$Pat,
        [string]$CollectionUrl,
        $Config,
        $Parent,
        [string[]]$IterationCandidates
    )

    $childType = [uri]::EscapeDataString($Config.childWorkItemType)
    $title = $Parent.fields.'System.Title'
    $assignee = if ($Config.assignedTo) { [string]$Config.assignedTo } else {
        Get-AssigneeValue `
            -CollectionUrl $CollectionUrl `
            -Pat $Pat `
            -ConfiguredAssignee $Config.assignedTo `
            -ParentWorkItem $Parent
    }

    $estimateField = if ($Config.estimateField) { [string]$Config.estimateField } else { 'Microsoft.VSTS.Scheduling.OriginalEstimate' }
    $rmLog1Field = if ($Config.rmLog1Field) { [string]$Config.rmLog1Field } else { 'Custom.RMLog1' }
    $estimateValue = if ($null -ne $Config.estimateValue) { [double]$Config.estimateValue } else { 2 }
    $rmLog1Value = if ($null -ne $Config.rmLog1Value) { [double]$Config.rmLog1Value } else { 2 }

    $lastError = $null
    foreach ($iterationPath in $IterationCandidates) {
        $uri = "$BaseUrl/_apis/wit/workitems/`$$childType`?api-version=6.0"
        $patch = @(
            @{ op = 'add'; path = '/fields/System.Title'; value = $title }
            @{ op = 'add'; path = '/fields/System.IterationPath'; value = $iterationPath }
            @{
                op = 'add'
                path = '/relations/-'
                value = @{
                    rel = 'System.LinkTypes.Hierarchy-Reverse'
                    url = $Parent.url
                }
            }
        )

        if ($assignee) {
            $patch += @{ op = 'add'; path = '/fields/System.AssignedTo'; value = $assignee }
        }

        if ($Parent.fields.'System.AreaPath') {
            $patch += @{
                op = 'add'
                path = '/fields/System.AreaPath'
                value = $Parent.fields.'System.AreaPath'
            }
        }

        $patch += @{ op = 'add'; path = "/fields/$estimateField"; value = $estimateValue }
        $patch += @{ op = 'add'; path = "/fields/$rmLog1Field"; value = $rmLog1Value }

        try {
            $created = Invoke-TfsRequest `
                -Method POST `
                -Uri $uri `
                -Pat $Pat `
                -Body $patch `
                -ContentType 'application/json-patch+json'

            return [pscustomobject]@{
                Id = [int]$created.id
                Title = $title
                ParentId = [int]$Parent.id
                IterationPath = $iterationPath
                Url = $created.url
                Created = $true
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Host "  -> iteration failed: $iterationPath"
        }
    }

    throw "Could not create task for PBI $($Parent.id). Last error: $lastError"
}

function Get-ParentIdList {
    param(
        [int]$SelectedParentId,
        $FromConfig
    )

    if ($SelectedParentId -gt 0) {
        return ,[int]$SelectedParentId
    }

    if ($null -ne $FromConfig) {
        $ids = @()
        foreach ($item in @($FromConfig)) {
            if ($item -is [System.Array]) {
                foreach ($inner in $item) { $ids += [int]$inner }
            }
            else {
                $ids += [int]$item
            }
        }
        return $ids
    }

    return @()
}

$config = Get-Config -Path $ConfigPath
$pat = $env:AZURE_DEVOPS_PAT
if (-not $pat) { $pat = $env:TFS_PAT }
if (-not $pat -and -not $DryRun) {
    throw 'Set AZURE_DEVOPS_PAT or TFS_PAT before running.'
}
if ($pat -match '^(ghp_|github_pat_)') {
    throw 'AZURE_DEVOPS_PAT looks like a GitHub token. Create a PAT from https://azure.okco.ir/_usersSettings/tokens'
}

$collection = [uri]::EscapeDataString($config.collection)
$project = [uri]::EscapeDataString($config.project)
$collectionUrl = "$($config.serverUrl.TrimEnd('/'))/$collection"
$baseUrl = "$collectionUrl/$project"
$iterationCandidates = @(Get-IterationCandidates -Project $config.project -ConfiguredPath $config.iterationPath)

$parentIds = @(Get-ParentIdList -SelectedParentId $RequestedParentId -FromConfig $config.parentIds)

if ((Get-ItemCount $parentIds) -eq 0) {
    $wiql = @{
        query = @"
SELECT [System.Id]
FROM WorkItems
WHERE [System.TeamProject] = @project
  AND [System.WorkItemType] = '$($config.parentWorkItemType)'
  AND [System.AssignedTo] = '$($config.assignedTo)'
  AND [System.State] = '$($config.parentStateFilter)'
ORDER BY [System.Id]
"@
    }
    $result = Invoke-TfsRequest -Method POST -Uri "$baseUrl/_apis/wit/wiql?api-version=6.0" -Pat $pat -Body $wiql
    $parentIds = @($result.workItems | ForEach-Object { [int]$_.id })
}

Write-Host "Sprint: $($config.iterationPath)"
Write-Host "Iteration candidates: $($iterationCandidates -join ' | ')"
Write-Host "Parents: $($parentIds -join ', ')"

$results = @()
foreach ($currentParentId in $parentIds) {
    $currentParentId = [int]$currentParentId
    Write-Host ''
    Write-Host "Loading PBI $currentParentId from TFS..."
    $parent = Get-WorkItem -BaseUrl $baseUrl -Pat $pat -WorkItemId $currentParentId -IncludeRelations
    $title = $parent.fields.'System.Title'
    Write-Host ''
    Write-Host "PBI ${currentParentId}: $title"

    $existing = Find-ExistingChildTask `
        -BaseUrl $baseUrl `
        -Pat $pat `
        -ParentWorkItem $parent `
        -IterationPath $config.iterationPath `
        -ChildType $config.childWorkItemType

    if ($existing) {
        Write-Host "  -> already has task $($existing.Id) in this sprint"
        $results += $existing
        continue
    }

    if ($DryRun) {
        Write-Host '  -> would create child task'
        $results += [pscustomobject]@{ ParentId = $currentParentId; Title = $title; DryRun = $true }
        continue
    }

    $created = New-ChildTask -BaseUrl $baseUrl -Pat $pat -CollectionUrl $collectionUrl -Config $config -Parent $parent -IterationCandidates $iterationCandidates
    Write-Host "  -> created task $($created.Id) in iteration: $($created.IterationPath)"
    $results += $created
}

Write-Host ''
Write-Host 'Summary:'
foreach ($item in $results) {
    if ($item.Created) {
        Write-Host "  CREATED Task $($item.Id) under PBI $($item.ParentId)"
    }
    elseif ($item.AlreadyExists) {
        Write-Host "  SKIPPED existing Task $($item.Id)"
    }
    elseif ($item.DryRun) {
        Write-Host "  DRY-RUN would create task under PBI $($item.ParentId)"
    }
}
