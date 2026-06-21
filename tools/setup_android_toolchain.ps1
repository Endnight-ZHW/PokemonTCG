[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$downloads = Join-Path $toolsRoot 'downloads'
$jdkRoot = Join-Path $toolsRoot 'jdk-17'
$sdkRoot = Join-Path $toolsRoot 'android-sdk'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
Set-PortableGodotEnvironment -ToolsRoot $toolsRoot
New-Item -ItemType Directory -Force -Path $downloads, $toolsRoot | Out-Null

$jdkZip = Join-Path $downloads 'temurin17.zip'
Get-VerifiedDownload -Uri $lock.java.url -Destination $jdkZip `
    -Sha256 $lock.java.sha256 -Force:$Force

if ($Force -or -not (Test-Path -LiteralPath (Join-Path $jdkRoot 'bin\java.exe'))) {
    $jdkTemp = Join-Path $toolsRoot 'jdk-extract'
    Assert-PathUnderRoot -Root $toolsRoot -Path $jdkTemp
    Assert-PathUnderRoot -Root $toolsRoot -Path $jdkRoot
    if (Test-Path -LiteralPath $jdkTemp) {
        Remove-Item -LiteralPath $jdkTemp -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $jdkTemp | Out-Null
    Expand-Archive -LiteralPath $jdkZip -DestinationPath $jdkTemp -Force
    $jdkSource = Get-ChildItem -LiteralPath $jdkTemp -Directory | Select-Object -First 1
    if (Test-Path -LiteralPath $jdkRoot) {
        Remove-Item -LiteralPath $jdkRoot -Recurse -Force
    }
    Move-Item -LiteralPath $jdkSource.FullName -Destination $jdkRoot
}

$commandLineZip = Join-Path $downloads 'android-commandlinetools.zip'
Get-VerifiedDownload -Uri $lock.android.command_line_tools_url `
    -Destination $commandLineZip `
    -Sha1 $lock.android.command_line_tools_sha1 `
    -Force:$Force

$sdkManager = Join-Path $sdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
if ($Force -or -not (Test-Path -LiteralPath $sdkManager)) {
    $sdkTemp = Join-Path $toolsRoot 'android-cli-extract'
    Assert-PathUnderRoot -Root $toolsRoot -Path $sdkTemp
    Assert-PathUnderRoot -Root $toolsRoot -Path $sdkRoot
    if (Test-Path -LiteralPath $sdkTemp) {
        Remove-Item -LiteralPath $sdkTemp -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $sdkTemp | Out-Null
    Expand-Archive -LiteralPath $commandLineZip -DestinationPath $sdkTemp -Force
    $latestRoot = Join-Path $sdkRoot 'cmdline-tools\latest'
    New-Item -ItemType Directory -Force -Path $latestRoot | Out-Null
    Copy-Item -Path (Join-Path $sdkTemp 'cmdline-tools\*') -Destination $latestRoot -Recurse -Force
}

$env:JAVA_HOME = $jdkRoot
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot
$env:Path = "$(Join-Path $jdkRoot 'bin');$(Join-Path $sdkRoot 'platform-tools');$env:Path"

$licenseInput = (1..30 | ForEach-Object { 'y' }) -join [Environment]::NewLine
$licenseInput | & $sdkManager --sdk_root=$sdkRoot --licenses | Out-Host
& $sdkManager --sdk_root=$sdkRoot `
    $lock.android.platform_tools `
    $lock.android.platform `
    $lock.android.build_tools `
    $lock.android.ndk

Write-Host "JAVA_HOME=$jdkRoot"
Write-Host "ANDROID_HOME=$sdkRoot"
& (Join-Path $jdkRoot 'bin\java.exe') -version
& (Join-Path $sdkRoot 'platform-tools\adb.exe') version
