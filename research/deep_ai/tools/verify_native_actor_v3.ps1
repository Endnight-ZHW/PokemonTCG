[CmdletBinding()]
param(
    [ValidateSet('rules', 'cuda-soak')]
    [string]$Mode = 'rules',
    [string]$CondaEnv = 'PokemonTCG-DeepAI',
    [string]$Device = 'cuda',
    [int]$Games = 0,
    [ValidateRange(1, 256)]
    [int]$Actors = 64,
    [ValidateRange(1, 256)]
    [int]$SearchSlots = 16,
    [ValidateRange(1, 1024)]
    [int]$Simulations = 8,
    [int]$MaxDecisions = 0,
    [int]$Seed = 1701,
    [string]$Output = 'build\benchmarks\native_actor_v3.json'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$conda = Get-Command conda.exe -ErrorAction Stop
$script = Join-Path $repoRoot 'scripts\verify_native_actor_v3.py'
$arguments = @(
    'run', '-n', $CondaEnv, 'python', '-B', $script,
    '--mode', $Mode,
    '--device', $Device,
    '--actors', [string]$Actors,
    '--search-slots', [string]$SearchSlots,
    '--simulations', [string]$Simulations,
    '--seed', [string]$Seed,
    '--output', [IO.Path]::GetFullPath((Join-Path $repoRoot $Output))
)
if ($Games -gt 0) {
    $arguments += @('--games', [string]$Games)
}
if ($MaxDecisions -gt 0) {
    $arguments += @('--max-decisions', [string]$MaxDecisions)
}
& $conda.Source @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Deep AI v3 native actor verification failed with exit code $LASTEXITCODE"
}
