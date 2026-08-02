[CmdletBinding()]
param(
    [ValidateSet('smoke', 'release')]
    [string]$Preset = 'smoke',
    [string]$OutputRoot = 'build\ai_training\alphazero-v2',
    [string]$BootstrapCache = 'python\data\ai_training\bootstrap-v2.pt',
    [string]$CondaEnv = 'DL',
    [string]$Device = 'cuda',
    [int]$Seed = 17,
    [int]$Simulations = 0,
    [int]$ActorThreads = 0,
    [int]$ConcurrentGames = 0,
    [int]$BatchSize = 0,
    [switch]$GenerateBootstrap,
    [switch]$AllowPythonFallback
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$conda = Get-Command conda.exe -ErrorAction Stop
$output = [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputRoot))
$cache = [IO.Path]::GetFullPath((Join-Path $repoRoot $BootstrapCache))

if ($GenerateBootstrap) {
    & $conda.Source run -n $CondaEnv python -B `
        (Join-Path $repoRoot 'python\scripts\train_deep_ai.py') `
        bootstrap --output $cache --workers 16 --seed $Seed
    if ($LASTEXITCODE -ne 0) {
        throw "AlphaZero v2 bootstrap generation failed with exit code $LASTEXITCODE"
    }
}

& $conda.Source run -n $CondaEnv python -B `
    (Join-Path $repoRoot 'python\scripts\train_deep_ai.py') `
    verify-cache --cache $cache
if ($LASTEXITCODE -ne 0) {
    throw "AlphaZero v2 bootstrap validation failed with exit code $LASTEXITCODE"
}

$arguments = @(
    '-B',
    (Join-Path $repoRoot 'python\scripts\train_deep_ai.py'),
    'train',
    '--preset', $Preset,
    '--output-dir', $output,
    '--bootstrap-cache', $cache,
    '--device', $Device,
    '--seed', [string]$Seed
)
if ($Simulations -gt 0) {
    $arguments += @('--simulations', [string]$Simulations)
}
if ($ActorThreads -gt 0) {
    $arguments += @('--actor-threads', [string]$ActorThreads)
}
if ($ConcurrentGames -gt 0) {
    $arguments += @('--concurrent-games', [string]$ConcurrentGames)
}
if ($BatchSize -gt 0) {
    $arguments += @('--batch-size', [string]$BatchSize)
}
if ($AllowPythonFallback) {
    $arguments += '--allow-python-fallback'
}

& $conda.Source run -n $CondaEnv python @arguments
if ($LASTEXITCODE -ne 0) {
    throw "AlphaZero v2 training failed with exit code $LASTEXITCODE"
}
