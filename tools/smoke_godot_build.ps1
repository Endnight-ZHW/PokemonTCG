[CmdletBinding()]
param(
    [int]$WindowsSeconds = 3
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$windowsExe = Join-Path $repoRoot 'godot_client\dist\windows\PokemonTCG.exe'
$androidApk = Join-Path $repoRoot 'godot_client\dist\android\PokemonTCG.apk'
$sdkRoot = Join-Path $repoRoot '.tools\android-sdk'
$adb = Join-Path $sdkRoot 'platform-tools\adb.exe'
$aapt = Join-Path $sdkRoot 'build-tools\35.0.0\aapt.exe'

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
