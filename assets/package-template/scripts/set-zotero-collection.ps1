param(
    [string]$Path,
    [string]$Key,
    [string]$ConfigFile,
    [switch]$RebuildQueue,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageDir = Split-Path -Parent $scriptDir
if (-not $ConfigFile) { $ConfigFile = Join-Path $packageDir 'configs\paper-reading-pool-config.json' }
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Config file not found: $ConfigFile" }
if (-not $Path -and -not $Key) { throw 'Provide -Path "Top -> Child" or -Key <collectionKey>.' }

function Ensure-LocalNoProxy {
    foreach ($name in @('NO_PROXY', 'no_proxy')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        $parts = @()
        if ($value) { $parts = @($value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        foreach ($entry in @('localhost', '127.0.0.1')) {
            if ($parts -notcontains $entry) { $parts += $entry }
        }
        [Environment]::SetEnvironmentVariable($name, ($parts -join ','), 'Process')
    }
}

function Invoke-ZoteroApi {
    param([Parameter(Mandatory = $true)][string]$Url)
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Proxy = $null
    $request.Timeout = 30000
    $request.Headers.Add('Zotero-API-Version', '3')
    $response = $request.GetResponse()
    try {
        $reader = [System.IO.StreamReader]::new($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $headers = @{}
        foreach ($headerName in $response.Headers.AllKeys) { $headers[$headerName] = $response.Headers[$headerName] }
        [pscustomobject]@{ Body = $body; Headers = $headers }
    } finally {
        $response.Dispose()
    }
}

function Get-ZoteroCollections {
    Ensure-LocalNoProxy
    $base = 'http://127.0.0.1:23119/api/users/0/collections?format=json&limit=100'
    $all = @()
    $start = 0
    while ($true) {
        $result = Invoke-ZoteroApi -Url ($base + '&start=' + $start)
        $chunk = @()
        if ($result.Body) {
            # Keep ConvertFrom-Json array output expanded. In Windows PowerShell,
            # @($json | ConvertFrom-Json) can wrap the whole JSON array as one
            # System.Object[] element, which corrupts collection path resolution.
            $parsed = $result.Body | ConvertFrom-Json
            $chunk = @($parsed)
        }
        if ($chunk.Count -eq 0) { break }
        $all += $chunk
        $total = 0
        foreach ($name in @('Total-Results', 'Zotero-Total-Results')) {
            if ($result.Headers.ContainsKey($name)) { $total = [int]$result.Headers[$name]; break }
        }
        if ($total -le 0) { $total = $all.Count }
        if ($all.Count -ge $total) { break }
        $start += $chunk.Count
    }
    return $all
}

function Get-CollectionPathParts {
    param($Collection, $ByKey)
    $parts = New-Object System.Collections.Generic.List[string]
    $current = $Collection
    $guard = 0
    while ($null -ne $current -and $guard -lt 50) {
        $name = [string]$current.data.name
        if ($name) { $parts.Insert(0, $name) }
        $parent = $current.data.parentCollection
        if (-not $parent -or [string]$parent -eq 'False') { break }
        $parentKey = [string]$parent
        if (-not $ByKey.ContainsKey($parentKey)) { break }
        $current = $ByKey[$parentKey]
        $guard++
    }
    return @($parts)
}

function Split-CollectionPath {
    param([Parameter(Mandatory = $true)][string]$Value)
    $normalized = $Value.Trim()
    if (-not $normalized) { throw 'Collection path is empty.' }
    $parts = @($normalized -split '\s*(?:->|/|\\|>)\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -lt 1) { throw "Could not parse collection path: $Value" }
    return $parts
}

$collections = @(Get-ZoteroCollections)
if ($collections.Count -eq 0) { throw 'No Zotero collections returned. Confirm Zotero Desktop and local API are running.' }
$byKey = @{}
foreach ($collection in $collections) { $byKey[[string]$collection.key] = $collection }

$target = $null
$targetPathParts = $null
if ($Key) {
    $normalizedKey = $Key.Trim().ToUpperInvariant()
    if (-not $byKey.ContainsKey($normalizedKey)) { throw "Collection key not found: $normalizedKey" }
    $target = $byKey[$normalizedKey]
    $targetPathParts = @(Get-CollectionPathParts -Collection $target -ByKey $byKey)
} else {
    $wantedParts = @(Split-CollectionPath $Path)
    $wantedJoined = ($wantedParts -join ' / ')
    $matches = @()
    foreach ($collection in $collections) {
        $parts = @(Get-CollectionPathParts -Collection $collection -ByKey $byKey)
        if (($parts -join ' / ') -eq $wantedJoined) {
            $matches += [pscustomobject]@{ Collection = $collection; Parts = $parts }
        }
    }
    if ($matches.Count -eq 0) {
        $available = $collections | ForEach-Object {
            $parts = @(Get-CollectionPathParts -Collection $_ -ByKey $byKey)
            [pscustomobject]@{ Key = $_.key; Path = ($parts -join ' / ') }
        } | Sort-Object Path
        $hint = ($available | Select-Object -First 30 | ForEach-Object { "$($_.Key)  $($_.Path)" }) -join [Environment]::NewLine
        throw "Collection path not found: $wantedJoined`nAvailable examples:`n$hint"
    }
    if ($matches.Count -gt 1) {
        $hint = ($matches | ForEach-Object { "$($_.Collection.key)  $($_.Parts -join ' / ')" }) -join [Environment]::NewLine
        throw "Collection path is ambiguous: $wantedJoined`n$hint"
    }
    $target = $matches[0].Collection
    $targetPathParts = @($matches[0].Parts)
}

$config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$entry = [pscustomobject]@{
    top = if ($targetPathParts.Count -gt 0) { $targetPathParts[0] } else { [string]$target.data.name }
    name = [string]$target.data.name
    key = [string]$target.key
    pathParts = @($targetPathParts)
}
$config.collections = @($entry)

if (-not $DryRun) {
    $json = $config | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($ConfigFile, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

$result = [ordered]@{
    ok = $true
    dryRun = [bool]$DryRun
    configFile = $ConfigFile
    collectionKey = [string]$target.key
    collectionPath = ($targetPathParts -join ' / ')
    collectionName = [string]$target.data.name
}
$result | ConvertTo-Json -Depth 8

if ($RebuildQueue -and -not $DryRun) {
    $runner = Join-Path $scriptDir 'run-zotero-paper-reading-pool.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -ConfigFile $ConfigFile -QueueOnly
    & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -ConfigFile $ConfigFile -QueueStatus
}
