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
    [ValidateSet('', 'stability', 'strength', 'equivalence', 'nightly-equivalence', 'deep-practical', 'deep', 'auto')]
    [string]$ValidateGate = '',
    [string]$Baseline = '',
    [string[]]$MergeInput = @(),
    [switch]$ShardOnly,
    [switch]$SkipReport,
    [switch]$SkipValidate,
    [switch]$Profile,
    [switch]$DynamicAIBudget,
    [switch]$CompareLegacyAI,
    [int]$ProgressEveryPairs = 1,
    [switch]$NoProgress,
    [switch]$DisableAICache,
    [switch]$DisableNativeMath,
    [string]$DistillOutput = '',
    [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$python = Join-Path $toolsRoot 'python311\python.exe'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$godot = (Get-GodotToolchainPaths -RepoRoot $repoRoot).Console

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
if ($ProgressEveryPairs -lt 1) {
    throw 'ProgressEveryPairs must be >= 1.'
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
if (
    -not $mergeOnly -and
    $CompareLegacyAI -and
    (
        -not [string]::IsNullOrWhiteSpace($StrategyA) -or
        -not [string]::IsNullOrWhiteSpace($StrategyB)
    )
) {
    throw 'CompareLegacyAI cannot be combined with explicit StrategyA or StrategyB.'
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

function New-DynamicAIBudgetConfig {
    return [ordered]@{
        enabled = $true
        min_simulations = 128
        ambiguous_min_simulations = 512
        check_interval = 32
        stable_checks = 3
        ambiguous_stable_checks = 5
        min_mean_gap = 0.10
        ambiguous_mean_gap = 0.14
        min_best_visits = 32
        min_best_visit_share = 0.35
        clear_prior_gap = 0.25
        max_root_actions_for_clear = 10
        single_action_simulations = 0
    }
}

function New-PresetAIStrategy {
    param(
        [string]$Id,
        [string]$Label,
        [string]$HeuristicVariant,
        [bool]$UseDynamicBudget
    )
    $strategy = [ordered]@{
        id = $Id
        label = $Label
    }
    if ($EvalPreset -eq 'Smoke') {
        $strategy['simulation_budget'] = 1
        $strategy['seconds'] = 0.01
        $strategy['max_depth'] = 1
        $strategy['deterministic'] = $true
    }
    elseif ($EvalPreset -eq 'Quick') {
        $strategy['simulation_budget'] = 64
        $strategy['seconds'] = 0.05
        $strategy['max_depth'] = 8
        $strategy['deterministic'] = $true
    }
    else {
        $strategy['preset'] = 'strongest'
    }
    if (-not [string]::IsNullOrWhiteSpace($HeuristicVariant)) {
        $strategy['heuristic_variant'] = $HeuristicVariant
    }
    if ($UseDynamicBudget) {
        $strategy['dynamic_budget'] = New-DynamicAIBudgetConfig
    }
    return $strategy
}

if (
    -not $mergeOnly -and
    [string]::IsNullOrWhiteSpace($StrategyA) -and
    [string]::IsNullOrWhiteSpace($StrategyB) -and
    $CompareLegacyAI
) {
    $semanticStrategyPath = Join-Path $OutputDir 'strategy_semantic_v2.json'
    $legacyStrategyPath = Join-Path $OutputDir 'strategy_legacy.json'
    $semanticStrategy = New-PresetAIStrategy `
        -Id 'semantic-v2' `
        -Label 'Semantic v2 Challenge AI' `
        -HeuristicVariant 'semantic_v2' `
        -UseDynamicBudget ([bool]$DynamicAIBudget)
    $legacyStrategy = New-PresetAIStrategy `
        -Id 'legacy' `
        -Label 'Legacy Challenge AI' `
        -HeuristicVariant 'legacy' `
        -UseDynamicBudget ([bool]$DynamicAIBudget)
    $semanticStrategy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $semanticStrategyPath -Encoding UTF8
    $legacyStrategy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $legacyStrategyPath -Encoding UTF8
    $StrategyA = $semanticStrategyPath
    $StrategyB = $legacyStrategyPath
}
elseif (
    -not $mergeOnly -and
    [string]::IsNullOrWhiteSpace($StrategyA) -and
    [string]::IsNullOrWhiteSpace($StrategyB) -and
    $DynamicAIBudget
) {
    $presetStrategyPath = Join-Path $OutputDir 'preset_strategy.json'
    $presetStrategy = [ordered]@{
        id = 'dynamic-budget-strongest'
        label = 'Dynamic Budget Strongest'
        preset = 'strongest'
        dynamic_budget = New-DynamicAIBudgetConfig
    }
    $presetStrategy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $presetStrategyPath -Encoding UTF8
    $StrategyA = $presetStrategyPath
    $StrategyB = $presetStrategyPath
}
elseif (
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
if (-not [string]::IsNullOrWhiteSpace($DistillOutput)) {
    $runnerArgs += @('--distill-output', (Resolve-RepoPathOrEmpty $DistillOutput))
}
if (-not $NoProgress) {
    $runnerArgs += @(
        '--progress',
        '--progress-every-pairs', ([string][Math]::Max(1, $ProgressEveryPairs))
    )
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
        [int]$ExitCode,
        [bool]$ReplayOutput = $true
    )
    $outputLines = @()
    if (Test-Path -LiteralPath $StdoutPath) {
        $outputLines += Get-Content -LiteralPath $StdoutPath
    }
    if (Test-Path -LiteralPath $StderrPath) {
        $outputLines += Get-Content -LiteralPath $StderrPath
    }
    if ($ReplayOutput) {
        $outputLines | ForEach-Object { Write-Host $_ }
    }
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

$script:AIEvalProgressByShard = @{}
$script:AIEvalProgressLastHostAt = [datetime]::MinValue

function Reset-AIEvaluationProgress {
    $script:AIEvalProgressByShard = @{}
    $script:AIEvalProgressLastHostAt = [datetime]::MinValue
}

function Read-NewLogLines {
    param(
        [string]$Path,
        [ref]$LineCount
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($lines.Count -le $LineCount.Value) {
        return @()
    }
    $start = [int]$LineCount.Value
    $LineCount.Value = $lines.Count
    return @($lines[$start..($lines.Count - 1)])
}

function ConvertFrom-AIEvaluationProgressLine {
    param([string]$Line)
    if ($Line -notmatch '^AI_EVALUATION_PROGRESS\s+(\{.*\})\s*$') {
        return $null
    }
    try {
        return ($Matches[1] | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Write-AIEvaluationProgressEvent {
    param([object]$Progress)
    if ($null -eq $Progress) {
        return
    }
    $shardKey = [string]$Progress.task_shard_index
    $script:AIEvalProgressByShard[$shardKey] = $Progress

    $completedPairs = 0
    $totalPairs = 0
    $completedGames = 0
    $totalGames = 0
    foreach ($item in $script:AIEvalProgressByShard.Values) {
        $completedPairs += [int]$item.completed_pairs
        $totalPairs += [int]$item.total_pairs
        $completedGames += [int]$item.completed_games
        $totalGames += [int]$item.total_games
    }
    $percent = 0
    if ($totalPairs -gt 0) {
        $percent = [Math]::Min(100, [Math]::Max(0, [int](100 * $completedPairs / $totalPairs)))
    }
    $status = "pairs $completedPairs/$totalPairs, games $completedGames/$totalGames"
    if (-not [string]::IsNullOrWhiteSpace([string]$Progress.matchup_key)) {
        $status += ", latest $($Progress.matchup_key)"
    }
    Write-Progress -Activity 'AI evaluation' -Status $status -PercentComplete $percent

    $now = Get-Date
    $isComplete = $totalPairs -gt 0 -and $completedPairs -ge $totalPairs
    if (($now - $script:AIEvalProgressLastHostAt).TotalSeconds -ge 2 -or $isComplete) {
        Write-Host "AI evaluation progress: $status"
        $script:AIEvalProgressLastHostAt = $now
    }
}

function Write-AIEvaluationOutputLine {
    param(
        [string]$Line,
        [string]$Prefix,
        [bool]$EnableProgress
    )
    if ([string]::IsNullOrEmpty($Line)) {
        return
    }
    if ($EnableProgress) {
        $progress = ConvertFrom-AIEvaluationProgressLine -Line $Line
        if ($null -ne $progress) {
            Write-AIEvaluationProgressEvent -Progress $progress
            return
        }
    }
    if ([string]::IsNullOrWhiteSpace($Prefix)) {
        Write-Host $Line
    }
    else {
        Write-Host "[$Prefix] $Line"
    }
}

function Watch-GodotShardProcesses {
    param(
        [object[]]$Items,
        [bool]$EnableProgress
    )
    foreach ($item in $Items) {
        $item.StdoutLines = 0
        $item.StderrLines = 0
    }
    while ($true) {
        $allExited = $true
        foreach ($item in $Items) {
            $label = if ($Items.Count -gt 1) { "shard $($item.TaskShardIndex)" } else { '' }
            $stdoutLines = [int]$item.StdoutLines
            foreach ($line in Read-NewLogLines -Path $item.Stdout -LineCount ([ref]$stdoutLines)) {
                Write-AIEvaluationOutputLine -Line $line -Prefix $label -EnableProgress $EnableProgress
            }
            $item.StdoutLines = $stdoutLines
            $stderrLines = [int]$item.StderrLines
            foreach ($line in Read-NewLogLines -Path $item.Stderr -LineCount ([ref]$stderrLines)) {
                $stderrLabel = if ([string]::IsNullOrWhiteSpace($label)) { 'stderr' } else { "$label stderr" }
                Write-AIEvaluationOutputLine -Line $line -Prefix $stderrLabel -EnableProgress $false
            }
            $item.StderrLines = $stderrLines
            if (-not $item.Process.HasExited) {
                $allExited = $false
            }
        }
        if ($allExited) {
            break
        }
        Start-Sleep -Milliseconds 200
    }
    foreach ($item in $Items) {
        $label = if ($Items.Count -gt 1) { "shard $($item.TaskShardIndex)" } else { '' }
        $stdoutLines = [int]$item.StdoutLines
        foreach ($line in Read-NewLogLines -Path $item.Stdout -LineCount ([ref]$stdoutLines)) {
            Write-AIEvaluationOutputLine -Line $line -Prefix $label -EnableProgress $EnableProgress
        }
        $item.StdoutLines = $stdoutLines
        $stderrLines = [int]$item.StderrLines
        foreach ($line in Read-NewLogLines -Path $item.Stderr -LineCount ([ref]$stderrLines)) {
            $stderrLabel = if ([string]::IsNullOrWhiteSpace($label)) { 'stderr' } else { "$label stderr" }
            Write-AIEvaluationOutputLine -Line $line -Prefix $stderrLabel -EnableProgress $false
        }
        $item.StderrLines = $stderrLines
    }
    if ($EnableProgress) {
        Write-Progress -Activity 'AI evaluation' -Completed
    }
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
        [bool]$SkipGolden,
        [bool]$EnableProgress
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
    if ($EnableProgress) {
        '' | Set-Content -LiteralPath $StdoutPath -Encoding UTF8
        '' | Set-Content -LiteralPath $StderrPath -Encoding UTF8
        $process = Start-Process `
            -FilePath $godot `
            -ArgumentList $args `
            -RedirectStandardOutput $StdoutPath `
            -RedirectStandardError $StderrPath `
            -WindowStyle Hidden `
            -PassThru
        $item = [pscustomobject]@{
            Process = $process
            Json = $ShardJsonPath
            Stdout = $StdoutPath
            Stderr = $StderrPath
            TaskShardIndex = $TaskShardIndex
            TaskShardCount = $TaskShardCount
            StdoutLines = 0
            StderrLines = 0
        }
        Watch-GodotShardProcesses -Items @($item) -EnableProgress $true
        $exitCode = $process.ExitCode
        Test-GodotShardOutput `
            -StdoutPath $StdoutPath `
            -StderrPath $StderrPath `
            -JsonPath $ShardJsonPath `
            -ExitCode $exitCode `
            -ReplayOutput $false
        return
    }
    $output = & $godot @args 2>&1
    $output | Set-Content -LiteralPath $StdoutPath -Encoding UTF8
    '' | Set-Content -LiteralPath $StderrPath -Encoding UTF8
    Test-GodotShardOutput `
        -StdoutPath $StdoutPath `
        -StderrPath $StderrPath `
        -JsonPath $ShardJsonPath `
        -ExitCode $(if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }) `
        -ReplayOutput $true
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
    $progressEnabled = -not $NoProgress
    if ($progressEnabled) {
        Reset-AIEvaluationProgress
    }

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
            -SkipGolden ($taskShardCount -gt 1 -and $taskShardIndex -ne 0) `
            -EnableProgress $progressEnabled
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
                StdoutLines = 0
                StderrLines = 0
            }
            $shardJsonPaths += $shardJson
        }
        if ($progressEnabled) {
            Watch-GodotShardProcesses -Items $processes -EnableProgress $true
        }
        foreach ($item in $processes) {
            if (-not $item.Process.HasExited) {
                $item.Process.WaitForExit()
            }
            Test-GodotShardOutput `
                -StdoutPath $item.Stdout `
                -StderrPath $item.Stderr `
                -JsonPath $item.Json `
                -ExitCode $item.Process.ExitCode `
                -ReplayOutput (-not $progressEnabled)
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
