[CmdletBinding()]
param(
    [ValidateSet('smoke', 'pr', 'nightly', 'release', 'calibration', 'focused')]
    [string]$Preset = 'smoke',
    [string]$Candidate = 'challenge_next',
    [string]$Baseline = 'challenge_release_v1',
    [ValidateRange(1, 64)]
    [int]$Workers = 8,
    [string]$Output = '',
    [string]$Python = '',
    [int]$Seed = 17,
    [int]$Replicates = 0,
    [ValidateRange(1, 4096)]
    [int]$MaxDecisions = 512,
    [ValidateSet('auto', 'none', 'structural', 'regression', 'promotion')]
    [string]$Gate = 'auto',
    [ValidateSet('release-bundle', 'implementation-only', 'same-binary-strategy')]
    [string]$ComparisonMode = 'release-bundle',
    [string[]]$CandidateDeck = @(),
    [string[]]$BaselineDeck = @(),
    [switch]$MirrorOnly,
    [switch]$AllowSelfPlay,
    [switch]$TraceAll
)

$ErrorActionPreference = 'Stop'
$researchRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $researchRoot)
$portablePython = Join-Path $repoRoot '.tools\python311\python.exe'
if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = if (Test-Path -LiteralPath $portablePython) {
        $portablePython
    } else {
        'python'
    }
}
& (Join-Path $PSScriptRoot 'build_native_binding.ps1') -Python $Python
if ($LASTEXITCODE -ne 0) {
    throw 'Native Challenge Arena binding build failed.'
}
$candidateManifest = ''
$baselineManifest = ''
$baselineRuntime = $Baseline
if ($ComparisonMode -ne 'same-binary-strategy') {
    $candidateBuildOutput = & (Join-Path $PSScriptRoot 'build_challenge_agent.ps1') `
        -AgentId $Candidate -BuildId 'working-tree' -Python $Python
    if ($LASTEXITCODE -ne 0) { throw 'Candidate Arena Agent build failed.' }
    $candidateManifest = [string]($candidateBuildOutput | Select-Object -Last 1)
    if ($Preset -eq 'calibration') {
        $baselineRuntime = "$Baseline-calibration-current"
        $baselineBuildOutput = & (Join-Path $PSScriptRoot 'build_challenge_agent.ps1') `
            -AgentId $baselineRuntime -BuildId 'working-tree' -Python $Python
    } else {
        $baselineSpecPath = Join-Path $researchRoot "arena\baselines\$Baseline.json"
        if (-not (Test-Path -LiteralPath $baselineSpecPath)) {
            throw "Baseline Arena Agent spec not found: $baselineSpecPath"
        }
        $baselineSpec = Get-Content -LiteralPath $baselineSpecPath -Raw | ConvertFrom-Json
        if ([string]$baselineSpec.schema -ne 'ptcg.challenge_arena.agent/2') {
            throw 'Baseline Arena Agent spec must use schema v2.'
        }
        $baselineRef = [string]$baselineSpec.git_ref
        if ($baselineRef -notmatch '^[0-9a-fA-F]{40}$') {
            throw 'Baseline Arena Agent spec must pin a full commit hash.'
        }
        if ([string]$baselineSpec.strategies_ref_path -ne 'godot/data/ai_strategies.json') {
            throw 'Baseline Arena Agent spec must pin its ref strategy catalog.'
        }
        $baselineBuildOutput = & (Join-Path $PSScriptRoot 'build_challenge_agent.ps1') `
            -GitRef $baselineRef `
            -AgentId $Baseline `
            -BuildId ([string]$baselineSpec.build_id) `
            -Python $Python
    }
    if ($LASTEXITCODE -ne 0) { throw 'Baseline Arena Agent build failed.' }
    $baselineManifest = [string]($baselineBuildOutput | Select-Object -Last 1)
}
$script = Join-Path $researchRoot 'scripts\run_challenge_arena.py'
if ([string]::IsNullOrWhiteSpace($Output)) {
    $Output = Join-Path $repoRoot "build\challenge-arena\$Preset"
} elseif (-not [IO.Path]::IsPathRooted($Output)) {
    $Output = [IO.Path]::GetFullPath((Join-Path $repoRoot $Output))
}
$arguments = @(
    '-B', $script,
    '--preset', $Preset,
    '--candidate', $Candidate,
    '--baseline', $baselineRuntime,
    '--workers', [string]$Workers,
    '--seed', [string]$Seed,
    '--max-decisions', [string]$MaxDecisions,
    '--comparison-mode', $ComparisonMode,
    '--gate', $Gate,
    '--output', $Output
)
if (-not [string]::IsNullOrWhiteSpace($candidateManifest)) {
    $arguments += @('--candidate-build-manifest', $candidateManifest)
}
if (-not [string]::IsNullOrWhiteSpace($baselineManifest)) {
    $arguments += @('--baseline-build-manifest', $baselineManifest)
}
if ($Replicates -gt 0) {
    $arguments += @('--replicates', [string]$Replicates)
}
foreach ($deck in $CandidateDeck) {
    $arguments += @('--candidate-deck', $deck)
}
foreach ($deck in $BaselineDeck) {
    $arguments += @('--baseline-deck', $deck)
}
if ($MirrorOnly) {
    $arguments += '--mirror-only'
}
if ($TraceAll) {
    $arguments += '--trace-all'
}
if ($AllowSelfPlay) {
    $arguments += '--allow-self-play'
}
& $Python @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Native Challenge Arena failed with exit code $LASTEXITCODE"
}
