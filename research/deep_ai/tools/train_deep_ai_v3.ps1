[CmdletBinding()]
param(
    [ValidateSet('smoke', 'pilot', 'release')]
    [string]$Preset = 'smoke',
    [string]$OutputRoot = 'build\ai_training\alphazero-v3',
    [string]$TeacherReplay = 'build\teacher-replay',
    [string]$CondaEnv = 'PokemonTCG-DeepAI',
    [string]$Device = 'cuda',
    [int]$Seed = 17,
    [int]$Cycles = 0,
    [int]$CycleSamples = 0,
    [int]$Simulations = 0,
    [int]$ConcurrentGames = 0,
    [int]$ActorThreads = 0,
    [int]$BatchSize = 0,
    [switch]$GenerateBootstrap,
    [int]$BootstrapTaskLimit = 0,
    [ValidateRange(1, 64)]
    [int]$BootstrapWorkers = 8
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$conda = Get-Command conda.exe -ErrorAction Stop
$output = [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputRoot))
$teacher = [IO.Path]::GetFullPath((Join-Path $repoRoot $TeacherReplay))
$script = Join-Path $repoRoot 'scripts\train_deep_ai_v3.py'

if ($GenerateBootstrap) {
    $bootstrapArgs = @(
        'run', '-n', $CondaEnv,
        'python', '-B', $script,
        'bootstrap', '--output', $teacher,
        '--seed', [string]$Seed,
        '--workers', [string]$BootstrapWorkers
    )
    if ($BootstrapTaskLimit -gt 0) {
        $bootstrapArgs += @('--task-limit', [string]$BootstrapTaskLimit)
    }
    & $conda.Source @bootstrapArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Deep AI v3 teacher generation failed with exit code $LASTEXITCODE"
    }
}

$arguments = @(
    'run', '-n', $CondaEnv,
    'python', '-B', $script,
    'train', '--preset', $Preset,
    '--output-dir', $output,
    '--device', $Device,
    '--seed', [string]$Seed
)
if (Test-Path -LiteralPath (Join-Path $teacher 'manifest.json')) {
    $arguments += @('--teacher-replay', $teacher)
} elseif ($Preset -ne 'smoke') {
    throw "Deep AI v3 $Preset requires teacher replay: $teacher"
}
foreach ($row in @(
    @($Cycles, '--cycles'),
    @($CycleSamples, '--cycle-samples'),
    @($Simulations, '--simulations'),
    @($ConcurrentGames, '--concurrent-games'),
    @($ActorThreads, '--actor-threads'),
    @($BatchSize, '--batch-size')
)) {
    if ([int]$row[0] -gt 0) {
        $arguments += @([string]$row[1], [string]$row[0])
    }
}
& $conda.Source @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Deep AI v3 training failed with exit code $LASTEXITCODE"
}
