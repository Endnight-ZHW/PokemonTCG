[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$downloads = Join-Path $toolsRoot 'downloads'
$nativeRoot = Join-Path $toolsRoot 'native'
$godotCpp = Join-Path $nativeRoot 'godot-cpp'
$ortRoot = Join-Path $nativeRoot 'onnxruntime-1.26.0'
$ortWindows = Join-Path $ortRoot 'windows-x64'
$ortAndroid = Join-Path $ortRoot 'android'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
New-Item -ItemType Directory -Force -Path $downloads, $nativeRoot, $ortRoot | Out-Null

if ($Force -and (Test-Path -LiteralPath $godotCpp)) {
    Assert-PathUnderRoot -Root $toolsRoot -Path $godotCpp
    Remove-Item -LiteralPath $godotCpp -Recurse -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $godotCpp 'SConstruct'))) {
    git clone https://github.com/godotengine/godot-cpp.git $godotCpp
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to clone godot-cpp.'
    }
}
git -C $godotCpp fetch --depth 1 origin $lock.native.godot_cpp_commit
git -C $godotCpp checkout --detach $lock.native.godot_cpp_commit
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to pin godot-cpp.'
}

$windowsZip = Join-Path $downloads 'onnxruntime-win-x64-1.26.0.zip'
Get-VerifiedDownload -Uri $lock.native.onnxruntime_windows_url `
    -Destination $windowsZip `
    -Sha256 $lock.native.onnxruntime_windows_sha256 `
    -Force:$Force
if ($Force -or -not (Test-Path -LiteralPath (Join-Path $ortWindows 'lib\onnxruntime.lib'))) {
    $temp = Join-Path $nativeRoot 'onnxruntime-windows-extract'
    Assert-PathUnderRoot -Root $toolsRoot -Path $temp
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    Expand-Archive -LiteralPath $windowsZip -DestinationPath $temp -Force
    $source = Get-ChildItem -LiteralPath $temp -Directory | Select-Object -First 1
    if (Test-Path -LiteralPath $ortWindows) {
        Remove-Item -LiteralPath $ortWindows -Recurse -Force
    }
    Move-Item -LiteralPath $source.FullName -Destination $ortWindows
}

$androidAar = Join-Path $downloads 'onnxruntime-android-1.26.0.aar'
Get-VerifiedDownload -Uri $lock.native.onnxruntime_android_url `
    -Destination $androidAar `
    -Sha1 $lock.native.onnxruntime_android_sha1 `
    -Force:$Force
if ($Force -or -not (Test-Path -LiteralPath (Join-Path $ortAndroid 'jni\arm64-v8a\libonnxruntime.so'))) {
    $androidZip = Join-Path $downloads 'onnxruntime-android-1.26.0.zip'
    Copy-Item -LiteralPath $androidAar -Destination $androidZip -Force
    if (Test-Path -LiteralPath $ortAndroid) {
        Assert-PathUnderRoot -Root $toolsRoot -Path $ortAndroid
        Remove-Item -LiteralPath $ortAndroid -Recurse -Force
    }
    Expand-Archive -LiteralPath $androidZip -DestinationPath $ortAndroid -Force
}

Write-Host "godot-cpp=$godotCpp"
Write-Host "onnxruntime-windows=$ortWindows"
Write-Host "onnxruntime-android=$ortAndroid"
