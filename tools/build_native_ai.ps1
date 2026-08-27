[CmdletBinding()]
param(
    [ValidateSet('windows', 'android', 'all')]
    [string]$Target = 'all',
    [ValidateSet('debug', 'release', 'all')]
    [string]$Configuration = 'all',
    [ValidateRange(1, 64)]
    [int]$Jobs = 4,
    [string]$Python = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$portablePython = Join-Path $toolsRoot 'python311\python.exe'
if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = if (Test-Path -LiteralPath $portablePython) {
        $portablePython
    } else {
        'python'
    }
}
$sourceRoot = Join-Path $repoRoot 'godot\native\bindings'
$projectRoot = Join-Path $repoRoot 'godot'
$godotCpp = Join-Path $toolsRoot 'native\godot-cpp'
$sdkRoot = Join-Path $toolsRoot 'android-sdk'
$ndkRoot = Join-Path $sdkRoot 'ndk\28.1.13356709'
$env:PYTHONNOUSERSITE = '1'

if (-not (Test-Path -LiteralPath (Join-Path $godotCpp 'SConstruct'))) {
    throw 'godot-cpp is missing. Run setup_native_ai_deps.ps1 first.'
}
& $Python -c 'import SCons' 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'SCons is missing from the selected Python interpreter.'
}

$configs = if ($Configuration -eq 'all') {
    @('debug', 'release')
} else {
    @($Configuration)
}
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
        $godotTarget = if ($config -eq 'release') {
            'template_release'
        } else {
            'template_debug'
        }
        $arguments = @(
            '-m', 'SCons',
            "-j$Jobs",
            "--directory=$sourceRoot",
            "godot_cpp_dir=$godotCpp",
            "project_root=$projectRoot",
            "platform=$platform",
            "target=$godotTarget",
            'arch=arm64'
        )
        if ($platform -eq 'windows') {
            if (-not (Test-Path -LiteralPath $vsDevCmd)) {
                throw 'Visual C++ Build Tools are missing.'
            }
            $arguments[-1] = 'arch=x86_64'
            $quoted = $arguments | ForEach-Object {
                if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
            }
            $command = (
                "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && " +
                "`"$Python`" $($quoted -join ' ')"
            )
            & cmd.exe /d /s /c $command
        } else {
            if (-not (Test-Path -LiteralPath $ndkRoot)) {
                throw 'Android NDK 28.1 is missing.'
            }
            $arguments += 'android_api_level=28'
            $arguments += "ANDROID_HOME=$sdkRoot"
            $env:ANDROID_HOME = $sdkRoot
            $env:ANDROID_SDK_ROOT = $sdkRoot
            $env:ANDROID_NDK_ROOT = $ndkRoot
            & $Python @arguments
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Native runtime build failed for $platform $config."
        }
    }
}

Write-Host 'NATIVE_RUNTIME_BUILD_OK'
