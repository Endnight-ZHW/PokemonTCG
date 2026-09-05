[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
$godotPaths = Get-GodotToolchainPaths -RepoRoot $repoRoot
$godot = $godotPaths.Console
Set-PortableGodotEnvironment -ToolsRoot $toolsRoot

if (-not (Test-Path -LiteralPath $godot)) {
    throw "Godot $($lock.godot.version) is not installed. Run tools/setup_godot_toolchain.ps1 first."
}

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

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
    -Script 'res://tests/card_catalog_contract.gd' `
    -SuccessMarker 'CARD_CATALOG_CONTRACT_OK' `
    -ContractName 'Card catalog contract'

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
    -Script 'res://tests/card_presentation_contract.gd' `
    -SuccessMarker 'CARD_PRESENTATION_CONTRACT_OK' `
    -ContractName 'Card visual audit coverage and shared presentation contract'

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
    -Script 'res://tests/network_protocol_contract.gd' `
    -SuccessMarker 'NETWORK_PROTOCOL_CONTRACT_OK' `
    -ContractName 'Network protocol contract'

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
    -Script 'res://tests/native_rules_session_contract_test.gd' `
    -SuccessMarker 'NATIVE_RULES_SESSION_CONTRACT_OK' `
    -ContractName 'Native ABI 2 stateful rules session, privacy, rollback, Snapshot and journal contract'

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
    -Script 'res://tests/vm_descriptor_contract_test.gd' `
    -SuccessMarker 'VM_DESCRIPTOR_CONTRACT_OK' `
    -ContractName 'Generated VM IR descriptor and negative-schema contract'

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
    -Script 'res://tests/frontend_layout_contract.gd' `
    -SuccessMarker 'FRONTEND_LAYOUT_CONTRACT_OK' `
    -ContractName 'Frontend layout contract'

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
    -Script 'res://tests/battle_feedback_lifecycle_contract.gd' `
    -SuccessMarker 'BATTLE_FEEDBACK_LIFECYCLE_OK' `
    -ContractName 'Battle feedback lifecycle contract'

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
    -Script 'res://tests/card_view_layers_contract.gd' `
    -SuccessMarker 'CARD_VIEW_LAYERS_OK' `
    -ContractName 'Card view layers contract'

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
    -Script 'res://tests/view_model_ownership_contract.gd' `
    -SuccessMarker 'VIEW_MODEL_OWNERSHIP_OK' `
    -ContractName 'Player view privacy and queued snapshot ownership'

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
    -Script 'res://tests/battle_drag_lifecycle_contract.gd' `
    -SuccessMarker 'BATTLE_DRAG_LIFECYCLE_OK' `
    -ContractName 'Drag tracking, stale completions, cancellation and resync'

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
    -Script 'res://tests/attachment_visual_contract.gd' `
    -SuccessMarker 'ATTACHMENT_VISUAL_CONTRACT_OK' `
    -ContractName 'Attachment visual descriptor and badge contract'

Invoke-GodotCheckedScript -Executable $godot -ProjectRoot (Join-Path $repoRoot godot) -AllowRootCertificateWarning `
    -Script 'res://tests/ui_workbench_transition_contract.gd' `
    -SuccessMarker 'UI_WORKBENCH_TRANSITION_OK' `
    -ContractName 'UI Workbench transition contract'
