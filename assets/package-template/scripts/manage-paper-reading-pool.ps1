param(
    [ValidateSet('status', 'configure', 'start', 'stop', 'restart')]
    [string]$Action = 'status',

    [int]$WorkerCount = 0,
    [string]$Model,
    [string]$ReasoningEffort,
    [string]$WireApi,
    [string]$AskForApproval,
    [string]$Sandbox,
    [Nullable[bool]]$EnableSearch,

    [string]$ConfigFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageDir = Split-Path -Parent $scriptDir
if (-not $ConfigFile) { $ConfigFile = Join-Path $packageDir 'configs\paper-reading-pool-config.json' }
$startScript = Join-Path $scriptDir 'start-paper-reading-pool.ps1'
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Config file not found: $ConfigFile" }
$ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path
if (-not (Test-Path -LiteralPath $startScript)) { throw "Start script not found: $startScript" }
$config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$runtimeCommon = Join-Path $scriptDir 'pool-runtime-common.ps1'
if (-not (Test-Path -LiteralPath $runtimeCommon)) { throw "Runtime helper not found: $runtimeCommon" }
. $runtimeCommon
$defaults = Get-PoolDefaults -PackageDir $packageDir
$identity = Get-PoolProjectIdentity -Config $config -PackageDir $packageDir
$root = $identity.Root

function Read-PoolConfig { Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json }
function Write-PoolConfig {
    param([Parameter(Mandatory = $true)]$Config)
    $json = $Config | ConvertTo-Json -Depth 40
    [System.IO.File]::WriteAllText($ConfigFile, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Get-QueueFilePath {
    $current = Read-PoolConfig
    $rootValue = if ($current.root) { [string]$current.root } else { '.' }
    $currentRoot = Resolve-PoolPath -PathValue $rootValue -BasePath $packageDir
    return (Resolve-PoolPath -PathValue ([string]$current.queueFile) -BasePath $currentRoot)
}

function Get-ActiveStates { @(Get-PoolActiveWorkerStates -Config (Read-PoolConfig) -Identity $identity) }

function Release-RunningQueueItems {
    $queueFile = Get-QueueFilePath
    if (-not (Test-Path -LiteralPath $queueFile)) { return }
    $lastError = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $queue = Get-Content -LiteralPath $queueFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $released = 0
            foreach ($item in $queue.items) {
                if ($item.status -eq 'running') {
                    $item.status = 'pending'
                    $item.lastError = 'Released by manage-paper-reading-pool stop/restart.'
                    $item.failureCode = 'stopped_by_user'
                    $item.workerId = $null
                    $item.runId = $null
                    $released++
                }
            }
            $queue.updatedAt = (Get-Date -Format 'yyyy/MM/dd HH:mm:ss')
            Write-PoolJsonAtomic -Path $queueFile -Data $queue
            Write-Host ('Released running queue items: {0}' -f $released)
            return
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }
    throw "Could not release running queue items after retries: $lastError"
}

function Show-PoolStatus {
    $current = Read-PoolConfig
    $active = @(Get-PoolActiveWorkerStates -Config $current -Identity $identity)
    $queueFile = Get-QueueFilePath
    $model = [string](Get-PoolConfigValue -Config $current -Defaults $defaults -Name 'codexModel' -Fallback 'mimo-v2.5')
    $configuredWireApi = [string](Get-PoolConfigValue -Config $current -Defaults $defaults -Name 'codexWireApi' -Fallback 'auto')
    Write-Host ('Project: {0}' -f $identity.ProjectId)
    Write-Host ('Runtime namespace: {0}' -f $identity.RuntimeNamespace)
    Write-Host ('Configured workerCount: {0}' -f (Get-PoolConfigInt -Config $current -Defaults $defaults -Name 'workerCount' -Fallback 1))
    Write-Host ('Configured model: {0}' -f $model)
    Write-Host ('Configured reasoning effort: {0}' -f (Get-PoolConfigValue -Config $current -Defaults $defaults -Name 'codexReasoningEffort' -Fallback 'xhigh'))
    Write-Host ('Configured wire API: {0}' -f $configuredWireApi)
    Write-Host ('Configured sandbox: {0}' -f (Get-PoolConfigValue -Config $current -Defaults $defaults -Name 'codexSandbox' -Fallback 'workspace-write'))
    Write-Host ('Configured search: {0}' -f (Get-PoolConfigBool -Config $current -Defaults $defaults -Name 'codexEnableSearch' -Fallback $true))
    Write-Host ('Running verified worker processes: {0}' -f $active.Count)
    foreach ($state in $active) { Write-Host ("  {0} pid={1} runId={2} status={3}" -f $state.workerId, $state.pid, $state.runId, $state.status) }
    Write-Host ('Project mutex: {0}' -f (Get-PoolProjectMutexName -Config $current -Identity $identity))
    Write-Host ('Queue mutex: {0}' -f (Get-PoolQueueMutexName -Config $current -Identity $identity))
    if (Test-Path -LiteralPath $queueFile) {
        $queue = Get-Content -LiteralPath $queueFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ('Queue: total={0} pdfReady={1} excludedPdf={2}' -f $queue.total, $queue.pdfBackedItems, $queue.excludedPdfCount)
        $queue.items | Group-Object status | Select-Object Name, Count | Sort-Object Name | Format-Table -AutoSize
        if ($queue.pdfAvailabilityCounts) { Write-Host ('PDF availability: ' + ($queue.pdfAvailabilityCounts | ConvertTo-Json -Compress)) }
    }
}

function Update-PoolConfig {
    $current = Read-PoolConfig
    $changed = $false
    if ($WorkerCount -gt 0) {
        $maxSupportedWorkers = Get-PoolConfigInt -Config $current -Defaults $defaults -Name 'maxSupportedWorkers' -Fallback 50
        if ($WorkerCount -gt $maxSupportedWorkers) { throw "WorkerCount $WorkerCount exceeds maxSupportedWorkers $maxSupportedWorkers." }
        $current.workerCount = $WorkerCount; $changed = $true
    }
    if ($Model) { $current.codexModel = $Model; $changed = $true }
    if ($ReasoningEffort) { $current.codexReasoningEffort = $ReasoningEffort; $changed = $true }
    if ($WireApi) {
        $normalized = $WireApi.Trim().ToLowerInvariant()
        if ($normalized -eq 'response') { $normalized = 'responses' }
        if ($normalized -notin @('auto', 'responses', 'chat')) { throw 'WireApi must be one of: auto, responses, chat.' }
        $current.codexWireApi = $normalized; $changed = $true
    }
    if ($AskForApproval) { $current.codexAskForApproval = $AskForApproval; $changed = $true }
    if ($Sandbox) { $current.codexSandbox = $Sandbox; $changed = $true }
    if ($null -ne $EnableSearch) { $current.codexEnableSearch = [bool]$EnableSearch; $changed = $true }
    if ($changed) { Write-PoolConfig $current; Write-Host "Updated config: $ConfigFile" } else { Write-Host 'No config changes requested.' }
}

function Stop-Pool {
    $current = Read-PoolConfig
    $active = @(Get-PoolActiveWorkerStates -Config $current -Identity $identity)
    $stoppedDescendants = 0
    foreach ($state in $active) {
        if (-not (Test-PoolProcessIdentity -State $state)) { continue }
        $descendants = @(Get-PoolProcessDescendants -RootProcessId ([int]$state.pid))
        foreach ($process in ($descendants | Sort-Object ProcessId -Descending)) {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue
            $stoppedDescendants++
        }
        Stop-Process -Id ([int]$state.pid) -Force -ErrorAction SilentlyContinue
        try { Update-PoolWorkerState -Config $current -Identity $identity -RunId ([string]$state.runId) -WorkerId ([string]$state.workerId) -Status 'stopped' -ExitCode 1 } catch {}
    }
    foreach ($runId in @($active | ForEach-Object { [string]$_.runId } | Where-Object { $_ } | Select-Object -Unique)) {
        try { Set-PoolRunStatus -Config $current -Identity $identity -RunId $runId -Status 'stopped' } catch {}
    }
    Start-Sleep -Seconds 2
    Write-Host ('Stopped verified worker processes: {0}' -f $active.Count)
    Write-Host ('Stopped verified worker descendants: {0}' -f $stoppedDescendants)
    Release-RunningQueueItems
}

function Start-Pool {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startScript, '-ConfigFile', $ConfigFile)
    if ($WorkerCount -gt 0) { $arguments += @('-WorkerCount', [string]$WorkerCount) }
    if ($Force) { $arguments += '-Force' }
    & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "Start script failed with exit code $LASTEXITCODE." }
}

switch ($Action) {
    'status' { Show-PoolStatus }
    'configure' { Update-PoolConfig; Show-PoolStatus }
    'start' { Start-Pool; Show-PoolStatus }
    'stop' { Stop-Pool; Show-PoolStatus }
    'restart' { Update-PoolConfig; Stop-Pool; Start-Pool; Show-PoolStatus }
}
