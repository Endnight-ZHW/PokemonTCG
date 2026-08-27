[CmdletBinding()]
param([string]$Python = '')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$common = Join-Path $PSScriptRoot 'toolchain_common.ps1'
. $common
$release = Get-ReleaseManifest -RepoRoot $repoRoot
Assert-ProductReleaseContract -Manifest $release
$portable = Join-Path $repoRoot '.tools\python311\python.exe'
if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = if (Test-Path -LiteralPath $portable) { $portable } else { 'python' }
}

& (Join-Path $PSScriptRoot 'test_python.ps1') -Tier full -Python $Python
if ($LASTEXITCODE -ne 0) { throw 'Full Python tests failed.' }

& $Python -B (Join-Path $repoRoot 'python\scripts\export_godot_data.py') `
    --check --skip-images
if ($LASTEXITCODE -ne 0) { throw 'Godot generated data check failed.' }

& (Join-Path $PSScriptRoot 'test_godot.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Godot core tests failed.' }

& (Join-Path $PSScriptRoot 'test_godot_network.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Godot network tests failed.' }

# Model export and promotion are explicit training-pipeline operations. Standard
# verification only validates the currently committed release state.

Write-Host 'STANDARD_VERIFICATION_OK'
