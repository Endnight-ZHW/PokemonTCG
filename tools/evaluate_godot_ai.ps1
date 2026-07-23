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
    [ValidateSet('', 'smoke', 'quick', 'stability', 'nightly-stability', 'equivalence', 'nightly-equivalence', 'deep-practical', 'deep', 'auto')]
    [string]$ValidateGate = '',
    [string[]]$MergeInput = @(),
    [Alias('PerformanceProbeInput')]
    [string[]]$SearchDepthProbeInput = @(),
    [Alias('PerformanceProbeOnly')]
    [switch]$SearchDepthProbeOnly,
    [switch]$ShardOnly,
    [switch]$SkipReport,
    [switch]$SkipValidate,
    [switch]$Profile,
    [switch]$DynamicAIBudget,
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
        if (-not $PSBoundParameters.ContainsKey('ValidateGate')) {
            $ValidateGate = 'smoke'
        }
    }
    'Quick' {
        if (-not $PSBoundParameters.ContainsKey('SeedBlocksPerDeck')) {
            $SeedBlocksPerDeck = 5
        }
        if (-not $PSBoundParameters.ContainsKey('MaxActions')) {
            $MaxActions = 800
        }
        if (-not $PSBoundParameters.ContainsKey('ValidateGate')) {
            $ValidateGate = 'quick'
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
    'Custom' {
        if (-not $PSBoundParameters.ContainsKey('ValidateGate')) {
            $ValidateGate = 'quick'
        }
    }
}

if ($SkipValidate -or $ShardOnly -or $SearchDepthProbeOnly) {
    $ValidateGate = ''
}
if ($ShardOnly -or $SearchDepthProbeOnly) {
    $SkipReport = $true
}
if ($ShardOnly -and $SearchDepthProbeOnly) {
    throw 'ShardOnly and SearchDepthProbeOnly cannot be combined.'
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
$searchDepthProbeInputPaths = @(Resolve-RepoPathList $SearchDepthProbeInput)
$mergeOnly = $mergeInputPaths.Count -gt 0

if ($mergeOnly -and $SearchDepthProbeOnly) {
    throw 'MergeInput and SearchDepthProbeOnly cannot be combined.'
}

if (-not $mergeOnly -and -not (Test-Path -LiteralPath $godot)) {
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
foreach ($path in $mergeInputPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "MergeInput file not found: $path"
    }
}
foreach ($path in $searchDepthProbeInputPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "SearchDepthProbeInput file not found: $path"
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
$validationPath = Join-Path $OutputDir 'validation.json'
$htmlPath = Join-Path $OutputDir 'report.html'
$provenancePath = Join-Path $OutputDir 'provenance.json'

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

if (
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

if (-not $mergeOnly) {
    $provenanceArgs = @(
        (Join-Path $repoRoot 'python\scripts\build_ai_evaluation_provenance.py'),
        '--repo-root', $repoRoot,
        '--godot-executable', $godot,
        '--target-platform', 'windows',
        '--output', $provenancePath
    )
    if (-not [string]::IsNullOrWhiteSpace($StrategyA)) {
        $provenanceArgs += @('--strategy', $StrategyA)
    }
    if (-not [string]::IsNullOrWhiteSpace($StrategyB)) {
        $provenanceArgs += @('--strategy', $StrategyB)
    }
    $provenanceOutput = & $python @provenanceArgs 2>&1
    $provenanceOutput | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $provenancePath)) {
        throw 'Failed to create AI evaluation provenance.json.'
    }
}

$runnerArgs = @(
    '--headless',
    '--path', (Join-Path $repoRoot 'godot'),
    '--script', 'res://tools/ai_evaluation_runner.gd',
    '--',
    '--eval-preset', $EvalPreset,
    '--seed-blocks-per-deck', ([string][Math]::Max(1, $SeedBlocksPerDeck)),
    '--seed', ([string]$Seed),
    '--max-actions', ([string][Math]::Max(1, $MaxActions)),
    '--provenance', $provenancePath,
    '--run-role', 'main',
    '--warmup-blocks-per-deck', '0'
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
        [string[]]$PerformanceInputPaths,
        [string]$OutputPath,
        [int]$WorkerCount
    )
    if ($InputPaths.Count -lt 1) {
        throw 'No AI evaluation shard inputs were provided for merge.'
    }
    $mergeArgs = @(
        (Join-Path $repoRoot 'python\scripts\merge_ai_evaluation_shards.py'),
        '--output', $OutputPath,
        '--error-output', (Join-Path $OutputDir 'merge_error.json'),
        '--workers', ([string][Math]::Max(1, $WorkerCount))
    )
    foreach ($path in $InputPaths) {
        $mergeArgs += @('--input', $path)
    }
    foreach ($path in $PerformanceInputPaths) {
        $mergeArgs += @('--search-depth-input', $path)
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

function Invoke-SearchDepthProbe {
    $probeRoot = Join-Path $OutputDir 'search_depth_probe'
    New-Item -ItemType Directory -Force -Path $probeRoot | Out-Null
    if (-not $NoProgress) {
        Reset-AIEvaluationProgress
    }
    $probeJson = Join-Path $probeRoot 'results.json'
    # Profiling overhead can itself reduce achieved depth. The probe keeps raw
    # latency samples for diagnosis, but runs the release search path unprofiled.
    $probeArgs = @($runnerArgs | Where-Object { $_ -ne '--profile' })
    # Later duplicate arguments intentionally override the main-matrix values.
    $probeArgs += @(
        '--eval-preset', 'Custom',
        '--seed-blocks-per-deck', '3',
        '--cross-seed-blocks-per-matchup', '0',
        '--seed', '17',
        '--matchup-mode', 'Mirror',
        '--run-role', 'search_depth_probe',
        '--warmup-blocks-per-deck', '1'
    )
    Invoke-GodotShard `
        -BaseArgs $probeArgs `
        -ShardJsonPath $probeJson `
        -SeedBlockStart 0 `
        -SeedBlockCount 0 `
        -TaskStart 0 `
        -TaskCount 0 `
        -TaskShardIndex 0 `
        -TaskShardCount 1 `
        -StdoutPath (Join-Path $probeRoot 'godot.stdout.log') `
        -StderrPath (Join-Path $probeRoot 'godot.stderr.log') `
        -SkipGolden $true `
        -EnableProgress (-not $NoProgress)
    return $probeJson
}

if ($SearchDepthProbeOnly) {
    $probeOnlyPath = Invoke-SearchDepthProbe
    Write-Host "AI evaluation search-depth probe: $probeOnlyPath"
    Write-Host "AI evaluation provenance: $provenancePath"
    return
}

$workerCount = [Math]::Max(1, $Workers)
$shardJsonPaths = @()
if ($mergeOnly) {
    $shardJsonPaths = $mergeInputPaths
}
else {
    $outerShardCount = if ($ShardCount -gt 0) { $ShardCount } else { 1 }
    $taskShardCount = $outerShardCount * $workerCount
    $taskShardBaseIndex = if ($ShardCount -gt 0) { $ShardIndex * $workerCount } else { 0 }
    $progressEnabled = -not $NoProgress
    if ($progressEnabled) {
        Reset-AIEvaluationProgress
    }
    $shardsRoot = Join-Path $OutputDir 'shards'
    New-Item -ItemType Directory -Force -Path $shardsRoot | Out-Null

    if ($workerCount -le 1) {
        $taskShardIndex = $taskShardBaseIndex
        $shardDir = Join-Path $shardsRoot 'shard-000'
        New-Item -ItemType Directory -Force -Path $shardDir | Out-Null
        $shardJson = Join-Path $shardDir 'results.json'
        Invoke-GodotShard `
            -BaseArgs $runnerArgs `
            -ShardJsonPath $shardJson `
            -SeedBlockStart $SeedBlockStart `
            -SeedBlockCount $SeedBlockCount `
            -TaskStart $TaskStart `
            -TaskCount $TaskCount `
            -TaskShardIndex $taskShardIndex `
            -TaskShardCount $taskShardCount `
            -StdoutPath (Join-Path $shardDir 'stdout.log') `
            -StderrPath (Join-Path $shardDir 'stderr.log') `
            -SkipGolden ($taskShardCount -gt 1 -and $taskShardIndex -ne 0) `
            -EnableProgress $progressEnabled
        $shardJsonPaths += $shardJson
    }
    else {
        $processes = @()
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
    }
}

if ($ShardOnly) {
    foreach ($path in $shardJsonPaths) {
        Write-Host "AI evaluation raw shard: $path"
    }
    Write-Host "AI evaluation provenance: $provenancePath"
    Write-Host 'AI evaluation shard-only mode: aggregation, report and validation skipped.'
    return
}

$effectiveProbePaths = @($searchDepthProbeInputPaths)
if (-not $mergeOnly -and $EvalPreset -eq 'Nightly' -and $effectiveProbePaths.Count -eq 0) {
    $effectiveProbePaths += Invoke-SearchDepthProbe
}

Invoke-AIEvaluationMerge `
    -InputPaths $shardJsonPaths `
    -PerformanceInputPaths $effectiveProbePaths `
    -OutputPath $jsonPath `
    -WorkerCount ([Math]::Max($workerCount, $shardJsonPaths.Count))

if ($mergeOnly) {
    $mergedPayload = Get-Content -Raw -LiteralPath $jsonPath | ConvertFrom-Json
    $mergedPayload.provenance | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $provenancePath -Encoding UTF8
}

$validateExit = 0
if (-not [string]::IsNullOrWhiteSpace($ValidateGate)) {
    $validateArgs = @(
        (Join-Path $repoRoot 'python\scripts\validate_ai_evaluation.py'),
        '--input', $jsonPath,
        '--output', $validationPath,
        '--gate', $ValidateGate
    )
    # A failed gate is expected evidence, not an orchestration failure: retain
    # its exit code, render the full report, then fail the command at the end.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $validateOutput = & $python @validateArgs 2>&1
        $validateExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $validateOutput | ForEach-Object { Write-Host $_ }
    if (-not (Test-Path -LiteralPath $validationPath)) {
        throw 'AI evaluation validation did not write validation.json.'
    }
}

if (-not $SkipReport) {
    $reportArgs = @(
        (Join-Path $repoRoot 'python\scripts\render_ai_evaluation_report.py'),
        '--input', $jsonPath,
        '--output', $htmlPath
    )
    if (Test-Path -LiteralPath $validationPath) {
        $reportArgs += @('--validation', $validationPath)
    }
    $reportOutput = & $python @reportArgs 2>&1
    $reportOutput | ForEach-Object { Write-Host $_ }
    $reportExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($reportExit -ne 0) {
        throw "AI evaluation report rendering failed with exit code $reportExit"
    }
    if (-not (Test-Path -LiteralPath $htmlPath)) {
        throw "AI evaluation report did not write $htmlPath"
    }
}

Write-Host "AI evaluation JSON: $jsonPath"
Write-Host "AI evaluation provenance: $provenancePath"
foreach ($path in $effectiveProbePaths) {
    Write-Host "AI evaluation search-depth probe: $path"
}
if (Test-Path -LiteralPath $validationPath) {
    Write-Host "AI evaluation validation: $validationPath"
}
if (-not $SkipReport) {
    Write-Host "AI evaluation report: $htmlPath"
}
if ($validateExit -ne 0) {
    throw "AI evaluation gate failed with exit code $validateExit; report and validation artifacts were preserved."
}
