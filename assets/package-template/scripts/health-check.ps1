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

function Resolve-Executable {
    param(
        [string]$ConfiguredValue,
        [string[]]$CommandNames = @(),
        [string[]]$FallbackPaths = @(),
        [string]$DisplayName = 'executable'
    )

    if ($ConfiguredValue) {
        $expanded = [Environment]::ExpandEnvironmentVariables($ConfiguredValue.Trim())
        $looksLikePath = [System.IO.Path]::IsPathRooted($expanded) -or $expanded.Contains('\') -or $expanded.Contains('/')
        if ($looksLikePath) {
            if (Test-Path -LiteralPath $expanded) { return (Resolve-Path -LiteralPath $expanded).Path }
            throw "$DisplayName configured at '$expanded' was not found."
        }
        $configuredCommand = Get-Command $expanded -ErrorAction SilentlyContinue
        if ($configuredCommand) { return $configuredCommand.Source }
        throw "$DisplayName command '$expanded' was not found."
    }

    foreach ($commandName in $CommandNames) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    foreach ($fallbackPath in $FallbackPaths) {
        if ($fallbackPath -and (Test-Path -LiteralPath $fallbackPath)) { return (Resolve-Path -LiteralPath $fallbackPath).Path }
    }
    throw "$DisplayName was not found."
}

function Resolve-Python {
    $configured = if ($config.pythonExecutable) { [string]$config.pythonExecutable } else { $null }
    $bundled = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    return Resolve-Executable -ConfiguredValue $configured -CommandNames @('python', 'py') -FallbackPaths @($bundled) -DisplayName 'python.exe'
}

function Resolve-Node {
    $configured = if ($config.nodeExecutable) { [string]$config.nodeExecutable } else { $null }
    $codexBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    $fallbackNodes = @()
    if (Test-Path -LiteralPath $codexBin) {
        $fallbackNodes = @(Get-ChildItem -LiteralPath $codexBin -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'node.exe' } |
            Where-Object { Test-Path -LiteralPath $_ })
    }
    return Resolve-Executable -ConfiguredValue $configured -CommandNames @('node') -FallbackPaths $fallbackNodes -DisplayName 'node.exe'
}

function Resolve-Codex {
    $configured = if ($config.codexExecutable) { [string]$config.codexExecutable } else { $null }
    $fallback = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\codex.exe'
    return Resolve-Executable -ConfiguredValue $configured -CommandNames @('codex') -FallbackPaths @($fallback) -DisplayName 'codex.exe'
}

function Resolve-WireApi {
    $configured = if ($config.codexWireApi) { ([string]$config.codexWireApi).Trim().ToLowerInvariant() } else { 'auto' }
    if ($configured -eq 'response') { $configured = 'responses' }
    if ($configured -in @('responses', 'chat')) { return $configured }
    $model = if ($config.codexModel) { [string]$config.codexModel } else { 'mimo-v2.5' }
    if ($model -match '^(?i:gpt)') { return 'responses' }
    return 'chat'
}

function Get-ZoteroBaseUrl {
    $base = if ($config.zoteroLocalApiBaseUrl) { [string]$config.zoteroLocalApiBaseUrl } else { [string]$env:ZOTERO_LOCAL_BASE_URL }
    if (-not $base) { $base = 'http://127.0.0.1:23119' }
    $base = $base.TrimEnd('/')
    if ($base.EndsWith('/api/users/0', [StringComparison]::OrdinalIgnoreCase)) {
        $base = $base.Substring(0, $base.Length - '/api/users/0'.Length).TrimEnd('/')
    }
    return $base
}

function Test-ZoteroLocalApi {
    $base = Get-ZoteroBaseUrl
    $uri = "$base/api/users/0/items?limit=1"
    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Method = 'GET'
    $request.Proxy = $null
    $request.Timeout = 10000
    $request.Headers['Zotero-API-Version'] = '3'
    $response = $null
    try {
        $response = $request.GetResponse()
        return [pscustomobject]@{ Ok = $true; Detail = "HTTP $([int]$response.StatusCode) ($base)" }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message }
    } finally {
        if ($response) { $response.Dispose() }
    }
}

$failed = 0
Write-Host 'Zotero Paper Reading Pool health check' -ForegroundColor Cyan
Write-Host "Package: $packageDir"
Write-Host ''

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
    Write-Check 'Required file' $ok $file
}

try {
    $config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Check 'Config parses as JSON' $true $ConfigFile
} catch {
    $failed++
    Write-Check 'Config parses as JSON' $false $_.Exception.Message
    exit 1
}

$root = Resolve-PackagePath ([string]$config.root)
$logRoot = Resolve-PackagePath ([string]$config.logRoot) $root
$studyRoot = Resolve-PackagePath ([string]$config.studyRoot) $root
$queueFile = Resolve-PackagePath ([string]$config.queueFile) $root
Write-Check 'Resolved root' $true $root
Write-Check 'Resolved study output' $true $studyRoot
Write-Check 'Resolved log output' $true $logRoot
Write-Check 'Resolved queue file' $true $queueFile

$styleFound = $false
if ($config.zoteroStyleCandidates) {
    foreach ($candidate in @($config.zoteroStyleCandidates)) {
        if (-not $candidate) { continue }
        $path = Resolve-PackagePath ([string]$candidate) $root
        if (Test-Path -LiteralPath $path) {
            $styleFound = $true
            Write-Check 'Zotero Style cache (optional)' $true $path
            break
        }
    }
}
if (-not $styleFound) {
    $defaultStyle = Join-Path $env:USERPROFILE 'Zotero\zoterostyle.json'
    if (Test-Path -LiteralPath $defaultStyle) {
        $styleFound = $true
        Write-Check 'Zotero Style cache (optional)' $true $defaultStyle
    }
}
if (-not $styleFound) {
    Write-Check 'Zotero Style cache (optional)' $true 'Not found; journal quartile lookup will be skipped.'
}

$wireApi = Resolve-WireApi
if ($wireApi -eq 'responses') {
    try {
        $codex = Resolve-Codex
        $version = & $codex --version 2>&1
        Write-Check 'Codex CLI' $true "$codex ($version)"
    } catch {
        $failed++
        Write-Check 'Codex CLI' $false $_.Exception.Message
    }
} else {
    try {
        $node = Resolve-Node
        $version = & $node --version 2>&1
        Write-Check 'Node.js (direct chat runtime)' $true "$node ($version)"
    } catch {
        $failed++
        Write-Check 'Node.js (direct chat runtime)' $false $_.Exception.Message
    }
}

try {
    $python = Resolve-Python
    $version = & $python --version 2>&1
    Write-Check 'Python runtime' $true "$python ($version)"
} catch {
    $failed++
    Write-Check 'Python runtime' $false $_.Exception.Message
}

$zoteroProbe = Test-ZoteroLocalApi
if (-not $zoteroProbe.Ok) { $failed++ }
Write-Check 'Zotero local API' $zoteroProbe.Ok $zoteroProbe.Detail

Write-Host ''
if ($failed -gt 0) {
    Write-Host "Health check failed: $failed issue(s)." -ForegroundColor Red
    exit 1
}

Write-Host "Health check passed (wire_api=$wireApi)." -ForegroundColor Green
