[CmdletBinding()]
param(
    [ValidateSet('windows', 'android', 'all')]
    [string]$Target = 'all',
    [ValidateSet('debug', 'release', 'all')]
    [string]$Configuration = 'all'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$python = Join-Path $toolsRoot 'python311\python.exe'
$sourceRoot = Join-Path $repoRoot 'godot\native\onnx_ai'
$projectRoot = Join-Path $repoRoot 'godot'
$godotCpp = Join-Path $toolsRoot 'native\godot-cpp'
$ortRoot = Join-Path $toolsRoot 'native\onnxruntime-1.26.0'
$sdkRoot = Join-Path $toolsRoot 'android-sdk'
$ndkRoot = Join-Path $toolsRoot 'android-sdk\ndk\28.1.13356709'
$env:PYTHONNOUSERSITE = '1'

if (-not (Test-Path -LiteralPath $python)) {
    throw 'AI Python toolchain is missing.'
}
if (-not (Test-Path -LiteralPath (Join-Path $godotCpp 'SConstruct'))) {
    throw 'godot-cpp is missing.'
}

$configs = if ($Configuration -eq 'all') { @('debug', 'release') } else { @($Configuration) }
$targets = if ($Target -eq 'all') { @('windows', 'android') } else { @($Target) }
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = if (Test-Path -LiteralPath $vswhere) {
    & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
}
$vsDevCmd = if ($vsPath) { Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat' } else { '' }

foreach ($platform in $targets) {
    foreach ($config in $configs) {
        $godotTarget = if ($config -eq 'release') { 'template_release' } else { 'template_debug' }
        $common = @(
            '-m', 'SCons',
            "--directory=$sourceRoot",
            "godot_cpp_dir=$godotCpp",
            "ort_root=$ortRoot",
            "project_root=$projectRoot",
            "platform=$platform",
            "target=$godotTarget",
            'arch=arm64'
        )
        if ($platform -eq 'windows') {
            if (-not (Test-Path -LiteralPath $vsDevCmd)) {
                throw 'Visual C++ Build Tools are missing.'
            }
            $common[-1] = 'arch=x86_64'
            $quotedArgs = $common | ForEach-Object {
                if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
            }
            $command = "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && `"$python`" $($quotedArgs -join ' ')"
            & cmd.exe /d /s /c $command
        }
        else {
            if (-not (Test-Path -LiteralPath $ndkRoot)) {
                throw 'Android NDK 28.1 is missing.'
            }
            $common += 'android_api_level=28'
            $common += "ANDROID_HOME=$sdkRoot"
            $env:ANDROID_HOME = $sdkRoot
            $env:ANDROID_SDK_ROOT = $sdkRoot
            $env:ANDROID_NDK_ROOT = $ndkRoot
            & $python @common
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Native AI build failed for $platform $config."
        }
    }
}

$windowsBin = Join-Path $projectRoot 'bin\windows'
$androidBin = Join-Path $projectRoot 'bin\android'
$noticeRoot = Join-Path $projectRoot 'third_party\onnxruntime'
New-Item -ItemType Directory -Force -Path $windowsBin, $androidBin, $noticeRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $ortRoot 'windows-x64\lib\onnxruntime.dll') `
    -Destination (Join-Path $windowsBin 'onnxruntime.dll') -Force
Copy-Item -LiteralPath (Join-Path $ortRoot 'android\jni\arm64-v8a\libonnxruntime.so') `
    -Destination (Join-Path $androidBin 'libonnxruntime.so') -Force
Copy-Item -LiteralPath (Join-Path $ortRoot 'windows-x64\LICENSE') `
    -Destination (Join-Path $noticeRoot 'LICENSE') -Force
Copy-Item -LiteralPath (Join-Path $ortRoot 'windows-x64\ThirdPartyNotices.txt') `
    -Destination (Join-Path $noticeRoot 'ThirdPartyNotices.txt') -Force
