[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'

. (Join-Path $PSScriptRoot 'godot_test_common.ps1')
$godotPaths = Initialize-GodotTestEnvironment -RepoRoot $repoRoot
$godot = $godotPaths.Console

function Clear-StaleGodotImportArtifacts {
    $binRoot = Join-Path $repoRoot 'godot\bin\windows'
    $userRoot = Join-Path $toolsRoot 'appdata\Godot\app_userdata\PokemonTCG'
    $editorRoot = Join-Path $toolsRoot 'appdata\Godot'
    if (Test-Path -LiteralPath $binRoot) {
        Get-ChildItem -LiteralPath $binRoot -Force -File |
            Where-Object { $_.Name -like '~libpokemon_ai.windows.*' } |
            Remove-Item -Force
    }
    $recoveryLock = Join-Path $userRoot '.recovery_mode_lock'
    if (Test-Path -LiteralPath $recoveryLock) {
        Remove-Item -LiteralPath $recoveryLock -Force
    }
    if (Test-Path -LiteralPath $editorRoot) {
        Get-ChildItem -LiteralPath $editorRoot -Force -File |
            Where-Object { $_.Name -like "editor_settings-$($godotPaths.Series).tres*.tmp" } |
            Remove-Item -Force
    }
}

$fatalGodotErrorPattern = '(?m)^(SCRIPT ERROR|ERROR|WARNING): (?!Failed to read the root certificate store\.)'

Clear-StaleGodotImportArtifacts
$importOutput = Invoke-GodotCapture -Executable $godot -ArgumentList @(
    '--headless',
    '--path', (Join-Path $repoRoot 'godot'),
    '--import'
)
$importOutput | ForEach-Object { Write-Host $_ }

$importExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
if ($importExitCode -ne 0) {
    throw "Godot import failed with exit code $importExitCode"
}
$joinedImportOutput = $importOutput -join "`n"
if ($joinedImportOutput -match $fatalGodotErrorPattern) {
    throw 'Godot emitted script/runtime errors during import.'
}

$contracts = @(
    @('card_catalog_contract', 'CARD_CATALOG_CONTRACT_OK', 'Card catalog contract'),
    @('card_presentation_contract', 'CARD_PRESENTATION_CONTRACT_OK', 'Card visual audit coverage and shared presentation contract'),
    @('network_protocol_contract', 'NETWORK_PROTOCOL_CONTRACT_OK', 'Network protocol contract'),
    @('native_rules_session_contract_test', 'NATIVE_RULES_SESSION_CONTRACT_OK', 'Native ABI 2 stateful rules session, privacy, rollback, Snapshot and journal contract'),
    @('vm_descriptor_contract_test', 'VM_DESCRIPTOR_CONTRACT_OK', 'Generated VM IR descriptor and negative-schema contract'),
    @('frontend_layout_contract', 'FRONTEND_LAYOUT_CONTRACT_OK', 'Frontend layout contract'),
    @('battle_feedback_lifecycle_contract', 'BATTLE_FEEDBACK_LIFECYCLE_OK', 'Battle feedback lifecycle contract'),
    @('card_view_layers_contract', 'CARD_VIEW_LAYERS_OK', 'Card view layers contract'),
    @('view_model_ownership_contract', 'VIEW_MODEL_OWNERSHIP_OK', 'Player view privacy and queued snapshot ownership'),
    @('battle_drag_lifecycle_contract', 'BATTLE_DRAG_LIFECYCLE_OK', 'Drag tracking, stale completions, cancellation and resync'),
    @('attachment_visual_contract', 'ATTACHMENT_VISUAL_CONTRACT_OK', 'Attachment visual descriptor and badge contract'),
    @('ui_workbench_transition_contract', 'UI_WORKBENCH_TRANSITION_OK', 'UI Workbench transition contract')
)
foreach ($contract in $contracts) {
    Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
        -Script "res://tests/$($contract[0]).gd" -SuccessMarker $contract[1] -ContractName $contract[2]
}
