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
