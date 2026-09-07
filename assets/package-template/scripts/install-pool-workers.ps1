param(
    [string]$TaskPrefix,
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
$ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path
$config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$runtimeCommon = Join-Path $scriptDir 'pool-runtime-common.ps1'
if (-not (Test-Path -LiteralPath $runtimeCommon)) { throw "Runtime helper not found: $runtimeCommon" }
. $runtimeCommon
$defaults = Get-PoolDefaults -PackageDir $packageDir
$identity = Get-PoolProjectIdentity -Config $config -PackageDir $packageDir

if ($WorkerCount -le 0) { $WorkerCount = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'workerCount' -Fallback 1 }
if ($TaskPrefix) { $config.taskPrefix = $TaskPrefix }
$maxSupportedWorkers = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'maxSupportedWorkers' -Fallback 50
if ($WorkerCount -lt 1) { throw 'WorkerCount must be >= 1.' }
if ($WorkerCount -gt $maxSupportedWorkers) { throw "WorkerCount $WorkerCount exceeds maxSupportedWorkers $maxSupportedWorkers in $ConfigFile." }
$workerIdPrefix = [string](Get-PoolConfigValue -Config $config -Defaults $defaults -Name 'workerIdPrefix' -Fallback 'worker')
$workerIdDigits = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'workerIdDigits' -Fallback 2
$workerIdFormat = '{0}-{1:D' + $workerIdDigits + '}'

for ($i = 1; $i -le $WorkerCount; $i++) {
    $workerId = $workerIdFormat -f $workerIdPrefix, $i
    $taskName = Get-PoolTaskName -Config $config -Identity $identity -WorkerNumber $i
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $worker + '" -ConfigFile "' + $ConfigFile + '" -WorkerId "' + $workerId + '"'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $packageDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description "Zotero/Codex paper reading worker $workerId for project $($identity.ProjectId)." -Force | Out-Null
    Write-Host "Created task: $taskName ($workerId)"
}
