[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('lint', 'status', 'test', 'export', 'check')]
    [string]$Command = 'lint',
    [string]$CardId = '',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path $repoRoot 'godot'
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$godotPaths = Get-GodotToolchainPaths -RepoRoot $repoRoot
$godot = $godotPaths.Console
Set-PortableGodotEnvironment -ToolsRoot (Join-Path $repoRoot '.tools')
if (-not (Test-Path -LiteralPath $godot -PathType Leaf)) {
    throw 'Godot is missing. Run tools/setup_godot_toolchain.ps1 first.'
}
$arguments = @(
    '--headless',
    '--path', $projectRoot,
    '--script', 'res://tools/content_cli.gd',
    '--',
    $Command
)
if (-not [string]::IsNullOrWhiteSpace($CardId)) {
    $arguments += @('--card-id', $CardId)
}
if ($Json) { $arguments += '--json' }
if ($Json -and $Command -eq 'status') {
    $output = @(& $godot @arguments 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        $output | ForEach-Object { Write-Host $_ }
        throw "Content $Command failed with exit code $exitCode."
    }
    $jsonLine = @($output | Where-Object { ([string]$_).TrimStart().StartsWith('{') }) |
        Select-Object -Last 1
    if ($null -eq $jsonLine) { throw 'Content status did not emit JSON.' }
    Write-Output ([string]$jsonLine)
} else {
    & $godot @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Content $Command failed with exit code $LASTEXITCODE."
    }
}
