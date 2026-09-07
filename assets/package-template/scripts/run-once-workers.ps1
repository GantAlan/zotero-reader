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
    if ($LASTEXITCODE -ne 0) { throw "Queue status failed with exit code $LASTEXITCODE." }
}

if ($WorkerCount -le 0) { $WorkerCount = Get-ConfigInt $config.workerCount 1 }
$maxSupportedWorkers = Get-ConfigInt $config.maxSupportedWorkers 50
if ($WorkerCount -lt 1) { throw 'WorkerCount must be >= 1.' }
if ($WorkerCount -gt $maxSupportedWorkers) { throw "WorkerCount $WorkerCount exceeds maxSupportedWorkers $maxSupportedWorkers." }
if ($PollSeconds -lt 1) { throw 'PollSeconds must be >= 1.' }
if ($TimeoutSeconds -lt 0) { throw 'TimeoutSeconds must be >= 0.' }

$originalMaxRunningPerCollection = Get-ConfigInt $config.maxRunningPerCollection 1
$changedCollectionLimit = $false
$jobs = @()
$failedJobs = 0
$runError = $null

try {
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
            & powershell -NoProfile -ExecutionPolicy Bypass -File $WorkerScriptPath -ConfigFile $ConfigPath -Once -WorkerId $WorkerIdValue
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
            Write-Host 'Timeout reached; stopping unfinished jobs.' -ForegroundColor Red
            $jobs | Where-Object { $_.State -in @('Running', 'NotStarted') } | Stop-Job -ErrorAction SilentlyContinue
            break
        }
    }
} catch {
    $runError = $_.Exception.Message
} finally {
    if (@($jobs).Count -gt 0) {
        $jobs | Where-Object { $_.State -in @('Running', 'NotStarted') } | Stop-Job -ErrorAction SilentlyContinue
        Write-Host '--- worker job outputs ---' -ForegroundColor Cyan
        foreach ($job in $jobs) {
            Write-Host "--- $($job.Name): $($job.State) ---"
            try {
                $output = Receive-Job -Id $job.Id -Keep -ErrorAction Continue 2>&1
                if ($output) { $output | ForEach-Object { $_ } }
            } catch {
                Write-Host "Unable to receive $($job.Name): $($_.Exception.Message)" -ForegroundColor Yellow
            }
            if ($job.State -ne 'Completed') { $failedJobs++ }
        }
        Remove-Job -Id ($jobs.Id) -Force -ErrorAction SilentlyContinue
    }

    if ($changedCollectionLimit) {
        try {
            $restoreConfig = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $restoreConfig.maxRunningPerCollection = $originalMaxRunningPerCollection
            Write-PoolConfig $restoreConfig
            Write-Host "Restored MaxRunningPerCollection to $originalMaxRunningPerCollection." -ForegroundColor Yellow
        } catch {
            $restoreError = "Unable to restore MaxRunningPerCollection: $($_.Exception.Message)"
            if ($runError) { $runError += " | $restoreError" } else { $runError = $restoreError }
        }
    }
}

Write-Host '--- final queue status ---' -ForegroundColor Cyan
try { Invoke-QueueStatus } catch {
    $statusError = "Final queue status failed: $($_.Exception.Message)"
    if ($runError) { $runError += " | $statusError" } else { $runError = $statusError }
}

if ($failedJobs -gt 0) {
    $jobError = "$failedJobs one-shot worker job(s) did not complete cleanly."
    if ($runError) { $runError += " | $jobError" } else { $runError = $jobError }
}
if ($runError) { throw $runError }
