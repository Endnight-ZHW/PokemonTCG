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
    [int]$Workers = 1,
    [int]$SeedBlockStart = 0,
    [int]$SeedBlockCount = 0,
    [int]$TaskStart = 0,
    [int]$TaskCount = 0,
    [int]$ShardIndex = -1,
    [int]$ShardCount = 0,
    [ValidateSet('', 'Mirror', 'Balanced', 'Matrix')]
    [string]$MatchupMode = '',
    [int]$CrossSeedBlocksPerMatchup = -1,
    [ValidateSet('', 'stability', 'strength', 'auto')]
    [string]$ValidateGate = '',
    [string]$Baseline = '',
    [string[]]$MergeInput = @(),
    [switch]$ShardOnly,
    [switch]$SkipReport,
    [switch]$SkipValidate,
    [switch]$Profile,
    [switch]$DisableAICache,
    [switch]$DisableNativeMath,
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

function Resolve-RepoPathList {
    param([string[]]$Paths)
    $resolved = @()
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        $resolved += (Resolve-RepoPathOrEmpty $path)
    }
    return $resolved
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
        if (-not $PSBoundParameters.ContainsKey('CrossSeedBlocksPerMatchup')) {
            $CrossSeedBlocksPerMatchup = 10
        }
        if (-not $PSBoundParameters.ContainsKey('MatchupMode')) {
            $MatchupMode = 'Balanced'
        }
        if (-not $PSBoundParameters.ContainsKey('ValidateGate')) {
            $ValidateGate = 'auto'
        }
        if (-not $PSBoundParameters.ContainsKey('MaxActions')) {
            $MaxActions = 1200
        }
    }
}

if ($SkipValidate -or $ShardOnly) {
    $ValidateGate = ''
}
if ($ShardOnly) {
    $SkipReport = $true
}
if ($Workers -lt 1) {
    throw 'Workers must be >= 1.'
}
if ($SeedBlockStart -lt 0 -or $SeedBlockCount -lt 0) {
    throw 'SeedBlockStart and SeedBlockCount must be >= 0.'
}
if ($TaskStart -lt 0 -or $TaskCount -lt 0) {
    throw 'TaskStart and TaskCount must be >= 0.'
}
if ($ShardCount -lt 0) {
    throw 'ShardCount must be >= 0.'
}
if ($ShardIndex -ge 0 -and $ShardCount -le 0) {
    throw 'ShardIndex requires ShardCount.'
}
if ($ShardCount -gt 0 -and ($ShardIndex -lt 0 -or $ShardIndex -ge $ShardCount)) {
    throw "ShardIndex must be in [0, $($ShardCount - 1)]."
}

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
Set-PortableGodotEnvironment -ToolsRoot $toolsRoot

$mergeInputPaths = @(Resolve-RepoPathList $MergeInput)
$mergeOnly = $mergeInputPaths.Count -gt 0

if (-not $mergeOnly -and -not (Test-Path -LiteralPath $godot)) {
    throw 'Godot 4.7 is not installed. Run tools/setup_godot_toolchain.ps1 first.'
}
if (-not (Test-Path -LiteralPath $python)) {
    $python = 'python'
}

$StrategyA = Resolve-RepoPathOrEmpty $StrategyA
$StrategyB = Resolve-RepoPathOrEmpty $StrategyB
$Baseline = Resolve-RepoPathOrEmpty $Baseline
if (-not [string]::IsNullOrWhiteSpace($StrategyA) -and -not (Test-Path -LiteralPath $StrategyA)) {
    throw "StrategyA file not found: $StrategyA"
}
if (-not [string]::IsNullOrWhiteSpace($StrategyB) -and -not (Test-Path -LiteralPath $StrategyB)) {
    throw "StrategyB file not found: $StrategyB"
}
if (-not [string]::IsNullOrWhiteSpace($Baseline) -and -not (Test-Path -LiteralPath $Baseline)) {
    throw "Baseline file not found: $Baseline"
}
foreach ($path in $mergeInputPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "MergeInput file not found: $path"
    }
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
    -not $mergeOnly -and
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
    '--eval-preset', $EvalPreset,
    '--seed-blocks-per-deck', ([string][Math]::Max(1, $SeedBlocksPerDeck)),
    '--seed', ([string]$Seed),
    '--max-actions', ([string][Math]::Max(1, $MaxActions))
)
if (-not [string]::IsNullOrWhiteSpace($MatchupMode)) {
    $runnerArgs += @('--matchup-mode', $MatchupMode)
}
if ($CrossSeedBlocksPerMatchup -ge 0) {
    $runnerArgs += @('--cross-seed-blocks-per-matchup', ([string][Math]::Max(0, $CrossSeedBlocksPerMatchup)))
}
if ($Profile) {
    $runnerArgs += @('--profile')
}
if ($DisableAICache) {
    $runnerArgs += @('--disable-ai-cache')
}
if ($DisableNativeMath) {
    $runnerArgs += @('--disable-native-math')
}
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

function Test-GodotShardOutput {
    param(
        [string]$StdoutPath,
        [string]$StderrPath,
        [string]$JsonPath,
        [int]$ExitCode
    )
    $outputLines = @()
    if (Test-Path -LiteralPath $StdoutPath) {
        $outputLines += Get-Content -LiteralPath $StdoutPath
    }
    if (Test-Path -LiteralPath $StderrPath) {
        $outputLines += Get-Content -LiteralPath $StderrPath
    }
    $outputLines | ForEach-Object { Write-Host $_ }
    $joined = $outputLines -join "`n"
    if ($ExitCode -ne 0) {
        throw "Godot AI evaluation failed with exit code $ExitCode. stdout=$StdoutPath stderr=$StderrPath"
    }
    if ($joined -match '(?m)^(SCRIPT ERROR|ERROR):') {
        throw "Godot emitted script/runtime errors during AI evaluation. stdout=$StdoutPath stderr=$StderrPath"
    }
    if ($joined -notmatch 'AI_EVALUATION_OK') {
        throw "Godot AI evaluation success marker was not emitted. stdout=$StdoutPath stderr=$StderrPath"
    }
    if (-not (Test-Path -LiteralPath $JsonPath)) {
        throw "Godot AI evaluation did not write $JsonPath"
    }
}

function New-GodotShardArgs {
    param(
        [string[]]$BaseArgs,
        [string]$ShardJsonPath,
        [int]$SeedBlockStart,
        [int]$SeedBlockCount,
        [int]$TaskStart,
        [int]$TaskCount,
        [int]$TaskShardIndex,
        [int]$TaskShardCount,
        [bool]$SkipGolden
    )
    $args = @($BaseArgs)
    $args += @('--output', $ShardJsonPath)
    if ($SeedBlockStart -gt 0 -or $SeedBlockCount -gt 0) {
        $args += @(
            '--seed-block-start', ([string]$SeedBlockStart),
            '--seed-block-count', ([string]$SeedBlockCount)
        )
    }
    if ($TaskStart -gt 0 -or $TaskCount -gt 0) {
        $args += @(
            '--task-start', ([string]$TaskStart),
            '--task-count', ([string]$TaskCount)
        )
    }
    if ($TaskShardCount -gt 1) {
        $args += @(
            '--task-shard-index', ([string]$TaskShardIndex),
            '--task-shard-count', ([string]$TaskShardCount)
        )
    }
    if ($SkipGolden) {
        $args += @('--skip-golden')
    }
    return $args
}

function Invoke-GodotShard {
    param(
        [string[]]$BaseArgs,
        [string]$ShardJsonPath,
        [int]$SeedBlockStart,
        [int]$SeedBlockCount,
        [int]$TaskStart,
        [int]$TaskCount,
        [int]$TaskShardIndex,
        [int]$TaskShardCount,
        [string]$StdoutPath,
        [string]$StderrPath,
        [bool]$SkipGolden
    )
    $args = New-GodotShardArgs `
        -BaseArgs $BaseArgs `
        -ShardJsonPath $ShardJsonPath `
        -SeedBlockStart $SeedBlockStart `
        -SeedBlockCount $SeedBlockCount `
        -TaskStart $TaskStart `
        -TaskCount $TaskCount `
        -TaskShardIndex $TaskShardIndex `
        -TaskShardCount $TaskShardCount `
        -SkipGolden $SkipGolden
    $output = & $godot @args 2>&1
    $output | Set-Content -LiteralPath $StdoutPath -Encoding UTF8
    '' | Set-Content -LiteralPath $StderrPath -Encoding UTF8
    Test-GodotShardOutput `
        -StdoutPath $StdoutPath `
        -StderrPath $StderrPath `
        -JsonPath $ShardJsonPath `
        -ExitCode $(if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE })
}

function Invoke-AIEvaluationMerge {
    param(
        [string[]]$InputPaths,
        [string]$OutputPath,
        [int]$WorkerCount
    )
    if ($InputPaths.Count -lt 1) {
        throw 'No AI evaluation shard inputs were provided for merge.'
    }
    $mergeArgs = @(
        (Join-Path $repoRoot 'python\scripts\merge_ai_evaluation_shards.py'),
        '--output', $OutputPath,
        '--workers', ([string][Math]::Max(1, $WorkerCount))
    )
    foreach ($path in $InputPaths) {
        $mergeArgs += @('--input', $path)
    }
    $mergeOutput = & $python @mergeArgs 2>&1
    $mergeOutput | ForEach-Object { Write-Host $_ }
    $mergeExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($mergeExit -ne 0) {
        throw "AI evaluation shard merge failed with exit code $mergeExit"
    }
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "AI evaluation shard merge did not write $OutputPath"
    }
}

if ($mergeOnly) {
    Invoke-AIEvaluationMerge `
        -InputPaths $mergeInputPaths `
        -OutputPath $jsonPath `
        -WorkerCount ([Math]::Max($Workers, $mergeInputPaths.Count))
}
else {
    $workerCount = [Math]::Max(1, $Workers)
    $outerShardCount = if ($ShardCount -gt 0) { $ShardCount } else { 1 }
    $taskShardCount = $outerShardCount * $workerCount
    $taskShardBaseIndex = if ($ShardCount -gt 0) { $ShardIndex * $workerCount } else { 0 }

    if ($workerCount -le 1) {
        $taskShardIndex = $taskShardBaseIndex
        Invoke-GodotShard `
            -BaseArgs $runnerArgs `
            -ShardJsonPath $jsonPath `
            -SeedBlockStart $SeedBlockStart `
            -SeedBlockCount $SeedBlockCount `
            -TaskStart $TaskStart `
            -TaskCount $TaskCount `
            -TaskShardIndex $taskShardIndex `
            -TaskShardCount $taskShardCount `
            -StdoutPath (Join-Path $OutputDir 'godot.stdout.log') `
            -StderrPath (Join-Path $OutputDir 'godot.stderr.log') `
            -SkipGolden ($taskShardCount -gt 1 -and $taskShardIndex -ne 0)
    }
    else {
        $shardsRoot = Join-Path $OutputDir 'shards'
        New-Item -ItemType Directory -Force -Path $shardsRoot | Out-Null
        $processes = @()
        $shardJsonPaths = @()
        for ($workerIndex = 0; $workerIndex -lt $workerCount; $workerIndex++) {
            $taskShardIndex = $taskShardBaseIndex + $workerIndex
            $shardDir = Join-Path $shardsRoot ('shard-{0:D3}' -f $workerIndex)
            New-Item -ItemType Directory -Force -Path $shardDir | Out-Null
            $shardJson = Join-Path $shardDir 'results.json'
            $stdoutPath = Join-Path $shardDir 'stdout.log'
            $stderrPath = Join-Path $shardDir 'stderr.log'
            $args = New-GodotShardArgs `
                -BaseArgs $runnerArgs `
                -ShardJsonPath $shardJson `
                -SeedBlockStart $SeedBlockStart `
                -SeedBlockCount $SeedBlockCount `
                -TaskStart $TaskStart `
                -TaskCount $TaskCount `
                -TaskShardIndex $taskShardIndex `
                -TaskShardCount $taskShardCount `
                -SkipGolden ($taskShardCount -gt 1 -and $taskShardIndex -ne 0)
            $process = Start-Process `
                -FilePath $godot `
                -ArgumentList $args `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath `
                -WindowStyle Hidden `
                -PassThru
            $processes += [pscustomobject]@{
                Process = $process
                Json = $shardJson
                Stdout = $stdoutPath
                Stderr = $stderrPath
                TaskShardIndex = $taskShardIndex
                TaskShardCount = $taskShardCount
            }
            $shardJsonPaths += $shardJson
        }
        foreach ($item in $processes) {
            $item.Process.WaitForExit()
            Test-GodotShardOutput `
                -StdoutPath $item.Stdout `
                -StderrPath $item.Stderr `
                -JsonPath $item.Json `
                -ExitCode $item.Process.ExitCode
        }
        Invoke-AIEvaluationMerge `
            -InputPaths $shardJsonPaths `
            -OutputPath $jsonPath `
            -WorkerCount $workerCount
    }
}

if (-not $SkipReport) {
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
}

if (-not [string]::IsNullOrWhiteSpace($ValidateGate)) {
    $validateArgs = @(
        (Join-Path $repoRoot 'python\scripts\validate_ai_evaluation.py'),
        '--input', $jsonPath,
        '--gate', $ValidateGate
    )
    if (-not [string]::IsNullOrWhiteSpace($Baseline)) {
        $validateArgs += @('--baseline', $Baseline)
    }
    $validateOutput = & $python @validateArgs 2>&1
    $validateOutput | ForEach-Object { Write-Host $_ }
    $validateExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($validateExit -ne 0) {
        throw "AI evaluation gate failed with exit code $validateExit"
    }
}

Write-Host "AI evaluation JSON: $jsonPath"
if (-not $SkipReport) {
    Write-Host "AI evaluation report: $htmlPath"
}
if ($ShardOnly) {
    Write-Host 'AI evaluation shard-only mode: report and validation skipped.'
}
