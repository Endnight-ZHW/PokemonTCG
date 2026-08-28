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
$classCache = Join-Path $projectRoot '.godot\global_script_class_cache.cfg'
$extensionList = Join-Path $projectRoot '.godot\extension_list.cfg'
$requiresImport = (
    -not (Test-Path -LiteralPath $classCache -PathType Leaf) -or
    -not (Test-Path -LiteralPath $extensionList -PathType Leaf)
)
if (-not $requiresImport) {
    $cacheTime = (Get-Item -LiteralPath $classCache).LastWriteTimeUtc
    $latestClassSource = Get-ChildItem -LiteralPath $projectRoot `
        -Recurse `
        -File `
        -Filter '*.gd' |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    $projectTime = (Get-Item -LiteralPath (
        Join-Path $projectRoot 'project.godot'
    )).LastWriteTimeUtc
    $requiresImport = (
        ($null -ne $latestClassSource -and
            $latestClassSource.LastWriteTimeUtc -gt $cacheTime) -or
        $projectTime -gt $cacheTime
    )
}
if ($requiresImport) {
    $importOutput = @(& $godot `
        --headless `
        --path $projectRoot `
        --import 2>&1)
    $importOutput | ForEach-Object { Write-Host $_ }
    $importExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    $joinedImportOutput = $importOutput -join "`n"
    if (
        $importExitCode -ne 0 -or
        $joinedImportOutput -match '(?m)^(SCRIPT ERROR|ERROR):'
    ) {
        throw 'Godot project cache bootstrap failed.'
    }
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
