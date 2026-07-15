# Create/update sprint tasks and mention a user in Discussion
$ErrorActionPreference = 'Stop'
Write-Host 'RUN-ALL version 2026-07-15c' -ForegroundColor Cyan

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$pat = $env:AZURE_DEVOPS_PAT
if (-not $pat) { throw 'Set AZURE_DEVOPS_PAT first' }

$configPath = Join-Path $PSScriptRoot 'config.json'
$config = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

$collection = [uri]::EscapeDataString($config.collection)
$project = [uri]::EscapeDataString($config.project)
$collectionUrl = "$($config.serverUrl.TrimEnd('/'))/$collection"
$baseUrl = "$collectionUrl/$project"
$iteration = $config.iterationPath
$parentIds = @($config.parentIds)
$assignee = $config.assignedTo
$estimateValue = [double]$config.estimateValue
$rmLog1Value = [double]$config.rmLog1Value
$mentionUser = [string]$config.mentionUser
$mentionDisplay = if ($config.mentionDisplayName) { [string]$config.mentionDisplayName } else { ($mentionUser -split '\\')[-1] }
$mentionExtra = [string]$config.mentionComment

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

function Resolve-FieldRef {
    param(
        [string]$PreferredRef,
        [string[]]$NameContains,
        $TaskFields
    )

    if ($PreferredRef) {
        $exact = @($TaskFields) | Where-Object { $_.referenceName -eq $PreferredRef } | Select-Object -First 1
        if ($exact) { return $exact.referenceName }
    }

    foreach ($token in $NameContains) {
        $match = @($TaskFields) | Where-Object {
            $_.name -like "*$token*" -or $_.referenceName -like "*$token*"
        } | Select-Object -First 1
        if ($match) { return $match.referenceName }
    }

    return $null
}

function Resolve-Identity {
    param([string]$SearchValue)

    $candidates = @(
        $SearchValue
        ($SearchValue -replace '^.*\\', '')
        ($SearchValue -replace '.*\\', '')
    ) | Select-Object -Unique

    $shortName = ($SearchValue -replace '^.*\\', '')
    $matches = @()

    foreach ($candidate in $candidates) {
        $uri = "$collectionUrl/_apis/identities?searchFilter=General&filterValue=$([uri]::EscapeDataString($candidate))&queryMembership=None&api-version=5.0"
        try {
            $result = Invoke-TfsJson -Uri $uri
            foreach ($identity in @($result.value)) {
                $unique = [string]$identity.uniqueName
                $display = [string]$identity.displayName
                $id = [string]$identity.id
                if (-not $id) { continue }

                $matches += [pscustomobject]@{
                    Id = $id
                    UniqueName = $unique
                    DisplayName = $(if ($display) { $display } else { $unique })
                }
            }
        }
        catch {
            Write-Host "  -> identity lookup failed for '$candidate'"
        }
    }

    $exact = $matches | Where-Object { $_.UniqueName -eq $SearchValue } | Select-Object -First 1
    if ($exact) { return $exact }

    $byShort = $matches | Where-Object {
        $_.UniqueName -eq $shortName -or
        $_.UniqueName -like "*\$shortName" -or
        $_.DisplayName -eq $shortName -or
        $_.DisplayName -like "*$shortName*"
    } | Select-Object -First 1
    if ($byShort) { return $byShort }

    return ($matches | Select-Object -First 1)
}

function Add-DiscussionMention {
    param(
        [int]$WorkItemId,
        $Identity
    )

    $display = $Identity.DisplayName
    $id = $Identity.Id
    $extra = if ($mentionExtra) { " $mentionExtra" } else { '' }
    $html = "<div><a href=`"#`" data-vss-mention=`"version:2.0,$id`">@$display</a>$extra</div>"

    # Prefer Comments API when available
    $commentUrls = @(
        "$baseUrl/_apis/wit/workItems/$WorkItemId/comments?api-version=6.0-preview.3"
        "$baseUrl/_apis/wit/workItems/$WorkItemId/comments?api-version=5.1-preview.3"
        "$baseUrl/_apis/wit/workItems/$WorkItemId/comments?api-version=7.0"
    )

    foreach ($uri in $commentUrls) {
        try {
            Invoke-TfsJson -Method POST -Uri $uri -Body @{ text = $html } | Out-Null
            return 'comments-api'
        }
        catch {
            # try next / fallback
        }
    }

    # Fallback: System.History discussion comment
    $patch = @(
        @{ op = 'add'; path = '/fields/System.History'; value = $html }
    )
    Invoke-TfsJson `
        -Method PATCH `
        -Uri "$baseUrl/_apis/wit/workitems/$WorkItemId`?api-version=6.0" `
        -Body $patch `
        -ContentType 'application/json-patch+json; charset=utf-8' | Out-Null
    return 'history'
}

Write-Host 'Loading Task field definitions...'
$taskFields = Invoke-TfsJson -Uri "$baseUrl/_apis/wit/workitemtypes/Task/fields?api-version=6.0"
$fields = @($taskFields.value)

$estimateField = Resolve-FieldRef -PreferredRef $config.estimateField -NameContains @('Original Estimate', 'Estimate') -TaskFields $fields
$rmLog1Field = Resolve-FieldRef -PreferredRef $config.rmLog1Field -NameContains @('RM Log1', 'RMLog1', 'RM Log 1') -TaskFields $fields

if (-not $estimateField) { throw 'Could not find Estimate field on Task work item type.' }
if (-not $rmLog1Field) { throw 'Could not find RM Log1 field on Task work item type. Run .\discover-fields.ps1 and set rmLog1Field in config.json' }

Write-Host "Resolving mention user: $mentionUser ..."
$mentionIdentity = Resolve-Identity -SearchValue $mentionUser
if (-not $mentionIdentity) {
    throw "Could not resolve mention user '$mentionUser'. Check the account name."
}
Write-Host "Mention       : @$($mentionIdentity.DisplayName) ($($mentionIdentity.UniqueName)) [$($mentionIdentity.Id)]"

Write-Host "Assignee      : $assignee"
Write-Host "Estimate field: $estimateField = $estimateValue"
Write-Host "RM Log1 field : $rmLog1Field = $rmLog1Value"
Write-Host "Parents       : $($parentIds -join ', ')"

foreach ($parentId in $parentIds) {
    Write-Host ""
    Write-Host "=== PBI $parentId ===" -ForegroundColor Cyan
    $parent = Invoke-TfsJson -Uri "$baseUrl/_apis/wit/workitems/$parentId`?`$expand=relations&api-version=6.0"
    $title = [string]$parent.fields.'System.Title'
    Write-Host "Title: $title"

    $existingId = $null
    foreach ($relation in @($parent.relations)) {
        if ($relation.rel -ne 'System.LinkTypes.Hierarchy-Forward') { continue }
        if ($relation.url -match '/workItems/(\d+)$') {
            $childId = [int]$Matches[1]
            $child = Invoke-TfsJson -Uri "$baseUrl/_apis/wit/workitems/$childId`?api-version=6.0"
            if ($child.fields.'System.WorkItemType' -eq 'Task' -and $child.fields.'System.IterationPath' -eq $iteration) {
                $existingId = $child.id
                break
            }
        }
    }

    if ($existingId) {
        Write-Host "Updating existing Task $existingId ..." -ForegroundColor Yellow
        $patch = @(
            @{ op = 'add'; path = '/fields/System.AssignedTo'; value = $assignee }
            @{ op = 'add'; path = "/fields/$estimateField"; value = $estimateValue }
            @{ op = 'add'; path = "/fields/$rmLog1Field"; value = $rmLog1Value }
        )
        $updated = Invoke-TfsJson `
            -Method PATCH `
            -Uri "$baseUrl/_apis/wit/workitems/$existingId`?api-version=6.0" `
            -Body $patch `
            -ContentType 'application/json-patch+json; charset=utf-8'

        $mode = Add-DiscussionMention -WorkItemId $updated.id -Identity $mentionIdentity
        Write-Host "UPDATED Task $($updated.id) | AssignedTo=$assignee | Estimate=$estimateValue | RM Log1=$rmLog1Value | Mention via $mode" -ForegroundColor Green
        continue
    }

    $patch = @(
        @{ op = 'add'; path = '/fields/System.Title'; value = $title }
        @{ op = 'add'; path = '/fields/System.AssignedTo'; value = $assignee }
        @{ op = 'add'; path = '/fields/System.IterationPath'; value = $iteration }
        @{ op = 'add'; path = '/fields/System.AreaPath'; value = $parent.fields.'System.AreaPath' }
        @{ op = 'add'; path = "/fields/$estimateField"; value = $estimateValue }
        @{ op = 'add'; path = "/fields/$rmLog1Field"; value = $rmLog1Value }
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

    $mode = Add-DiscussionMention -WorkItemId $created.id -Identity $mentionIdentity
    Write-Host "CREATED Task $($created.id) : $($created.fields.'System.Title') | Mention via $mode" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
