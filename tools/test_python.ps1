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
        'tests.test_game_engine_refactor',
        'tests.test_action_preflight',
        'tests.test_regression_fixes',
        'tests.test_vm_ir_contract',
        'tests.test_godot_export',
        'tests.test_release_manifest',
        'tests.test_model_promotion',
        'tests.test_android_release_gate',
        'tests.test_rules_migration',
        'tests.test_evaluation_stats',
        'tests.test_pending_continuations',
        'tests.test_snapshot_schema',
        'tests.test_game_screen_input',
        'tests.test_python_tool_boundary',
        'tests.test_relay_server',
        'tests.test_type_matchups',
        'tests.test_darkness_deck',
        'tests.test_steel_deck'
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
