[CmdletBinding()]
param([string]$Python = '')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$portable = Join-Path $repoRoot '.tools\python311\python.exe'
if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = if (Test-Path -LiteralPath $portable) { $portable } else { 'python' }
}

& (Join-Path $PSScriptRoot 'test_python.ps1') -Tier full -Python $Python
if ($LASTEXITCODE -ne 0) { throw 'Full Python tests failed.' }

& (Join-Path $PSScriptRoot 'test_godot.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Godot core tests failed.' }

& (Join-Path $PSScriptRoot 'test_godot_network.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Godot network tests failed.' }

& (Join-Path $PSScriptRoot 'export_onnx_models.ps1') -Check
if ($LASTEXITCODE -ne 0) { throw 'ONNX contract check failed.' }

Write-Host 'STANDARD_VERIFICATION_OK'
