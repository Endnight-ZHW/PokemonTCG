[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$godot = Join-Path $toolsRoot 'godot-4.7\Godot_v4.7-stable_win64_console.exe'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
Set-PortableGodotEnvironment -ToolsRoot $toolsRoot
if (-not (Test-Path -LiteralPath $godot)) {
    throw 'Godot 4.7 is not installed.'
}
$output = & $godot `
    --headless `
    --path (Join-Path $repoRoot 'godot_client') `
    --script 'res://tests/ai_regression.gd' 2>&1
$output | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    throw "Godot AI regression failed with exit code $LASTEXITCODE"
}
$joined = $output -join "`n"
if ($joined -match '(?m)^(SCRIPT ERROR|ERROR):') {
    throw 'Godot emitted errors during AI regression.'
}
if ($joined -notmatch 'AI_REGRESSION_OK') {
    throw 'Godot AI regression success marker was not emitted.'
}
