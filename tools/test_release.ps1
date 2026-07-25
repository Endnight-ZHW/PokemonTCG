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
Assert-ReleaseDeepFallbackContract -Manifest $release
$version = [string]$release.version
$compatibleModelCount = [int]$release.compatible_model_count
$zipPath = Join-Path $distRoot "PokemonTCG-Windows-x86_64-$version.zip"
$apkPath = Join-Path $distRoot "PokemonTCG-Android-arm64-$version-test.apk"
$smokeApkPath = Join-Path $projectRoot 'dist\release\android\PokemonTCG-smoke.apk'
$buildToolsVersion = ($lock.android.build_tools -split ';')[-1]
$aapt = Join-Path $sdkRoot "build-tools\$buildToolsVersion\aapt.exe"
$apksigner = Join-Path $sdkRoot "build-tools\$buildToolsVersion\apksigner.bat"
$jar = Join-Path $jdkRoot 'bin\jar.exe'
$env:JAVA_HOME = $jdkRoot
$env:Path = "$(Join-Path $jdkRoot 'bin');$env:Path"

foreach ($required in @($zipPath, $apkPath, $manifestPath, $aapt, $apksigner, $jar)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing release verification input: $required"
    }
}

$windowsExe = Join-Path $windowsRoot 'PokemonTCG.exe'
$smoke = Start-Process `
    -FilePath $windowsExe `
    -ArgumentList @('--', '--phase6-release-smoke') `
    -PassThru `
    -WindowStyle Hidden
try {
    if (-not $smoke.WaitForExit(180000)) {
        throw 'Windows release smoke timed out after 180 seconds.'
    }
    $smokeExitCode = $smoke.ExitCode
}
finally {
    if (-not $smoke.HasExited) {
        Stop-Process -Id $smoke.Id -Force
        $smoke.WaitForExit()
    }
}
if ($smokeExitCode -ne 0) {
    throw "Windows release smoke failed with exit code $smokeExitCode."
}
Write-Host 'WINDOWS_RELEASE_RUNTIME_OK'

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $entries = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    foreach ($suffix in @(
        '/PokemonTCG.exe',
        '/PokemonTCG.pck',
        '/libpokemon_ai.windows.template_release.x86_64.dll',
        '/onnxruntime.dll',
        '/RELEASE_NOTES.md',
        '/RELEASE_MANIFEST.json',
        '/BUILD_INFO.json',
        '/ONNXRUNTIME_LICENSE.txt',
        '/THIRD_PARTY_NOTICES.txt'
    )) {
        if (-not ($entries | Where-Object { $_.EndsWith($suffix) })) {
            throw "Windows ZIP is missing $suffix"
        }
    }
    foreach ($forbidden in @('.py', '.onnx', 'torch', '/tests/', '/tools/', 'console.exe')) {
        if ($entries | Where-Object { $_.ToLowerInvariant().Contains($forbidden) }) {
            throw "Windows ZIP contains forbidden release content: $forbidden"
        }
    }
    $buildInfoEntry = @(
        $zip.Entries | Where-Object { $_.FullName.Replace('\', '/').EndsWith('/BUILD_INFO.json') }
    ) | Select-Object -First 1
    if ($null -eq $buildInfoEntry) {
        throw 'Windows ZIP is missing BUILD_INFO.json.'
    }
    $reader = [System.IO.StreamReader]::new($buildInfoEntry.Open())
    try {
        $buildInfo = $reader.ReadToEnd() | ConvertFrom-Json
    }
    finally {
        $reader.Dispose()
    }
    if (
        [int]$buildInfo.onnx_models -ne $compatibleModelCount -or
        [int]$buildInfo.legacy_models -ne [int]$release.legacy_model_count -or
        [bool]$buildInfo.deep_runtime_enabled -ne [bool]$release.deep_runtime_enabled -or
        [string]$buildInfo.deep_fallback -ne 'challenge'
    ) {
        throw 'Windows ZIP BUILD_INFO.json does not match the Deep runtime contract.'
    }
}
finally {
    $zip.Dispose()
}
Write-Host 'WINDOWS_RELEASE_ZIP_OK'

$badging = & $aapt dump badging $apkPath
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect the Android release APK.'
}
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
if ($LASTEXITCODE -ne 0) {
    throw 'Android release APK signature verification failed.'
}
$apkEntries = & $jar tf $apkPath
foreach ($nativeEntry in @(
    'lib/arm64-v8a/libpokemon_ai.android.template_release.arm64.so',
    'lib/arm64-v8a/libonnxruntime.so'
)) {
    if ($nativeEntry -notin $apkEntries) {
        throw "Android release APK is missing $nativeEntry."
    }
}
$actualApkModels = @(
    $apkEntries |
        Where-Object { $_ -match '^assets/data/ai_models/[^/]+\.onnx$' } |
        ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) } |
        Sort-Object
)
if ($actualApkModels.Count -ne $compatibleModelCount) {
    throw "Android release APK contains $($actualApkModels.Count) compatible models; expected $compatibleModelCount."
}
Write-Host "ANDROID_RELEASE_APK_OK signing=test compatible_models=$compatibleModelCount abi=arm64-v8a"

& (Join-Path $PSScriptRoot 'test_android_runtime.ps1') `
    -ApkPath $apkPath `
    -SmokeApkPath $smokeApkPath `
    -ExpectedModels $compatibleModelCount `
    -RequireDevice:$RequireAndroidDevice `
    -AllowCleanInstall:$AllowAndroidCleanInstall
if ($LASTEXITCODE -ne 0) {
    throw 'Android release runtime smoke failed.'
}

$manifestPayload = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
# Windows PowerShell 5.1 preserves a top-level JSON array as one pipeline
# object inside @(...); assigning first and then expanding normalizes PS 5/7.
$manifest = @($manifestPayload)
$releaseTargets = @{
    ([IO.Path]::GetFileName($zipPath)) = $zipPath
    'PokemonTCG.exe' = $windowsExe
    'PokemonTCG.pck' = (Join-Path $windowsRoot 'PokemonTCG.pck')
    'libpokemon_ai.windows.template_release.x86_64.dll' = (
        Join-Path $windowsRoot 'libpokemon_ai.windows.template_release.x86_64.dll'
    )
    'onnxruntime.dll' = (Join-Path $windowsRoot 'onnxruntime.dll')
    ([IO.Path]::GetFileName($apkPath)) = $apkPath
}
$expectedManifestFiles = @($releaseTargets.Keys)
$actualManifestFiles = @($manifest | ForEach-Object { [string]$_.file })
$uniqueManifestFiles = @($actualManifestFiles | Sort-Object -Unique)
$manifestFileDifferences = @(
    Compare-Object `
        @($expectedManifestFiles | Sort-Object) `
        @($actualManifestFiles | Sort-Object)
)
Write-Host (
    "RELEASE_CHECKSUM_SET expected=$($expectedManifestFiles.Count) " +
    "actual=$($actualManifestFiles.Count) unique=$($uniqueManifestFiles.Count) " +
    "differences=$($manifestFileDifferences.Count)"
)
if (
    $uniqueManifestFiles.Count -ne $actualManifestFiles.Count -or
    $manifestFileDifferences.Count -ne 0
) {
    throw 'Checksum manifest file set is missing, duplicated, or unexpected.'
}
foreach ($row in $manifest) {
    $path = $releaseTargets[[string]$row.file]
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        throw "Checksum manifest target is missing: $($row.file)"
    }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($actual -ne $row.sha256) {
        throw "Checksum mismatch: $($row.file)"
    }
}
Write-Host "RELEASE_CHECKSUMS_OK entries=$($manifest.Count)"
