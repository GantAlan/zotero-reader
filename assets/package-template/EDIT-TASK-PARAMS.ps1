param(
    [switch]$RestartAfterApply,
    [switch]$StartAfterApply,
    [switch]$StopAfterApply
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# =========================
# Task Parameter Table
# =========================

$TaskParams = [ordered]@{
    WorkerCount             = 1
    Model                   = 'mimo-v2.5'
    ReasoningEffort         = 'xhigh'
    WireApi                 = 'auto'
    EnableSearch            = $true
    WorkerSleepSeconds      = 30
    MonitorRefreshSeconds   = 60
    MaxAttempts             = 3
    LeaseHours              = 3
    MaxRunningPerCollection = 1
    Sandbox                 = 'workspace-write'
    AskForApproval          = 'never'
}

# Usually do not edit below this line.
$packageDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configFile = Join-Path $packageDir 'configs\paper-reading-pool-config.json'
$manageScript = Join-Path $packageDir 'scripts\manage-paper-reading-pool.ps1'

function Assert-OneActionSwitch {
    $count = @($RestartAfterApply, $StartAfterApply, $StopAfterApply | Where-Object { $_ }).Count
    if ($count -gt 1) {
        throw 'Use only one action switch: -RestartAfterApply, -StartAfterApply, or -StopAfterApply.'
    }
}

function Assert-TaskParams {
    param($Params, [int]$MaxSupportedWorkers)

    $validReasoningEfforts = @('minimal', 'low', 'medium', 'high', 'xhigh')
    $validWireApis = @('auto', 'responses', 'chat')
    $validAskForApproval = @('never', 'on-request', 'on-failure', 'untrusted')
    $validSandbox = @('read-only', 'workspace-write', 'danger-full-access')

    if ([int]$Params['WorkerCount'] -lt 1) { throw 'WorkerCount must be >= 1.' }
    if ([int]$Params['WorkerCount'] -gt $MaxSupportedWorkers) {
        throw "WorkerCount $($Params['WorkerCount']) exceeds maxSupportedWorkers $MaxSupportedWorkers in $configFile."
    }
    if (-not $Params['Model']) { throw 'Model cannot be empty.' }
    if ($validReasoningEfforts -notcontains $Params['ReasoningEffort']) {
        throw "ReasoningEffort must be one of: $($validReasoningEfforts -join ', ')"
    }
    if ($validWireApis -notcontains $Params['WireApi']) {
        throw "WireApi must be one of: $($validWireApis -join ', ')"
    }
    if ($validAskForApproval -notcontains $Params['AskForApproval']) {
        throw "AskForApproval must be one of: $($validAskForApproval -join ', ')"
    }
    if ($validSandbox -notcontains $Params['Sandbox']) {
        throw "Sandbox must be one of: $($validSandbox -join ', ')"
    }
    if ([int]$Params['WorkerSleepSeconds'] -lt 1) { throw 'WorkerSleepSeconds must be >= 1.' }
    if ([int]$Params['MonitorRefreshSeconds'] -lt 1) { throw 'MonitorRefreshSeconds must be >= 1.' }
    if ([int]$Params['MaxAttempts'] -lt 1) { throw 'MaxAttempts must be >= 1.' }
    if ([int]$Params['LeaseHours'] -lt 1) { throw 'LeaseHours must be >= 1.' }
    if ([int]$Params['MaxRunningPerCollection'] -lt 1) { throw 'MaxRunningPerCollection must be >= 1.' }
}

function Set-ConfigValue {
    param($Config, $Params)

    if (-not ($Config.PSObject.Properties.Name -contains 'monitorRefreshSeconds')) {
        $Config | Add-Member -MemberType NoteProperty -Name monitorRefreshSeconds -Value 5
    }
    $Config.workerCount = [int]$Params['WorkerCount']
    $Config.codexModel = [string]$Params['Model']
    $Config.codexReasoningEffort = [string]$Params['ReasoningEffort']
    $Config.codexWireApi = [string]$Params['WireApi']
    $Config.codexEnableSearch = [bool]$Params['EnableSearch']
    $Config.workerSleepSeconds = [int]$Params['WorkerSleepSeconds']
    $Config.monitorRefreshSeconds = [int]$Params['MonitorRefreshSeconds']
    $Config.maxAttempts = [int]$Params['MaxAttempts']
    $Config.leaseHours = [int]$Params['LeaseHours']
    $Config.maxRunningPerCollection = [int]$Params['MaxRunningPerCollection']
    $Config.codexSandbox = [string]$Params['Sandbox']
    $Config.codexAskForApproval = [string]$Params['AskForApproval']
}

function Show-TaskParams {
    param($Params, [string]$ConfigPath)

    Write-Host 'Updated task parameters:' -ForegroundColor Green
    Write-Host "  Config: $ConfigPath"
    Write-Host ''
    Write-Host '  Runtime'
    Write-Host "    WorkerCount:             $($Params['WorkerCount'])"
    Write-Host "    WorkerSleepSeconds:      $($Params['WorkerSleepSeconds'])"
    Write-Host "    MonitorRefreshSeconds:   $($Params['MonitorRefreshSeconds'])"
    Write-Host "    MaxRunningPerCollection: $($Params['MaxRunningPerCollection'])"
    Write-Host ''
    Write-Host '  Model'
    Write-Host "    Model:                   $($Params['Model'])"
    Write-Host "    ReasoningEffort:         $($Params['ReasoningEffort'])"
    Write-Host "    WireApi:                 $($Params['WireApi'])"
    Write-Host "    EnableSearch:            $($Params['EnableSearch'])"
    Write-Host ''
    Write-Host '  Reliability'
    Write-Host "    MaxAttempts:             $($Params['MaxAttempts'])"
    Write-Host "    LeaseHours:              $($Params['LeaseHours'])"
    Write-Host ''
    Write-Host '  Codex Safety'
    Write-Host "    Sandbox:                 $($Params['Sandbox'])"
    Write-Host "    AskForApproval:          $($Params['AskForApproval'])"
}

if (-not (Test-Path -LiteralPath $configFile)) { throw "Config file not found: $configFile" }
if (-not (Test-Path -LiteralPath $manageScript)) { throw "Manage script not found: $manageScript" }

Assert-OneActionSwitch

$config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
$maxSupportedWorkers = if ($config.maxSupportedWorkers) { [int]$config.maxSupportedWorkers } else { 50 }
Assert-TaskParams -Params $TaskParams -MaxSupportedWorkers $maxSupportedWorkers

Set-ConfigValue -Config $config -Params $TaskParams

$json = $config | ConvertTo-Json -Depth 30
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($configFile, $json + [Environment]::NewLine, $utf8NoBom)

Show-TaskParams -Params $TaskParams -ConfigPath $configFile

if ($RestartAfterApply) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $manageScript -Action restart
} elseif ($StartAfterApply) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $manageScript -Action start
} elseif ($StopAfterApply) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $manageScript -Action stop
} else {
    Write-Host ''
    Write-Host 'Parameters saved. Existing running workers keep old settings until restart.' -ForegroundColor Yellow
    Write-Host 'To restart with new settings, run:'
    Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File ".\EDIT-TASK-PARAMS.ps1" -RestartAfterApply'
}
