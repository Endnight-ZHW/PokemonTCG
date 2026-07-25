[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunId,
    [int]$Workers = 0,
    [string]$RunsRoot = '',
    [switch]$NoProgress
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($RunsRoot)) {
    $RunsRoot = Join-Path $repoRoot 'build\ai_training\runs'
}
$runsRootFull = [System.IO.Path]::GetFullPath($RunsRoot)
$runDir = [System.IO.Path]::GetFullPath((Join-Path $runsRootFull $RunId))
$relative = [System.IO.Path]::GetRelativePath($runsRootFull, $runDir)
if (
    [System.IO.Path]::IsPathRooted($relative) -or
    $relative -eq '..' -or
    $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)")
) {
    throw 'RunId resolves outside the configured runs root.'
}

$runPath = Join-Path $runDir 'run.json'
$candidatePath = Join-Path $runDir 'staging\candidate_manifest.json'
$runtimePath = Join-Path $runDir 'staging\godot\data\ai_models_runtime.json'
$releasePath = Join-Path $runDir 'staging\godot\data\release_manifest.json'
foreach ($required in @($runPath, $candidatePath, $runtimePath, $releasePath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Hybrid candidate input is missing: $required"
    }
}
$run = Get-Content -Raw -LiteralPath $runPath | ConvertFrom-Json
if ([string]$run.preset -ne 'release') {
    throw 'Only a fixed Release run can enter the authoritative candidate gate.'
}
if ($Workers -le 0) {
    $Workers = [Math]::Max(1, [Math]::Min(12, [Environment]::ProcessorCount))
}

$evaluationRoot = Join-Path $runDir 'evaluation\godot_windows'
$deepStrategy = Join-Path $repoRoot 'godot\tools\ai_baseline\deep_candidate_strategy.json'
$challengeStrategy = Join-Path $repoRoot 'godot\tools\ai_baseline\challenge_production_strategy.json'

& (Join-Path $PSScriptRoot 'evaluate_godot_ai.ps1') `
    -EvalPreset Nightly `
    -StrategyA $deepStrategy `
    -StrategyB $challengeStrategy `
    -MatchupMode Balanced `
    -Seed 17 `
    -SeedBlocksPerDeck 50 `
    -CrossSeedBlocksPerMatchup 10 `
    -MaxActions 1200 `
    -Workers $Workers `
    -LogicalShardCount 50 `
    -ValidateGate deep-release `
    -DeepRuntimeManifest $runtimePath `
    -DeepReleaseManifest $releasePath `
    -OutputDir $evaluationRoot `
    -NoProgress:$NoProgress
if ($LASTEXITCODE -ne 0) {
    throw "Hybrid candidate evaluation failed with exit code $LASTEXITCODE."
}

Write-Host "HYBRID_CANDIDATE_EVALUATION_OK run_id=$RunId output=$evaluationRoot"
