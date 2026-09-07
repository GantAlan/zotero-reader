# Shared runtime helpers for the Zotero paper-reading pool.
# This file is dot-sourced by package scripts and intentionally has no side effects.

function Get-PoolDefaults {
    param([Parameter(Mandatory = $true)][string]$PackageDir)
    $path = Join-Path $PackageDir 'configs\paper-reading-pool-defaults.json'
    if (Test-Path -LiteralPath $path) {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    return [pscustomobject]@{
        workerCount = 1; maxSupportedWorkers = 50; maxRunningPerCollection = 1
        maxAttempts = 3; leaseHours = 3; workerSleepSeconds = 30; monitorRefreshSeconds = 60
        codexModel = 'mimo-v2.5'; codexReasoningEffort = 'xhigh'; codexWireApi = 'auto'
        codexEnableSearch = $true; codexAskForApproval = 'never'; codexSandbox = 'workspace-write'
        logRetentionDays = 14; retainPrompts = $false; retainPdfText = $false
        retainRawModelOutput = $false; retainFailureDiagnostics = $true; redactSensitivePaths = $true
        pdfChunkingEnabled = $true; pdfMaxCharsPerChunk = 18000; pdfChunkOverlapChars = 1200
        pdfMaxPagesPerChunk = 4; pdfMaxPromptChars = 180000; outputDataRoot = 'study-data'; runReservationGraceSeconds = 120
    }
}

function Get-PoolConfigValue {
    param(
        [object]$Config,
        [object]$Defaults,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Fallback = $null
    )
    if ($null -ne $Config) {
        $property = $Config.PSObject.Properties[$Name]
        if ($null -ne $property -and $null -ne $property.Value -and [string]$property.Value -ne '') { return $property.Value }
    }
    if ($null -ne $Defaults) {
        $property = $Defaults.PSObject.Properties[$Name]
        if ($null -ne $property -and $null -ne $property.Value -and [string]$property.Value -ne '') { return $property.Value }
    }
    return $Fallback
}

function Get-PoolConfigInt {
    param([object]$Config, [object]$Defaults, [string]$Name, [int]$Fallback)
    $value = Get-PoolConfigValue -Config $Config -Defaults $Defaults -Name $Name -Fallback $Fallback
    return [int]$value
}

function Get-PoolConfigBool {
    param([object]$Config, [object]$Defaults, [string]$Name, [bool]$Fallback)
    $value = Get-PoolConfigValue -Config $Config -Defaults $Defaults -Name $Name -Fallback $Fallback
    if ($value -is [bool]) { return [bool]$value }
    $parsed = $false
    if ([bool]::TryParse([string]$value, [ref]$parsed)) { return $parsed }
    if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) { return ([double]$value -ne 0) }
    return $Fallback
}

function ConvertTo-PoolSafeName {
    param([Parameter(Mandatory = $true)][string]$Value, [int]$MaxLength = 80)
    $safe = [regex]::Replace($Value.Trim(), '[^\p{L}\p{N}._-]+', '_').Trim('_')
    if (-not $safe) { $safe = 'default' }
    if ($safe.Length -gt $MaxLength) { $safe = $safe.Substring(0, $MaxLength).Trim('_') }
    return $safe
}

function Resolve-PoolPath {
    param([Parameter(Mandatory = $true)][string]$PathValue, [Parameter(Mandatory = $true)][string]$BasePath)
    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    $candidate = if ([System.IO.Path]::IsPathRooted($expanded)) { $expanded } else { Join-Path $BasePath $expanded }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Get-PoolProjectIdentity {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$PackageDir)
    $rootValue = if ($Config.root) { [string]$Config.root } else { '.' }
    $root = Resolve-PoolPath -PathValue $rootValue -BasePath $PackageDir
    $projectId = [string](Get-PoolConfigValue -Config $Config -Defaults $null -Name 'projectId' -Fallback '')
    if (-not $projectId) {
        $leaf = Split-Path -Leaf ($root.TrimEnd('\', '/'))
        $hash = [System.Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant()))).Replace('-', '').Substring(0, 12) }
        finally { $hash.Dispose() }
        $projectId = if ($leaf) { "$leaf-$digest" } else { $digest }
    }
    $namespace = [string](Get-PoolConfigValue -Config $Config -Defaults $null -Name 'runtimeNamespace' -Fallback 'zotero-reader')
    $projectId = ConvertTo-PoolSafeName $projectId 50
    $namespace = ConvertTo-PoolSafeName $namespace 40
    [pscustomobject]@{ ProjectId = $projectId; RuntimeNamespace = $namespace; Root = $root }
}

function Get-PoolRunId {
    param([string]$RequestedRunId)
    if ($RequestedRunId) { return (ConvertTo-PoolSafeName $RequestedRunId 100) }
    return 'run_{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), ([guid]::NewGuid().ToString('N').Substring(0, 12))
}

function Get-PoolStateRoot {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$Root)
    $value = if ($Config.stateRoot) { [string]$Config.stateRoot } else { 'state' }
    return (Resolve-PoolPath -PathValue $value -BasePath $Root)
}

function Get-PoolRunDirectory {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$RunId)
    return (Join-Path (Join-Path (Get-PoolStateRoot -Config $Config -Root $Root) 'runs') $RunId)
}

function Get-PoolWorkerStatePath {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$RunId, [Parameter(Mandatory = $true)][string]$WorkerId)
    return (Join-Path (Join-Path (Get-PoolRunDirectory -Config $Config -Root $Root -RunId $RunId) 'workers') ((ConvertTo-PoolSafeName $WorkerId 80) + '.json'))
}

function Get-PoolCurrentRunPath {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$Root)
    return (Join-Path (Get-PoolStateRoot -Config $Config -Root $Root) 'current-run.json')
}

function Write-PoolJsonAtomic {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Data)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $json = $Data | ConvertTo-Json -Depth 40
    [System.IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-PoolJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-PoolUtcNow {
    return [DateTime]::UtcNow.ToString('o')
}

function Get-PoolQueueMutexName {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Identity)
    if ($Config.mutexName) {
        $configured = [string]$Config.mutexName
        if ($configured.IndexOf([string]$Identity.ProjectId, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $configured }
    }
    return "Global\ZoteroPaperReadingPool_$($Identity.RuntimeNamespace)_$($Identity.ProjectId)_Queue"
}

function Get-PoolProjectMutexName {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Identity)
    if ($Config.projectMutexName) {
        $configured = [string]$Config.projectMutexName
        if ($configured.IndexOf([string]$Identity.ProjectId, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $configured }
    }
    return "Global\ZoteroPaperReadingPool_$($Identity.RuntimeNamespace)_$($Identity.ProjectId)"
}

function Invoke-PoolProjectMutex {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Identity, [Parameter(Mandatory = $true)][scriptblock]$Body)
    $name = Get-PoolProjectMutexName -Config $Config -Identity $Identity
    $mutex = New-Object System.Threading.Mutex($false, $name)
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
        if (-not $hasLock) { throw "Could not acquire project mutex: $name" }
        return (& $Body)
    } finally {
        if ($hasLock) { $mutex.ReleaseMutex() | Out-Null }
        $mutex.Dispose()
    }
}

function Test-PoolRunReservation {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Identity, [string]$ExcludeRunId)
    $current = Read-PoolJson -Path (Get-PoolCurrentRunPath -Config $Config -Root $Identity.Root)
    if ($null -eq $current -or $current.status -ne 'running') { return $false }
    if ($ExcludeRunId -and [string]$current.runId -eq [string]$ExcludeRunId) { return $false }
    $active = @(Get-PoolActiveWorkerStates -Config $Config -Identity $Identity)
    if ($active.Count -gt 0) { return $true }
    $graceSeconds = Get-PoolConfigInt -Config $Config -Defaults $null -Name 'runReservationGraceSeconds' -Fallback 120
    try {
        $started = [DateTime]::Parse([string]$current.startedAtUtc).ToUniversalTime()
        return ([DateTime]::UtcNow - $started).TotalSeconds -lt $graceSeconds
    } catch { return $true }
}

function New-PoolRunState {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Identity, [Parameter(Mandatory = $true)][string]$RunId, [string[]]$WorkerIds = @())
    $runDirectory = Get-PoolRunDirectory -Config $Config -Root $Identity.Root -RunId $RunId
    New-Item -ItemType Directory -Force -Path (Join-Path $runDirectory 'workers') | Out-Null
    $run = [ordered]@{
        schemaVersion = 1; runId = $RunId; projectId = $Identity.ProjectId; runtimeNamespace = $Identity.RuntimeNamespace
        packageRoot = $Identity.Root; startedAtUtc = Get-PoolUtcNow; updatedAtUtc = Get-PoolUtcNow; status = 'running'
        expectedWorkerIds = @($WorkerIds); workers = @()
    }
    Write-PoolJsonAtomic -Path (Join-Path $runDirectory 'run.json') -Data $run
    Write-PoolJsonAtomic -Path (Get-PoolCurrentRunPath -Config $Config -Root $Identity.Root) -Data $run
    return $run
}

function Get-PoolStateMutexName {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Identity)
    return "Global\ZoteroPaperReadingPool_$($Identity.RuntimeNamespace)_$($Identity.ProjectId)_State"
}

function Invoke-PoolStateMutex {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Identity, [Parameter(Mandatory = $true)][scriptblock]$Body)
    $name = Get-PoolStateMutexName -Config $Config -Identity $Identity
    $mutex = New-Object System.Threading.Mutex($false, $name)
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
        if (-not $hasLock) { throw "Could not acquire state mutex: $name" }
        return (& $Body)
    } finally {
        if ($hasLock) { $mutex.ReleaseMutex() | Out-Null }
        $mutex.Dispose()
    }
}

function Update-PoolRunState {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Identity, [Parameter(Mandatory = $true)][string]$RunId, [Parameter(Mandatory = $true)]$WorkerState, [string]$RunStatus = 'running')
    return Invoke-PoolStateMutex -Config $Config -Identity $Identity -Body {
        $runDirectory = Get-PoolRunDirectory -Config $Config -Root $Identity.Root -RunId $RunId
        $runPath = Join-Path $runDirectory 'run.json'
        $run = Read-PoolJson -Path $runPath
        if ($null -eq $run) { $run = New-PoolRunState -Config $Config -Identity $Identity -RunId $RunId -WorkerIds @($WorkerState.workerId) }
        $workers = @($run.workers | Where-Object { $_.workerId -ne $WorkerState.workerId })
        $workers += $WorkerState
        $run.workers = @($workers)
        $run.status = $RunStatus
        $run.updatedAtUtc = Get-PoolUtcNow
        Write-PoolJsonAtomic -Path $runPath -Data $run
        Write-PoolJsonAtomic -Path (Get-PoolCurrentRunPath -Config $Config -Root $Identity.Root) -Data $run
        return $run
    }
}

function New-PoolWorkerState {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Identity, [Parameter(Mandatory = $true)][string]$RunId, [Parameter(Mandatory = $true)][string]$WorkerId, [Parameter(Mandatory = $true)][int]$ProcessId, [Parameter(Mandatory = $true)][string]$WorkerScript, [Parameter(Mandatory = $true)][string]$ConfigFile)
    $state = [ordered]@{
        schemaVersion = 1; runId = $RunId; projectId = $Identity.ProjectId; runtimeNamespace = $Identity.RuntimeNamespace
        workerId = $WorkerId; pid = $ProcessId; processStartTimeUtc = $null; packageRoot = $Identity.Root
        configFile = [IO.Path]::GetFullPath($ConfigFile); workerScript = [IO.Path]::GetFullPath($WorkerScript)
        status = 'running'; startedAtUtc = Get-PoolUtcNow; updatedAtUtc = Get-PoolUtcNow; exitCode = $null; runIdArgumentVerified = $false
    }
    try {
        $state.processStartTimeUtc = (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
        $workerCommandLine = Get-PoolProcessCommandLine -ProcessId $ProcessId
        $state.runIdArgumentVerified = Test-PoolCommandLineContains -CommandLine $workerCommandLine -Value ([string]$RunId)
    } catch {}
    $path = Get-PoolWorkerStatePath -Config $Config -Root $Identity.Root -RunId $RunId -WorkerId $WorkerId
    Write-PoolJsonAtomic -Path $path -Data $state
    Update-PoolRunState -Config $Config -Identity $Identity -RunId $RunId -WorkerState $state | Out-Null
    return $state
}

function Update-PoolWorkerState {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Identity, [Parameter(Mandatory = $true)][string]$RunId, [Parameter(Mandatory = $true)][string]$WorkerId, [string]$Status, [Nullable[int]]$ExitCode)
    $path = Get-PoolWorkerStatePath -Config $Config -Root $Identity.Root -RunId $RunId -WorkerId $WorkerId
    $state = Read-PoolJson -Path $path
    if ($null -eq $state) { return }
    if ($Status) { $state.status = $Status }
    if ($ExitCode.HasValue) { $state.exitCode = $ExitCode.Value }
    $state.updatedAtUtc = Get-PoolUtcNow
    Write-PoolJsonAtomic -Path $path -Data $state
    Update-PoolRunState -Config $Config -Identity $Identity -RunId $RunId -WorkerState $state -RunStatus $(if ($Status -eq 'failed') { 'failed' } else { 'running' }) | Out-Null
}

function Get-PoolProcessCommandLine {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    try { return [string](Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop | Select-Object -ExpandProperty CommandLine -ErrorAction Stop) } catch { return '' }
}

function Test-PoolCommandLineContains {
    param([string]$CommandLine, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($CommandLine) -or [string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $CommandLine.IndexOf($Value, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-PoolProcessIdentity {
    param([Parameter(Mandatory = $true)]$State)
    if (-not $State.pid) { return $false }
    $process = Get-Process -Id ([int]$State.pid) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    $commandLine = Get-PoolProcessCommandLine -ProcessId ([int]$State.pid)
    if (-not (Test-PoolCommandLineContains -CommandLine $commandLine -Value ([string]$State.workerScript))) { return $false }
    if (-not (Test-PoolCommandLineContains -CommandLine $commandLine -Value ([string]$State.configFile))) { return $false }
    if (-not (Test-PoolCommandLineContains -CommandLine $commandLine -Value ([string]$State.workerId))) { return $false }
    if ($State.runIdArgumentVerified -and -not (Test-PoolCommandLineContains -CommandLine $commandLine -Value ([string]$State.runId))) { return $false }
    if ($State.processStartTimeUtc) {
        try {
            $actual = $process.StartTime.ToUniversalTime()
            $expected = [DateTime]::Parse([string]$State.processStartTimeUtc).ToUniversalTime()
            if ([Math]::Abs(($actual - $expected).TotalSeconds) -gt 3) { return $false }
        } catch { return $false }
    }
    return $true
}

function Get-PoolProcessDescendants {
    param([Parameter(Mandatory = $true)][int]$RootProcessId)
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $pending = New-Object System.Collections.Generic.Queue[int]
    $pending.Enqueue($RootProcessId)
    $seen = New-Object System.Collections.Generic.HashSet[int]
    [void]$seen.Add($RootProcessId)
    $descendants = @()
    while ($pending.Count -gt 0) {
        $parentId = $pending.Dequeue()
        foreach ($process in $all | Where-Object { [int]$_.ParentProcessId -eq $parentId }) {
            $childId = [int]$process.ProcessId
            if ($seen.Add($childId)) {
                $descendants += $process
                $pending.Enqueue($childId)
            }
        }
    }
    return @($descendants)
}

function Get-PoolActiveWorkerStates {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Identity)
    $stateRoot = Get-PoolStateRoot -Config $Config -Root $Identity.Root
    if (-not (Test-Path -LiteralPath $stateRoot)) { return @() }
    $states = @()
    foreach ($file in Get-ChildItem -LiteralPath $stateRoot -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue) {
        if ($file.Name -eq 'current-run.json' -or $file.Name -eq 'run.json') { continue }
        try { $state = Read-PoolJson -Path $file.FullName } catch { continue }
        if ($null -eq $state -or $state.projectId -ne $Identity.ProjectId) { continue }
        if ($state.status -notin @('running', 'idle')) { continue }
        if (Test-PoolProcessIdentity -State $state) { $states += $state }
    }
    return @($states)
}

function Set-PoolRunStatus {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Identity, [Parameter(Mandatory = $true)][string]$RunId, [Parameter(Mandatory = $true)][string]$Status)
    Invoke-PoolStateMutex -Config $Config -Identity $Identity -Body {
        $runPath = Join-Path (Get-PoolRunDirectory -Config $Config -Root $Identity.Root -RunId $RunId) 'run.json'
        $run = Read-PoolJson -Path $runPath
        if ($null -eq $run) { return }
        $run.status = $Status
        $run.updatedAtUtc = Get-PoolUtcNow
        Write-PoolJsonAtomic -Path $runPath -Data $run
        Write-PoolJsonAtomic -Path (Get-PoolCurrentRunPath -Config $Config -Root $Identity.Root) -Data $run
    } | Out-Null
}

function Get-PoolTaskName {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Identity, [Parameter(Mandatory = $true)][int]$WorkerNumber)
    $prefix = [string](Get-PoolConfigValue -Config $Config -Defaults $null -Name 'taskPrefix' -Fallback 'ZoteroPaperReadingPool')
    return ('{0}_{1}_{2:D2}' -f (ConvertTo-PoolSafeName $prefix 60), $Identity.ProjectId, $WorkerNumber)
}

function ConvertTo-PoolPrivacySafeText {
    param([string]$Text, [string]$RootPath = '', [string[]]$AdditionalPaths = @())
    if ($null -eq $Text) { return '' }
    $safe = [string]$Text
    foreach ($path in @($RootPath) + @($AdditionalPaths)) {
        if ($path) { $safe = $safe -replace [regex]::Escape($path), '<path>' }
    }
    foreach ($path in @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA)) {
        if ($path) { $safe = $safe -replace [regex]::Escape($path), '<user-path>' }
    }
    $safe = [regex]::Replace($safe, '(?i)Bearer\s+[A-Za-z0-9._~+/=-]+', 'Bearer <redacted>')
    $safe = [regex]::Replace($safe, '(?i)(api[_-]?key|token|secret)\s*[:=]\s*[^\s,;]+', '$1=<redacted>')
    return $safe
}

function Protect-PoolDiagnosticFile {
    param([string]$Path, [string]$RootPath, [string[]]$AdditionalPaths = @())
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $safe = ConvertTo-PoolPrivacySafeText -Text $text -RootPath $RootPath -AdditionalPaths $AdditionalPaths
        [System.IO.File]::WriteAllText($Path, $safe, [System.Text.UTF8Encoding]::new($false))
    } catch {}
}

function Invoke-PoolArtifactCleanup {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Defaults, [Parameter(Mandatory = $true)][string]$WorkerLogDir, [Parameter(Mandatory = $true)][bool]$Succeeded, [string]$RootPath = '')
    $retainPrompts = Get-PoolConfigBool -Config $Config -Defaults $Defaults -Name 'retainPrompts' -Fallback $false
    $retainPdfText = Get-PoolConfigBool -Config $Config -Defaults $Defaults -Name 'retainPdfText' -Fallback $false
    $retainRaw = Get-PoolConfigBool -Config $Config -Defaults $Defaults -Name 'retainRawModelOutput' -Fallback $false
    $retainFailure = Get-PoolConfigBool -Config $Config -Defaults $Defaults -Name 'retainFailureDiagnostics' -Fallback $true
    $redact = Get-PoolConfigBool -Config $Config -Defaults $Defaults -Name 'redactSensitivePaths' -Fallback $true
    if (-not $Succeeded -and $retainFailure) { $retainRaw = $true }
    if (-not $Succeeded -and -not $retainFailure) { $retainRaw = $false }
    if ($redact) {
        foreach ($file in Get-ChildItem -LiteralPath $WorkerLogDir -File -ErrorAction SilentlyContinue) {
            if ($file.Extension -in @('.log', '.txt')) { Protect-PoolDiagnosticFile -Path $file.FullName -RootPath $RootPath }
        }
    }
    if (-not $retainPrompts) { Get-ChildItem -LiteralPath $WorkerLogDir -File -Filter '*prompt*.txt' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
    if (-not $retainPdfText) {
        Get-ChildItem -LiteralPath $WorkerLogDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'fulltext|pdf[_-]?chunks|extract' } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    if (-not $retainRaw) {
        Get-ChildItem -LiteralPath $WorkerLogDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'last_message|codex_paper_run' } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -LiteralPath $WorkerLogDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.chat.mjs', '.extract.py') } | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Invoke-PoolLogCleanup {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Defaults, [Parameter(Mandatory = $true)][string]$RootPath)
    $days = Get-PoolConfigInt -Config $Config -Defaults $Defaults -Name 'logRetentionDays' -Fallback 14
    if ($days -le 0) { return }
    $logValue = if ($Config.logRoot) { [string]$Config.logRoot } else { 'logs' }
    $logRoot = Resolve-PoolPath -PathValue $logValue -BasePath $RootPath
    if (-not (Test-Path -LiteralPath $logRoot)) { return }
    $cutoff = (Get-Date).AddDays(-$days)
    Get-ChildItem -LiteralPath $logRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
