[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunId,
    [string]$RunsRoot = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$godot = (Get-GodotToolchainPaths -RepoRoot $repoRoot).Console
if ([string]::IsNullOrWhiteSpace($RunsRoot)) {
    $RunsRoot = Join-Path $repoRoot 'build\ai_training\runs'
}
$runsRootFull = [System.IO.Path]::GetFullPath($RunsRoot)
$runDir = [System.IO.Path]::GetFullPath((Join-Path $runsRootFull $RunId))
$relative = [System.IO.Path]::GetRelativePath($runsRootFull, $runDir)
if (
    [System.IO.Path]::IsPathRooted($relative) -or
    $relative -eq '..' -or
    $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)")
) {
    throw 'RunId resolves outside the configured runs root.'
}

$candidate = Join-Path $runDir 'staging\candidate_manifest.json'
$runtime = Join-Path $runDir 'staging\godot\data\ai_models_runtime.json'
$release = Join-Path $runDir 'staging\godot\data\release_manifest.json'
$output = Join-Path $runDir 'evaluation\windows_runtime.json'
foreach ($required in @($candidate, $runtime, $release)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Hybrid candidate input is missing: $required"
    }
}

& $godot `
    --headless `
    --path (Join-Path $repoRoot 'godot') `
    --script 'res://tools/candidate_runtime_smoke.gd' `
    -- `
    --candidate-manifest $candidate `
    --runtime-manifest $runtime `
    --release-manifest $release `
    --output $output
if ($LASTEXITCODE -ne 0) {
    throw "Windows candidate ONNX smoke failed with exit code $LASTEXITCODE."
}
Write-Host "HYBRID_WINDOWS_RUNTIME_OK run_id=$RunId output=$output"
