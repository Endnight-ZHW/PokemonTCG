[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path $repoRoot 'godot'
$distRoot = Join-Path $projectRoot 'dist\release'
$windowsRoot = Join-Path $distRoot 'windows'
$zipPath = Join-Path $distRoot 'PokemonTCG-Windows-x86_64-0.3.2.zip'
$apkPath = Join-Path $distRoot 'PokemonTCG-Android-arm64-0.3.2-test.apk'
$manifestPath = Join-Path $distRoot 'SHA256SUMS.json'
$sdkRoot = Join-Path $repoRoot '.tools\android-sdk'
$jdkRoot = Join-Path $repoRoot '.tools\jdk-17'
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
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
    -Wait `
    -WindowStyle Hidden
if ($smoke.ExitCode -ne 0) {
    throw "Windows release smoke failed with exit code $($smoke.ExitCode)."
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
        '/BUILD_INFO.json',
        '/ONNXRUNTIME_LICENSE.txt',
        '/THIRD_PARTY_NOTICES.txt'
    )) {
        if (-not ($entries | Where-Object { $_.EndsWith($suffix) })) {
            throw "Windows ZIP is missing $suffix"
        }
    }
    foreach ($forbidden in @('.py', 'torch', '/tests/', '/tools/', 'console.exe')) {
        if ($entries | Where-Object { $_.ToLowerInvariant().Contains($forbidden) }) {
            throw "Windows ZIP contains forbidden release content: $forbidden"
        }
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
    "package: name='com.pokemontcg.game' versionCode='5' versionName='0.3.2'",
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
foreach ($deckKey in @(
    'fire', 'water', 'psychic', 'lightning',
    'fighting', 'colorless', 'dragon', 'grass'
)) {
    if ("assets/data/ai_models/$deckKey.onnx" -notin $apkEntries) {
        throw "Android release APK is missing $deckKey.onnx."
    }
}
foreach ($nativeEntry in @(
    'lib/arm64-v8a/libpokemon_ai.android.template_release.arm64.so',
    'lib/arm64-v8a/libonnxruntime.so'
)) {
    if ($nativeEntry -notin $apkEntries) {
        throw "Android release APK is missing $nativeEntry."
    }
}
Write-Host 'ANDROID_RELEASE_APK_OK signing=test models=8 abi=arm64-v8a'

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
foreach ($row in $manifest) {
    $path = if ($row.file.StartsWith('models/')) {
        Join-Path $projectRoot ('data\ai_models\' + [IO.Path]::GetFileName($row.file))
    } else {
        Get-ChildItem -LiteralPath $distRoot -Recurse -File |
            Where-Object Name -eq $row.file |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        throw "Checksum manifest target is missing: $($row.file)"
    }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($actual -ne $row.sha256) {
        throw "Checksum mismatch: $($row.file)"
    }
}
Write-Host "RELEASE_CHECKSUMS_OK entries=$($manifest.Count)"
