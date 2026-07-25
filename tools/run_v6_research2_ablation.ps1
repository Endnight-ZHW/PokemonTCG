[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PooledRunId,
    [Parameter(Mandatory)]
    [string]$CrossRunId,
    [string]$RunsRoot = '',
    [string]$Output = '',
    [string]$CondaEnv = 'DL',
    [int]$Workers = 4,
    [switch]$SkipTraining
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($RunsRoot)) {
    $RunsRoot = Join-Path $repoRoot 'build\ai_training\runs'
}
$runsRoot = [System.IO.Path]::GetFullPath($RunsRoot)
if ([string]::IsNullOrWhiteSpace($Output)) {
    $evidenceRoot = Join-Path $repoRoot 'build\ai_training\research_evidence'
    $Output = Join-Path $evidenceRoot (
        "v6_ablation_${PooledRunId}_vs_${CrossRunId}.json"
    )
}
$Output = [System.IO.Path]::GetFullPath($Output)
$pooledRun = [System.IO.Path]::GetFullPath(
    (Join-Path $runsRoot $PooledRunId)
)
$crossRun = [System.IO.Path]::GetFullPath(
    (Join-Path $runsRoot $CrossRunId)
)
foreach ($row in @(
    @{ Id = $PooledRunId; Path = $pooledRun },
    @{ Id = $CrossRunId; Path = $crossRun }
)) {
    $relative = [System.IO.Path]::GetRelativePath($runsRoot, $row.Path)
    if (
        [System.IO.Path]::IsPathRooted($relative) -or
        $relative -eq '..' -or
        $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)")
    ) {
        throw "RunId resolves outside the configured runs root: $($row.Id)"
    }
}
if ($PooledRunId -eq $CrossRunId) {
    throw 'PooledRunId and CrossRunId must be different.'
}
if ($Workers -lt 1) {
    throw 'Workers must be >= 1.'
}

$releaseManifest = Join-Path $repoRoot 'release_manifest.json'
$releaseShaBefore = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $releaseManifest
).Hash.ToLowerInvariant()
$conda = (Get-Command conda.exe -ErrorAction Stop).Source
$trainer = Join-Path $repoRoot 'python\scripts\run_hybrid_population_training.py'
if (-not $SkipTraining) {
    foreach ($spec in @(
        @{ Id = $PooledRunId; Variant = 'v6_pooled' },
        @{ Id = $CrossRunId; Variant = 'v6_cross_attention' }
    )) {
        & $conda @(
            'run',
            '--no-capture-output',
            '-n',
            $CondaEnv,
            'python',
            $trainer,
            '--run-id',
            $spec.Id,
            '--runs-root',
            $runsRoot,
            '--preset',
            'research2',
            '--seed',
            '17',
            '--model-variant',
            $spec.Variant
        )
        if ($LASTEXITCODE -ne 0) {
            throw (
                "$($spec.Variant) research2 training failed with " +
                "exit code $LASTEXITCODE."
            )
        }
    }
}

foreach ($spec in @(
    @{ Path = $pooledRun; Variant = 'v6_pooled' },
    @{ Path = $crossRun; Variant = 'v6_cross_attention' }
)) {
    $runPath = Join-Path $spec.Path 'run.json'
    if (-not (Test-Path -LiteralPath $runPath -PathType Leaf)) {
        throw "research2 run metadata is missing: $runPath"
    }
    $run = Get-Content -Raw -LiteralPath $runPath | ConvertFrom-Json
    if (
        [string]$run.preset -ne 'research2' -or
        [string]$run.status -ne 'completed' -or
        [bool]$run.promotable -or
        [int]$run.config.seed -ne 17 -or
        [string]$run.config.model_variant -ne $spec.Variant
    ) {
        throw "Invalid completed research2 run: $($spec.Path)"
    }
}

$outputParent = Split-Path -Parent $Output
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
}
& $conda @(
    'run',
    '--no-capture-output',
    '-n',
    $CondaEnv,
    'python',
    (Join-Path $repoRoot 'python\scripts\evaluate_v6_ablation.py'),
    '--pooled-run',
    $pooledRun,
    '--cross-run',
    $crossRun,
    '--output',
    $Output,
    '--seed',
    '17',
    '--workers',
    [string]$Workers,
    '--mirror-blocks',
    '50',
    '--cross-blocks',
    '20'
)
if ($LASTEXITCODE -ne 0) {
    throw (
        "v6 ablation failed or both variants were unreliable; " +
        "evidence was preserved at $Output"
    )
}

$report = Get-Content -Raw -LiteralPath $Output | ConvertFrom-Json
if (
    [string]$report.schema -ne 'deep_ai_v6_ablation_v1' -or
    [int]$report.schedule.games -ne 280 -or
    [bool]$report.promotable -or
    [string]$report.winner -notin @(
        'v6_pooled',
        'v6_cross_attention'
    )
) {
    throw 'The v6 ablation did not produce a valid research-only winner.'
}
$releaseShaAfter = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $releaseManifest
).Hash.ToLowerInvariant()
if ($releaseShaAfter -ne $releaseShaBefore) {
    throw 'The research2 workflow modified the formal release manifest.'
}
$evidenceSha = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $Output
).Hash.ToLowerInvariant()
Write-Host (
    "V6_ABLATION_WINNER variant=$($report.winner) " +
    "evidence_sha256=$evidenceSha promotable=false path=$Output"
)
