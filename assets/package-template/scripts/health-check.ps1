param(
    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageDir = Split-Path -Parent $scriptDir
if (-not $ConfigFile) { $ConfigFile = Join-Path $packageDir 'configs\paper-reading-pool-config.json' }

function Resolve-PackagePath {
    param([Parameter(Mandatory = $true)][string]$PathValue, [string]$BasePath = $packageDir)
    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    if ([System.IO.Path]::IsPathRooted($expanded)) { return $expanded }
    return (Join-Path $BasePath $expanded)
}

function Write-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $prefix = if ($Ok) { '[OK]' } else { '[FAIL]' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("{0} {1}" -f $prefix, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("     {0}" -f $Detail) -ForegroundColor DarkGray }
}

function Resolve-Python {
    $bundledPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    if (Test-Path -LiteralPath $bundledPython) { return $bundledPython }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'python.exe not found.'
}

$failed = 0
Write-Host "Zotero Paper Reading Pool health check" -ForegroundColor Cyan
Write-Host "Package: $packageDir"
Write-Host ""

$requiredFiles = @(
    $ConfigFile,
    (Join-Path $scriptDir 'pool-queue-manager.py'),
    (Join-Path $scriptDir 'run-zotero-paper-reading-pool.ps1'),
    (Join-Path $scriptDir 'start-paper-reading-pool.ps1'),
    (Join-Path $scriptDir 'manage-paper-reading-pool.ps1'),
    (Join-Path $scriptDir 'install-pool-workers.ps1'),
    (Join-Path $packageDir 'study-paper-template\reading-note-template.md'),
    (Join-Path $packageDir 'study-paper-template\fill-instructions.md')
)

foreach ($file in $requiredFiles) {
    $ok = Test-Path -LiteralPath $file
    if (-not $ok) { $failed++ }
    Write-Check "Required file" $ok $file
}

try {
    $config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Check "Config parses as JSON" $true $ConfigFile
} catch {
    $failed++
    Write-Check "Config parses as JSON" $false $_.Exception.Message
    exit 1
}

$root = Resolve-PackagePath ([string]$config.root)
$logRoot = Resolve-PackagePath ([string]$config.logRoot) $root
$studyRoot = Resolve-PackagePath ([string]$config.studyRoot) $root
$queueFile = Resolve-PackagePath ([string]$config.queueFile) $root
Write-Check "Resolved root" $true $root
Write-Check "Resolved study output" $true $studyRoot
Write-Check "Resolved log output" $true $logRoot
Write-Check "Resolved queue file" $true $queueFile

$styleFound = $false
if ($config.zoteroStyleCandidates) {
    foreach ($candidate in @($config.zoteroStyleCandidates)) {
        if (-not $candidate) { continue }
        $path = Resolve-PackagePath ([string]$candidate) $root
        if (Test-Path -LiteralPath $path) {
            $styleFound = $true
            Write-Check "Zotero Style cache" $true $path
            break
        }
    }
}
if (-not $styleFound) {
    $failed++
    Write-Check "Zotero Style cache" $false "No candidate path exists."
}

$codex = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\codex.exe'
if (Test-Path -LiteralPath $codex) {
    try {
        $version = & $codex --version 2>&1
        Write-Check "Codex CLI" $true "$codex ($version)"
    } catch {
        $failed++
        Write-Check "Codex CLI" $false $_.Exception.Message
    }
} else {
    $failed++
    Write-Check "Codex CLI" $false $codex
}

try {
    $python = Resolve-Python
    $probe = "import urllib.request; req=urllib.request.Request('http://127.0.0.1:23119/api/users/0/items?limit=1', headers={'Zotero-API-Version':'3'}); opener=urllib.request.build_opener(urllib.request.ProxyHandler({})); r=opener.open(req, timeout=10); print(r.status)"
    $status = & $python -c $probe 2>&1
    $ok = ($LASTEXITCODE -eq 0 -and (($status | Select-Object -Last 1) -eq '200'))
    if (-not $ok) { throw ($status -join "`n") }
    Write-Check "Zotero local API" $true "HTTP 200"
} catch {
    $failed++
    Write-Check "Zotero local API" $false $_.Exception.Message
}

Write-Host ""
if ($failed -gt 0) {
    Write-Host "Health check failed: $failed issue(s)." -ForegroundColor Red
    exit 1
}

Write-Host "Health check passed." -ForegroundColor Green
