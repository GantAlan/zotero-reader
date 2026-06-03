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
$config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json

$workerScript = Join-Path $scriptDir 'run-zotero-paper-reading-pool.ps1'
if (-not (Test-Path -LiteralPath $workerScript)) { throw "Worker script not found: $workerScript" }

function Get-ConfigInt {
    param([object]$Value, [int]$Default)
    if ($null -eq $Value -or $Value -eq '') { return $Default }
    return [int]$Value
}

$configuredWorkerCount = Get-ConfigInt $config.workerCount 5
if ($WorkerCount -le 0) { $WorkerCount = $configuredWorkerCount }
$maxSupportedWorkers = Get-ConfigInt $config.maxSupportedWorkers 40
if ($WorkerCount -lt 1) { throw "WorkerCount must be >= 1." }
if ($WorkerCount -gt $maxSupportedWorkers) { throw "WorkerCount $WorkerCount exceeds maxSupportedWorkers $maxSupportedWorkers in $ConfigFile." }

$workerIdPrefix = if ($config.workerIdPrefix) { [string]$config.workerIdPrefix } else { 'worker' }
$workerIdDigits = Get-ConfigInt $config.workerIdDigits 2
$workerIdFormat = '{0}-{1:D' + $workerIdDigits + '}'

$existingPoolProcesses = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^(powershell|pwsh)\.exe$' -and
    $_.CommandLine -like '*run-zotero-paper-reading-pool.ps1*' -and
    $_.CommandLine -like "*${ConfigFile}*"
})

for ($i = 1; $i -le $WorkerCount; $i++) {
    $workerId = $workerIdFormat -f $workerIdPrefix, $i
    $alreadyRunning = @($existingPoolProcesses | Where-Object { $_.CommandLine -like "*WorkerId *$workerId*" -or $_.CommandLine -like "*WorkerId `"$workerId`"*" }).Count -gt 0
    if ($alreadyRunning -and -not $Force) {
        Write-Host "Already running: $workerId"
        continue
    }
    Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$workerScript`" -ConfigFile `"$ConfigFile`" -WorkerId `"$workerId`""
    Write-Host "Started: $workerId"
}

$active = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^(powershell|pwsh)\.exe$' -and
    $_.CommandLine -like '*run-zotero-paper-reading-pool.ps1*' -and
    $_.CommandLine -like "*${ConfigFile}*"
}).Count
Write-Host "Active pool workers for this config: $active"
