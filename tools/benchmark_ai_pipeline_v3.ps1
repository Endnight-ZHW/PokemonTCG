[CmdletBinding()]
param(
    [string]$CondaEnv = 'DL',
    [string]$Device = 'cuda',
    [ValidateRange(1, 256)]
    [int]$Games = 64,
    [ValidateRange(1, 1024)]
    [int]$Simulations = 64,
    [ValidateRange(1, 2048)]
    [int]$MaxDecisions = 64,
    [ValidateRange(1, 20)]
    [int]$Repeats = 5,
    [int]$Seed = 1701,
    [string]$Output = 'build\benchmarks\deep_ai_pipeline_v3.json'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$conda = Get-Command conda.exe -ErrorAction Stop
$script = Join-Path $repoRoot 'python\scripts\benchmark_ai_pipeline_v3.py'
$outputPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $Output))
$arguments = @(
    'run', '-n', $CondaEnv, 'python', '-B', $script,
    '--device', $Device,
    '--games', [string]$Games,
    '--simulations', [string]$Simulations,
    '--max-decisions', [string]$MaxDecisions,
    '--repeats', [string]$Repeats,
    '--seed', [string]$Seed,
    '--output', $outputPath
)
& $conda.Source @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Deep AI v3 benchmark failed with exit code $LASTEXITCODE"
}
