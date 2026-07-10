[CmdletBinding()]
param(
    [switch]$RequireDeepRuntime
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
$godot = (Get-GodotToolchainPaths -RepoRoot $repoRoot).Console
Set-PortableGodotEnvironment -ToolsRoot $toolsRoot
if (-not (Test-Path -LiteralPath $godot)) {
    throw "Godot $($lock.godot.version) is not installed."
}

function Invoke-GodotCapture {
    param([string[]]$ArgumentList)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $godot @ArgumentList 2>&1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

$ignoredGodotErrorPattern = 'Failed to read the root certificate store\.'
$fatalGodotErrorPattern = "(?m)^(SCRIPT ERROR|ERROR): (?!$ignoredGodotErrorPattern)"

$output = Invoke-GodotCapture -ArgumentList @(
    '--headless',
    '--path', (Join-Path $repoRoot 'godot'),
    '--script', 'res://tests/ai_regression.gd'
)
$output | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    throw "Godot AI regression failed with exit code $LASTEXITCODE"
}
$joined = $output -join "`n"
if ($joined -match $fatalGodotErrorPattern) {
    throw 'Godot emitted errors during AI regression.'
}
if ($joined -notmatch 'AI_REGRESSION_OK') {
    throw 'Godot AI regression success marker was not emitted.'
}
if ($RequireDeepRuntime) {
    $marker = @($output | Where-Object { [string]$_ -match '^AI_REGRESSION_OK\s+\{' }) | Select-Object -Last 1
    if (-not $marker) {
        throw 'Godot AI regression did not emit a parseable summary.'
    }
    try {
        $summaryJson = ([string]$marker).Substring(([string]$marker).IndexOf('{'))
        $summary = $summaryJson | ConvertFrom-Json
    } catch {
        throw 'Godot AI regression summary JSON is invalid.'
    }
    $deepGames = @($summary.games | Where-Object { $_.mode -eq 'deep' })
    if ($deepGames.Count -eq 0) {
        throw 'Godot AI regression did not run any Deep AI game.'
    }
    $badDeepGames = @($deepGames | Where-Object { $_.skipped -eq $true -or $_.success -ne $true })
    if ($badDeepGames.Count -gt 0) {
        throw 'Godot Deep AI runtime was skipped or failed during required release validation.'
    }
}
