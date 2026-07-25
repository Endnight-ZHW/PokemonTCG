[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunId,
    [string]$RunsRoot = '',
    [int]$Workers = 0,
    [string]$CondaEnv = 'DL',
    [switch]$SkipPrepare,
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
if (-not (Test-Path -LiteralPath $runPath -PathType Leaf)) {
    throw "research10 run metadata is missing: $runPath"
}
$run = Get-Content -Raw -LiteralPath $runPath | ConvertFrom-Json
if (
    [string]$run.preset -ne 'research10' -or
    [string]$run.status -ne 'completed' -or
    [bool]$run.promotable
) {
    throw 'The research gate requires a completed, non-promotable research10 run.'
}
if (
    [string]$run.config.model_variant -notin @(
        'v6_pooled',
        'v6_cross_attention'
    )
) {
    throw 'The research10 run does not use a supported v6 model variant.'
}
if ($Workers -le 0) {
    $Workers = [Math]::Max(
        1,
        [Math]::Min(10, [Environment]::ProcessorCount)
    )
}

$releaseManifest = Join-Path $repoRoot 'release_manifest.json'
$releaseShaBefore = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $releaseManifest
).Hash.ToLowerInvariant()
$conda = (Get-Command conda.exe -ErrorAction Stop).Source
if (-not $SkipPrepare) {
    & $conda @(
        'run',
        '--no-capture-output',
        '-n',
        $CondaEnv,
        'python',
        (Join-Path $repoRoot 'python\scripts\prepare_hybrid_candidate.py'),
        '--run-dir',
        $runDir,
        '--allow-research'
    )
    if ($LASTEXITCODE -ne 0) {
        throw "research10 candidate preparation failed with exit code $LASTEXITCODE."
    }
}

$candidatePath = Join-Path $runDir 'staging\candidate_manifest.json'
$runtimePath = Join-Path $runDir 'staging\godot\data\ai_models_runtime.json'
$candidateReleasePath = Join-Path $runDir 'staging\godot\data\release_manifest.json'
foreach ($required in @($candidatePath, $runtimePath, $candidateReleasePath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "research10 candidate input is missing: $required"
    }
}
$candidate = Get-Content -Raw -LiteralPath $candidatePath | ConvertFrom-Json
if (
    -not [bool]$candidate.research_only -or
    [bool]$candidate.promotable -or
    [string]$candidate.source_preset -ne 'research10'
) {
    throw 'The isolated candidate manifest is not research10-only.'
}

$evaluationRoot = Join-Path $runDir 'evaluation\godot_windows_research10'
$deepStrategy = Join-Path $repoRoot 'godot\tools\ai_baseline\deep_candidate_strategy.json'
$challengeStrategy = Join-Path $repoRoot 'godot\tools\ai_baseline\challenge_production_strategy.json'

& (Join-Path $PSScriptRoot 'evaluate_godot_ai.ps1') `
    -EvalPreset Custom `
    -StrategyA $deepStrategy `
    -StrategyB $challengeStrategy `
    -MatchupMode Balanced `
    -Seed 17 `
    -SeedBlocksPerDeck 5 `
    -CrossSeedBlocksPerMatchup 1 `
    -MaxActions 1200 `
    -Workers $Workers `
    -LogicalShardCount 10 `
    -DeepRuntimeManifest $runtimePath `
    -DeepReleaseManifest $candidateReleasePath `
    -OutputDir $evaluationRoot `
    -SkipValidate `
    -NoProgress:$NoProgress
if ($LASTEXITCODE -ne 0) {
    throw "research10 Godot evaluation failed with exit code $LASTEXITCODE."
}

$python = Join-Path $repoRoot '.tools\python311\python.exe'
$resultsPath = Join-Path $evaluationRoot 'results.json'
$gatePath = Join-Path $evaluationRoot 'research10_gate.json'
& $python @(
    (Join-Path $repoRoot 'python\scripts\validate_v6_research10.py'),
    '--input',
    $resultsPath,
    '--output',
    $gatePath,
    '--run-dir',
    $runDir
)
$gateExit = $LASTEXITCODE

$releaseShaAfter = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $releaseManifest
).Hash.ToLowerInvariant()
if ($releaseShaAfter -ne $releaseShaBefore) {
    throw 'The research10 workflow modified the formal release manifest.'
}
if ($gateExit -ne 0) {
    throw (
        "research10 gate failed with exit code $gateExit; " +
        "evidence was preserved at $gatePath"
    )
}

Write-Host (
    "V6_RESEARCH10_VERIFIED run_id=$RunId " +
    "promotable=false release_manifest_unchanged=true evidence=$gatePath"
)
