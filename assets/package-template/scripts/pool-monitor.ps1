param(
    [string]$ConfigFile,
    [int]$RefreshSeconds = 0
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageDir = Split-Path -Parent $scriptDir
if (-not $ConfigFile) { $ConfigFile = Join-Path $packageDir 'configs\paper-reading-pool-config.json' }
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Config file not found: $ConfigFile" }

function Resolve-PackagePath {
    param([Parameter(Mandatory = $true)][string]$PathValue, [string]$BasePath = $packageDir)
    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    if ([System.IO.Path]::IsPathRooted($expanded)) { return $expanded }
    return (Join-Path $BasePath $expanded)
}

function Resolve-CodexWireApi {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [string]$ConfiguredWireApi = 'auto'
    )

    $wireApi = if ($ConfiguredWireApi) { $ConfiguredWireApi.Trim().ToLowerInvariant() } else { 'auto' }
    if ($wireApi -eq 'response') { $wireApi = 'responses' }
    if ($wireApi -in @('responses', 'chat')) { return $wireApi }

    if ($Model -match '^(?i:gpt)') { return 'responses' }
    return 'chat'
}

while ($true) {
    Clear-Host
    $config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $effectiveRefreshSeconds = if ($RefreshSeconds -gt 0) {
        $RefreshSeconds
    } elseif ($config.monitorRefreshSeconds) {
        [int]$config.monitorRefreshSeconds
    } else {
        5
    }
    $root = Resolve-PackagePath ([string]$config.root)
    $queueFile = Resolve-PackagePath ([string]$config.queueFile) $root
    $logRoot = Resolve-PackagePath ([string]$config.logRoot) $root
    $studyRoot = Resolve-PackagePath ([string]$config.studyRoot) $root
    $workerCount = if ($config.workerCount) { [int]$config.workerCount } else { 1 }
    $model = if ($config.codexModel) { [string]$config.codexModel } else { 'mimo-v2.5' }
    $reasoningEffort = if ($config.codexReasoningEffort) { [string]$config.codexReasoningEffort } else { 'xhigh' }
    $configuredWireApi = if ($config.PSObject.Properties.Name -contains 'codexWireApi') { [string]$config.codexWireApi } else { 'auto' }
    $effectiveWireApi = Resolve-CodexWireApi -Model $model -ConfiguredWireApi $configuredWireApi
    $enableSearch = if ($null -ne $config.codexEnableSearch) { [bool]$config.codexEnableSearch } else { $true }

    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ("  Zotero Paper Reading Pool - {0} Workers" -f $workerCount) -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ("Model: {0} | Effort: {1} | WireApi: {2} -> {3} | Search: {4}" -f $model, $reasoningEffort, $configuredWireApi, $effectiveWireApi, $enableSearch) -ForegroundColor White
    Write-Host ("MaxRunningPerCollection: {0} | Sleep: {1}s | MaxAttempts: {2} | LeaseHours: {3}" -f $config.maxRunningPerCollection, $config.workerSleepSeconds, $config.maxAttempts, $config.leaseHours) -ForegroundColor DarkGray

    if (Test-Path -LiteralPath $queueFile) {
        try {
            $queue = Get-Content -LiteralPath $queueFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $pending = @($queue.items | Where-Object { $_.status -eq 'pending' }).Count
            $running = @($queue.items | Where-Object { $_.status -eq 'running' }).Count
            $done = @($queue.items | Where-Object { $_.status -eq 'done' }).Count
            $failed = @($queue.items | Where-Object { $_.status -eq 'failed' }).Count
            Write-Host ""
            Write-Host "Total: $($queue.total) | Pending: $pending | Running: $running | Done: $done | Failed: $failed"
            Write-Host ""
            Write-Host "Running items:" -ForegroundColor White
            $queue.items | Where-Object { $_.status -eq 'running' } | ForEach-Object {
                $title = [string]$_.title
                if ($title.Length -gt 70) { $title = $title.Substring(0, 70) + '...' }
                Write-Host ("  {0} | {1}/{2} #{3:D3} | {4}" -f $_.workerId, $_.topCollectionName, $_.collectionName, [int]$_.collectionIndex, $title)
            }
        } catch {
            Write-Host "Queue file exists but cannot be parsed: $queueFile" -ForegroundColor Yellow
            Write-Host $_.Exception.Message -ForegroundColor DarkYellow
        }
    } else {
        Write-Host ""
        Write-Host "Queue file not found yet: $queueFile" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Recent scheduler log:" -ForegroundColor White
    $scheduler = Join-Path $logRoot 'scheduler.log'
    if (Test-Path -LiteralPath $scheduler) {
        Get-Content -LiteralPath $scheduler -Tail 10 -Encoding UTF8 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }

    Write-Host ""
    Write-Host "Generated notes: " -NoNewline
    $notes = @(Get-ChildItem -LiteralPath $studyRoot -Recurse -Filter "*_reading-note.md" -ErrorAction SilentlyContinue)
    Write-Host $notes.Count -ForegroundColor Green
    Write-Host ""
    Write-Host ("Refreshing every {0} seconds. Close window to stop monitoring only." -f $effectiveRefreshSeconds) -ForegroundColor DarkGray
    Start-Sleep -Seconds $effectiveRefreshSeconds
}
