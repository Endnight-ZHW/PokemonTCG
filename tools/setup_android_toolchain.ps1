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

New-Item -ItemType Directory -Force -Path $downloads, $toolsRoot | Out-Null

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

$jdkZip = Join-Path $downloads 'temurin17.zip'
$jdkApi = 'https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse'
Get-PortableArchive -Uri $jdkApi -Destination $jdkZip

if ($Force -or -not (Test-Path -LiteralPath (Join-Path $jdkRoot 'bin\java.exe'))) {
    $jdkTemp = Join-Path $toolsRoot 'jdk-extract'
    Assert-UnderToolsRoot $jdkTemp
    Assert-UnderToolsRoot $jdkRoot
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

$studioPage = Invoke-WebRequest -Uri 'https://developer.android.com/studio'
$match = [regex]::Match(
    $studioPage.Content,
    'https://dl\.google\.com/android/repository/commandlinetools-win-[0-9]+_latest\.zip'
)
if (-not $match.Success) {
    throw 'Unable to find the current Android command-line tools download URL.'
}

$commandLineZip = Join-Path $downloads 'android-commandlinetools.zip'
Get-PortableArchive -Uri $match.Value -Destination $commandLineZip

$sdkManager = Join-Path $sdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
if ($Force -or -not (Test-Path -LiteralPath $sdkManager)) {
    $sdkTemp = Join-Path $toolsRoot 'android-cli-extract'
    Assert-UnderToolsRoot $sdkTemp
    Assert-UnderToolsRoot $sdkRoot
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
    'platform-tools' `
    'platforms;android-35' `
    'build-tools;35.0.0' `
    'ndk;28.1.13356709'

Write-Host "JAVA_HOME=$jdkRoot"
Write-Host "ANDROID_HOME=$sdkRoot"
& (Join-Path $jdkRoot 'bin\java.exe') -version
& (Join-Path $sdkRoot 'platform-tools\adb.exe') version
