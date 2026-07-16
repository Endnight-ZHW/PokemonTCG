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
Assert-ReleaseDeepFallbackContract -Manifest $release
$compatibleModelCount = [int]$release.compatible_model_count
$legacyModelCount = [int]$release.legacy_model_count
$buildToolsVersion = ($lock.android.build_tools -split ';')[-1]
$aapt = Join-Path $sdkRoot "build-tools\$buildToolsVersion\aapt.exe"
Set-PortableGodotEnvironment -ToolsRoot (Join-Path $repoRoot '.tools')

if (-not (Test-Path -LiteralPath $windowsExe)) {
    throw 'Windows export is missing.'
}
if (-not (Test-Path -LiteralPath $androidApk)) {
    throw 'Android export is missing.'
}

$process = Start-Process `
    -FilePath $windowsExe `
    -PassThru `
    -WindowStyle Hidden
try {
    Start-Sleep -Seconds $WindowsSeconds
    if ($process.HasExited) {
        throw "Windows export exited during startup smoke test (exit $($process.ExitCode))."
    }
    Write-Host 'WINDOWS_STARTUP_OK'
}
finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
}

$badging = & $aapt dump badging $androidApk
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect Android APK.'
}
$badgingText = $badging -join "`n"
foreach ($expected in @(
    "package: name='com.pokemontcg.game'",
    "sdkVersion:'28'",
    "targetSdkVersion:'35'",
    "native-code: 'arm64-v8a'"
)) {
    if (-not $badgingText.Contains($expected)) {
        throw "Android APK metadata mismatch: $expected"
    }
}
Write-Host 'ANDROID_APK_METADATA_OK'

if (-not (Test-Path -LiteralPath $windowsConsole)) {
    throw 'Windows console export is missing.'
}
$aiSmoke = & $windowsConsole -- --phase4-ai-smoke 2>&1
$aiSmokeText = $aiSmoke -join "`n"
if (
    $LASTEXITCODE -ne 0 -or
    -not $aiSmokeText.Contains('PHASE4_EXPORT_AI_OK') -or
    -not $aiSmokeText.Contains('deep=disabled') -or
    -not $aiSmokeText.Contains('fallback=challenge') -or
    -not $aiSmokeText.Contains('onnx_assets=0')
) {
    throw "Exported Windows AI fallback smoke test failed.`n$aiSmokeText"
}
Write-Host 'WINDOWS_AI_FALLBACK_OK deep=disabled fallback=challenge onnx_assets=0'

$networkSmoke = & $windowsConsole -- --phase5-network-smoke 2>&1
$networkSmokeText = $networkSmoke -join "`n"
if (
    $LASTEXITCODE -ne 0 -or
    -not $networkSmokeText.Contains('PHASE5_EXPORT_NETWORK_OK')
) {
    throw "Exported Windows network smoke test failed.`n$networkSmokeText"
}
Write-Host 'WINDOWS_NETWORK_OK protocol=4 transports=enet,websocket'

$releaseSmoke = & $windowsConsole -- --phase6-release-smoke 2>&1
$releaseSmokeText = $releaseSmoke -join "`n"
if (
    $LASTEXITCODE -ne 0 -or
    -not $releaseSmokeText.Contains('PHASE6_EXPORT_RELEASE_OK') -or
    -not $releaseSmokeText.Contains("compatible_models=$compatibleModelCount") -or
    -not $releaseSmokeText.Contains("legacy_models=$legacyModelCount") -or
    -not $releaseSmokeText.Contains('onnx_assets=0')
) {
    throw "Exported Windows release model smoke test failed.`n$releaseSmokeText"
}
Write-Host "WINDOWS_RELEASE_AI_OK compatible_models=$compatibleModelCount legacy_models=$legacyModelCount onnx_assets=0"

$jar = Join-Path $jdkRoot 'bin\jar.exe'
$apkEntries = & $jar tf $androidApk
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to list Android APK contents.'
}
foreach ($nativeEntry in @(
    'lib/arm64-v8a/libonnxruntime.so',
    'lib/arm64-v8a/libpokemon_ai.android.template_debug.arm64.so'
)) {
    if ($nativeEntry -notin $apkEntries) {
        throw "Android APK is missing native library: $nativeEntry"
    }
}
$actualApkModels = @(
    $apkEntries |
        Where-Object { $_ -match '^assets/data/ai_models/[^/]+\.onnx$' } |
        ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) } |
        Sort-Object
)
if ($actualApkModels.Count -ne $compatibleModelCount) {
    throw "Android APK contains $($actualApkModels.Count) models; expected $compatibleModelCount."
}
Write-Host "ANDROID_AI_ASSETS_OK compatible_models=$compatibleModelCount abi=arm64-v8a"

& (Join-Path $PSScriptRoot 'test_android_runtime.ps1') `
    -ApkPath $androidApk `
    -SmokeApkPath $androidSmokeApk `
    -ExpectedModels $compatibleModelCount `
    -RequireDevice:$RequireAndroidDevice `
    -AllowCleanInstall:$AllowAndroidCleanInstall
if ($LASTEXITCODE -ne 0) {
    throw 'Android runtime smoke failed.'
}
