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
    [ValidateSet('', 'smoke', 'quick', 'stability', 'nightly-stability', 'equivalence', 'nightly-equivalence', 'superiority', 'nightly-superiority', 'deep-practical', 'deep-release', 'deep-noninferiority', 'deep', 'auto')]
    [string]$ValidateGate = '',
    [string]$DeepRuntimeManifest = '',
    [string]$DeepReleaseManifest = '',
    [string[]]$MergeInput = @(),
    [Alias('SearchDepthProbeInput', 'PerformanceProbeInput')]
    [string[]]$PerformanceBenchmarkInput = @(),
    [Alias('SearchDepthProbeOnly', 'PerformanceProbeOnly')]
    [switch]$PerformanceBenchmarkOnly,
    [switch]$PerformanceBenchmark,
    [int]$LogicalShardCount = 0,
    [string]$CheckpointDir = '',
    [switch]$NoResume,
    [switch]$ContinueOnStructuralFailure,
    [switch]$V1CalibrationOnly,
    [switch]$ShardOnly,
    [switch]$SkipReport,
    [switch]$SkipValidate,
    [switch]$Profile,
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

function Get-SafeDefaultWorkerCount {
    $physicalCores = 0
    try {
        $physicalCores = [int]((
            Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop |
                Measure-Object -Property NumberOfCores -Sum
        ).Sum)
    }
    catch {
        $physicalCores = [Math]::Max(1, [int][Environment]::ProcessorCount)
    }
    return [Math]::Max(1, [Math]::Min(12, $physicalCores))
}

if ($V1CalibrationOnly) {
    if ($MergeInput.Count -gt 0 -or $PerformanceBenchmarkInput.Count -gt 0) {
        throw 'V1CalibrationOnly cannot be combined with merge or performance inputs.'
    }
    $EvalPreset = 'Custom'
    $Deck = @('fire')
    $SeedBlocksPerDeck = 1
    $CrossSeedBlocksPerMatchup = 0
    $Seed = 17
    $MaxActions = 300
    $Workers = 1
    $LogicalShardCount = 1
    $MatchupMode = 'Mirror'
    $ValidateGate = ''
    $ShardOnly = $true
    $SkipReport = $true
    $NoProgress = $true
    $NoResume = $true
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
        if (-not $PSBoundParameters.ContainsKey('Workers')) {
            $Workers = Get-SafeDefaultWorkerCount
        }
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
        if (-not $PSBoundParameters.ContainsKey('LogicalShardCount')) {
            $LogicalShardCount = 50
        }
    }
    'Custom' {
        if (-not $PSBoundParameters.ContainsKey('ValidateGate')) {
            $ValidateGate = 'quick'
        }
    }
}

if ($SkipValidate -or $ShardOnly -or $PerformanceBenchmarkOnly) {
    $ValidateGate = ''
}
if ($ShardOnly -or $PerformanceBenchmarkOnly) {
    $SkipReport = $true
}
if ($ShardOnly -and $PerformanceBenchmarkOnly) {
    throw 'ShardOnly and PerformanceBenchmarkOnly cannot be combined.'
}
if ($ShardOnly -and $PerformanceBenchmark) {
    throw 'ShardOnly and PerformanceBenchmark cannot be combined.'
}
if ($PerformanceBenchmark -and $PerformanceBenchmarkOnly) {
    throw 'PerformanceBenchmark and PerformanceBenchmarkOnly cannot be combined.'
}
if (
    ($PerformanceBenchmark -or $PerformanceBenchmarkOnly) -and
    -not [string]::IsNullOrWhiteSpace($DistillOutput)
) {
    throw 'PerformanceBenchmark cannot be combined with DistillOutput.'
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
if ($SeedBlockStart -ge [Math]::Max(1, $SeedBlocksPerDeck)) {
    throw 'SeedBlockStart must be less than SeedBlocksPerDeck.'
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
if ($LogicalShardCount -lt 0) {
    throw 'LogicalShardCount must be >= 0.'
}
if ($LogicalShardCount -eq 0) {
    $defaultOuterShardCount = if ($ShardCount -gt 0) { $ShardCount } else { 1 }
    $LogicalShardCount = [Math]::Max(1, $Workers * $defaultOuterShardCount)
}

Set-PortableGodotEnvironment -ToolsRoot $toolsRoot

$mergeInputPaths = @(Resolve-RepoPathList $MergeInput)
$performanceBenchmarkInputPaths = @(Resolve-RepoPathList $PerformanceBenchmarkInput)
$mergeOnly = $mergeInputPaths.Count -gt 0

if ($mergeOnly -and $PerformanceBenchmarkOnly) {
    throw 'MergeInput and PerformanceBenchmarkOnly cannot be combined.'
}
if ($mergeOnly -and $PerformanceBenchmark) {
    throw 'MergeInput and PerformanceBenchmark cannot be combined; use PerformanceBenchmarkInput.'
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
foreach ($path in $performanceBenchmarkInputPaths) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "PerformanceBenchmarkInput file not found: $path"
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
if ([string]::IsNullOrWhiteSpace($CheckpointDir)) {
    $CheckpointDir = Join-Path $OutputDir 'checkpoints'
}
elseif (-not [System.IO.Path]::IsPathRooted($CheckpointDir)) {
    $CheckpointDir = Join-Path $repoRoot $CheckpointDir
}
$jsonPath = Join-Path $OutputDir 'results.json'
$validationPath = Join-Path $OutputDir 'validation.json'
$htmlPath = Join-Path $OutputDir 'report.html'
$provenancePath = Join-Path $OutputDir 'provenance.json'

if ($V1CalibrationOnly) {
    $calibrationThresholdPath = Join-Path $repoRoot 'godot\tools\ai_baseline\v1_calibration_v7.json'
    if (-not (Test-Path -LiteralPath $calibrationThresholdPath)) {
        throw "Missing frozen v1 calibration thresholds: $calibrationThresholdPath"
    }
    $calibrationThreshold = Get-Content -Raw -LiteralPath $calibrationThresholdPath |
        ConvertFrom-Json
    $calibrationStrategyPath = Join-Path $OutputDir 'v1_calibration_strategy.json'
    [ordered]@{
        id = 'turn-beam-v1-calibration'
        label = 'Frozen v1 Calibration'
        engine = 'turn_beam_v1'
        simulation_budget = [int]$calibrationThreshold.config.simulation_budget
        seconds = [double]$calibrationThreshold.config.seconds
        max_depth = [int]$calibrationThreshold.config.max_depth
        deterministic = $true
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $calibrationStrategyPath -Encoding UTF8
    $StrategyA = $calibrationStrategyPath
    $StrategyB = $calibrationStrategyPath
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
            engine = 'turn_beam_v2'
            internal_evaluation_smoke = $true
            deterministic = $true
        }
    }
    else {
        $presetStrategy = [ordered]@{
            id = 'quick-preset'
            label = 'Quick Preset'
            engine = 'turn_beam_v2'
            internal_evaluation_smoke = $true
            deterministic = $true
        }
    }
    $presetStrategy | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $presetStrategyPath -Encoding UTF8
    $StrategyA = $presetStrategyPath
    $StrategyB = $presetStrategyPath
}
elseif (
    -not $mergeOnly -and
    [string]::IsNullOrWhiteSpace($StrategyA) -and
    [string]::IsNullOrWhiteSpace($StrategyB) -and
    $EvalPreset -eq 'Nightly'
) {
    $candidatePath = Join-Path $OutputDir 'candidate_turn_beam_v2.json'
    $baselinePath = Join-Path $OutputDir 'baseline_turn_beam_v1.json'
    [ordered]@{
        id = 'turn-beam-v2-candidate'
        label = 'Fixed Depth 8 Candidate'
        engine = 'turn_beam_v2'
        deterministic = $true
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $candidatePath -Encoding UTF8
    [ordered]@{
        id = 'turn-beam-v1-baseline'
        label = 'Frozen Time-Budget Baseline'
        engine = 'turn_beam_v1'
        simulation_budget = 192
        seconds = 0.85
        max_depth = 6
        deterministic = $true
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $baselinePath -Encoding UTF8
    $StrategyA = $candidatePath
    $StrategyB = $baselinePath
}

$defaultDeckKeys = @(
    'colorless',
    'darkness',
    'dragon',
    'fighting',
    'fire',
    'grass',
    'lightning',
    'psychic',
    'steel',
    'water'
)
$selectedDeckKeys = @(
    if ($Deck.Count -gt 0) {
        $Deck |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Sort-Object -Unique
    }
    else {
        $defaultDeckKeys
    }
)
$effectiveMatchupMode = $MatchupMode
if ([string]::IsNullOrWhiteSpace($effectiveMatchupMode)) {
    $effectiveMatchupMode = if ($EvalPreset -eq 'Nightly') { 'Balanced' } else { 'Mirror' }
}
$effectiveCrossSeedBlocks = if ($CrossSeedBlocksPerMatchup -ge 0) {
    [Math]::Max(0, $CrossSeedBlocksPerMatchup)
}
else {
    10
}
$taskManifestDescriptor = [ordered]@{
    protocol_id = 'traditional_ai_evaluation_v7'
    deck_keys = $selectedDeckKeys
    seed = $Seed
    seed_blocks_per_deck = [Math]::Max(1, $SeedBlocksPerDeck)
    cross_seed_blocks_per_matchup = $effectiveCrossSeedBlocks
    matchup_mode = $effectiveMatchupMode
    max_actions = [Math]::Max(1, $MaxActions)
    rules_options = [ordered]@{
        apply_type_matchups = $false
    }
    seed_block_start = $SeedBlockStart
    seed_block_count = $SeedBlockCount
    task_start = $TaskStart
    task_count = $TaskCount
}
$taskManifestPath = Join-Path $OutputDir 'task_manifest.json'
if (-not $mergeOnly) {
    $taskManifestDescriptor | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $taskManifestPath -Encoding UTF8
    $taskManifestOutput = & $python @(
        '-X', 'utf8',
        (Join-Path $repoRoot 'python\scripts\build_ai_evaluation_task_manifest.py'),
        '--config', $taskManifestPath,
        '--output', $taskManifestPath
    ) 2>&1
    $taskManifestOutput | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $taskManifestPath)) {
        throw 'Failed to create the canonical AI evaluation task manifest.'
    }
    $taskManifestId = [string](
        (Get-Content -Raw -LiteralPath $taskManifestPath | ConvertFrom-Json).
            task_manifest_id
    )
    if ($taskManifestId -notmatch '^[0-9a-f]{64}$') {
        throw "Invalid canonical task manifest id: $taskManifestId"
    }
}
else {
    $taskManifestId = ''
}
$executionHostCount = if ($ShardCount -gt 0) { $ShardCount } else { 1 }
$executionProfileId = 'windows-h{0}-w{1}-cache-{2}-native-{3}-profile-{4}' -f @(
    $executionHostCount,
    $Workers,
    $(if ($DisableAICache) { 'off' } else { 'on' }),
    $(if ($DisableNativeMath) { 'off' } else { 'on' }),
    $(if ($Profile) { 'on' } else { 'off' })
)
$simulationConfigPath = Join-Path $OutputDir 'simulation_config.json'
$simulationConfig = [ordered]@{
    protocol_id = 'traditional_ai_evaluation_v7'
    eval_preset = $EvalPreset
    deck_keys = $selectedDeckKeys
    seed = $Seed
    seed_blocks_per_deck = [Math]::Max(1, $SeedBlocksPerDeck)
    cross_seed_blocks_per_matchup = $effectiveCrossSeedBlocks
    matchup_mode = $effectiveMatchupMode
    max_actions = [Math]::Max(1, $MaxActions)
    rules_options = [ordered]@{
        apply_type_matchups = $false
    }
    profile = [bool]$Profile
    disable_ai_cache = [bool]$DisableAICache
    disable_native_math = [bool]$DisableNativeMath
    workers = $Workers
    external_shard_count = $executionHostCount
    global_parallel_workers = $Workers * $executionHostCount
    task_manifest_id = $taskManifestId
    evidence_shard_count = $LogicalShardCount
    execution_profile_id = $executionProfileId
}
if (-not $mergeOnly) {
    $simulationConfig | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $simulationConfigPath -Encoding UTF8
}

if (-not $mergeOnly) {
    $provenanceArgs = @(
        '-X', 'utf8',
        (Join-Path $repoRoot 'python\scripts\build_ai_evaluation_provenance.py'),
        '--repo-root', $repoRoot,
        '--godot-executable', $godot,
        '--target-platform', 'windows',
        '--simulation-config', $simulationConfigPath,
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
    '--warmup-blocks-per-deck', '0',
    '--task-manifest-id', $taskManifestId,
    '--execution-profile-id', $executionProfileId
)
if (-not $ContinueOnStructuralFailure) {
    $runnerArgs += @('--fail-fast-fatal')
}
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
if (-not [string]::IsNullOrWhiteSpace($DeepRuntimeManifest)) {
    $runnerArgs += @(
        '--deep-runtime-manifest',
        (Resolve-RepoPathOrEmpty $DeepRuntimeManifest)
    )
}
if (-not [string]::IsNullOrWhiteSpace($DeepReleaseManifest)) {
    $runnerArgs += @(
        '--deep-release-manifest',
        (Resolve-RepoPathOrEmpty $DeepReleaseManifest)
    )
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
    try {
        $payload = Get-Content -Raw -LiteralPath $JsonPath | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Godot AI evaluation wrote invalid JSON: $JsonPath"
    }
    if ([bool]$payload.fatal_stop) {
        $details = $payload.fatal_stop_details | ConvertTo-Json -Compress -Depth 8
        throw "Godot AI evaluation stopped on a structural failure: $details"
    }
}

function New-GodotShardArgs {
    param(
        [string[]]$BaseArgs,
        [string]$ShardJsonPath,
        [string]$ShardCheckpointDir,
        [int]$SeedBlockStart,
        [int]$SeedBlockCount,
        [int]$TaskStart,
        [int]$TaskCount,
        [int]$EvidenceShardIndex,
        [int]$EvidenceShardCount,
        [bool]$SkipGolden
    )
    $args = @($BaseArgs)
    $args += @(
        '--output', $ShardJsonPath,
        '--evidence-shard-index', ([string]$EvidenceShardIndex),
        '--evidence-shard-count', ([string][Math]::Max(1, $EvidenceShardCount))
    )
    if (-not [string]::IsNullOrWhiteSpace($ShardCheckpointDir)) {
        $args += @('--checkpoint-dir', $ShardCheckpointDir)
        if (-not $NoResume) {
            $args += @('--resume-checkpoints')
        }
    }
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

function New-LogTailState {
    return [pscustomobject]@{
        Offset = [long]0
        Remainder = ''
        Decoder = ([System.Text.UTF8Encoding]::new($false)).GetDecoder()
        FirstChunk = $true
    }
}

function Read-NewLogLines {
    param(
        [string]$Path,
        [object]$State,
        [switch]$Flush
    )
    $builder = [System.Text.StringBuilder]::new()
    if (Test-Path -LiteralPath $Path) {
        $stream = $null
        try {
            $stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            )
            if ($stream.Length -lt [long]$State.Offset) {
                $State.Offset = [long]0
                $State.Remainder = ''
                $State.Decoder.Reset()
                $State.FirstChunk = $true
            }
            [void]$stream.Seek([long]$State.Offset, [System.IO.SeekOrigin]::Begin)
            $byteBuffer = [byte[]]::new(65536)
            $charBuffer = [char[]]::new(65536)
            while (($read = $stream.Read($byteBuffer, 0, $byteBuffer.Length)) -gt 0) {
                $State.Offset += $read
                $byteIndex = 0
                while ($byteIndex -lt $read) {
                    $bytesUsed = 0
                    $charsUsed = 0
                    $completed = $false
                    $State.Decoder.Convert(
                        $byteBuffer,
                        $byteIndex,
                        $read - $byteIndex,
                        $charBuffer,
                        0,
                        $charBuffer.Length,
                        $false,
                        [ref]$bytesUsed,
                        [ref]$charsUsed,
                        [ref]$completed
                    )
                    if ($charsUsed -gt 0) {
                        [void]$builder.Append($charBuffer, 0, $charsUsed)
                    }
                    $byteIndex += $bytesUsed
                }
            }
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
    }
    if ($Flush) {
        $emptyBytes = [byte[]]::new(0)
        $flushChars = [char[]]::new(8)
        $bytesUsed = 0
        $charsUsed = 0
        $completed = $false
        $State.Decoder.Convert(
            $emptyBytes,
            0,
            0,
            $flushChars,
            0,
            $flushChars.Length,
            $true,
            [ref]$bytesUsed,
            [ref]$charsUsed,
            [ref]$completed
        )
        if ($charsUsed -gt 0) {
            [void]$builder.Append($flushChars, 0, $charsUsed)
        }
    }
    $text = [string]$State.Remainder + $builder.ToString()
    if ($State.FirstChunk -and $text.StartsWith([char]0xFEFF)) {
        $text = $text.Substring(1)
    }
    if ($text.Length -gt 0) {
        $State.FirstChunk = $false
    }
    $parts = [System.Text.RegularExpressions.Regex]::Split($text, "\r?\n")
    if ($Flush) {
        $State.Remainder = ''
        if ($parts.Count -gt 0 -and $parts[$parts.Count - 1] -eq '') {
            if ($parts.Count -eq 1) {
                return @()
            }
            return @($parts[0..($parts.Count - 2)])
        }
        return @($parts)
    }
    if ($parts.Count -le 1) {
        $State.Remainder = $text
        return @()
    }
    $State.Remainder = $parts[$parts.Count - 1]
    return @($parts[0..($parts.Count - 2)])
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
    $shardKey = if ($null -ne $Progress.evidence_shard_index) {
        [string]$Progress.evidence_shard_index
    }
    else {
        [string]$Progress.task_shard_index
    }
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
        $item.StdoutTail = New-LogTailState
        $item.StderrTail = New-LogTailState
    }
    while ($true) {
        $allExited = $true
        foreach ($item in $Items) {
            $label = if ($Items.Count -gt 1) { "shard $($item.EvidenceShardIndex)" } else { '' }
            foreach ($line in Read-NewLogLines -Path $item.Stdout -State $item.StdoutTail) {
                Write-AIEvaluationOutputLine -Line $line -Prefix $label -EnableProgress $EnableProgress
            }
            foreach ($line in Read-NewLogLines -Path $item.Stderr -State $item.StderrTail) {
                $stderrLabel = if ([string]::IsNullOrWhiteSpace($label)) { 'stderr' } else { "$label stderr" }
                Write-AIEvaluationOutputLine -Line $line -Prefix $stderrLabel -EnableProgress $false
            }
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
        $label = if ($Items.Count -gt 1) { "shard $($item.EvidenceShardIndex)" } else { '' }
        foreach ($line in Read-NewLogLines -Path $item.Stdout -State $item.StdoutTail -Flush) {
            Write-AIEvaluationOutputLine -Line $line -Prefix $label -EnableProgress $EnableProgress
        }
        foreach ($line in Read-NewLogLines -Path $item.Stderr -State $item.StderrTail -Flush) {
            $stderrLabel = if ([string]::IsNullOrWhiteSpace($label)) { 'stderr' } else { "$label stderr" }
            Write-AIEvaluationOutputLine -Line $line -Prefix $stderrLabel -EnableProgress $false
        }
    }
    if ($EnableProgress) {
        Write-Progress -Activity 'AI evaluation' -Completed
    }
}

function Invoke-GodotShard {
    param(
        [string[]]$BaseArgs,
        [string]$ShardJsonPath,
        [string]$ShardCheckpointDir,
        [int]$SeedBlockStart,
        [int]$SeedBlockCount,
        [int]$TaskStart,
        [int]$TaskCount,
        [int]$EvidenceShardIndex,
        [int]$EvidenceShardCount,
        [string]$StdoutPath,
        [string]$StderrPath,
        [bool]$SkipGolden,
        [bool]$EnableProgress
    )
    $args = New-GodotShardArgs `
        -BaseArgs $BaseArgs `
        -ShardJsonPath $ShardJsonPath `
        -ShardCheckpointDir $ShardCheckpointDir `
        -SeedBlockStart $SeedBlockStart `
        -SeedBlockCount $SeedBlockCount `
        -TaskStart $TaskStart `
        -TaskCount $TaskCount `
        -EvidenceShardIndex $EvidenceShardIndex `
        -EvidenceShardCount $EvidenceShardCount `
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
            EvidenceShardIndex = $EvidenceShardIndex
            EvidenceShardCount = $EvidenceShardCount
            StdoutTail = $null
            StderrTail = $null
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
        [int]$WorkerCount,
        [double]$WallClockMs = 0.0,
        [ValidateSet('', 'full_evidence_stage', 'current_attempt_only')]
        [string]$WallClockScope = ''
    )
    if ($InputPaths.Count -lt 1) {
        throw 'No AI evaluation shard inputs were provided for merge.'
    }
    $mergeArgs = @(
        '-X', 'utf8',
        (Join-Path $repoRoot 'python\scripts\merge_ai_evaluation_shards.py'),
        '--output', $OutputPath,
        '--error-output', (Join-Path $OutputDir 'merge_error.json'),
        '--workers', ([string][Math]::Max(1, $WorkerCount))
    )
    foreach ($path in $InputPaths) {
        $mergeArgs += @('--input', $path)
    }
    foreach ($path in $PerformanceInputPaths) {
        $mergeArgs += @('--performance-input', $path)
    }
    if ($WallClockMs -gt 0.0) {
        $mergeArgs += @(
            '--wall-clock-ms',
            $WallClockMs.ToString(
                '0.###',
                [System.Globalization.CultureInfo]::InvariantCulture
            ),
            '--wall-clock-scope',
            $WallClockScope
        )
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

function Invoke-PerformanceBenchmark {
    $benchmarkRoot = Join-Path $OutputDir 'performance_benchmark'
    New-Item -ItemType Directory -Force -Path $benchmarkRoot | Out-Null
    if (-not $NoProgress) {
        Reset-AIEvaluationProgress
    }
    $benchmarkJson = Join-Path $benchmarkRoot 'results.json'
    # Profiling overhead changes latency. Keep the optional benchmark on the
    # release search path and reserve -Profile for the main diagnostic run.
    $benchmarkArgs = @($runnerArgs | Where-Object { $_ -ne '--profile' })
    # Later duplicate arguments intentionally override the main-matrix values.
    $benchmarkArgs += @(
        '--eval-preset', 'Custom',
        '--seed-blocks-per-deck', '3',
        '--cross-seed-blocks-per-matchup', '0',
        '--seed', '17',
        '--matchup-mode', 'Mirror',
        '--run-role', 'performance_benchmark',
        '--warmup-blocks-per-deck', '1',
        '--task-manifest-id', "$taskManifestId-performance",
        '--execution-profile-id', "$executionProfileId-performance"
    )
    Invoke-GodotShard `
        -BaseArgs $benchmarkArgs `
        -ShardJsonPath $benchmarkJson `
        -ShardCheckpointDir '' `
        -SeedBlockStart 0 `
        -SeedBlockCount 0 `
        -TaskStart 0 `
        -TaskCount 0 `
        -EvidenceShardIndex 0 `
        -EvidenceShardCount 1 `
        -StdoutPath (Join-Path $benchmarkRoot 'godot.stdout.log') `
        -StderrPath (Join-Path $benchmarkRoot 'godot.stderr.log') `
        -SkipGolden $true `
        -EnableProgress (-not $NoProgress)
    return $benchmarkJson
}

if ($PerformanceBenchmarkOnly) {
    $benchmarkOnlyPath = Invoke-PerformanceBenchmark
    Write-Host "AI evaluation performance benchmark: $benchmarkOnlyPath"
    Write-Host "AI evaluation provenance: $provenancePath"
    return
}

$workerCount = [Math]::Max(1, $Workers)
$shardJsonPaths = @()
$evidenceWallClockMs = 0.0
$evidenceWallClockScope = 'not_recorded'
if ($mergeOnly) {
    $shardJsonPaths = $mergeInputPaths
}
else {
    $outerShardCount = if ($ShardCount -gt 0) { $ShardCount } else { 1 }
    $outerShardIndex = if ($ShardCount -gt 0) { $ShardIndex } else { 0 }
    $assignedEvidenceShards = @(
        0..($LogicalShardCount - 1) |
            Where-Object { ($_ % $outerShardCount) -eq $outerShardIndex }
    )
    if ($assignedEvidenceShards.Count -eq 0) {
        throw (
            "External shard $outerShardIndex/$outerShardCount has no logical evidence shards " +
            "within LogicalShardCount=$LogicalShardCount."
        )
    }
    $progressEnabled = -not $NoProgress
    if ($progressEnabled) {
        Reset-AIEvaluationProgress
    }
    $checkpointEnabled = (
        -not $V1CalibrationOnly -and
        -not $NoResume -and
        -not $Profile -and
        [string]::IsNullOrWhiteSpace($DistillOutput)
    )
    $hadCheckpointFilesAtEvidenceStart = $false
    if (
        $checkpointEnabled -and
        (Test-Path -LiteralPath $CheckpointDir)
    ) {
        $hadCheckpointFilesAtEvidenceStart = $null -ne (
            Get-ChildItem `
                -LiteralPath $CheckpointDir `
                -Recurse `
                -Filter '*.json' `
                -File `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1
        )
    }
    # Existing checkpoints make this invocation a resumed-attempt measurement;
    # otherwise the stopwatch covers the complete evidence stage.
    $evidenceWallClockScope = if ($hadCheckpointFilesAtEvidenceStart) {
        'current_attempt_only'
    }
    else {
        'full_evidence_stage'
    }
    if ($checkpointEnabled) {
        New-Item -ItemType Directory -Force -Path $CheckpointDir | Out-Null
    }

    function Start-EvidenceShardProcess {
        param(
            [int]$EvidenceShardIndex,
            [string[]]$BaseArgs,
            [string]$StageRoot,
            [string]$StageLabel,
            [bool]$ForceSkipGolden
        )

        $shardDir = Join-Path $StageRoot ('shard-{0:D3}' -f $EvidenceShardIndex)
        $shardCheckpointDir = if ($checkpointEnabled) {
            Join-Path $CheckpointDir ('shard-{0:D3}' -f $EvidenceShardIndex)
        }
        else {
            ''
        }
        New-Item -ItemType Directory -Force -Path $shardDir | Out-Null
        if ($checkpointEnabled) {
            New-Item -ItemType Directory -Force -Path $shardCheckpointDir | Out-Null
        }
        $shardJson = Join-Path $shardDir 'results.json'
        $stdoutPath = Join-Path $shardDir 'stdout.log'
        $stderrPath = Join-Path $shardDir 'stderr.log'
        $args = New-GodotShardArgs `
            -BaseArgs $BaseArgs `
            -ShardJsonPath $shardJson `
            -ShardCheckpointDir $shardCheckpointDir `
            -SeedBlockStart $SeedBlockStart `
            -SeedBlockCount $SeedBlockCount `
            -TaskStart $TaskStart `
            -TaskCount $TaskCount `
            -EvidenceShardIndex $EvidenceShardIndex `
            -EvidenceShardCount $LogicalShardCount `
            -SkipGolden (
                $ForceSkipGolden -or
                ($LogicalShardCount -gt 1 -and $EvidenceShardIndex -ne 0)
            )
        $process = Start-Process `
            -FilePath $godot `
            -ArgumentList $args `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -WindowStyle Hidden `
            -PassThru
        return [pscustomobject]@{
            Process = $process
            Json = $shardJson
            Stdout = $stdoutPath
            Stderr = $stderrPath
            StageLabel = $StageLabel
            EvidenceShardIndex = $EvidenceShardIndex
            EvidenceShardCount = $LogicalShardCount
            StdoutTail = New-LogTailState
            StderrTail = New-LogTailState
        }
    }

    function Write-EvidenceShardIncrementalOutput {
        param(
            [object]$Item,
            [switch]$Flush
        )
        $label = if ($LogicalShardCount -gt 1) {
            "$($Item.StageLabel) shard $($Item.EvidenceShardIndex)"
        }
        else {
            [string]$Item.StageLabel
        }
        foreach ($line in Read-NewLogLines -Path $Item.Stdout -State $Item.StdoutTail -Flush:$Flush) {
            Write-AIEvaluationOutputLine `
                -Line $line `
                -Prefix $label `
                -EnableProgress $progressEnabled
        }
        foreach ($line in Read-NewLogLines -Path $Item.Stderr -State $Item.StderrTail -Flush:$Flush) {
            $stderrLabel = if ([string]::IsNullOrWhiteSpace($label)) {
                'stderr'
            }
            else {
                "$label stderr"
            }
            Write-AIEvaluationOutputLine `
                -Line $line `
                -Prefix $stderrLabel `
                -EnableProgress $false
        }
    }

    function Invoke-EvidenceShardStage {
        param(
            [string[]]$BaseArgs,
            [string]$StageRoot,
            [string]$StageLabel,
            [bool]$ForceSkipGolden,
            [int[]]$EvidenceShards
        )

        New-Item -ItemType Directory -Force -Path $StageRoot | Out-Null
        if ($progressEnabled) {
            Reset-AIEvaluationProgress
        }
        $pendingEvidenceShards = [System.Collections.Generic.Queue[int]]::new()
        foreach ($evidenceShardIndex in $EvidenceShards) {
            $pendingEvidenceShards.Enqueue([int]$evidenceShardIndex)
        }
        $activeProcesses = [System.Collections.ArrayList]::new()
        $stageResults = [System.Collections.Generic.List[string]]::new()
        $shardFailures = [System.Collections.Generic.List[string]]::new()
        while ($pendingEvidenceShards.Count -gt 0 -or $activeProcesses.Count -gt 0) {
            while (
                $pendingEvidenceShards.Count -gt 0 -and
                $activeProcesses.Count -lt [Math]::Min($workerCount, $EvidenceShards.Count)
            ) {
                $nextEvidenceShard = $pendingEvidenceShards.Dequeue()
                [void]$activeProcesses.Add((
                    Start-EvidenceShardProcess `
                        -EvidenceShardIndex $nextEvidenceShard `
                        -BaseArgs $BaseArgs `
                        -StageRoot $StageRoot `
                        -StageLabel $StageLabel `
                        -ForceSkipGolden $ForceSkipGolden
                ))
            }

            foreach ($item in @($activeProcesses)) {
                Write-EvidenceShardIncrementalOutput -Item $item
                if (-not $item.Process.HasExited) {
                    continue
                }
                $item.Process.WaitForExit()
                Write-EvidenceShardIncrementalOutput -Item $item -Flush
                try {
                    Test-GodotShardOutput `
                        -StdoutPath $item.Stdout `
                        -StderrPath $item.Stderr `
                        -JsonPath $item.Json `
                        -ExitCode $item.Process.ExitCode `
                        -ReplayOutput $false
                    $stageResults.Add([string]$item.Json)
                }
                catch {
                    $message = (
                        "$StageLabel evidence shard $($item.EvidenceShardIndex) failed: " +
                        $_.Exception.Message
                    )
                    $shardFailures.Add($message)
                    Write-Error -Message $message -ErrorAction Continue
                    if (-not $ContinueOnStructuralFailure) {
                        foreach ($running in @($activeProcesses)) {
                            if (-not $running.Process.HasExited) {
                                Stop-Process -Id $running.Process.Id -Force -ErrorAction SilentlyContinue
                            }
                        }
                        throw $message
                    }
                }
                [void]$activeProcesses.Remove($item)
            }
            if ($activeProcesses.Count -gt 0) {
                Start-Sleep -Milliseconds 200
            }
        }
        if ($progressEnabled) {
            Write-Progress -Activity 'AI evaluation' -Completed
        }
        if ($shardFailures.Count -gt 0) {
            throw (
                "$($shardFailures.Count) $StageLabel evidence shard(s) failed. " +
                "Artifacts were preserved because ContinueOnStructuralFailure was enabled."
            )
        }
        return @($stageResults)
    }

    $evidenceStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $shardJsonPaths = @(Invoke-EvidenceShardStage `
        -BaseArgs $runnerArgs `
        -StageRoot (Join-Path $OutputDir 'shards') `
        -StageLabel 'main' `
        -ForceSkipGolden $false `
        -EvidenceShards $assignedEvidenceShards)
    $evidenceStopwatch.Stop()
    $evidenceWallClockMs = $evidenceStopwatch.Elapsed.TotalMilliseconds
}

function Test-V1CalibrationOutput {
    param(
        [string]$InputPath,
        [object]$Threshold
    )

    $payload = Get-Content -Raw -LiteralPath $InputPath | ConvertFrom-Json
    $matches = @($payload.matches)
    $simulationBudget = [int]$Threshold.config.simulation_budget
    $samples = @(
        foreach ($match in $matches) {
            foreach ($strategy in @('A', 'B')) {
                $property = $match.simulation_samples_by_strategy.PSObject.Properties[$strategy]
                if ($null -ne $property) {
                    foreach ($sample in @($property.Value)) {
                        [int]$sample
                    }
                }
            }
        }
    )
    $simulationSum = [int](($samples | Measure-Object -Sum).Sum)
    $fullBudgetDecisions = @(
        $samples | Where-Object { $_ -ge $simulationBudget }
    ).Count
    $deadlineDecisions = 0
    $cleanGames = 0
    foreach ($match in $matches) {
        $deadlineProperty = $match.dynamic_budget_stop_reasons.PSObject.Properties['deadline']
        if ($null -ne $deadlineProperty) {
            $deadlineDecisions += [int]$deadlineProperty.Value
        }
        if (
            [string]$match.terminal_reason -eq 'game_over' -and
            [int]$match.invalid_actions -eq 0 -and
            [int]$match.choice_failures -eq 0 -and
            [int]$match.rule_exceptions -eq 0 -and
            [int]$match.emergency_fallbacks -eq 0 -and
            -not [bool]$match.max_actions_exhausted
        ) {
            $cleanGames += 1
        }
    }
    $checks = [ordered]@{
        game_count = $matches.Count -eq [int]$Threshold.config.games
        clean_games = $cleanGames -ge [int]$Threshold.minimum.clean_games
        simulation_sum = $simulationSum -ge [int]$Threshold.minimum.simulation_sum
        full_budget_decisions = (
            $fullBudgetDecisions -ge [int]$Threshold.minimum.full_budget_decisions
        )
        deadline_decisions = (
            $deadlineDecisions -le [int]$Threshold.maximum.deadline_decisions
        )
    }
    $passed = -not ($checks.Values -contains $false)
    $artifact = [ordered]@{
        schema_version = 7
        protocol_id = 'traditional_ai_evaluation_v7'
        artifact_kind = 'v1_runtime_calibration'
        passed = $passed
        source = $InputPath
        observed = [ordered]@{
            games = $matches.Count
            clean_games = $cleanGames
            simulation_samples = $samples.Count
            simulation_sum = $simulationSum
            full_budget_decisions = $fullBudgetDecisions
            deadline_decisions = $deadlineDecisions
        }
        minimum = $Threshold.minimum
        maximum = $Threshold.maximum
        checks = $checks
    }
    $artifactPath = Join-Path $OutputDir 'v1_calibration.json'
    $artifact | ConvertTo-Json -Depth 12 |
        Set-Content -LiteralPath $artifactPath -Encoding UTF8
    Write-Host (
        "v1 calibration: clean=$cleanGames/$($matches.Count), " +
        "simulation_sum=$simulationSum, full_budget=$fullBudgetDecisions, " +
        "deadlines=$deadlineDecisions"
    )
    Write-Host "v1 calibration artifact: $artifactPath"
    if (-not $passed) {
        throw "Frozen v1 runtime calibration failed. See $artifactPath"
    }
}

if ($ShardOnly) {
    if ($V1CalibrationOnly) {
        if ($shardJsonPaths.Count -ne 1) {
            throw "V1 calibration expected one raw shard, found $($shardJsonPaths.Count)."
        }
        Test-V1CalibrationOutput `
            -InputPath $shardJsonPaths[0] `
            -Threshold $calibrationThreshold
        return
    }
    foreach ($path in $shardJsonPaths) {
        Write-Host "AI evaluation raw shard: $path"
    }
    Write-Host "AI evaluation provenance: $provenancePath"
    Write-Host 'AI evaluation shard-only mode: aggregation, report and validation skipped.'
    return
}

$effectivePerformanceBenchmarkPaths = @($performanceBenchmarkInputPaths)
if (-not $mergeOnly -and $PerformanceBenchmark) {
    $effectivePerformanceBenchmarkPaths += Invoke-PerformanceBenchmark
}

Invoke-AIEvaluationMerge `
    -InputPaths $shardJsonPaths `
    -PerformanceInputPaths $effectivePerformanceBenchmarkPaths `
    -OutputPath $jsonPath `
    -WorkerCount $workerCount `
    -WallClockMs $evidenceWallClockMs `
    -WallClockScope $evidenceWallClockScope

if ($mergeOnly) {
    $mergedPayload = Get-Content -Raw -LiteralPath $jsonPath | ConvertFrom-Json
    $mergedPayload.provenance | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $provenancePath -Encoding UTF8
}

$validateExit = 0
if (-not [string]::IsNullOrWhiteSpace($ValidateGate)) {
    $validateArgs = @(
        '-X', 'utf8',
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
        '-X', 'utf8',
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
foreach ($path in $effectivePerformanceBenchmarkPaths) {
    Write-Host "AI evaluation performance benchmark: $path"
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
