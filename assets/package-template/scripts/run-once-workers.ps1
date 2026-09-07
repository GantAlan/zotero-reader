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
$ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path
$config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$runtimeCommon = Join-Path $scriptDir 'pool-runtime-common.ps1'
if (-not (Test-Path -LiteralPath $runtimeCommon)) { throw "Runtime helper not found: $runtimeCommon" }
. $runtimeCommon
$defaults = Get-PoolDefaults -PackageDir $packageDir
$identity = Get-PoolProjectIdentity -Config $config -PackageDir $packageDir
$root = $identity.Root

function Invoke-QueueStatus {
    $runner = Join-Path $scriptDir 'run-zotero-paper-reading-pool.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -ConfigFile $ConfigFile -QueueStatus
    if ($LASTEXITCODE -ne 0) { throw "Queue status failed with exit code $LASTEXITCODE." }
}

if ($WorkerCount -le 0) { $WorkerCount = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'workerCount' -Fallback 1 }
$maxSupportedWorkers = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'maxSupportedWorkers' -Fallback 50
if ($WorkerCount -lt 1) { throw 'WorkerCount must be >= 1.' }
if ($WorkerCount -gt $maxSupportedWorkers) { throw "WorkerCount $WorkerCount exceeds maxSupportedWorkers $maxSupportedWorkers." }
if ($PollSeconds -lt 1) { throw 'PollSeconds must be >= 1.' }
if ($TimeoutSeconds -lt 0) { throw 'TimeoutSeconds must be >= 0.' }

$originalMaxRunningPerCollection = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'maxRunningPerCollection' -Fallback 1
$collectionLimitOverride = 0
$jobs = @()
$failedJobs = 0
$runError = $null
$runId = Get-PoolRunId
$workerIdPrefix = [string](Get-PoolConfigValue -Config $config -Defaults $defaults -Name 'workerIdPrefix' -Fallback 'worker')
$workerIdDigits = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'workerIdDigits' -Fallback 2
$workerIdFormat = '{0}-{1:D' + $workerIdDigits + '}'
$workerIds = @()
for ($i = 1; $i -le $WorkerCount; $i++) { $workerIds += ($workerIdFormat -f $workerIdPrefix, $i) }

try {
    Invoke-PoolProjectMutex -Config $config -Identity $identity -Body {
        if (Test-PoolRunReservation -Config $config -Identity $identity -ExcludeRunId $runId) {
            throw "Another run is already reserved for project '$($identity.ProjectId)'. Stop it or wait for its reservation to expire."
        }
        $active = @(Get-PoolActiveWorkerStates -Config $config -Identity $identity)
        if ($active.Count -gt 0) {
            $activeText = ($active | ForEach-Object { "$($_.workerId) pid=$($_.pid) run=$($_.runId)" }) -join '; '
            throw "Active workers already exist for project '$($identity.ProjectId)': $activeText"
        }
        New-PoolRunState -Config $config -Identity $identity -RunId $runId -WorkerIds $workerIds | Out-Null
    }
    if (-not $PreserveCollectionLimit -and $originalMaxRunningPerCollection -lt $WorkerCount) {
        $collectionLimitOverride = $WorkerCount
        Write-Host "Using MaxRunningPerCollection=$collectionLimitOverride for one-shot parallelism without changing the config file." -ForegroundColor Yellow
    }

    $workerScript = Join-Path $scriptDir 'run-zotero-paper-reading-pool.ps1'
    Write-Host "Starting one-shot workers: $WorkerCount (runId=$runId)" -ForegroundColor Cyan
    for ($i = 0; $i -lt $workerIds.Count; $i++) {
        $workerId = $workerIds[$i]
        $jobs += Start-Job -Name "zotero-reader-once-$workerId" -ScriptBlock {
            param($PackageDir, $ConfigPath, $WorkerScriptPath, $WorkerIdValue, $RunIdValue, $CollectionLimitOverrideValue)
            foreach ($name in @('NO_PROXY', 'no_proxy')) {
                $value = [Environment]::GetEnvironmentVariable($name, 'Process')
                $parts = @()
                if ($value) { $parts = @($value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                foreach ($entry in @('localhost', '127.0.0.1')) { if ($parts -notcontains $entry) { $parts += $entry } }
                [Environment]::SetEnvironmentVariable($name, ($parts -join ','), 'Process')
            }
            Set-Location -LiteralPath $PackageDir
            $workerArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $WorkerScriptPath, '-ConfigFile', $ConfigPath, '-Once', '-WorkerId', $WorkerIdValue, '-RunId', $RunIdValue)
            if ($CollectionLimitOverrideValue -gt 0) { $workerArguments += @('-MaxRunningPerCollectionOverride', [string]$CollectionLimitOverrideValue) }
            & powershell.exe @workerArguments
            $code = $LASTEXITCODE
            if ($code -ne 0) { throw "Worker $WorkerIdValue failed with exit code $code" }
        } -ArgumentList $packageDir, $ConfigFile, $workerScript, $workerId, $runId, $collectionLimitOverride
        Write-Host "Started: $workerId"
    }

    $started = Get-Date
    while (@($jobs | Where-Object { $_.State -in @('Running', 'NotStarted') }).Count -gt 0) {
        Start-Sleep -Seconds $PollSeconds
        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        Write-Host ("--- elapsed {0}s ---" -f $elapsed) -ForegroundColor DarkCyan
        Get-Job -Id ($jobs.Id) | Select-Object Id,Name,State,HasMoreData | Format-Table -AutoSize
        try { Invoke-QueueStatus } catch { Write-Host "QueueStatus failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        if ($TimeoutSeconds -gt 0 -and $elapsed -ge $TimeoutSeconds) {
            Write-Host 'Timeout reached; stopping unfinished jobs.' -ForegroundColor Red
            $jobs | Where-Object { $_.State -in @('Running', 'NotStarted') } | Stop-Job -ErrorAction SilentlyContinue
            $runError = "Timeout reached after $TimeoutSeconds seconds."
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
            } catch { Write-Host "Unable to receive $($job.Name): $($_.Exception.Message)" -ForegroundColor Yellow }
            if ($job.State -ne 'Completed') { $failedJobs++ }
        }
        Remove-Job -Id ($jobs.Id) -Force -ErrorAction SilentlyContinue
    }
}

if ($runError) {
    $activeAfterStop = @(Get-PoolActiveWorkerStates -Config $config -Identity $identity | Where-Object { $_.runId -eq $runId })
    foreach ($state in $activeAfterStop) {
        if (Test-PoolProcessIdentity -State $state) {
            foreach ($child in @(Get-PoolProcessDescendants -RootProcessId ([int]$state.pid) | Sort-Object ProcessId -Descending)) {
                Stop-Process -Id ([int]$child.ProcessId) -Force -ErrorAction SilentlyContinue
            }
            Stop-Process -Id ([int]$state.pid) -Force -ErrorAction SilentlyContinue
        }
        try { Update-PoolWorkerState -Config $config -Identity $identity -RunId ([string]$state.runId) -WorkerId ([string]$state.workerId) -Status 'stopped' -ExitCode 1 } catch {}
    }
}

if ($failedJobs -gt 0) {
    $jobError = "$failedJobs one-shot worker job(s) did not complete cleanly."
    if ($runError) { $runError += " | $jobError" } else { $runError = $jobError }
}
try {
    Set-PoolRunStatus -Config $config -Identity $identity -RunId $runId -Status $(if ($runError) { 'failed' } else { 'completed' })
} catch {}
Write-Host '--- final queue status ---' -ForegroundColor Cyan
try { Invoke-QueueStatus } catch {
    $statusError = "Final queue status failed: $($_.Exception.Message)"
    if ($runError) { $runError += " | $statusError" } else { $runError = $statusError }
}
if ($runError) { throw $runError }
