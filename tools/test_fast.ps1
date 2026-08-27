[CmdletBinding()]
param([string]$Python = '')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$portable = Join-Path $repoRoot '.tools\python311\python.exe'
if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = if (Test-Path -LiteralPath $portable) { $portable } else { 'python' }
}
$env:PYTHONNOUSERSITE = '1'

& (Join-Path $PSScriptRoot 'test_ptcg_core.ps1') -Python $Python
if ($LASTEXITCODE -ne 0) { throw 'Dependency-free C++ rules core failed.' }

& (Join-Path $PSScriptRoot 'test_challenge_core.ps1') -Python $Python
if ($LASTEXITCODE -ne 0) { throw 'Dependency-free C++ Challenge core failed.' }

& $Python -B (Join-Path $repoRoot 'python\scripts\card_author.py') lint
if ($LASTEXITCODE -ne 0) { throw 'Card authoring contract failed.' }

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$godotPaths = Get-GodotToolchainPaths -RepoRoot $repoRoot
$godot = $godotPaths.Console
Set-PortableGodotEnvironment -ToolsRoot (Join-Path $repoRoot '.tools')
$projectRoot = Join-Path $repoRoot 'godot'
$classCache = Join-Path $projectRoot '.godot\global_script_class_cache.cfg'
$requiresImport = -not (Test-Path -LiteralPath $classCache -PathType Leaf)
if (-not $requiresImport) {
    $cacheTime = (Get-Item -LiteralPath $classCache).LastWriteTimeUtc
    $latestClassSource = Get-ChildItem -LiteralPath $projectRoot `
        -Recurse `
        -File `
        -Filter '*.gd' |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    $projectTime = (Get-Item -LiteralPath (
        Join-Path $projectRoot 'project.godot'
    )).LastWriteTimeUtc
    $requiresImport = (
        ($null -ne $latestClassSource -and
            $latestClassSource.LastWriteTimeUtc -gt $cacheTime) -or
        $projectTime -gt $cacheTime
    )
}
if ($requiresImport) {
    $importOutput = & $godot `
        --headless `
        --path $projectRoot `
        --import 2>&1
    $importOutput | ForEach-Object { Write-Host $_ }
    $importExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    $joinedImportOutput = $importOutput -join "`n"
    if (
        $importExitCode -ne 0 -or
        $joinedImportOutput -match '(?m)^(SCRIPT ERROR|ERROR):'
    ) {
        throw 'Godot class-cache bootstrap failed.'
    }
}
$godotOutput = & $godot `
    --headless `
    --path $projectRoot `
    --script 'res://tests/native_rules_session_contract_test.gd' 2>&1
$godotOutput | ForEach-Object { Write-Host $_ }
$godotExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
$joinedGodotOutput = $godotOutput -join "`n"
if (
    $godotExitCode -ne 0 `
    -or $joinedGodotOutput -match '(?m)^(SCRIPT ERROR|ERROR|WARNING):' `
    -or $joinedGodotOutput -notmatch 'NATIVE_RULES_SESSION_CONTRACT_OK'
) {
    throw 'Single-process Godot Native ABI 2 contract failed.'
}

Write-Host 'FAST_VERIFICATION_OK'
