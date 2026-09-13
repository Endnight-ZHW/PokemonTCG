[CmdletBinding()]
param([switch]$SkipPerformance)

$ErrorActionPreference = 'Stop'
$frontendRepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'godot_test_common.ps1')
$frontendGodot = (Initialize-GodotTestEnvironment -RepoRoot $frontendRepoRoot).Console
$frontendOutput = Join-Path $frontendRepoRoot 'build/frontend-club'
New-Item -ItemType Directory -Force -Path $frontendOutput | Out-Null
$frontendArguments = @('--path', (Join-Path $frontendRepoRoot 'godot'),
    '--script', 'res://tests/frontend_club_visual_contract.gd')
if ($SkipPerformance) { $frontendArguments += @('--', '--skip-performance') }
$frontendCapture = Invoke-GodotCapture -Executable $frontendGodot -ArgumentList $frontendArguments
$frontendExitCode = $LASTEXITCODE
$frontendCapture | Set-Content -LiteralPath (Join-Path $frontendOutput 'club-visual.log') -Encoding utf8
$frontendLog = $frontendCapture -join "`n"
if ($frontendExitCode -ne 0 -or $frontendLog -notmatch 'FRONTEND_CLUB_VISUAL_OK' -or
    $frontendLog -match '(?m)^(SCRIPT ERROR|SHADER ERROR|ERROR|WARNING): (?!Failed to read the root certificate store\.)') {
    $frontendCapture | Select-Object -Last 30 | Write-Host
    throw 'Frontend graphics, lifecycle or frame-budget validation failed.'
}
$frontendCapture | Where-Object { $_ -match '^FRONTEND_' } | Write-Host
