[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AblationEvidence,
    [Parameter(Mandatory)]
    [string]$RunId,
    [string]$RunsRoot = '',
    [string]$CondaEnv = 'DL',
    [int]$Workers = 0,
    [switch]$SkipTraining,
    [switch]$NoProgress
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$AblationEvidence = [System.IO.Path]::GetFullPath($AblationEvidence)
if (-not (Test-Path -LiteralPath $AblationEvidence -PathType Leaf)) {
    throw "Ablation evidence is missing: $AblationEvidence"
}
$ablation = Get-Content -Raw -LiteralPath $AblationEvidence | ConvertFrom-Json
$winner = [string]$ablation.winner
if (
    [string]$ablation.schema -ne 'deep_ai_v6_ablation_v1' -or
    [int]$ablation.seed -ne 17 -or
    [int]$ablation.schedule.games -ne 280 -or
    [bool]$ablation.promotable -or
    [bool]$ablation.release_manifest_modified -or
    $winner -notin @('v6_pooled', 'v6_cross_attention')
) {
    throw 'Ablation evidence does not authorize a research10 winner.'
}
foreach ($variant in @('v6_pooled', 'v6_cross_attention')) {
    $row = $ablation.reliability.PSObject.Properties[$variant].Value
    if ($null -eq $row) {
        throw "Ablation evidence lacks reliability data for $variant."
    }
}
$winnerReliability = (
    $ablation.reliability.PSObject.Properties[$winner].Value
)
foreach ($metric in $winnerReliability.PSObject.Properties) {
    if ([int]$metric.Value -ne 0) {
        throw (
            "Ablation winner has a non-zero reliability metric: " +
            "$($metric.Name)=$($metric.Value)"
        )
    }
}
$winnerChoice = (
    $ablation.choice_drift.PSObject.Properties[$winner].Value
)
if ($null -eq $winnerChoice -or -not [bool]$winnerChoice.passed) {
    throw 'Ablation winner did not pass the Choice drift gate.'
}

if ([string]::IsNullOrWhiteSpace($RunsRoot)) {
    $RunsRoot = Join-Path $repoRoot 'build\ai_training\runs'
}
$RunsRoot = [System.IO.Path]::GetFullPath($RunsRoot)
$runDir = [System.IO.Path]::GetFullPath((Join-Path $RunsRoot $RunId))
$relative = [System.IO.Path]::GetRelativePath($RunsRoot, $runDir)
if (
    [System.IO.Path]::IsPathRooted($relative) -or
    $relative -eq '..' -or
    $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)")
) {
    throw 'RunId resolves outside the configured runs root.'
}
$conda = (Get-Command conda.exe -ErrorAction Stop).Source
if (-not $SkipTraining) {
    & $conda @(
        'run',
        '--no-capture-output',
        '-n',
        $CondaEnv,
        'python',
        (Join-Path $repoRoot 'python\scripts\run_hybrid_population_training.py'),
        '--run-id',
        $RunId,
        '--runs-root',
        $RunsRoot,
        '--preset',
        'research10',
        '--seed',
        '17',
        '--model-variant',
        $winner
    )
    if ($LASTEXITCODE -ne 0) {
        throw "research10 training failed with exit code $LASTEXITCODE."
    }
}

$runPath = Join-Path $runDir 'run.json'
$run = Get-Content -Raw -LiteralPath $runPath | ConvertFrom-Json
if (
    [string]$run.preset -ne 'research10' -or
    [string]$run.status -ne 'completed' -or
    [bool]$run.promotable -or
    [string]$run.config.model_variant -ne $winner
) {
    throw 'The completed research10 run does not match the ablation winner.'
}
$python = Join-Path $repoRoot '.tools\python311\python.exe'
& $python @(
    (Join-Path $repoRoot 'python\scripts\record_v6_stage_lineage.py'),
    '--run-dir',
    $runDir,
    '--evidence',
    $AblationEvidence,
    '--kind',
    'ablation'
)
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to record the ablation evidence lineage.'
}

& (Join-Path $PSScriptRoot 'evaluate_v6_research10.ps1') `
    -RunId $RunId `
    -RunsRoot $RunsRoot `
    -Workers $Workers `
    -CondaEnv $CondaEnv `
    -NoProgress:$NoProgress
if ($LASTEXITCODE -ne 0) {
    throw 'research10 Godot gate failed.'
}

$ablationSha = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $AblationEvidence
).Hash.ToLowerInvariant()
Write-Host (
    "V6_RESEARCH10_STAGE_COMPLETE run_id=$RunId variant=$winner " +
    "ablation_sha256=$ablationSha promotable=false"
)
