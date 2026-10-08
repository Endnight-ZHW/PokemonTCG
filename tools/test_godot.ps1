[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'

& (Join-Path $PSScriptRoot 'build_audio.ps1') -Check

. (Join-Path $PSScriptRoot 'godot_test_common.ps1')
$godotPaths = Initialize-GodotTestEnvironment -RepoRoot $repoRoot
$godot = $godotPaths.Console

function Clear-StaleGodotImportArtifacts {
    $binRoot = Join-Path $repoRoot 'godot\bin\windows'
    $userRoot = Join-Path $env:APPDATA 'Godot\app_userdata\PokemonTCG'
    $editorRoot = Join-Path $env:APPDATA 'Godot'
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
    @('audio_system_contract', 'AUDIO_SYSTEM_CONTRACT_OK', 'Audio assets, variations, scoped voices, music lifecycle and settings'),
    @('happy4_contract', 'HAPPY4_CONTRACT_OK', 'Happy Set 4 deck lists, real card effects and choice privacy'),
    @('card_catalog_contract', 'CARD_CATALOG_CONTRACT_OK', 'Card catalog contract'),
    @('card_presentation_contract', 'CARD_PRESENTATION_CONTRACT_OK', 'Card audit, shared presentation and player-facing notification text'),
    @('network_protocol_contract', 'NETWORK_PROTOCOL_CONTRACT_OK', 'Network protocol contract'),
    @('relay_connection_contract', 'RELAY_CONNECTION_CONTRACT_OK', 'Relay defaults, asynchronous failures, handshake timeout and room waiting'),
    @('relay_srv_contract', 'RELAY_SRV_CONTRACT_OK', 'SRV discovery, DNS packet validation, changing ports and room handshakes'),
    @('native_rules_session_contract_test', 'NATIVE_RULES_SESSION_CONTRACT_OK', 'Native ABI 2 stateful rules session, privacy, rollback, Snapshot and journal contract'),
    @('vm_descriptor_contract_test', 'VM_DESCRIPTOR_CONTRACT_OK', 'Generated VM IR descriptor and negative-schema contract'),
    @('desktop_layout_contract', 'DESKTOP_LAYOUT_CONTRACT_OK', 'Unified desktop and tablet layout, auto previews and resize stability'),
    @('frontend_layout_contract', 'FRONTEND_LAYOUT_CONTRACT_OK', 'Frontend layout contract'),
    @('frontend_redesign_contract', 'FRONTEND_REDESIGN_OK', 'Deck assignment, shared attribute badges, network picker, modal restoration and result states'),
    @('title_showcase_contract', 'TITLE_SHOWCASE_CONTRACT_OK', 'Random homepage decks, collision clearance, drag and modal suspension'),
    @('home_interaction_contract', 'HOME_INTERACTION_CONTRACT_OK', 'Homepage box, artwork, coin, touch, interruption and rotation contract'),
    @('home_prop_clearance_contract', 'HOME_PROP_CLEARANCE_OK', 'Consistent attribute badge style and coin takeoff/landing clearance'),
    @('modal_scroll_contract', 'MODAL_SCROLL_CONTRACT_OK', 'Single-owner modal scrolling, content reachability and reading-position restoration'),
    @('touch_scroll_contract', 'TOUCH_SCROLL_CONTRACT_OK', 'Physical touch scrolling, tap cancellation, sliders, choices and button-only hand actions'),
    @('battle_touch_resume_contract', 'BATTLE_TOUCH_RESUME_CONTRACT_OK', 'Projected hand/prize taps and battle-to-home showcase lifecycle'),
    @('battle_feedback_lifecycle_contract', 'BATTLE_FEEDBACK_LIFECYCLE_OK', 'Battle feedback lifecycle contract'),
    @('battle_animation_contract', 'BATTLE_ANIMATION_CONTRACT_OK', 'Animation fixtures, contact commits, cancellation, privacy and bounded audio'),
    @('battle_motion_clearance_contract', 'BATTLE_MOTION_CLEARANCE_OK', 'Actual flipped card volumes, hand/pile clearance and completed flight cleanup'),
    @('battle_action_identity_contract', 'BATTLE_ACTION_IDENTITY_OK', 'Duplicate hand source identity and attach-before-switch stacks using real native actions'),
    @('battle_coin_choice_contract', 'BATTLE_COIN_CHOICE_OK', 'Real Catcher, Hammer and attack choices, shared physical coin, contact audio and modal lifecycle'),
    @('battle_landing_feedback_contract', 'BATTLE_LANDING_FEEDBACK_OK', 'Physical landing feedback geometry, both views and compact/portrait layouts'),
    @('double_knockout_flow_contract', 'DOUBLE_KNOCKOUT_FLOW_OK', 'Reactive double knockout animation, prize selection, promotions and AI continuation'),
    @('card_view_layers_contract', 'CARD_VIEW_LAYERS_OK', 'Card view layers contract'),
    @('view_model_ownership_contract', 'VIEW_MODEL_OWNERSHIP_OK', 'Player view privacy and queued snapshot ownership'),
    @('battle_button_interaction_contract', 'BATTLE_BUTTON_INTERACTION_OK', 'Explicit card actions, target guidance, highlights, cancellation and stale confirmation'),
    @('card_action_popover_layout_contract', 'CARD_ACTION_POPOVER_LAYOUT_OK', 'Vertical action menus, constrained placement, scroll reachability and pointer activation'),
    @('battle_interaction_redesign_contract', 'BATTLE_INTERACTION_REDESIGN_OK', 'Real pointer cancellation, distribution drafts, reassignment, undo and system Back'),
    @('energy_sparse_source_contract', 'ENERGY_SPARSE_SOURCE_OK', 'Real Miraidon source identity, sparse indices, physical duplicates and cinematic pointer submission'),
    @('battle_card_effect_hand_contract', 'BATTLE_CARD_EFFECT_HAND_OK', 'Native card effects, pending choices, hand identity, duplicate packets and hidden-hand rendering'),
    @('battle_3d_contract', 'BATTLE_3D_CONTRACT_OK', 'Physical cards, hand layout, projection, privacy, motion, pooling and adaptive quality'),
    @('battle_usability_contract', 'BATTLE_USABILITY_CONTRACT_OK', 'Pointer gestures, cancellation, browsing anchors and safe confirmations'),
    @('attachment_visual_contract', 'ATTACHMENT_VISUAL_CONTRACT_OK', 'Attachment visual descriptor and badge contract'),
    @('ui_workbench_transition_contract', 'UI_WORKBENCH_TRANSITION_OK', 'UI Workbench transition contract')
)
foreach ($contract in $contracts) {
    Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
        -Script "res://tests/$($contract[0]).gd" -SuccessMarker $contract[1] -ContractName $contract[2]
}
