param(
    [int]$WorkerCount = 0,
    [string]$ConfigFile,
    [int]$PollSeconds = 20,
    [int]$TimeoutSeconds = 0,
    [switch]$PreserveCollectionLimit
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageDir = Split-Path -Parent $scriptDir
if (-not $ConfigFile) { $ConfigFile = Join-Path $packageDir 'configs\paper-reading-pool-config.json' }
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Config file not found: $ConfigFile" }
$config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json

function Write-PoolConfig {
    param([Parameter(Mandatory = $true)]$Config)
    $json = $Config | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($ConfigFile, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Get-ConfigInt {
    param([object]$Value, [int]$Default)
    if ($null -eq $Value -or [string]$Value -eq '') { return $Default }
    return [int]$Value
}

function Invoke-QueueStatus {
    $runner = Join-Path $scriptDir 'run-zotero-paper-reading-pool.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $runner -ConfigFile $ConfigFile -QueueStatus
}

if ($WorkerCount -le 0) { $WorkerCount = Get-ConfigInt $config.workerCount 1 }
$maxSupportedWorkers = Get-ConfigInt $config.maxSupportedWorkers 50
if ($WorkerCount -lt 1) { throw 'WorkerCount must be >= 1.' }
if ($WorkerCount -gt $maxSupportedWorkers) { throw "WorkerCount $WorkerCount exceeds maxSupportedWorkers $maxSupportedWorkers." }
if ($PollSeconds -lt 1) { throw 'PollSeconds must be >= 1.' }

$originalMaxRunningPerCollection = Get-ConfigInt $config.maxRunningPerCollection 1
$changedCollectionLimit = $false
if (-not $PreserveCollectionLimit -and $originalMaxRunningPerCollection -lt $WorkerCount) {
    $config.maxRunningPerCollection = $WorkerCount
    Write-PoolConfig $config
    $changedCollectionLimit = $true
    Write-Host "Temporarily raised MaxRunningPerCollection from $originalMaxRunningPerCollection to $WorkerCount for one-shot parallelism." -ForegroundColor Yellow
}

$workerScript = Join-Path $scriptDir 'run-zotero-paper-reading-pool.ps1'
$workerIdPrefix = if ($config.workerIdPrefix) { [string]$config.workerIdPrefix } else { 'worker' }
$workerIdDigits = Get-ConfigInt $config.workerIdDigits 2
$workerIdFormat = '{0}-{1:D' + $workerIdDigits + '}'

Write-Host "Starting one-shot workers: $WorkerCount" -ForegroundColor Cyan
$jobs = @()
for ($i = 1; $i -le $WorkerCount; $i++) {
    $workerId = $workerIdFormat -f $workerIdPrefix, $i
    $jobs += Start-Job -Name "zotero-reader-once-$workerId" -ScriptBlock {
        param($PackageDir, $ConfigPath, $WorkerScriptPath, $WorkerIdValue)
        foreach ($name in @('NO_PROXY', 'no_proxy')) {
            $value = [Environment]::GetEnvironmentVariable($name, 'Process')
            $parts = @()
            if ($value) { $parts = @($value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            foreach ($entry in @('localhost', '127.0.0.1')) {
                if ($parts -notcontains $entry) { $parts += $entry }
            }
            [Environment]::SetEnvironmentVariable($name, ($parts -join ','), 'Process')
        }
        Set-Location -LiteralPath $PackageDir
        powershell -NoProfile -ExecutionPolicy Bypass -File $WorkerScriptPath -ConfigFile $ConfigPath -Once -WorkerId $WorkerIdValue
        $code = $LASTEXITCODE
        if ($code -ne 0) { throw "Worker $WorkerIdValue failed with exit code $code" }
    } -ArgumentList $packageDir,$ConfigFile,$workerScript,$workerId
    Write-Host "Started: $workerId"
}

$started = Get-Date
while (@($jobs | Where-Object { $_.State -in @('Running', 'NotStarted') }).Count -gt 0) {
    Start-Sleep -Seconds $PollSeconds
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    Write-Host "--- elapsed ${elapsed}s ---" -ForegroundColor DarkCyan
    Get-Job -Id ($jobs.Id) | Select-Object Id,Name,State,HasMoreData | Format-Table -AutoSize
    try { Invoke-QueueStatus } catch { Write-Host "QueueStatus failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    if ($TimeoutSeconds -gt 0 -and $elapsed -ge $TimeoutSeconds) {
        Write-Host "Timeout reached; stopping unfinished jobs." -ForegroundColor Red
        $jobs | Where-Object { $_.State -in @('Running', 'NotStarted') } | Stop-Job
        break
    }
}

$failed = 0
Write-Host '--- worker job outputs ---' -ForegroundColor Cyan
foreach ($job in $jobs) {
    Write-Host "--- $($job.Name): $($job.State) ---"
    $output = Receive-Job -Id $job.Id -Keep 2>&1
    if ($output) { $output | ForEach-Object { $_ } }
    if ($job.State -ne 'Completed') { $failed++ }
}
Remove-Job -Id ($jobs.Id) -Force -ErrorAction SilentlyContinue

if ($changedCollectionLimit) {
    $config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $config.maxRunningPerCollection = $originalMaxRunningPerCollection
    Write-PoolConfig $config
    Write-Host "Restored MaxRunningPerCollection to $originalMaxRunningPerCollection." -ForegroundColor Yellow
}

Write-Host '--- final queue status ---' -ForegroundColor Cyan
Invoke-QueueStatus
if ($failed -gt 0) { throw "$failed one-shot worker job(s) did not complete cleanly." }
