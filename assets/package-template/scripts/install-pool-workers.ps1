param(
    [string]$TaskPrefix = "ZoteroPaperReadingPool",
    [int]$WorkerCount = 0,
    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageDir = Split-Path -Parent $scriptDir
if (-not $ConfigFile) { $ConfigFile = Join-Path $packageDir 'configs\paper-reading-pool-config.json' }
$worker = Join-Path $scriptDir 'run-zotero-paper-reading-pool.ps1'
if (-not (Test-Path -LiteralPath $worker)) { throw "Worker script not found: $worker" }
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Config file not found: $ConfigFile" }
$config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-ConfigInt {
    param([object]$Value, [int]$Default)
    if ($null -eq $Value -or $Value -eq '') { return $Default }
    return [int]$Value
}

if ($WorkerCount -le 0) { $WorkerCount = Get-ConfigInt $config.workerCount 5 }
if ($TaskPrefix -eq 'ZoteroPaperReadingPool' -and $config.taskPrefix) { $TaskPrefix = [string]$config.taskPrefix }
$maxSupportedWorkers = Get-ConfigInt $config.maxSupportedWorkers 40
if ($WorkerCount -lt 1) { throw "WorkerCount must be >= 1." }
if ($WorkerCount -gt $maxSupportedWorkers) { throw "WorkerCount $WorkerCount exceeds maxSupportedWorkers $maxSupportedWorkers in $ConfigFile." }
$workerIdPrefix = if ($config.workerIdPrefix) { [string]$config.workerIdPrefix } else { 'worker' }
$workerIdDigits = Get-ConfigInt $config.workerIdDigits 2
$workerIdFormat = '{0}-{1:D' + $workerIdDigits + '}'

for ($i = 1; $i -le $WorkerCount; $i++) {
    $workerId = $workerIdFormat -f $workerIdPrefix, $i
    $taskName = '{0}_{1:D2}' -f $TaskPrefix, $i
    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$worker`" -ConfigFile `"$ConfigFile`" -WorkerId `"$workerId`"" `
        -WorkingDirectory $packageDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet `
        -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Description "Zotero/Codex global paper reading pool worker $workerId." `
        -Force | Out-Null
    Write-Host "Created task: $taskName ($workerId)"
}
