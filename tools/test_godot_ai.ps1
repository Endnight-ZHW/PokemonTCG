[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'godot_test_common.ps1')
$godot = (Initialize-GodotTestEnvironment -RepoRoot $repoRoot).Console

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) `
    -Script 'res://tests/ai_regression.gd' -SuccessMarker 'AI_REGRESSION_OK' `
    -AllowWarnings -AllowRootCertificateWarning
Write-Host 'GODOT_CHALLENGE_VERIFICATION_OK'
