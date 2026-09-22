[CmdletBinding()]
param([switch]$SkipPerformance)

$ErrorActionPreference = 'Stop'
$frontendRepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'godot_test_common.ps1')
$frontendGodot = (Initialize-GodotTestEnvironment -RepoRoot $frontendRepoRoot).Console
$frontendOutput = Join-Path $frontendRepoRoot 'build/frontend-club'
New-Item -ItemType Directory -Force -Path $frontendOutput | Out-Null
$frontendContracts = @(
    @{ Script = 'frontend_club_visual_contract'; Marker = 'FRONTEND_CLUB_VISUAL_OK'; Log = 'club-visual.log' },
    @{ Script = 'battle_touch_resume_contract'; Marker = 'BATTLE_TOUCH_RESUME_CONTRACT_OK'; Log = 'battle-return.log' }
)
foreach ($frontendContract in $frontendContracts) {
    $frontendArguments = @('--path', (Join-Path $frontendRepoRoot 'godot'),
        '--script', "res://tests/$($frontendContract.Script).gd")
    if ($SkipPerformance -and $frontendContract.Script -eq 'frontend_club_visual_contract') {
        $frontendArguments += @('--', '--skip-performance')
    }
    $frontendCapture = Invoke-GodotCapture -Executable $frontendGodot -ArgumentList $frontendArguments
    $frontendExitCode = $LASTEXITCODE
    $frontendCapture | Set-Content -LiteralPath (Join-Path $frontendOutput $frontendContract.Log) -Encoding utf8
    $frontendLog = $frontendCapture -join "`n"
    if ($frontendExitCode -ne 0 -or $frontendLog -notmatch $frontendContract.Marker -or
        $frontendLog -match '(?m)^(SCRIPT ERROR|SHADER ERROR|ERROR|WARNING): (?!Failed to read the root certificate store\.)') {
        $frontendCapture | Select-Object -Last 30 | Write-Host
        throw "Frontend graphics validation failed: $($frontendContract.Script)"
    }
    $frontendCapture | Where-Object { $_ -match '^(FRONTEND_|COMPLETED_MATCH_RETURN|BATTLE_TOUCH_RESUME_)' } | Write-Host
}
