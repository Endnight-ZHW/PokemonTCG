[CmdletBinding()]
param(
    [int]$WindowsSeconds = 3
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$windowsExe = Join-Path $repoRoot 'godot_client\dist\windows\PokemonTCG.exe'
$windowsConsole = Join-Path $repoRoot 'godot_client\dist\windows\PokemonTCG.console.exe'
$androidApk = Join-Path $repoRoot 'godot_client\dist\android\PokemonTCG.apk'
$sdkRoot = Join-Path $repoRoot '.tools\android-sdk'
$jdkRoot = Join-Path $repoRoot '.tools\jdk-17'
$adb = Join-Path $sdkRoot 'platform-tools\adb.exe'
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
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
    -not $aiSmokeText.Contains('provider=CPUExecutionProvider') -or
    -not $aiSmokeText.Contains('runtime=1.26.0')
) {
    throw "Exported Windows Deep AI smoke test failed.`n$aiSmokeText"
}
Write-Host 'WINDOWS_DEEP_AI_OK provider=CPUExecutionProvider runtime=1.26.0'

$networkSmoke = & $windowsConsole -- --phase5-network-smoke 2>&1
$networkSmokeText = $networkSmoke -join "`n"
if (
    $LASTEXITCODE -ne 0 -or
    -not $networkSmokeText.Contains('PHASE5_EXPORT_NETWORK_OK')
) {
    throw "Exported Windows network smoke test failed.`n$networkSmokeText"
}
Write-Host 'WINDOWS_NETWORK_OK protocol=3 transports=enet,websocket'

$jar = Join-Path $jdkRoot 'bin\jar.exe'
$apkEntries = & $jar tf $androidApk
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to list Android APK contents.'
}
foreach ($deckKey in @(
    'fire',
    'water',
    'psychic',
    'lightning',
    'fighting',
    'colorless',
    'dragon',
    'grass'
)) {
    if ("assets/data/ai_models/$deckKey.onnx" -notin $apkEntries) {
        throw "Android APK is missing the $deckKey ONNX model."
    }
}
foreach ($nativeEntry in @(
    'lib/arm64-v8a/libonnxruntime.so',
    'lib/arm64-v8a/libpokemon_ai.android.template_debug.arm64.so'
)) {
    if ($nativeEntry -notin $apkEntries) {
        throw "Android APK is missing native library: $nativeEntry"
    }
}
Write-Host 'ANDROID_AI_ASSETS_OK models=8 abi=arm64-v8a'

$deviceRows = & $adb devices
$connected = @(
    $deviceRows |
        Select-Object -Skip 1 |
        Where-Object { $_ -match "\tdevice(\s|$)" }
)
if ($connected.Count -eq 0) {
    Write-Host 'ANDROID_DEVICE_SKIPPED no connected ADB device'
    exit 0
}

& $adb install -r $androidApk
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to install Android APK on the connected device.'
}
& $adb shell am force-stop com.pokemontcg.game
& $adb shell monkey -p com.pokemontcg.game 1 | Out-Host
Start-Sleep -Seconds 3
$pidValue = (& $adb shell pidof com.pokemontcg.game).Trim()
if (-not $pidValue) {
    throw 'Android app did not stay running after launch.'
}
Write-Host "ANDROID_STARTUP_OK pid=$pidValue"
