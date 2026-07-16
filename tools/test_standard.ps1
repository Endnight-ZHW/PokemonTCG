[CmdletBinding()]
param([string]$Python = '')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$common = Join-Path $PSScriptRoot 'toolchain_common.ps1'
. $common
$release = Get-ReleaseManifest -RepoRoot $repoRoot
Assert-ReleaseDeepFallbackContract -Manifest $release
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

# Deep v10 checkpoints intentionally retain their old rules sidecars.  The
# full Python/Godot suites assert they are rejected and fall back to Challenge;
# they must not be re-exported or re-stamped as current release models here.

Write-Host 'STANDARD_VERIFICATION_OK'
