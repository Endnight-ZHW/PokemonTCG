[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$godot = (Get-GodotToolchainPaths -RepoRoot $repoRoot).Console
Set-PortableGodotEnvironment -ToolsRoot $toolsRoot
if (-not (Test-Path -LiteralPath $godot)) {
    throw 'Godot is not installed. Run setup_godot_toolchain.ps1 first.'
}

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) `
    -Script 'res://tests/ai_regression.gd' -SuccessMarker 'AI_REGRESSION_OK' `
    -AllowWarnings -AllowRootCertificateWarning
Write-Host 'GODOT_CHALLENGE_VERIFICATION_OK'
