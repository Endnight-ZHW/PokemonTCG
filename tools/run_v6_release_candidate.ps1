[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResearchRunId,
    [Parameter(Mandatory)]
    [string]$ReleaseRunId,
    [string]$RunsRoot = '',
    [string]$CondaEnv = 'DL',
    [int]$Workers = 0,
    [string]$DeviceSerial = '',
    [int]$AndroidTimeoutSeconds = 240,
    [switch]$SkipTraining,
    [switch]$NoProgress,
    [switch]$KeepAndroidBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($RunsRoot)) {
    $RunsRoot = Join-Path $repoRoot 'build\ai_training\runs'
}
$RunsRoot = [System.IO.Path]::GetFullPath($RunsRoot)
$researchRunDir = [System.IO.Path]::GetFullPath(
    (Join-Path $RunsRoot $ResearchRunId)
)
$releaseRunDir = [System.IO.Path]::GetFullPath(
    (Join-Path $RunsRoot $ReleaseRunId)
)
foreach ($path in @($researchRunDir, $releaseRunDir)) {
    $relative = [System.IO.Path]::GetRelativePath($RunsRoot, $path)
    if (
        [System.IO.Path]::IsPathRooted($relative) -or
        $relative -eq '..' -or
        $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)")
    ) {
        throw 'A run ID resolves outside the configured runs root.'
    }
}
if ($ResearchRunId -eq $ReleaseRunId) {
    throw 'ReleaseRunId must be a fresh run ID.'
}

$researchRunPath = Join-Path $researchRunDir 'run.json'
$researchRun = Get-Content -Raw -LiteralPath $researchRunPath | ConvertFrom-Json
$gateRelative = [string]$researchRun.candidate_stage.research_evaluation_path
if ([string]::IsNullOrWhiteSpace($gateRelative)) {
    throw 'The research10 run has no verified Godot gate evidence.'
}
$gatePath = [System.IO.Path]::GetFullPath(
    (Join-Path $researchRunDir $gateRelative)
)
$gateContainment = [System.IO.Path]::GetRelativePath(
    $researchRunDir,
    $gatePath
)
if (
    [System.IO.Path]::IsPathRooted($gateContainment) -or
    $gateContainment -eq '..' -or
    $gateContainment.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)")
) {
    throw 'The research10 gate path resolves outside its run.'
}
$gateSha = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $gatePath
).Hash.ToLowerInvariant()
$gate = Get-Content -Raw -LiteralPath $gatePath | ConvertFrom-Json
$winner = [string]$researchRun.config.model_variant
if (
    [string]$researchRun.preset -ne 'research10' -or
    [string]$researchRun.status -ne 'completed' -or
    [bool]$researchRun.promotable -or
    [string]$researchRun.candidate_stage.status -ne 'research10_verified' -or
    $gateSha -ne [string]$researchRun.candidate_stage.research_evaluation_sha256 -or
    [string]$gate.schema -ne 'deep_ai_v6_research10_gate_v1' -or
    -not [bool]$gate.valid -or
    [bool]$gate.promotable -or
    $winner -notin @('v6_pooled', 'v6_cross_attention')
) {
    throw 'The research10 evidence does not authorize a full candidate run.'
}

$releaseManifest = Join-Path $repoRoot 'release_manifest.json'
$releaseShaBefore = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $releaseManifest
).Hash.ToLowerInvariant()
$conda = (Get-Command conda.exe -ErrorAction Stop).Source
if (-not $SkipTraining) {
    & $conda @(
        'run',
        '--no-capture-output',
        '-n',
        $CondaEnv,
        'python',
        (Join-Path $repoRoot 'python\scripts\run_hybrid_population_training.py'),
        '--run-id',
        $ReleaseRunId,
        '--runs-root',
        $RunsRoot,
        '--preset',
        'release',
        '--seed',
        '17',
        '--model-variant',
        $winner
    )
    if ($LASTEXITCODE -ne 0) {
        throw "full release training failed with exit code $LASTEXITCODE."
    }
}

$releaseRunPath = Join-Path $releaseRunDir 'run.json'
$releaseRun = Get-Content -Raw -LiteralPath $releaseRunPath | ConvertFrom-Json
if (
    [string]$releaseRun.preset -ne 'release' -or
    [string]$releaseRun.status -ne 'completed' -or
    -not [bool]$releaseRun.promotable -or
    [string]$releaseRun.config.model_variant -ne $winner
) {
    throw 'The full candidate run does not match the verified research winner.'
}
$python = Join-Path $repoRoot '.tools\python311\python.exe'
& $python @(
    (Join-Path $repoRoot 'python\scripts\record_v6_stage_lineage.py'),
    '--run-dir',
    $releaseRunDir,
    '--evidence',
    $gatePath,
    '--kind',
    'research10_gate'
)
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to record the research10 evidence lineage.'
}

$verifyArgs = @{
    RunId = $ReleaseRunId
    RunsRoot = $RunsRoot
    Workers = $Workers
    AndroidTimeoutSeconds = $AndroidTimeoutSeconds
    NoProgress = $NoProgress
    KeepAndroidBuild = $KeepAndroidBuild
}
if (-not [string]::IsNullOrWhiteSpace($DeviceSerial)) {
    $verifyArgs.DeviceSerial = $DeviceSerial
}
& (Join-Path $PSScriptRoot 'verify_hybrid_candidate.ps1') @verifyArgs
if ($LASTEXITCODE -ne 0) {
    throw 'Full candidate verification failed.'
}

$releaseShaAfter = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $releaseManifest
).Hash.ToLowerInvariant()
if ($releaseShaAfter -ne $releaseShaBefore) {
    throw 'Candidate verification modified the formal release manifest.'
}
$finalRun = Get-Content -Raw -LiteralPath $releaseRunPath | ConvertFrom-Json
if (
    [string]$finalRun.status -ne 'verified_candidate' -or
    [bool]$finalRun.deep_enabled
) {
    throw 'The workflow did not stop at a disabled verified candidate.'
}
Write-Host (
    "V6_VERIFIED_CANDIDATE run_id=$ReleaseRunId variant=$winner " +
    "research10_sha256=$gateSha release_manifest_unchanged=true " +
    "deep_enabled=false"
)
