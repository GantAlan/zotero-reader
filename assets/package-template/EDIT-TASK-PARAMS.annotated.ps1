param(
    [switch]$RestartAfterApply,
    [switch]$StartAfterApply,
    [switch]$StopAfterApply
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================================
# Zotero Paper Reading Pool 参数表（注释版）
# ============================================================
# 用法：
# 1. 只修改下面 $TaskParams 里面每一行等号右边的值。
# 2. 保存文件。
# 3. 应用参数：
#    powershell -NoProfile -ExecutionPolicy Bypass -File ".\EDIT-TASK-PARAMS.annotated.ps1"
# 4. 应用参数并马上重启 worker：
#    powershell -NoProfile -ExecutionPolicy Bypass -File ".\EDIT-TASK-PARAMS.annotated.ps1" -RestartAfterApply
# ============================================================

$TaskParams = @{
    # 同时运行多少个 worker。越大越快，但更吃 CPU、内存、Zotero、本地代理和模型并发。
    # 建议：5-10 稳定后再升到 25；失败率高就降。
    WorkerCount             = 1

    # 使用的 Codex 模型名。你现在本地代理模型是 mimo-v2.5。
    Model = 'mimo-v2.5'

    # 模型思考强度。可选：minimal, low, medium, high, xhigh。
    # low/medium 更快；xhigh 更慢但笔记通常更完整。
    ReasoningEffort = 'xhigh'

    # 模型接口模式。推荐 auto：
    # auto = gpt* 模型走 responses，mimo-v2.5 等非 GPT 模型走 chat。
    # 如果代理明确要求，也可以手动写 responses 或 chat。
    WireApi = 'auto'

    # 是否允许联网搜索。$true 允许搜索，$false 只用 Zotero/PDF/本地缓存。
    # 注意：chat 模式不支持 Codex 的 Responses web_search 工具，会自动跳过搜索。
    EnableSearch = $true

    # worker 没抢到任务时等待多少秒再检查队列。
    WorkerSleepSeconds = 30

    # 监控面板刷新间隔，单位：秒。
    # 只影响 scripts\pool-monitor.ps1 的默认刷新速度，不影响 worker 执行速度。
    MonitorRefreshSeconds = 60

    # 单篇文献失败后最多重试几次。
    MaxAttempts = 3

    # 任务租约小时数。worker 异常退出后，超过该时间可重新释放任务。
    LeaseHours = 3

    # 同一个 collection 同时允许跑几篇。1 更稳；2+ 更快但更容易同时写同目录。
    MaxRunningPerCollection = 1

    # Codex 沙盒模式。推荐 workspace-write。
    # 可选：read-only, workspace-write, danger-full-access。
    Sandbox = 'workspace-write'

    # 是否需要人工批准。自动化批量任务推荐 never。
    # 可选：never, on-request, on-failure, untrusted。
    AskForApproval = 'never'
}

# 一般不要改下面的代码。
$packageDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
if (-not $packageDir) { $packageDir = (Get-Location).Path }
$configFile = Join-Path $packageDir 'configs\paper-reading-pool-config.json'
$manageScript = Join-Path $packageDir 'scripts\manage-paper-reading-pool.ps1'

if (-not (Test-Path -LiteralPath $configFile)) { throw "Config file not found: $configFile" }
if (-not (Test-Path -LiteralPath $manageScript)) { throw "Manage script not found: $manageScript" }

$actionSwitchCount = @($RestartAfterApply, $StartAfterApply, $StopAfterApply | Where-Object { $_ }).Count
if ($actionSwitchCount -gt 1) {
    throw 'Use only one action switch: -RestartAfterApply, -StartAfterApply, or -StopAfterApply.'
}

$validReasoningEfforts = @('minimal', 'low', 'medium', 'high', 'xhigh')
$validWireApis = @('auto', 'responses', 'chat')
$validAskForApproval = @('never', 'on-request', 'on-failure', 'untrusted')
$validSandbox = @('read-only', 'workspace-write', 'danger-full-access')

if ([int]$TaskParams['WorkerCount'] -lt 1) { throw 'WorkerCount must be >= 1.' }
if (-not $TaskParams['Model']) { throw 'Model cannot be empty.' }
if ($validReasoningEfforts -notcontains $TaskParams['ReasoningEffort']) {
    throw "ReasoningEffort must be one of: $($validReasoningEfforts -join ', ')"
}
if ($validWireApis -notcontains $TaskParams['WireApi']) {
    throw "WireApi must be one of: $($validWireApis -join ', ')"
}
if ($validAskForApproval -notcontains $TaskParams['AskForApproval']) {
    throw "AskForApproval must be one of: $($validAskForApproval -join ', ')"
}
if ($validSandbox -notcontains $TaskParams['Sandbox']) {
    throw "Sandbox must be one of: $($validSandbox -join ', ')"
}
if ([int]$TaskParams['WorkerSleepSeconds'] -lt 1) { throw 'WorkerSleepSeconds must be >= 1.' }
if ([int]$TaskParams['MonitorRefreshSeconds'] -lt 1) { throw 'MonitorRefreshSeconds must be >= 1.' }
if ([int]$TaskParams['MaxAttempts'] -lt 1) { throw 'MaxAttempts must be >= 1.' }
if ([int]$TaskParams['LeaseHours'] -lt 1) { throw 'LeaseHours must be >= 1.' }
if ([int]$TaskParams['MaxRunningPerCollection'] -lt 1) { throw 'MaxRunningPerCollection must be >= 1.' }

$config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
$maxSupportedWorkers = if ($config.maxSupportedWorkers) { [int]$config.maxSupportedWorkers } else { 50 }
if ([int]$TaskParams['WorkerCount'] -gt $maxSupportedWorkers) {
    throw "WorkerCount $($TaskParams['WorkerCount']) exceeds maxSupportedWorkers $maxSupportedWorkers in $configFile."
}

if (-not ($config.PSObject.Properties.Name -contains 'monitorRefreshSeconds')) {
    $config | Add-Member -MemberType NoteProperty -Name monitorRefreshSeconds -Value 5
}
$config.workerCount = [int]$TaskParams['WorkerCount']
$config.codexModel = [string]$TaskParams['Model']
$config.codexReasoningEffort = [string]$TaskParams['ReasoningEffort']
$config.codexWireApi = [string]$TaskParams['WireApi']
$config.codexEnableSearch = [bool]$TaskParams['EnableSearch']
$config.workerSleepSeconds = [int]$TaskParams['WorkerSleepSeconds']
$config.monitorRefreshSeconds = [int]$TaskParams['MonitorRefreshSeconds']
$config.maxAttempts = [int]$TaskParams['MaxAttempts']
$config.leaseHours = [int]$TaskParams['LeaseHours']
$config.maxRunningPerCollection = [int]$TaskParams['MaxRunningPerCollection']
$config.codexSandbox = [string]$TaskParams['Sandbox']
$config.codexAskForApproval = [string]$TaskParams['AskForApproval']

$json = $config | ConvertTo-Json -Depth 30
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($configFile, $json + [Environment]::NewLine, $utf8NoBom)

Write-Host 'Updated task parameters:' -ForegroundColor Green
Write-Host "  Config: $configFile"
Write-Host ''
Write-Host '  Runtime'
Write-Host "    WorkerCount:             $($TaskParams['WorkerCount'])"
Write-Host "    WorkerSleepSeconds:      $($TaskParams['WorkerSleepSeconds'])"
Write-Host "    MonitorRefreshSeconds:   $($TaskParams['MonitorRefreshSeconds'])"
Write-Host "    MaxRunningPerCollection: $($TaskParams['MaxRunningPerCollection'])"
Write-Host ''
Write-Host '  Model'
Write-Host "    Model:                   $($TaskParams['Model'])"
Write-Host "    ReasoningEffort:         $($TaskParams['ReasoningEffort'])"
Write-Host "    WireApi:                 $($TaskParams['WireApi'])"
Write-Host "    EnableSearch:            $($TaskParams['EnableSearch'])"
Write-Host ''
Write-Host '  Reliability'
Write-Host "    MaxAttempts:             $($TaskParams['MaxAttempts'])"
Write-Host "    LeaseHours:              $($TaskParams['LeaseHours'])"
Write-Host ''
Write-Host '  Codex Safety'
Write-Host "    Sandbox:                 $($TaskParams['Sandbox'])"
Write-Host "    AskForApproval:          $($TaskParams['AskForApproval'])"

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
    Write-Host '  powershell -NoProfile -ExecutionPolicy Bypass -File ".\EDIT-TASK-PARAMS.annotated.ps1" -RestartAfterApply'
}
