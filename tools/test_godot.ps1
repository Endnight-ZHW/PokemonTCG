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
$fatalGodotErrorPattern = "(?m)^(SCRIPT ERROR|ERROR): (?!$ignoredGodotErrorPattern)"

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

$testOutput = Invoke-GodotCapture -ArgumentList @(
    '--headless',
    '--path', (Join-Path $repoRoot 'godot'),
    '--script', 'res://tests/test_runner.gd'
)
$testOutput | ForEach-Object { Write-Host $_ }

$exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
if ($exitCode -ne 0) {
    throw "Godot tests failed with exit code $exitCode"
}
$joinedOutput = $testOutput -join "`n"
if ($joinedOutput -match $fatalGodotErrorPattern) {
    throw 'Godot emitted script/runtime errors during tests.'
}
if ($joinedOutput -notmatch 'GODOT_TESTS_OK') {
    throw 'Godot test success marker was not emitted.'
}

$catalogContractOutput = Invoke-GodotCapture -ArgumentList @(
    '--headless',
    '--path', (Join-Path $repoRoot 'godot'),
    '--script', 'res://tests/card_catalog_contract.gd'
)
$catalogContractOutput | ForEach-Object { Write-Host $_ }

$catalogContractExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
if ($catalogContractExitCode -ne 0) {
    throw "Card catalog contract failed with exit code $catalogContractExitCode"
}
$joinedCatalogContractOutput = $catalogContractOutput -join "`n"
if ($joinedCatalogContractOutput -match $fatalGodotErrorPattern) {
    throw 'Godot emitted script/runtime errors during the card catalog contract.'
}
if ($joinedCatalogContractOutput -notmatch 'CARD_CATALOG_CONTRACT_OK') {
    throw 'Card catalog contract success marker was not emitted.'
}

$networkContractOutput = Invoke-GodotCapture -ArgumentList @(
    '--headless',
    '--path', (Join-Path $repoRoot 'godot'),
    '--script', 'res://tests/network_protocol_contract.gd'
)
$networkContractOutput | ForEach-Object { Write-Host $_ }

$networkContractExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
if ($networkContractExitCode -ne 0) {
    throw "Network protocol contract failed with exit code $networkContractExitCode"
}
$joinedNetworkContractOutput = $networkContractOutput -join "`n"
if ($joinedNetworkContractOutput -match $fatalGodotErrorPattern) {
    throw 'Godot emitted script/runtime errors during the network protocol contract.'
}
if ($joinedNetworkContractOutput -notmatch 'NETWORK_PROTOCOL_CONTRACT_OK') {
    throw 'Network protocol contract success marker was not emitted.'
}
