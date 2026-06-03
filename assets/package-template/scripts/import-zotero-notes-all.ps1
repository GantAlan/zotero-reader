param(
  [string]$PackageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [int]$BatchSize = 10,
  [int]$RunTimeoutSeconds = 180,
  [int]$DelaySeconds = 2,
  [int]$MaxBatches = 0
)

$ErrorActionPreference = 'Stop'

$BatchScript = Join-Path $PSScriptRoot 'import-zotero-notes-batch10.ps1'
$QueueDir = Join-Path $PackageRoot 'queue'
$StatePath = Join-Path $QueueDir 'zotero-note-import-state.json'
$LogPath = Join-Path $QueueDir 'zotero-note-import-all.log'
$SummaryPath = Join-Path $QueueDir 'zotero-note-import-all-summary.json'

if (-not (Test-Path -LiteralPath $BatchScript)) {
  throw "Batch script not found: $BatchScript"
}

function Get-CoveredCount {
  if (-not (Test-Path -LiteralPath $StatePath)) {
    return 0
  }
  $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
  @($state.entries | Where-Object { $_.status -in @('imported', 'skipped_existing') }).Count
}

function Write-ImportLog {
  param([Parameter(Mandatory=$true)][string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  $written = $false
  for ($i = 0; $i -lt 20 -and -not $written; $i++) {
    try {
      Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
      $written = $true
    }
    catch [System.IO.IOException] {
      Start-Sleep -Milliseconds 300
    }
  }
  if (-not $written) {
    throw "Failed to write log after retries: $LogPath"
  }
  Write-Host $line
}

$startedAt = Get-Date
$initialCovered = Get-CoveredCount
$batchNo = 0
$totalImported = 0
$totalSkipped = 0
$totalFailed = 0
$lastCovered = $initialCovered

Write-ImportLog "START package=$PackageRoot batchSize=$BatchSize initialCovered=$initialCovered"

while ($true) {
  if ($MaxBatches -gt 0 -and $batchNo -ge $MaxBatches) {
    Write-ImportLog "STOP reached MaxBatches=$MaxBatches"
    break
  }

  $batchNo += 1
  $beforeCovered = Get-CoveredCount
  Write-ImportLog "BATCH $batchNo begin covered=$beforeCovered"

  try {
    $raw = powershell -NoProfile -ExecutionPolicy Bypass -File $BatchScript `
      -PackageRoot $PackageRoot `
      -BatchSize $BatchSize `
      -RunTimeoutSeconds $RunTimeoutSeconds
    if ($LASTEXITCODE -ne 0) {
      throw "Batch script exited with code $LASTEXITCODE"
    }
  }
  catch {
    Write-ImportLog "ERROR batch=$batchNo message=$($_.Exception.Message)"
    throw
  }

  $text = ($raw | Out-String).Trim()
  if (-not $text) {
    throw "Batch $batchNo returned empty output"
  }

  $parsed = $text | ConvertFrom-Json
  if ($parsed.mode -eq 'nothing_to_import') {
    Write-ImportLog "DONE no more records to import"
    break
  }
  if (-not $parsed.result -or -not $parsed.verify) {
    throw "Batch $batchNo returned an incomplete result. Raw output: $text"
  }

  $counts = @{}
  foreach ($r in @($parsed.result.results)) {
    $action = [string]$r.action
    if (-not $counts.ContainsKey($action)) {
      $counts[$action] = 0
    }
    $counts[$action] += 1
  }

  $imported = 0
  $skipped = 0
  $failed = 0
  if ($counts.ContainsKey('imported')) { $imported = [int]$counts['imported'] }
  if ($counts.ContainsKey('skipped_existing')) { $skipped = [int]$counts['skipped_existing'] }
  if ($counts.ContainsKey('failed')) { $failed = [int]$counts['failed'] }
  $totalImported += $imported
  $totalSkipped += $skipped
  $totalFailed += $failed

  $afterCovered = Get-CoveredCount
  $indexes = @($parsed.prepared.globalIndexes) -join ','
  Write-ImportLog "BATCH $batchNo end indexes=$indexes imported=$imported skipped=$skipped failed=$failed covered=$afterCovered verifyOk=$($parsed.verify.ok)"

  if (-not $parsed.verify.ok) {
    throw "Batch $batchNo verification failed. See $($parsed.verifyPath)"
  }

  if ($afterCovered -le $lastCovered -and $failed -gt 0) {
    throw "Batch $batchNo made no covered progress and has failed records; stopping to avoid repeated retries."
  }
  $lastCovered = $afterCovered

  Start-Sleep -Seconds $DelaySeconds
}

$summary = [ordered]@{
  ok = $true
  startedAt = $startedAt.ToString('yyyy-MM-dd HH:mm:ss')
  finishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  packageRoot = $PackageRoot
  batchSize = $BatchSize
  batchesRun = $batchNo
  initialCovered = $initialCovered
  finalCovered = Get-CoveredCount
  importedThisRun = $totalImported
  skippedThisRun = $totalSkipped
  failedActionsThisRun = $totalFailed
  logPath = $LogPath
  statePath = $StatePath
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
Write-ImportLog "SUMMARY $($summary | ConvertTo-Json -Compress)"
$summary | ConvertTo-Json -Depth 8
