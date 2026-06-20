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

New-Item -ItemType Directory -Force -Path $downloads, $godotRoot | Out-Null

function Assert-UnderToolsRoot {
    param([Parameter(Mandatory)] [string]$Path)
    $resolvedTools = [System.IO.Path]::GetFullPath($toolsRoot)
    $resolvedTarget = [System.IO.Path]::GetFullPath($Path)
    if (-not $resolvedTarget.StartsWith($resolvedTools, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing filesystem operation outside tools root: $resolvedTarget"
    }
}

function Get-PortableArchive {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$Destination
    )
    if ($Force -or -not (Test-Path -LiteralPath $Destination)) {
        Write-Host "Downloading $Uri"
        Invoke-WebRequest -Uri $Uri -OutFile $Destination
    }
}

$godotZip = Join-Path $downloads 'Godot_v4.7-stable_win64.exe.zip'
Get-PortableArchive `
    -Uri 'https://godot-releases.nbg1.your-objectstorage.com/4.7-stable/Godot_v4.7-stable_win64.exe.zip' `
    -Destination $godotZip

if ($Force -or -not (Test-Path -LiteralPath $godotExe)) {
    Expand-Archive -LiteralPath $godotZip -DestinationPath $godotRoot -Force
}

$templateArchive = Join-Path $downloads 'Godot_v4.7-stable_export_templates.tpz'
Get-PortableArchive `
    -Uri 'https://godot-releases.nbg1.your-objectstorage.com/4.7-stable/Godot_v4.7-stable_export_templates.tpz' `
    -Destination $templateArchive

$templateRoot = Join-Path $env:APPDATA 'Godot\export_templates\4.7.stable'
if ($Force -or -not (Test-Path -LiteralPath (Join-Path $templateRoot 'version.txt'))) {
    $templateTemp = Join-Path $toolsRoot 'template-extract'
    Assert-UnderToolsRoot $templateTemp
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
