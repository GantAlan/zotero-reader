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
$root = $packageDir
$startScript = Join-Path $scriptDir 'start-paper-reading-pool.ps1'
$workerScriptName = 'run-zotero-paper-reading-pool.ps1'

if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Config file not found: $ConfigFile" }
if (-not (Test-Path -LiteralPath $startScript)) { throw "Start script not found: $startScript" }

function Read-PoolConfig {
    Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-PoolConfig {
    param([Parameter(Mandatory = $true)]$Config)
    $json = $Config | ConvertTo-Json -Depth 20
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($ConfigFile, $json, $utf8NoBom)
}

function Get-ConfigInt {
    param([object]$Value, [int]$Default)
    if ($null -eq $Value -or $Value -eq '') { return $Default }
    return [int]$Value
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

function Get-PoolWorkerProcesses {
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^(powershell|pwsh)\.exe$' -and
        $_.CommandLine -like "*$workerScriptName*" -and
        $_.CommandLine -like "*${ConfigFile}*"
    }
}

function Get-PoolCodexProcesses {
    $config = Read-PoolConfig
    $logRoot = if ($config.logRoot) { [string]$config.logRoot } else { 'logs-global' }
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -like 'codex*' -and
        $_.CommandLine -like "*$root*" -and
        $_.CommandLine -like "*$logRoot*"
    }
}

function Get-QueueFilePath {
    $config = Read-PoolConfig
    if ([System.IO.Path]::IsPathRooted([string]$config.queueFile)) { return [string]$config.queueFile }
    return (Join-Path $root ([string]$config.queueFile))
}

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
                    $item.workerId = $null
                    $released++
                }
            }
            $queue.updatedAt = (Get-Date -Format 'yyyy/MM/dd HH:mm:ss')
            $json = $queue | ConvertTo-Json -Depth 20
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($queueFile, $json, $utf8NoBom)
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
    $config = Read-PoolConfig
    $workers = @(Get-PoolWorkerProcesses)
    $codex = @(Get-PoolCodexProcesses)
    $queueFile = Get-QueueFilePath

    $model = if ($config.codexModel) { [string]$config.codexModel } else { 'mimo-v2.5' }
    $configuredWireApi = if ($config.PSObject.Properties.Name -contains 'codexWireApi') { [string]$config.codexWireApi } else { 'auto' }
    $effectiveWireApi = Resolve-CodexWireApi -Model $model -ConfiguredWireApi $configuredWireApi

    Write-Host ('Configured workerCount: {0}' -f (Get-ConfigInt $config.workerCount 5))
    Write-Host ('Configured model: {0}' -f $model)
    Write-Host ('Configured reasoning effort: {0}' -f $(if ($config.codexReasoningEffort) { $config.codexReasoningEffort } else { 'xhigh' }))
    Write-Host ('Configured wire API: {0} (effective: {1})' -f $configuredWireApi, $effectiveWireApi)
    Write-Host ('Configured sandbox: {0}' -f $(if ($config.codexSandbox) { $config.codexSandbox } else { 'workspace-write' }))
    Write-Host ('Configured search: {0}' -f $(if ($null -ne $config.codexEnableSearch) { [bool]$config.codexEnableSearch } else { $true }))
    Write-Host ('Running worker processes: {0}' -f $workers.Count)
    Write-Host ('Running pool Codex processes: {0}' -f $codex.Count)

    if (Test-Path -LiteralPath $queueFile) {
        $queue = Get-Content -LiteralPath $queueFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host 'Queue status counts:'
        $queue.items | Group-Object status | Select-Object Name, Count | Sort-Object Name | Format-Table -AutoSize
    }
}

function Update-PoolConfig {
    $config = Read-PoolConfig
    $changed = $false

    if ($WorkerCount -gt 0) {
        $maxSupportedWorkers = Get-ConfigInt $config.maxSupportedWorkers 40
        if ($WorkerCount -gt $maxSupportedWorkers) { throw "WorkerCount $WorkerCount exceeds maxSupportedWorkers $maxSupportedWorkers." }
        $config.workerCount = $WorkerCount
        $changed = $true
    }
    if ($Model) { $config.codexModel = $Model; $changed = $true }
    if ($ReasoningEffort) { $config.codexReasoningEffort = $ReasoningEffort; $changed = $true }
    if ($WireApi) {
        $normalizedWireApi = $WireApi.Trim().ToLowerInvariant()
        if ($normalizedWireApi -eq 'response') { $normalizedWireApi = 'responses' }
        if ($normalizedWireApi -notin @('auto', 'responses', 'chat')) { throw 'WireApi must be one of: auto, responses, chat.' }
        $config.codexWireApi = $normalizedWireApi
        $changed = $true
    }
    if ($AskForApproval) { $config.codexAskForApproval = $AskForApproval; $changed = $true }
    if ($Sandbox) { $config.codexSandbox = $Sandbox; $changed = $true }
    if ($null -ne $EnableSearch) { $config.codexEnableSearch = [bool]$EnableSearch; $changed = $true }

    if ($changed) {
        Write-PoolConfig $config
        Write-Host "Updated config: $ConfigFile"
    } else {
        Write-Host 'No config changes requested.'
    }
}

function Stop-Pool {
    $workers = @(Get-PoolWorkerProcesses)
    $codex = @(Get-PoolCodexProcesses)
    foreach ($process in $codex) { Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    foreach ($process in $workers) { Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Write-Host ('Stopped pool Codex processes: {0}' -f $codex.Count)
    Write-Host ('Stopped worker processes: {0}' -f $workers.Count)
    Release-RunningQueueItems
}

function Start-Pool {
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $startScript, '-ConfigFile', $ConfigFile)
    if ($WorkerCount -gt 0) {
        $args += @('-WorkerCount', [string]$WorkerCount)
    }
    if ($Force) { $args += '-Force' }
    & powershell.exe @args
}

switch ($Action) {
    'status' { Show-PoolStatus }
    'configure' { Update-PoolConfig; Show-PoolStatus }
    'start' { Start-Pool; Show-PoolStatus }
    'stop' { Stop-Pool; Show-PoolStatus }
    'restart' { Update-PoolConfig; Stop-Pool; Start-Pool; Show-PoolStatus }
}
