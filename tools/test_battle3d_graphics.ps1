[CmdletBinding()]
param([switch]$SkipPerformance)

$ErrorActionPreference = 'Stop'
$battleRepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'godot_test_common.ps1')
$battleGodot = (Initialize-GodotTestEnvironment -RepoRoot $battleRepoRoot).Console
$battleProject = Join-Path $battleRepoRoot 'godot'
$battleBuild = Join-Path $battleRepoRoot 'build'
New-Item -ItemType Directory -Force -Path $battleBuild | Out-Null

function Invoke-BattleGraphicsCheck {
    param([string]$Script, [string]$Marker, [string]$LogName)
    $capture = Invoke-GodotCapture -Executable $battleGodot -ArgumentList @(
        '--path', $battleProject, '--script', $Script
    )
    $battleExitCode = $LASTEXITCODE
    $capture | Set-Content -LiteralPath (Join-Path $battleBuild $LogName) -Encoding utf8
    $combined = $capture -join "`n"
    if ($battleExitCode -ne 0 -or $combined -notmatch [regex]::Escape($Marker) -or
        $combined -match '(?m)^(SCRIPT ERROR|SHADER ERROR|ERROR|WARNING): (?!Failed to read the root certificate store\.)') {
        $capture | Select-Object -Last 35 | Write-Host
        throw "Battle graphics validation failed: $Script"
    }
    Write-Host $Marker
}

Invoke-BattleGraphicsCheck -Script 'res://tests/battle_button_interaction_contract.gd' `
    -Marker 'BATTLE_BUTTON_INTERACTION_OK' -LogName 'battle3d-button-interaction.log'
Invoke-BattleGraphicsCheck -Script 'res://tests/battle_3d_contract.gd' `
    -Marker 'BATTLE_3D_CONTRACT_OK' -LogName 'battle3d-graphics-contract.log'
Invoke-BattleGraphicsCheck -Script 'res://tests/battle_3d_visual_contract.gd' `
    -Marker 'BATTLE_3D_VISUAL_CONTRACT_OK' -LogName 'battle3d-visual-contract.log'
Invoke-BattleGraphicsCheck -Script 'res://tests/battle_animation_visual.gd' `
    -Marker 'BATTLE_ANIMATION_VISUAL_OK' -LogName 'battle-animation-visual.log'
Invoke-BattleGraphicsCheck -Script 'res://tests/battle_coin_choice_contract.gd' `
    -Marker 'BATTLE_COIN_CHOICE_OK' -LogName 'coin-choice-graphics.log'
Invoke-BattleGraphicsCheck -Script 'res://tests/battle_landing_feedback_contract.gd' `
    -Marker 'BATTLE_LANDING_FEEDBACK_OK' -LogName 'battle-landing-feedback.log'
Invoke-BattleGraphicsCheck -Script 'res://tests/battle_hand_distribution_contract.gd' `
    -Marker 'BATTLE_HAND_DISTRIBUTION_OK' -LogName 'battle-hand-distribution.log'
Invoke-BattleGraphicsCheck -Script 'res://tests/battle_animation_motion_review.gd' `
    -Marker 'BATTLE_ANIMATION_MOTION_OK' -LogName 'battle-animation-motion.log'
Invoke-BattleGraphicsCheck -Script 'res://tests/battle_card_effect_hand_contract.gd' `
    -Marker 'BATTLE_CARD_EFFECT_HAND_OK' -LogName 'battle3d-card-effect-hand.log'
Invoke-BattleGraphicsCheck -Script 'res://tests/battle_action_identity_contract.gd' `
    -Marker 'BATTLE_ACTION_IDENTITY_OK' -LogName 'battle-action-identity-graphics.log'
Invoke-BattleGraphicsCheck -Script 'res://tests/double_knockout_flow_contract.gd' `
    -Marker 'DOUBLE_KNOCKOUT_FLOW_OK' -LogName 'battle3d-double-knockout-flow.log'
Invoke-BattleGraphicsCheck -Script 'res://tests/ui_preview.gd' `
    -Marker 'UI_PREVIEWS_OK' -LogName 'battle3d-all-preview.log'
if (-not $SkipPerformance) {
    Invoke-BattleGraphicsCheck -Script 'res://tests/battle_3d_performance.gd' `
        -Marker 'BATTLE_3D_PERFORMANCE_JSON=' -LogName 'battle3d-performance.log'
    $report = Get-Content -Raw -LiteralPath (Join-Path $battleBuild 'battle3d-performance.json') | ConvertFrom-Json
    foreach ($profile in $report.profiles) {
        if (-not $profile.passes_budget) {
            throw "Frame budget exceeded: $($profile.profile), P95=$($profile.p95_ms) ms"
        }
        Write-Host "BATTLE_3D_FRAME_BUDGET_OK profile=$($profile.profile) p95_ms=$($profile.p95_ms) draws=$($profile.draw_calls)"
    }
}
Write-Host 'BATTLE_3D_GRAPHICS_OK'
