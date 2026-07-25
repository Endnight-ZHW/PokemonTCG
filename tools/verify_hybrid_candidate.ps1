[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunId,
    [string]$RunsRoot = '',
    [int]$Workers = 0,
    [string]$DeviceSerial = '',
    [int]$AndroidTimeoutSeconds = 240,
    [switch]$NoProgress,
    [switch]$KeepAndroidBuild
)

$ErrorActionPreference = 'Stop'
$common = @{
    RunId = $RunId
}
if (-not [string]::IsNullOrWhiteSpace($RunsRoot)) {
    $common.RunsRoot = $RunsRoot
}

& (Join-Path $PSScriptRoot 'evaluate_hybrid_candidate.ps1') `
    @common `
    -Workers $Workers `
    -NoProgress:$NoProgress
if ($LASTEXITCODE -ne 0) {
    throw 'Authoritative 2800-game Godot evaluation failed.'
}

& (Join-Path $PSScriptRoot 'test_hybrid_candidate_windows.ps1') @common
if ($LASTEXITCODE -ne 0) {
    throw 'Windows candidate load/infer verification failed.'
}

$android = @{
    RunId = $RunId
    TimeoutSeconds = $AndroidTimeoutSeconds
    KeepBuild = $KeepAndroidBuild
}
if (-not [string]::IsNullOrWhiteSpace($RunsRoot)) {
    $android.RunsRoot = $RunsRoot
}
if (-not [string]::IsNullOrWhiteSpace($DeviceSerial)) {
    $android.DeviceSerial = $DeviceSerial
}
& (Join-Path $PSScriptRoot 'test_hybrid_candidate_android.ps1') @android
if ($LASTEXITCODE -ne 0) {
    throw 'ARM64 Android candidate load/infer verification failed.'
}

& (Join-Path $PSScriptRoot 'finalize_hybrid_candidate.ps1') @common
if ($LASTEXITCODE -ne 0) {
    throw 'Candidate evidence finalization failed.'
}

Write-Host (
    "HYBRID_VERIFIED_CANDIDATE run_id=$RunId " +
    "release_manifest_unchanged=true deep_enabled=false"
)
