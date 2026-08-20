[CmdletBinding()]
param(
    [ValidateSet('core', 'full')]
    [string]$Tier = 'full',
    [string]$Python = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Python)) {
    $portable = Join-Path $repoRoot '.tools\python311\python.exe'
    $Python = if (Test-Path -LiteralPath $portable) { $portable } else { 'python' }
} elseif (
    -not [System.IO.Path]::IsPathRooted($Python) -and
    (Test-Path -LiteralPath $Python -PathType Leaf)
) {
    # Resolve caller-relative executable paths before Push-Location changes
    # the working directory to python/.  CI passes .\.tools\python311 here.
    $Python = (Resolve-Path -LiteralPath $Python).Path
}

$env:PYTHONNOUSERSITE = '1'
$modules = @()
if ($Tier -eq 'core') {
    $modules = @(
		'tests.test_card_authoring_dsl',
		'tests.test_card_rules_consistency',
		'tests.test_vm_descriptors',
		'tests.test_native_rules_session',
		'tests.test_native_game_engine_facade',
        'tests.test_godot_export',
        'tests.test_release_manifest',
        'tests.test_android_release_gate',
        'tests.test_snapshot_schema',
        'tests.test_draw_ai_semantics',
		'tests.test_energy_view',
		'tests.test_ai_strategy_definitions',
		'tests.test_ai_evaluation_report',
		'tests.test_release_evidence_v2',
        'tests.test_python_tool_boundary',
		'tests.test_relay_server'
    )
}

Push-Location (Join-Path $repoRoot 'python')
try {
    if ($Tier -eq 'full') {
        & $Python -B -m unittest discover -q
    } else {
        & $Python -B -m unittest @modules -q
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Python $Tier tests failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}
Write-Host "PYTHON_TESTS_OK tier=$Tier"
