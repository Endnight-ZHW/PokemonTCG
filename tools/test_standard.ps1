[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$common = Join-Path $PSScriptRoot 'toolchain_common.ps1'
. $common
$release = Get-ReleaseManifest -RepoRoot $repoRoot
Assert-ProductReleaseContract -Manifest $release
& (Join-Path $PSScriptRoot 'build_native_ai.ps1') -Target windows -Configuration debug
if ($LASTEXITCODE -ne 0) { throw 'Godot native debug runtime build failed.' }

& (Join-Path $PSScriptRoot 'content.ps1') check
if ($LASTEXITCODE -ne 0) { throw 'Godot generated data check failed.' }

& (Join-Path $PSScriptRoot 'test_relay.ps1')
if ($LASTEXITCODE -ne 0) { throw 'C++ Relay protocol tests failed.' }

& (Join-Path $PSScriptRoot 'test_godot.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Godot core tests failed.' }

& (Join-Path $PSScriptRoot 'test_godot_network.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Godot network tests failed.' }

# Model export and promotion are explicit training-pipeline operations. Standard
# verification only validates the currently committed release state.

Write-Host 'STANDARD_VERIFICATION_OK'
