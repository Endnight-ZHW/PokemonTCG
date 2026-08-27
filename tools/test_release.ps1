[CmdletBinding()]
param(
    [switch]$RequireAndroidDevice,
    [switch]$AllowAndroidCleanInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path $repoRoot 'godot'
$distRoot = Join-Path $projectRoot 'dist\release'
$windowsRoot = Join-Path $distRoot 'windows'
$manifestPath = Join-Path $distRoot 'SHA256SUMS.json'
$sdkRoot = Join-Path $repoRoot '.tools\android-sdk'
$jdkRoot = Join-Path $repoRoot '.tools\jdk-17'
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
$release = Get-ReleaseManifest -RepoRoot $repoRoot
Assert-ProductReleaseContract -Manifest $release
$version = [string]$release.version
$zipPath = Join-Path $distRoot "PokemonTCG-Windows-x86_64-$version.zip"
$apkPath = Join-Path $distRoot "PokemonTCG-Android-arm64-$version-test.apk"
$smokeApkPath = Join-Path $projectRoot 'dist\release\android\PokemonTCG-smoke.apk'
$buildToolsVersion = ($lock.android.build_tools -split ';')[-1]
$aapt = Join-Path $sdkRoot "build-tools\$buildToolsVersion\aapt.exe"
$apksigner = Join-Path $sdkRoot "build-tools\$buildToolsVersion\apksigner.bat"
$jar = Join-Path $jdkRoot 'bin\jar.exe'
$env:JAVA_HOME = $jdkRoot
$env:Path = "$(Join-Path $jdkRoot 'bin');$env:Path"

foreach ($required in @($zipPath, $apkPath, $smokeApkPath, $manifestPath, $aapt, $apksigner, $jar)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing release verification input: $required"
    }
}

$windowsExe = Join-Path $windowsRoot 'PokemonTCG.exe'
$windowsPck = Join-Path $windowsRoot 'PokemonTCG.pck'
$windowsDll = Join-Path $windowsRoot 'libpokemon_ai.windows.template_release.x86_64.dll'
$smoke = Start-Process -FilePath $windowsExe `
    -ArgumentList @('--', '--phase6-release-smoke') -PassThru -WindowStyle Hidden
try {
    if (-not $smoke.WaitForExit(180000)) { throw 'Windows release smoke timed out.' }
    if ($smoke.ExitCode -ne 0) { throw "Windows release smoke failed: $($smoke.ExitCode)" }
} finally {
    if (-not $smoke.HasExited) {
        Stop-Process -Id $smoke.Id -Force
        $smoke.WaitForExit()
    }
}
Write-Host 'WINDOWS_RELEASE_RUNTIME_OK'

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entryNames = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    foreach ($suffix in @(
        '/PokemonTCG.exe',
        '/PokemonTCG.pck',
        '/libpokemon_ai.windows.template_release.x86_64.dll',
        '/RELEASE_NOTES.md',
        '/RELEASE_MANIFEST.json',
        '/BUILD_INFO.json'
    )) {
        if (-not ($entryNames | Where-Object { $_.EndsWith($suffix) })) {
            throw "Windows ZIP is missing $suffix"
        }
    }
    foreach ($forbidden in @(
        '.py', '.onnx', 'onnxruntime', '/research/', '/deep_ai/', '/tests/',
        '/tools/', 'console.exe', 'ptcg_relay_server'
    )) {
        if ($entryNames | Where-Object { $_.ToLowerInvariant().Contains($forbidden) }) {
            throw "Windows ZIP contains forbidden content: $forbidden"
        }
    }
    $buildInfoEntry = $zip.Entries | Where-Object {
        $_.FullName.Replace('\', '/').EndsWith('/BUILD_INFO.json')
    } | Select-Object -First 1
    if ($null -eq $buildInfoEntry) { throw 'Windows ZIP is missing BUILD_INFO.json.' }
    $reader = [IO.StreamReader]::new($buildInfoEntry.Open())
    try { $buildInfo = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    if (
        [string]$buildInfo.version -ne $version -or
        [int]$buildInfo.protocol -ne 6 -or
        [int]$buildInfo.action_schema -ne 4 -or
        [int]$buildInfo.choice_view_schema -ne 2 -or
        [string]$buildInfo.native_rules -ne 'ptcg_core' -or
        [string]$buildInfo.native_challenge -ne 'challenge_core'
    ) {
        throw 'Windows ZIP BUILD_INFO.json does not match the product contract.'
    }
} finally {
    $zip.Dispose()
}
Write-Host 'WINDOWS_RELEASE_ZIP_OK'

$badging = & $aapt dump badging $apkPath
if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect Android release APK.' }
$badgingText = $badging -join "`n"
foreach ($expected in @(
    "package: name='com.pokemontcg.game' versionCode='$([int]$release.android_version_code)' versionName='$version'",
    "sdkVersion:'28'",
    "targetSdkVersion:'35'",
    "native-code: 'arm64-v8a'"
)) {
    if (-not $badgingText.Contains($expected)) {
        throw "Android release metadata mismatch: $expected"
    }
}
& $apksigner verify --verbose --print-certs $apkPath | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Android release signature verification failed.' }
$apkEntries = @(& $jar tf $apkPath)
if ($LASTEXITCODE -ne 0) { throw 'Unable to list Android release APK.' }
$releaseNative = @($apkEntries | Where-Object {
    $_ -match '^lib/arm64-v8a/libpokemon_ai\.android\.template_release\.arm64\.so$'
})
if ($releaseNative.Count -ne 1) {
    throw 'Android release APK is missing its product native library.'
}
$forbiddenApk = @($apkEntries | Where-Object {
    $_ -match '(?i)(\.onnx$|onnxruntime|ptcg_relay_server|(^|/)(research|deep_ai)(/|$))'
})
if ($forbiddenApk.Count -ne 0) {
    throw "Android release APK contains forbidden content: $($forbiddenApk[0])"
}
Write-Host 'ANDROID_RELEASE_APK_OK signing=test abi=arm64-v8a onnx_assets=0'

& (Join-Path $PSScriptRoot 'test_android_runtime.ps1') `
    -ApkPath $apkPath -SmokeApkPath $smokeApkPath `
    -RequireDevice:$RequireAndroidDevice `
    -AllowAndroidCleanInstall:$AllowAndroidCleanInstall
if ($LASTEXITCODE -ne 0) { throw 'Android release runtime smoke failed.' }

$manifestPayload = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$manifest = @($manifestPayload)
$releaseTargets = @{
    ([IO.Path]::GetFileName($zipPath)) = $zipPath
    'PokemonTCG.exe' = $windowsExe
    'PokemonTCG.pck' = $windowsPck
    'libpokemon_ai.windows.template_release.x86_64.dll' = $windowsDll
    ([IO.Path]::GetFileName($apkPath)) = $apkPath
}
$expectedFiles = @($releaseTargets.Keys | Sort-Object)
$actualFiles = @($manifest | ForEach-Object { [string]$_.file } | Sort-Object)
if (@(Compare-Object $expectedFiles $actualFiles).Count -ne 0) {
    throw 'Checksum manifest file set is missing, duplicated, or unexpected.'
}
foreach ($row in $manifest) {
    $path = $releaseTargets[[string]$row.file]
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        throw "Checksum manifest target is missing: $($row.file)"
    }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $row.sha256) {
        throw "Checksum mismatch: $($row.file)"
    }
}
Write-Host "RELEASE_CHECKSUMS_OK entries=$($manifest.Count)"
