[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$forbidden = @(
    'python',
    'requirements.txt',
    'tools/test_python.ps1',
    'godot/data/card_ir_v3.json',
    'python/ptcg_ai_core.pyd',
    'python/ptcg_ai_core.exp',
    'python/ptcg_ai_core.lib'
)
foreach ($relative in $forbidden) {
    if (Test-Path -LiteralPath (Join-Path $repoRoot $relative)) {
        throw "Removed product Python boundary reappeared: $relative"
    }
}

$pythonFiles = @(& git -C $repoRoot ls-files --cached --others --exclude-standard -- '*.py')
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to enumerate product Python files through Git.'
}
foreach ($path in $pythonFiles) {
    $relative = ([string]$path).Replace('\', '/')
    if (-not $relative.StartsWith('research/deep_ai/', [StringComparison]::Ordinal)) {
        throw "Python business file exists outside Deep AI: $relative"
    }
}
foreach ($required in @(
    'godot/authoring/cards',
    'native/ptcg_core/src/ptcg_content_compiler.cpp',
    'native/relay_server/src/relay_server.cpp',
    'research/deep_ai/python/data/card_registry.py'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $required))) {
        throw "Migration boundary input is missing: $required"
    }
}
Write-Host "PRODUCT_BOUNDARY_OK python_files=$($pythonFiles.Count) deep_ai_only=1"
