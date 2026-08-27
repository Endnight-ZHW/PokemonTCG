[CmdletBinding()]
param(
    [int]$WindowsSeconds = 3,
    [switch]$RequireAndroidDevice,
    [switch]$AllowAndroidCleanInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$windowsExe = Join-Path $repoRoot 'godot\dist\windows\PokemonTCG.exe'
$windowsConsole = Join-Path $repoRoot 'godot\dist\windows\PokemonTCG.console.exe'
$androidApk = Join-Path $repoRoot 'godot\dist\android\PokemonTCG.apk'
$androidSmokeApk = Join-Path $repoRoot 'godot\dist\android\PokemonTCG-smoke.apk'
$sdkRoot = Join-Path $repoRoot '.tools\android-sdk'
$jdkRoot = Join-Path $repoRoot '.tools\jdk-17'
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
$release = Get-ReleaseManifest -RepoRoot $repoRoot
Assert-ProductReleaseContract -Manifest $release
$buildToolsVersion = ($lock.android.build_tools -split ';')[-1]
$aapt = Join-Path $sdkRoot "build-tools\$buildToolsVersion\aapt.exe"
$jar = Join-Path $jdkRoot 'bin\jar.exe'
Set-PortableGodotEnvironment -ToolsRoot (Join-Path $repoRoot '.tools')

foreach ($required in @($windowsExe, $windowsConsole, $androidApk, $androidSmokeApk, $aapt, $jar)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Smoke-test input is missing: $required"
    }
}

$process = Start-Process -FilePath $windowsExe -PassThru -WindowStyle Hidden
try {
    Start-Sleep -Seconds $WindowsSeconds
    if ($process.HasExited) {
        throw "Windows export exited during startup smoke test (exit $($process.ExitCode))."
    }
    Write-Host 'WINDOWS_STARTUP_OK'
} finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
}

$badging = & $aapt dump badging $androidApk
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect Android APK.' }
$badgingText = $badging -join "`n"
foreach ($expected in @(
    "package: name='com.pokemontcg.game'",
    "versionCode='$([int]$release.android_version_code)'",
    "versionName='$([string]$release.version)'",
    "sdkVersion:'28'",
    "targetSdkVersion:'35'",
    "native-code: 'arm64-v8a'"
)) {
    if (-not $badgingText.Contains($expected)) {
        throw "Android APK metadata mismatch: $expected"
    }
}
Write-Host 'ANDROID_APK_METADATA_OK'

$nativeSmoke = & $windowsConsole -- --phase4-ai-smoke 2>&1
$nativeSmokeText = $nativeSmoke -join "`n"
if (
    $LASTEXITCODE -ne 0 -or
    -not $nativeSmokeText.Contains('PHASE4_EXPORT_AI_OK') -or
    -not $nativeSmokeText.Contains('challenge=native') -or
    -not $nativeSmokeText.Contains('onnx_assets=0')
) {
    throw "Exported Windows native runtime smoke failed.`n$nativeSmokeText"
}
Write-Host 'WINDOWS_NATIVE_RUNTIME_OK challenge=native onnx_assets=0'

$networkSmoke = & $windowsConsole -- --phase5-network-smoke 2>&1
$networkSmokeText = $networkSmoke -join "`n"
if ($LASTEXITCODE -ne 0 -or -not $networkSmokeText.Contains('PHASE6_EXPORT_NETWORK_OK')) {
    throw "Exported Windows network smoke failed.`n$networkSmokeText"
}
Write-Host 'WINDOWS_NETWORK_OK protocol=6 transports=enet,websocket'

$releaseSmoke = & $windowsConsole -- --phase6-release-smoke 2>&1
$releaseSmokeText = $releaseSmoke -join "`n"
if (
    $LASTEXITCODE -ne 0 -or
    -not $releaseSmokeText.Contains('PHASE6_EXPORT_RELEASE_OK') -or
    -not $releaseSmokeText.Contains("version=$([string]$release.version)") -or
    -not $releaseSmokeText.Contains('challenge=native') -or
    -not $releaseSmokeText.Contains('onnx_assets=0')
) {
    throw "Exported Windows release smoke failed.`n$releaseSmokeText"
}
Write-Host 'WINDOWS_RELEASE_CONTRACT_OK'

$apkEntries = @(& $jar tf $androidApk)
if ($LASTEXITCODE -ne 0) { throw 'Unable to list Android APK contents.' }
$nativeEntry = 'lib/arm64-v8a/libpokemon_ai.android.template_debug.arm64.so'
if ($nativeEntry -notin $apkEntries) {
    throw "Android APK is missing native library: $nativeEntry"
}
$forbiddenEntries = @(
    $apkEntries | Where-Object {
        $_ -match '(?i)(\.onnx$|onnxruntime|(^|/)(research|deep_ai)(/|$))'
    }
)
if ($forbiddenEntries.Count -ne 0) {
    throw "Android APK contains forbidden research/runtime content: $($forbiddenEntries[0])"
}
Write-Host 'ANDROID_PRODUCT_PAYLOAD_OK abi=arm64-v8a onnx_assets=0'

& (Join-Path $PSScriptRoot 'test_android_runtime.ps1') `
    -ApkPath $androidApk -SmokeApkPath $androidSmokeApk `
    -RequireDevice:$RequireAndroidDevice `
    -AllowAndroidCleanInstall:$AllowAndroidCleanInstall
if ($LASTEXITCODE -ne 0) { throw 'Android runtime smoke failed.' }
