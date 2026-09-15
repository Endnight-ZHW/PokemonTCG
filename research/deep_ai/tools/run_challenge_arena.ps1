[CmdletBinding()]
param(
    [ValidateSet('smoke', 'pr', 'nightly', 'release', 'calibration')]
    [string]$Preset = 'smoke',
    [string]$Candidate = 'challenge_next',
    [string]$Baseline = '',
    [string]$Anchor = 'challenge_release_v1',
    [string]$CacheDirectory = '',
    [switch]$DeclareOnly,
    [ValidateSet('', 'turn_beam_v2', 'strategic_intent_v3')]
    [string]$CandidateEngine = '',
    [ValidateSet('', 'turn_beam_v2', 'strategic_intent_v3')]
    [string]$BaselineEngine = '',
    [ValidateSet('', 'enabled', 'disabled')]
    [string]$CandidateDeckInspection = '',
    [ValidateSet('', 'enabled', 'disabled')]
    [string]$BaselineDeckInspection = '',
    [ValidateSet('', 'enabled', 'disabled')]
    [string]$CandidateStrategyOptimization = '',
    [ValidateSet('', 'enabled', 'disabled')]
    [string]$BaselineStrategyOptimization = '',
    [ValidateRange(1, 64)]
    [int]$Workers = 8,
    [string]$Output = '',
    [string]$Python = '',
    [int]$Seed = 17,
    [int]$Replicates = 0,
    [ValidateRange(1, 4096)]
    [int]$MaxDecisions = 1024,
    [ValidateRange(1, 600000)]
    [int]$DecisionTimeoutMilliseconds = 120000,
    [ValidateSet('release-bundle', 'implementation-only', 'same-binary-strategy')]
    [string]$ComparisonMode = 'release-bundle',
    [switch]$AllowSelfPlay,
    [switch]$TraceAll
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Baseline)) {
    $Baseline = if ($Preset -eq 'smoke') { 'challenge_release_v1' } else { 'challenge_champion_v1' }
}
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
$anchorManifest = ''
$baselineRuntime = $Baseline
if ($ComparisonMode -ne 'same-binary-strategy') {
    $candidateBuildOutput = & (Join-Path $PSScriptRoot 'build_challenge_agent.ps1') `
        -AgentId $Candidate -BuildId 'working-tree' -Python $Python
    if ($LASTEXITCODE -ne 0) { throw 'Candidate Arena Agent build failed.' }
    $candidateManifest = [string]($candidateBuildOutput | Select-Object -Last 1)
    if ($Preset -eq 'calibration') {
        $baselineRuntime = "$Baseline-calibration-current"
        # Calibrate the exact same artifact, including its binary checksum.
        $baselineBuildOutput = @($candidateManifest)
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
    if ($Preset -eq 'release') {
        $anchorSpecPath = Join-Path $researchRoot "arena\baselines\$Anchor.json"
        $anchorSpec = Get-Content -LiteralPath $anchorSpecPath -Raw | ConvertFrom-Json
        if ([string]$anchorSpec.git_ref -notmatch '^[0-9a-fA-F]{40}$') {
            throw 'Anchor must pin a full commit hash.'
        }
        $anchorBuildOutput = & (Join-Path $PSScriptRoot 'build_challenge_agent.ps1') `
            -GitRef ([string]$anchorSpec.git_ref) -AgentId $Anchor `
            -BuildId ([string]$anchorSpec.build_id) -Python $Python
        if ($LASTEXITCODE -ne 0) { throw 'Anchor Arena Agent build failed.' }
        $anchorManifest = [string]($anchorBuildOutput | Select-Object -Last 1)
    }
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
    '--decision-timeout-milliseconds', [string]$DecisionTimeoutMilliseconds,
    '--comparison-mode', $ComparisonMode,
    '--output', $Output
)
if (-not [string]::IsNullOrWhiteSpace($candidateManifest)) {
    $arguments += @('--candidate-build-manifest', $candidateManifest)
}
if (-not [string]::IsNullOrWhiteSpace($baselineManifest)) {
    $arguments += @('--baseline-build-manifest', $baselineManifest)
}
if (-not [string]::IsNullOrWhiteSpace($anchorManifest)) {
    $arguments += @('--anchor', $Anchor, '--anchor-build-manifest', $anchorManifest)
}
if (-not [string]::IsNullOrWhiteSpace($CacheDirectory)) {
    $arguments += @('--cache-dir', $CacheDirectory)
}
if ($DeclareOnly) { $arguments += '--declare-only' }
if (-not [string]::IsNullOrWhiteSpace($CandidateEngine)) {
    $arguments += @('--candidate-engine', $CandidateEngine)
}
if (-not [string]::IsNullOrWhiteSpace($BaselineEngine)) {
    $arguments += @('--baseline-engine', $BaselineEngine)
}
if (-not [string]::IsNullOrWhiteSpace($CandidateDeckInspection)) {
    $arguments += @('--candidate-deck-inspection', $CandidateDeckInspection)
}
if (-not [string]::IsNullOrWhiteSpace($BaselineDeckInspection)) {
    $arguments += @('--baseline-deck-inspection', $BaselineDeckInspection)
}
if (-not [string]::IsNullOrWhiteSpace($CandidateStrategyOptimization)) {
    $arguments += @('--candidate-strategy-optimization', $CandidateStrategyOptimization)
}
if (-not [string]::IsNullOrWhiteSpace($BaselineStrategyOptimization)) {
    $arguments += @('--baseline-strategy-optimization', $BaselineStrategyOptimization)
}
if ($Replicates -gt 0) {
    $arguments += @('--replicates', [string]$Replicates)
}
if ($TraceAll) {
    $arguments += '--trace-all'
}
if ($AllowSelfPlay) {
    $arguments += '--allow-self-play'
}
& $Python @arguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
