[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$godot = Join-Path $repoRoot '.tools\godot-4.7\Godot_v4.7-stable_win64_console.exe'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
Set-PortableGodotEnvironment -ToolsRoot $toolsRoot

if (-not (Test-Path -LiteralPath $godot)) {
    throw 'Godot 4.7 is not installed. Run tools/setup_godot_toolchain.ps1 first.'
}

$importOutput = & $godot `
    --headless `
    --editor `
    --path (Join-Path $repoRoot 'godot_client') `
    --import 2>&1
$importOutput | ForEach-Object { Write-Host $_ }

$importExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
if ($importExitCode -ne 0) {
    throw "Godot import failed with exit code $importExitCode"
}
$joinedImportOutput = $importOutput -join "`n"
if ($joinedImportOutput -match '(?m)^(SCRIPT ERROR|ERROR):') {
    throw 'Godot emitted script/runtime errors during import.'
}

$testOutput = & $godot `
    --headless `
    --path (Join-Path $repoRoot 'godot_client') `
    --script 'res://tests/test_runner.gd' 2>&1
$testOutput | ForEach-Object { Write-Host $_ }

$exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
if ($exitCode -ne 0) {
    throw "Godot tests failed with exit code $exitCode"
}
$joinedOutput = $testOutput -join "`n"
if ($joinedOutput -match '(?m)^(SCRIPT ERROR|ERROR):') {
    throw 'Godot emitted script/runtime errors during tests.'
}
if ($joinedOutput -notmatch 'GODOT_TESTS_OK') {
    throw 'Godot test success marker was not emitted.'
}
