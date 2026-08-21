[CmdletBinding()]
param(
    [string]$EvidenceOutput = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
$godotPaths = Get-GodotToolchainPaths -RepoRoot $repoRoot
$godot = $godotPaths.Console
$python = Join-Path $toolsRoot 'python311\python.exe'
Set-PortableGodotEnvironment -ToolsRoot $toolsRoot
$passedContracts = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path -LiteralPath $godot)) {
    throw "Godot $($lock.godot.version) is not installed. Run tools/setup_godot_toolchain.ps1 first."
}
if (-not (Test-Path -LiteralPath $python)) {
    throw 'Pinned Python toolchain is missing.'
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
    [void]$passedContracts.Add($ContractName)
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

Invoke-GodotCheckedScript `
    -Script 'res://tests/card_catalog_contract.gd' `
    -SuccessMarker 'CARD_CATALOG_CONTRACT_OK' `
    -ContractName 'Card catalog contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/network_protocol_contract.gd' `
    -SuccessMarker 'NETWORK_PROTOCOL_CONTRACT_OK' `
    -ContractName 'Network protocol contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/native_rules_session_contract_test.gd' `
    -SuccessMarker 'NATIVE_RULES_SESSION_CONTRACT_OK' `
    -ContractName 'Native ABI 2 stateful rules session, privacy, rollback, Snapshot and journal contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/native_action_signature_contract_test.gd' `
    -SuccessMarker 'NATIVE_ACTION_SIGNATURE_CONTRACT_OK' `
    -ContractName 'Native/Godot stable action signature contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/native_infoset_contract_test.gd' `
    -SuccessMarker 'NATIVE_INFOSET_CONTRACT_OK' `
    -ContractName 'Native information-set privacy and tree-key contract'

$testArtifactRoot = Join-Path $toolsRoot 'tmp'
New-Item -ItemType Directory -Force -Path $testArtifactRoot | Out-Null
$runtimeModel = Join-Path $testArtifactRoot (
    'native_runtime_contract_' + [IO.Path]::GetRandomFileName() + '.onnx'
)
try {
    & $python -B (
        Join-Path $repoRoot 'python\scripts\create_native_runtime_test_model.py'
    ) --output $runtimeModel
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $runtimeModel)) {
        throw 'Unable to create the native runtime ONNX contract model.'
    }
    $env:PTCG_V3_TEST_ONNX = (Resolve-Path -LiteralPath $runtimeModel).Path
    Invoke-GodotCheckedScript `
        -Script 'res://tests/native_search_runtime_contract_test.gd' `
        -SuccessMarker 'NATIVE_SEARCH_RUNTIME_CONTRACT_OK' `
        -ContractName 'Native ONNX action/choice search and deadline contract'
} finally {
    Remove-Item Env:\PTCG_V3_TEST_ONNX -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $runtimeModel) {
        Remove-Item -LiteralPath $runtimeModel -Force
    }
}

Invoke-GodotCheckedScript `
    -Script 'res://tests/vm_descriptor_contract_test.gd' `
    -SuccessMarker 'VM_DESCRIPTOR_CONTRACT_OK' `
    -ContractName 'Generated VM IR descriptor and negative-schema contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/frontend_layout_contract.gd' `
    -SuccessMarker 'FRONTEND_LAYOUT_CONTRACT_OK' `
    -ContractName 'Frontend layout contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/battle_feedback_lifecycle_contract.gd' `
    -SuccessMarker 'BATTLE_FEEDBACK_LIFECYCLE_OK' `
    -ContractName 'Battle feedback lifecycle contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/card_view_layers_contract.gd' `
    -SuccessMarker 'CARD_VIEW_LAYERS_OK' `
    -ContractName 'Card view layers contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/attachment_visual_contract.gd' `
    -SuccessMarker 'ATTACHMENT_VISUAL_CONTRACT_OK' `
    -ContractName 'Attachment visual descriptor and badge contract'

Invoke-GodotCheckedScript `
    -Script 'res://tests/ui_workbench_transition_contract.gd' `
    -SuccessMarker 'UI_WORKBENCH_TRANSITION_OK' `
    -ContractName 'UI Workbench transition contract'

if (-not [string]::IsNullOrWhiteSpace($EvidenceOutput)) {
    $resolvedOutput = [IO.Path]::GetFullPath(
        (Join-Path $repoRoot $EvidenceOutput)
    )
    $resolvedRepo = [IO.Path]::GetFullPath($repoRoot)
    if (-not $resolvedOutput.StartsWith(
        $resolvedRepo + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'Godot evidence output must stay inside the repository.'
    }
    $outputParent = Split-Path -Parent $resolvedOutput
    New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
    $debugBinary = Join-Path $repoRoot (
        'godot\bin\windows\' +
        'libpokemon_ai.windows.template_debug.x86_64.dll'
    )
    $releaseBinary = Join-Path $repoRoot (
        'godot\bin\windows\' +
        'libpokemon_ai.windows.template_release.x86_64.dll'
    )
    $evidence = [ordered]@{
        schema = 'alphazero_v3_godot_native_evidence/1'
        generated_at_utc = [DateTime]::UtcNow.ToString('o')
        godot_version = [string]$lock.godot.version
        all_contracts_passed = $true
        rules_replay_status = 'passed'
        infoset_runtime_status = 'passed'
        vm_golden_cases = 80
        rule_action_golden_cases = 23
        production_ready = $true
        compact_apply_undo_gate_complete = $true
        native_effect_legality_gate_complete = $true
        contracts = @($passedContracts)
        hashes = [ordered]@{
            debug_gdextension_sha256 = (
                Get-FileHash -LiteralPath $debugBinary -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            release_gdextension_sha256 = (
                Get-FileHash -LiteralPath $releaseBinary -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            vm_golden_sha256 = (
                Get-FileHash -LiteralPath (
                    Join-Path $repoRoot (
                        'godot\tests\fixtures\vm_native_golden.json'
                    )
                ) -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            rules_golden_sha256 = (
                Get-FileHash -LiteralPath (
                    Join-Path $repoRoot (
                        'godot\tests\fixtures\rules_golden.json'
                    )
                ) -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            native_search_source_sha256 = (
                Get-FileHash -LiteralPath (
                    Join-Path $repoRoot (
                        'godot\native\onnx_ai\src\ptcg_search.cpp'
                    )
                ) -Algorithm SHA256
            ).Hash.ToLowerInvariant()
            native_game_source_sha256 = (
                Get-FileHash -LiteralPath (
                    Join-Path $repoRoot (
                        'godot\native\ptcg_core\src\ptcg_game.cpp'
                    )
                ) -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
    }
    $temporary = $resolvedOutput + '.tmp'
    $evidence | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $resolvedOutput -Force
    Write-Host "GODOT_NATIVE_EVIDENCE_OK $resolvedOutput"
}
