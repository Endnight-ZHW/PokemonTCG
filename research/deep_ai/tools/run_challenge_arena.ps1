[CmdletBinding()]
param(
    [ValidateSet('smoke', 'pr', 'nightly', 'release', 'focused')]
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
    [string[]]$CandidateDeck = @(),
    [string[]]$BaselineDeck = @(),
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
$binding = Join-Path $researchRoot 'build\native\ptcg_ai_core.pyd'
if (-not (Test-Path -LiteralPath $binding)) {
    & (Join-Path $PSScriptRoot 'build_native_binding.ps1') -Python $Python
    if ($LASTEXITCODE -ne 0) {
        throw 'Native Challenge Arena binding build failed.'
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
    '--baseline', $Baseline,
    '--workers', [string]$Workers,
    '--seed', [string]$Seed,
    '--max-decisions', [string]$MaxDecisions,
    '--gate', $Gate,
    '--output', $Output
)
if ($Replicates -gt 0) {
    $arguments += @('--replicates', [string]$Replicates)
}
foreach ($deck in $CandidateDeck) {
    $arguments += @('--candidate-deck', $deck)
}
foreach ($deck in $BaselineDeck) {
    $arguments += @('--baseline-deck', $deck)
}
if ($TraceAll) {
    $arguments += '--trace-all'
}
& $Python @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Native Challenge Arena failed with exit code $LASTEXITCODE"
}
