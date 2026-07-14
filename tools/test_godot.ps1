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

function Invoke-GodotCapture {
    param([string[]]$ArgumentList)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $godot @ArgumentList 2>&1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

$ignoredGodotErrorPattern = 'Failed to read the root certificate store\.'
$fatalGodotErrorPattern = "(?m)^(SCRIPT ERROR|ERROR|WARNING): (?!$ignoredGodotErrorPattern)"

function Invoke-GodotCheckedScript {
    param(
        [Parameter(Mandatory)]
        [string]$Script,

        [Parameter(Mandatory)]
        [string]$SuccessMarker,

        [Parameter(Mandatory)]
        [string]$ContractName
    )

    $output = Invoke-GodotCapture -ArgumentList @(
        '--headless',
        '--path', (Join-Path $repoRoot 'godot'),
        '--script', $Script
    )
    $output | ForEach-Object { Write-Host $_ }

    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "$ContractName failed with exit code $exitCode"
    }
    $joinedOutput = $output -join "`n"
    if ($joinedOutput -match $fatalGodotErrorPattern) {
        throw "Godot emitted script/runtime errors during $ContractName."
    }
    if ($joinedOutput -notmatch [regex]::Escape($SuccessMarker)) {
        throw "$ContractName success marker '$SuccessMarker' was not emitted."
    }
}

Clear-StaleGodotImportArtifacts
$importOutput = Invoke-GodotCapture -ArgumentList @(
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

$battleTableLayoutContractPath = Join-Path $repoRoot 'godot\tests\battle_table_layout_contract.gd'
$testRunnerPath = Join-Path $repoRoot 'godot\tests\test_runner.gd'
if (-not (Test-Path -LiteralPath $battleTableLayoutContractPath)) {
    throw 'Battle table layout contract script is missing.'
}
$testRunnerSource = Get-Content -LiteralPath $testRunnerPath -Raw
if ($testRunnerSource -notmatch 'BattleTableLayoutContract\.run\(\)') {
    throw 'Battle table layout contract is not registered in the main Godot test runner.'
}

# BattleTableLayoutContract is a RefCounted suite, so the main SceneTree runner
# executes it and GODOT_TESTS_OK is its process-level success marker.
Invoke-GodotCheckedScript `
    -Script 'res://tests/test_runner.gd' `
    -SuccessMarker 'GODOT_TESTS_OK' `
    -ContractName 'Godot tests (including the battle table layout contract)'

Invoke-GodotCheckedScript `
    -Script 'res://tests/card_catalog_contract.gd' `
    -SuccessMarker 'CARD_CATALOG_CONTRACT_OK' `
    -ContractName 'Card catalog contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/network_protocol_contract.gd' `
    -SuccessMarker 'NETWORK_PROTOCOL_CONTRACT_OK' `
    -ContractName 'Network protocol contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/frontend_layout_contract.gd' `
    -SuccessMarker 'FRONTEND_LAYOUT_CONTRACT_OK' `
    -ContractName 'Frontend layout contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/presentation_event_contract.gd' `
    -SuccessMarker 'PRESENTATION_EVENT_CONTRACT_OK' `
    -ContractName 'Presentation event contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/battle_feedback_lifecycle_contract.gd' `
    -SuccessMarker 'BATTLE_FEEDBACK_LIFECYCLE_OK' `
    -ContractName 'Battle feedback lifecycle contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/card_view_layers_contract.gd' `
    -SuccessMarker 'CARD_VIEW_LAYERS_OK' `
    -ContractName 'Card view layers contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/battle_transition_contract.gd' `
    -SuccessMarker 'BATTLE_TRANSITION_CONTRACT_OK' `
    -ContractName 'Battle transition contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/ui_workbench_transition_contract.gd' `
    -SuccessMarker 'UI_WORKBENCH_TRANSITION_OK' `
    -ContractName 'UI Workbench transition contract'
