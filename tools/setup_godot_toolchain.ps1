[CmdletBinding()]
param(
    [switch]$IncludeAndroid,
    [switch]$SkipExportTemplates,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$downloads = Join-Path $toolsRoot 'downloads'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
$godotPaths = Get-GodotToolchainPaths -RepoRoot $repoRoot
$godotRoot = $godotPaths.Root
$godotExe = $godotPaths.Editor
$godotConsole = $godotPaths.Console
Set-PortableGodotEnvironment -ToolsRoot $toolsRoot
New-Item -ItemType Directory -Force -Path $downloads, $godotRoot | Out-Null

$godotZip = Join-Path $downloads "Godot_v$($lock.godot.version)_win64.exe.zip"
Get-VerifiedDownload -Uri $lock.godot.editor_url -Destination $godotZip `
    -Sha256 $lock.godot.editor_sha256 -Force:$Force

if ($Force -or -not (Test-Path -LiteralPath $godotExe)) {
    Expand-Archive -LiteralPath $godotZip -DestinationPath $godotRoot -Force
}

if ($IncludeAndroid -and $SkipExportTemplates) {
    throw 'Android setup requires Godot export templates.'
}
if (-not $SkipExportTemplates) {
    $templateArchive = Join-Path $downloads (
        "Godot_v$($lock.godot.version)_export_templates.tpz"
    )
    Get-VerifiedDownload -Uri $lock.godot.templates_url -Destination $templateArchive `
        -Sha256 $lock.godot.templates_sha256 -Force:$Force

    $templateRoot = $godotPaths.TemplateRoot
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
}

if ($IncludeAndroid) {
    & (Join-Path $PSScriptRoot 'setup_android_toolchain.ps1') -Force:$Force
}

Write-Host "Godot: $godotExe"
& $godotConsole --version
