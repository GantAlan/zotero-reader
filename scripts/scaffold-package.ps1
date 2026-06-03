param(
  [Parameter(Mandatory = $true)]
  [string]$Destination,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$skillRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$template = Join-Path $skillRoot 'assets\package-template'

if (-not (Test-Path -LiteralPath $template)) {
  throw "Template package not found: $template"
}

$expandedDestination = [Environment]::ExpandEnvironmentVariables($Destination)
$destinationPath = if ([System.IO.Path]::IsPathRooted($expandedDestination)) {
  [System.IO.Path]::GetFullPath($expandedDestination)
} else {
  [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $expandedDestination))
}

if ((Test-Path -LiteralPath $destinationPath) -and -not $Force) {
  $existing = @(Get-ChildItem -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue)
  if ($existing.Count -gt 0) {
    throw "Destination is not empty. Use -Force to merge into: $destinationPath"
  }
}

New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
Copy-Item -Path (Join-Path $template '*') -Destination $destinationPath -Recurse -Force

[ordered]@{
  ok = $true
  destination = $destinationPath
  copiedFrom = $template
  files = @(Get-ChildItem -LiteralPath $destinationPath -Recurse -File).Count
} | ConvertTo-Json -Depth 4
