[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
# Each child script throws on failure; LASTEXITCODE belongs to native commands.
& (Join-Path $PSScriptRoot 'test_product_boundary.ps1')

& (Join-Path $PSScriptRoot 'test_source_boundaries.ps1')

& (Join-Path $PSScriptRoot 'test_ptcg_core.ps1')

& (Join-Path $PSScriptRoot 'test_challenge_core.ps1')

& (Join-Path $PSScriptRoot 'build_native_ai.ps1') -Target windows -Configuration debug

& (Join-Path $PSScriptRoot 'test_relay.ps1')

& (Join-Path $PSScriptRoot 'content.ps1') test

. (Join-Path $PSScriptRoot 'godot_test_common.ps1')
$godot = (Initialize-GodotTestEnvironment -RepoRoot $repoRoot).Console
$projectRoot = Join-Path $repoRoot 'godot'
Invoke-GodotCheckedScript -Executable $godot -ProjectRoot $projectRoot `
    -Script 'res://tests/native_rules_session_contract_test.gd' `
    -SuccessMarker 'NATIVE_RULES_SESSION_CONTRACT_OK' `
    -ContractName 'Single-process Godot Native ABI 2 contract'

Write-Host 'FAST_VERIFICATION_OK'
