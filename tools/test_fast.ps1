[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'test_product_boundary.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Product Python boundary failed.' }

& (Join-Path $PSScriptRoot 'test_source_boundaries.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Source responsibility boundary failed.' }

& (Join-Path $PSScriptRoot 'test_ptcg_core.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Dependency-free C++ rules core failed.' }

& (Join-Path $PSScriptRoot 'test_challenge_core.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Dependency-free C++ Challenge core failed.' }

& (Join-Path $PSScriptRoot 'build_native_ai.ps1') -Target windows -Configuration debug
if ($LASTEXITCODE -ne 0) { throw 'Godot native debug runtime build failed.' }

& (Join-Path $PSScriptRoot 'test_relay.ps1')
if ($LASTEXITCODE -ne 0) { throw 'C++ Relay protocol core failed.' }

& (Join-Path $PSScriptRoot 'content.ps1') test
if ($LASTEXITCODE -ne 0) { throw 'Native content compiler contract failed.' }

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$godotPaths = Get-GodotToolchainPaths -RepoRoot $repoRoot
$godot = $godotPaths.Console
Set-PortableGodotEnvironment -ToolsRoot (Join-Path $repoRoot '.tools')
$projectRoot = Join-Path $repoRoot 'godot'
$godotOutput = & $godot `
    --headless `
    --path $projectRoot `
    --script 'res://tests/native_rules_session_contract_test.gd' 2>&1
$godotOutput | ForEach-Object { Write-Host $_ }
$godotExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
$joinedGodotOutput = $godotOutput -join "`n"
if (
    $godotExitCode -ne 0 `
    -or $joinedGodotOutput -match '(?m)^(SCRIPT ERROR|ERROR|WARNING):' `
    -or $joinedGodotOutput -notmatch 'NATIVE_RULES_SESSION_CONTRACT_OK'
) {
    throw 'Single-process Godot Native ABI 2 contract failed.'
}

Write-Host 'FAST_VERIFICATION_OK'
