[CmdletBinding()]
param(
    [switch]$IncludeAndroid,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$downloads = Join-Path $toolsRoot 'downloads'
$godotRoot = Join-Path $toolsRoot 'godot-4.7'
$godotExe = Join-Path $godotRoot 'Godot_v4.7-stable_win64.exe'
$godotConsole = Join-Path $godotRoot 'Godot_v4.7-stable_win64_console.exe'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
Set-PortableGodotEnvironment -ToolsRoot $toolsRoot
New-Item -ItemType Directory -Force -Path $downloads, $godotRoot | Out-Null

$godotZip = Join-Path $downloads 'Godot_v4.7-stable_win64.exe.zip'
Get-VerifiedDownload -Uri $lock.godot.editor_url -Destination $godotZip `
    -Sha256 $lock.godot.editor_sha256 -Force:$Force

if ($Force -or -not (Test-Path -LiteralPath $godotExe)) {
    Expand-Archive -LiteralPath $godotZip -DestinationPath $godotRoot -Force
}

$templateArchive = Join-Path $downloads 'Godot_v4.7-stable_export_templates.tpz'
Get-VerifiedDownload -Uri $lock.godot.templates_url -Destination $templateArchive `
    -Sha256 $lock.godot.templates_sha256 -Force:$Force

$templateRoot = Join-Path $env:APPDATA 'Godot\export_templates\4.7.stable'
if ($Force -or -not (Test-Path -LiteralPath (Join-Path $templateRoot 'version.txt'))) {
    $templateTemp = Join-Path $toolsRoot 'template-extract'
    Assert-PathUnderRoot -Root $toolsRoot -Path $templateTemp
    if (Test-Path -LiteralPath $templateTemp) {
        Remove-Item -LiteralPath $templateTemp -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $templateTemp, $templateRoot | Out-Null
    Expand-Archive -LiteralPath $templateArchive -DestinationPath $templateTemp -Force
    $source = Join-Path $templateTemp 'templates'
    Copy-Item -Path (Join-Path $source '*') -Destination $templateRoot -Recurse -Force
}

if ($IncludeAndroid) {
    & (Join-Path $PSScriptRoot 'setup_android_toolchain.ps1') -Force:$Force
}

Write-Host "Godot: $godotExe"
& $godotConsole --version
