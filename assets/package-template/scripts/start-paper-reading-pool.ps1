param(
    [int]$WorkerCount = 0,
    [string]$ConfigFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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

$workerScript = Join-Path $scriptDir 'run-zotero-paper-reading-pool.ps1'
if (-not (Test-Path -LiteralPath $workerScript)) { throw "Worker script not found: $workerScript" }
$workerScript = (Resolve-Path -LiteralPath $workerScript).Path

$configuredWorkerCount = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'workerCount' -Fallback 1
if ($WorkerCount -le 0) { $WorkerCount = $configuredWorkerCount }
$maxSupportedWorkers = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'maxSupportedWorkers' -Fallback 50
if ($WorkerCount -lt 1) { throw 'WorkerCount must be >= 1.' }
if ($WorkerCount -gt $maxSupportedWorkers) { throw "WorkerCount $WorkerCount exceeds maxSupportedWorkers $maxSupportedWorkers in $ConfigFile." }

$workerIdPrefix = [string](Get-PoolConfigValue -Config $config -Defaults $defaults -Name 'workerIdPrefix' -Fallback 'worker')
$workerIdDigits = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'workerIdDigits' -Fallback 2
$workerIdFormat = '{0}-{1:D' + $workerIdDigits + '}'
$workerIds = @()
for ($i = 1; $i -le $WorkerCount; $i++) { $workerIds += ($workerIdFormat -f $workerIdPrefix, $i) }

$runId = Get-PoolRunId
$launchedProcesses = @()
try {
    Invoke-PoolProjectMutex -Config $config -Identity $identity -Body {
        Invoke-PoolLogCleanup -Config $config -Defaults $defaults -RootPath $root
        if (Test-PoolRunReservation -Config $config -Identity $identity -ExcludeRunId $runId) {
            throw "Another run is already reserved for project '$($identity.ProjectId)'. Stop it or wait for its reservation to expire."
        }
        $active = @(Get-PoolActiveWorkerStates -Config $config -Identity $identity)
        if ($active.Count -gt 0) {
            $activeText = ($active | ForEach-Object { "$($_.workerId) pid=$($_.pid) run=$($_.runId)" }) -join '; '
            throw "Active workers already exist for project '$($identity.ProjectId)': $activeText. Stop them before starting another run."
        }
        New-PoolRunState -Config $config -Identity $identity -RunId $runId -WorkerIds $workerIds | Out-Null
        for ($i = 0; $i -lt $workerIds.Count; $i++) {
            $workerId = $workerIds[$i]
            $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $workerScript + '" -ConfigFile "' + $ConfigFile + '" -WorkerId "' + $workerId + '" -RunId "' + $runId + '"'
            $process = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments -WorkingDirectory $packageDir -PassThru
            $launchedProcesses += [pscustomobject]@{ pid = $process.Id; workerId = $workerId; runId = $runId; workerScript = $workerScript; configFile = $ConfigFile; processStartTimeUtc = $null; runIdArgumentVerified = $true }
            Write-Host "Started: $workerId (runId=$runId)"
        }
        $deadline = (Get-Date).AddSeconds(30)
        do {
            Start-Sleep -Milliseconds 250
            $activeForRun = @(Get-PoolActiveWorkerStates -Config $config -Identity $identity | Where-Object { $_.runId -eq $runId -and $workerIds -contains $_.workerId })
        } while ($activeForRun.Count -lt $workerIds.Count -and (Get-Date) -lt $deadline)
        if ($activeForRun.Count -lt $workerIds.Count) {
            $ready = ($activeForRun | ForEach-Object { $_.workerId }) -join ', '
            throw "Only $($activeForRun.Count)/$($workerIds.Count) workers registered for runId=$runId. Ready: $ready"
        }
    }
} catch {
    $activeForRun = @(Get-PoolActiveWorkerStates -Config $config -Identity $identity | Where-Object { $_.runId -eq $runId })
    $cleanupStates = @($activeForRun) + @($launchedProcesses)
    foreach ($state in $cleanupStates) {
        if (Test-PoolProcessIdentity -State $state) {
            foreach ($child in @(Get-PoolProcessDescendants -RootProcessId ([int]$state.pid) | Sort-Object ProcessId -Descending)) {
                Stop-Process -Id ([int]$child.ProcessId) -Force -ErrorAction SilentlyContinue
            }
            Stop-Process -Id ([int]$state.pid) -Force -ErrorAction SilentlyContinue
        }
        if ($state.workerId) {
            try { Update-PoolWorkerState -Config $config -Identity $identity -RunId ([string]$runId) -WorkerId ([string]$state.workerId) -Status 'stopped' -ExitCode 1 } catch {}
        }
    }
    try { Set-PoolRunStatus -Config $config -Identity $identity -RunId $runId -Status 'failed' } catch {}
    throw
}

$activeAfter = @(Get-PoolActiveWorkerStates -Config $config -Identity $identity | Where-Object { $_.runId -eq $runId })
Write-Host ("Project: {0} | Runtime namespace: {1}" -f $identity.ProjectId, $identity.RuntimeNamespace)
Write-Host ("RunId: {0}" -f $runId)
Write-Host ("Active verified worker states: {0}/{1}" -f $activeAfter.Count, $WorkerCount)
