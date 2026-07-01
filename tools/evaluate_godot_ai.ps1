[CmdletBinding()]
param(
    [ValidateSet('Smoke', 'Quick', 'Nightly', 'Custom')]
    [string]$EvalPreset = 'Nightly',
    [string]$StrategyA = '',
    [string]$StrategyB = '',
    [string[]]$Deck = @(),
    [int]$SeedBlocksPerDeck = 50,
    [int]$Seed = 17,
    [int]$MaxActions = 1200,
    [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$godot = Join-Path $toolsRoot 'godot-4.7\Godot_v4.7-stable_win64_console.exe'
$python = Join-Path $toolsRoot 'python311\python.exe'

function Resolve-RepoPathOrEmpty {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path $repoRoot $Path)
}

switch ($EvalPreset) {
    'Smoke' {
        if (-not $PSBoundParameters.ContainsKey('Deck')) {
            $Deck = @('fire')
        }
        if (-not $PSBoundParameters.ContainsKey('SeedBlocksPerDeck')) {
            $SeedBlocksPerDeck = 1
        }
        if (-not $PSBoundParameters.ContainsKey('MaxActions')) {
            $MaxActions = 80
        }
    }
    'Quick' {
        if (-not $PSBoundParameters.ContainsKey('SeedBlocksPerDeck')) {
            $SeedBlocksPerDeck = 5
        }
        if (-not $PSBoundParameters.ContainsKey('MaxActions')) {
            $MaxActions = 800
        }
    }
    'Nightly' {
        if (-not $PSBoundParameters.ContainsKey('SeedBlocksPerDeck')) {
            $SeedBlocksPerDeck = 50
        }
        if (-not $PSBoundParameters.ContainsKey('MaxActions')) {
            $MaxActions = 1200
        }
    }
}

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
Set-PortableGodotEnvironment -ToolsRoot $toolsRoot

if (-not (Test-Path -LiteralPath $godot)) {
    throw 'Godot 4.7 is not installed. Run tools/setup_godot_toolchain.ps1 first.'
}
if (-not (Test-Path -LiteralPath $python)) {
    $python = 'python'
}

$StrategyA = Resolve-RepoPathOrEmpty $StrategyA
$StrategyB = Resolve-RepoPathOrEmpty $StrategyB
if (-not [string]::IsNullOrWhiteSpace($StrategyA) -and -not (Test-Path -LiteralPath $StrategyA)) {
    throw "StrategyA file not found: $StrategyA"
}
if (-not [string]::IsNullOrWhiteSpace($StrategyB) -and -not (Test-Path -LiteralPath $StrategyB)) {
    throw "StrategyB file not found: $StrategyB"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDir = Join-Path $repoRoot ".test_tmp\ai_eval\$stamp"
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $repoRoot $OutputDir
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$jsonPath = Join-Path $OutputDir 'results.json'
$htmlPath = Join-Path $OutputDir 'report.html'

if (
    [string]::IsNullOrWhiteSpace($StrategyA) -and
    [string]::IsNullOrWhiteSpace($StrategyB) -and
    $EvalPreset -in @('Smoke', 'Quick')
) {
    $presetStrategyPath = Join-Path $OutputDir 'preset_strategy.json'
    if ($EvalPreset -eq 'Smoke') {
        $presetStrategy = [ordered]@{
            id = 'smoke-preset'
            label = 'Smoke Preset'
            simulation_budget = 1
            seconds = 0.01
            max_depth = 1
            deterministic = $true
        }
    }
    else {
        $presetStrategy = [ordered]@{
            id = 'quick-preset'
            label = 'Quick Preset'
            simulation_budget = 64
            seconds = 0.05
            max_depth = 8
            deterministic = $true
        }
    }
    $presetStrategy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $presetStrategyPath -Encoding UTF8
    $StrategyA = $presetStrategyPath
    $StrategyB = $presetStrategyPath
}

$runnerArgs = @(
    '--headless',
    '--path', (Join-Path $repoRoot 'godot'),
    '--script', 'res://tools/ai_evaluation_runner.gd',
    '--',
    '--output', $jsonPath,
    '--eval-preset', $EvalPreset,
    '--seed-blocks-per-deck', ([string][Math]::Max(1, $SeedBlocksPerDeck)),
    '--seed', ([string]$Seed),
    '--max-actions', ([string][Math]::Max(1, $MaxActions))
)
if (-not [string]::IsNullOrWhiteSpace($StrategyA)) {
    $runnerArgs += @('--strategy-a', $StrategyA)
}
if (-not [string]::IsNullOrWhiteSpace($StrategyB)) {
    $runnerArgs += @('--strategy-b', $StrategyB)
}
foreach ($deckKey in $Deck) {
    if (-not [string]::IsNullOrWhiteSpace($deckKey)) {
        $runnerArgs += @('--deck', $deckKey)
    }
}

$godotOutput = & $godot @runnerArgs 2>&1
$godotOutput | ForEach-Object { Write-Host $_ }
$godotExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
if ($godotExit -ne 0) {
    throw "Godot AI evaluation failed with exit code $godotExit"
}
$joinedGodotOutput = $godotOutput -join "`n"
if ($joinedGodotOutput -match '(?m)^(SCRIPT ERROR|ERROR):') {
    throw 'Godot emitted script/runtime errors during AI evaluation.'
}
if ($joinedGodotOutput -notmatch 'AI_EVALUATION_OK') {
    throw 'Godot AI evaluation success marker was not emitted.'
}
if (-not (Test-Path -LiteralPath $jsonPath)) {
    throw "Godot AI evaluation did not write $jsonPath"
}

$reportOutput = & $python `
    (Join-Path $repoRoot 'python\scripts\render_ai_evaluation_report.py') `
    --input $jsonPath `
    --output $htmlPath 2>&1
$reportOutput | ForEach-Object { Write-Host $_ }
$reportExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
if ($reportExit -ne 0) {
    throw "AI evaluation report rendering failed with exit code $reportExit"
}
if (-not (Test-Path -LiteralPath $htmlPath)) {
    throw "AI evaluation report did not write $htmlPath"
}

Write-Host "AI evaluation JSON: $jsonPath"
Write-Host "AI evaluation report: $htmlPath"
