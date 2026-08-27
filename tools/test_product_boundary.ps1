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

$pythonFiles = @(& rg --files $repoRoot -g '*.py' -g '!.tools/**' -g '!godot/.godot/**' `
    -g '!godot/dist/**' -g '!dist/**' -g '!research/deep_ai/build/**')
foreach ($path in $pythonFiles) {
    $relative = [IO.Path]::GetRelativePath($repoRoot, [string]$path).Replace('\', '/')
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
