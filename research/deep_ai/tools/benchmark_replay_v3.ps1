[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Replay,
    [Parameter(Mandatory)]
    [string]$Summary,
    [string]$Device = 'cuda',
    [string]$CondaEnv = 'PokemonTCG-DeepAI',
    [string]$Output = 'build\benchmarks\deep_ai_replay_v3.json'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$conda = Get-Command conda.exe -ErrorAction Stop
$script = Join-Path $repoRoot 'scripts\benchmark_replay_v3.py'
& $conda.Source run -n $CondaEnv python -B $script `
    --replay ([IO.Path]::GetFullPath((Join-Path $repoRoot $Replay))) `
    --summary ([IO.Path]::GetFullPath((Join-Path $repoRoot $Summary))) `
    --device $Device `
    --output ([IO.Path]::GetFullPath((Join-Path $repoRoot $Output)))
if ($LASTEXITCODE -ne 0) {
    throw "Deep AI v3 replay benchmark failed with exit code $LASTEXITCODE"
}
