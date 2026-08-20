[CmdletBinding()]
param([string]$Python = '')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$portable = Join-Path $repoRoot '.tools\python311\python.exe'
if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = if (Test-Path -LiteralPath $portable) { $portable } else { 'python' }
}
$env:PYTHONNOUSERSITE = '1'

& (Join-Path $PSScriptRoot 'test_ptcg_core.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Dependency-free C++ rules core failed.' }

& $Python -B (Join-Path $repoRoot 'python\scripts\card_author.py') lint
if ($LASTEXITCODE -ne 0) { throw 'Card authoring contract failed.' }

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$godotPaths = Get-GodotToolchainPaths -RepoRoot $repoRoot
$godot = $godotPaths.Console
Set-PortableGodotEnvironment -ToolsRoot (Join-Path $repoRoot '.tools')
$godotOutput = & $godot `
    --headless `
    --path (Join-Path $repoRoot 'godot') `
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
