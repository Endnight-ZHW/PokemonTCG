[CmdletBinding()]
param([string]$Python = '')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$portable = Join-Path $repoRoot '.tools\python311\python.exe'
if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = if (Test-Path -LiteralPath $portable) { $portable } else { 'python' }
}
$env:PYTHONNOUSERSITE = '1'

& (Join-Path $PSScriptRoot 'test_python.ps1') -Tier core -Python $Python
if ($LASTEXITCODE -ne 0) { throw 'Python core tests failed.' }

& $Python -B (Join-Path $repoRoot 'python\scripts\export_godot_data.py') `
    --check --skip-images
if ($LASTEXITCODE -ne 0) { throw 'Godot generated data check failed.' }

& (Join-Path $PSScriptRoot 'test_godot.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Godot core tests failed.' }

Write-Host 'FAST_VERIFICATION_OK'
