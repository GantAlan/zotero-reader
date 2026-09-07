$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$parseFailures = @()
foreach ($file in Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.ps1') {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $parseFailures += [pscustomobject]@{
            File = $file.FullName
            Errors = ($errors | ForEach-Object { $_.Message }) -join '; '
        }
    }
}
if ($parseFailures.Count -gt 0) {
    $parseFailures | Format-List | Out-String | Write-Error
    throw 'PowerShell parser validation failed.'
}

foreach ($file in Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.json') {
    try {
        Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | Out-Null
    } catch {
        throw "JSON validation failed for $($file.FullName): $($_.Exception.Message)"
    }
}

Write-Host 'PowerShell and JSON validation passed.' -ForegroundColor Green


$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    & $python.Source -m compileall -q (Join-Path $repoRoot 'assets/package-template/scripts') (Join-Path $repoRoot 'tests')
    if ($LASTEXITCODE -ne 0) { throw 'Python syntax validation failed.' }
    Write-Host 'Python syntax validation passed.' -ForegroundColor Green
} else {
    Write-Warning 'python was not found; Python syntax validation was skipped.'
}

$requiredArtifacts = @(
    (Join-Path $repoRoot 'assets/package-template/configs/paper-reading-pool-defaults.json'),
    (Join-Path $repoRoot 'assets/package-template/scripts/pool-runtime-common.ps1'),
    (Join-Path $repoRoot 'assets/package-template/scripts/extract-pdf-chunks.py'),
    (Join-Path $repoRoot 'assets/package-template/schemas/reading-note.schema.json'),
    (Join-Path $repoRoot 'assets/package-template/scripts/validate-reading-note.py'),
    (Join-Path $repoRoot 'assets/package-template/scripts/write-study-data.py'),
    (Join-Path $repoRoot 'assets/package-template/scripts/render-reading-note.py')
)
foreach ($artifact in $requiredArtifacts) {
    if (-not (Test-Path -LiteralPath $artifact)) { throw "Required artifact missing: $artifact" }
}
Write-Host 'Required runtime artifacts are present.' -ForegroundColor Green
