[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunDir
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$paths = Get-GodotToolchainPaths -RepoRoot $repoRoot
$run = [IO.Path]::GetFullPath($RunDir)
$runtime = Join-Path $run 'release_staging\godot\data\ai_models_runtime.json'
$release = Join-Path $run 'release_staging\godot\data\release_manifest.json'
$candidate = Join-Path $run 'release-evidence.json'
$output = Join-Path $run 'evidence\windows_runtime.json'
foreach ($required in @($runtime, $release, $candidate)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "AlphaZero v2 candidate artifact is missing: $required"
    }
}
$trainingEvidence = Get-Content -LiteralPath $candidate -Raw | ConvertFrom-Json
if (
    [string]$trainingEvidence.schema -ne 'alphazero_v2_training_evidence/1' -or
    -not [bool]$trainingEvidence.accepted -or
    -not [bool]$trainingEvidence.native_core_available -or
    -not [bool]$trainingEvidence.native_core_ready
) {
    throw 'Windows candidate runtime requires accepted, production-ready training evidence.'
}

# A staged candidate is deliberately disabled until every independent release
# gate passes. Exercise it with an isolated manifest copy so this smoke test
# cannot prematurely enable the staged or live release manifest.
$temporaryRelease = Join-Path $run 'evidence\windows_candidate_release_enabled.json'
$temporaryReleasePayload = Get-Content -LiteralPath $release -Raw | ConvertFrom-Json
if (-not [bool]$temporaryReleasePayload.native_ai.production_ready) {
    throw 'Windows candidate requires a production-ready native rules kernel.'
}
$temporaryReleasePayload.deep_runtime_enabled = $true
$temporaryReleasePayload.model_count = 1
$temporaryReleasePayload.compatible_model_count = 1
$temporaryReleasePayload.legacy_model_count = 0
$temporaryDirectory = Split-Path -Parent $temporaryRelease
New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
[IO.File]::WriteAllText(
    $temporaryRelease,
    ($temporaryReleasePayload | ConvertTo-Json -Depth 100) + "`n",
    [Text.UTF8Encoding]::new($false)
)

& $paths.Console --headless --path (Join-Path $repoRoot 'godot') `
    --script 'res://tools/candidate_runtime_smoke.gd' -- `
    --runtime-manifest $runtime `
    --release-manifest $temporaryRelease `
    --candidate-manifest $candidate `
    --output $output
$candidateExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
if ($candidateExitCode -ne 0) {
    throw "Windows AlphaZero v2 candidate runtime failed with exit code $candidateExitCode"
}
$evidenceDeadline = [DateTime]::UtcNow.AddSeconds(5)
while (
    -not (Test-Path -LiteralPath $output -PathType Leaf) -and
    [DateTime]::UtcNow -lt $evidenceDeadline
) {
    Start-Sleep -Milliseconds 100
}
if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw 'Windows candidate runtime did not produce its evidence file.'
}
$payload = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
if (
    -not [bool]$payload.passed -or
    [int]$payload.model_count -ne 1 -or
    [int]$payload.route_count -ne 10 -or
    [string]$payload.platform -ne 'windows' -or
    -not [bool]$payload.search_deadline_passed -or
    -not [bool]$payload.minimum_simulations_passed -or
    -not [bool]$payload.fallback_path_passed -or
    [int]$payload.illegal_actions -ne 0 -or
    [int]$payload.timeouts -ne 0 -or
    [int]$payload.degraded -ne 0 -or
    [int]$payload.fallbacks -ne 0
) {
    throw 'Windows AlphaZero v2 candidate evidence is incomplete.'
}
Write-Host "ALPHAZERO_V2_WINDOWS_RUNTIME_OK output=$output"
