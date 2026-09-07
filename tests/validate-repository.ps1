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
