[CmdletBinding()]
param(
    [ValidateSet('test', 'production', 'none')]
    [string]$AndroidSigning = 'test',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path $repoRoot 'godot'
$distRoot = Join-Path $projectRoot 'dist\release'
$windowsRoot = Join-Path $distRoot 'windows'
$androidRoot = Join-Path $distRoot 'android'
$stagingRoot = Join-Path $repoRoot '.tools\release-staging'
$jdkRoot = Join-Path $repoRoot '.tools\jdk-17'
$version = '0.3.1'

function Set-TestSigningEnvironment {
    $signingRoot = Join-Path $repoRoot '.tools\signing'
    $keystore = Join-Path $signingRoot 'pokemontcg-stage6-test.jks'
    $credentialsPath = Join-Path $signingRoot 'test-signing.json'
    New-Item -ItemType Directory -Force -Path $signingRoot | Out-Null
    if (-not (Test-Path -LiteralPath $credentialsPath)) {
        $password = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')).Substring(0, 32)
        [ordered]@{
            alias = 'pokemontcg-stage6'
            password = $password
        } | ConvertTo-Json | Set-Content -LiteralPath $credentialsPath -Encoding UTF8
    }
    $credentials = Get-Content -Raw -LiteralPath $credentialsPath | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $keystore)) {
        $keytool = Join-Path $jdkRoot 'bin\keytool.exe'
        if (-not (Test-Path -LiteralPath $keytool)) {
            throw 'JDK 17 is missing. Run tools/setup_android_toolchain.ps1 first.'
        }
        & $keytool `
            -genkeypair `
            -v `
            -keystore $keystore `
            -storepass $credentials.password `
            -keypass $credentials.password `
            -alias $credentials.alias `
            -keyalg RSA `
            -keysize 2048 `
            -validity 10000 `
            -dname 'CN=PokemonTCG Stage 6 Test, OU=Local Testing, O=PokemonTCG, C=CN'
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to generate the local Stage 6 test keystore.'
        }
    }
    $env:GODOT_ANDROID_KEYSTORE_RELEASE_PATH = $keystore
    $env:GODOT_ANDROID_KEYSTORE_RELEASE_USER = [string]$credentials.alias
    $env:GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD = [string]$credentials.password
    Write-Host 'ANDROID_SIGNING_MODE=test (local non-production key)'
}

function Assert-ProductionSigningEnvironment {
    foreach ($name in @(
        'GODOT_ANDROID_KEYSTORE_RELEASE_PATH',
        'GODOT_ANDROID_KEYSTORE_RELEASE_USER',
        'GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD'
    )) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Production Android signing requires $name."
        }
    }
    if (-not (Test-Path -LiteralPath $env:GODOT_ANDROID_KEYSTORE_RELEASE_PATH)) {
        throw 'The production Android release keystore does not exist.'
    }
    Write-Host 'ANDROID_SIGNING_MODE=production'
}

if ($AndroidSigning -eq 'test') {
    Set-TestSigningEnvironment
} elseif ($AndroidSigning -eq 'production') {
    Assert-ProductionSigningEnvironment
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build_native_ai.ps1') -Target all -Configuration release
    if ($LASTEXITCODE -ne 0) {
        throw 'Release native AI build failed.'
    }
    $target = if ($AndroidSigning -eq 'none') { 'windows' } else { 'all' }
    & (Join-Path $PSScriptRoot 'build_godot.ps1') -Target $target -Configuration release
    if ($LASTEXITCODE -ne 0) {
        throw 'Godot release export failed.'
    }
}

$windowsExe = Join-Path $windowsRoot 'PokemonTCG.exe'
$windowsPck = Join-Path $windowsRoot 'PokemonTCG.pck'
foreach ($required in @($windowsExe, $windowsPck)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing release artifact: $required"
    }
}

$releaseSmokeProcess = Start-Process `
    -FilePath $windowsExe `
    -ArgumentList @('--', '--phase6-release-smoke') `
    -PassThru `
    -Wait `
    -WindowStyle Hidden
$releaseSmokeExitCode = $releaseSmokeProcess.ExitCode
if ($releaseSmokeExitCode -ne 0) {
    throw "Windows release smoke failed with exit code $releaseSmokeExitCode."
}
Write-Host 'WINDOWS_RELEASE_SMOKE_OK'

if (Test-Path -LiteralPath $stagingRoot) {
    $resolvedStaging = (Resolve-Path -LiteralPath $stagingRoot).Path
    $resolvedTools = (Resolve-Path -LiteralPath (Join-Path $repoRoot '.tools')).Path
    if (-not $resolvedStaging.StartsWith($resolvedTools, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe staging path: $resolvedStaging"
    }
    Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
}
$packageRoot = Join-Path $stagingRoot "PokemonTCG-$version"
New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null

foreach ($name in @(
    'PokemonTCG.exe',
    'PokemonTCG.pck',
    'libpokemon_ai.windows.template_release.x86_64.dll',
    'onnxruntime.dll'
)) {
    Copy-Item -LiteralPath (Join-Path $windowsRoot $name) -Destination $packageRoot
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'docs\RELEASE_NOTES.md') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $projectRoot 'third_party\onnxruntime\LICENSE') `
    -Destination (Join-Path $packageRoot 'ONNXRUNTIME_LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $projectRoot 'third_party\onnxruntime\ThirdPartyNotices.txt') `
    -Destination (Join-Path $packageRoot 'THIRD_PARTY_NOTICES.txt')

$buildInfo = [ordered]@{
    version = $version
    created_utc = [DateTime]::UtcNow.ToString('o')
    godot = '4.7.stable'
    protocol = 3
    rules_schema = 3
    action_schema = 3
    onnx_runtime = '1.26.0'
    onnx_models = 8
    windows_arch = 'x86_64'
    android_arch = if ($AndroidSigning -eq 'none') { $null } else { 'arm64-v8a' }
    android_signing = $AndroidSigning
}
$buildInfo | ConvertTo-Json | Set-Content `
    -LiteralPath (Join-Path $packageRoot 'BUILD_INFO.json') -Encoding UTF8

$zipPath = Join-Path $distRoot "PokemonTCG-Windows-x86_64-$version.zip"
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -LiteralPath $packageRoot -DestinationPath $zipPath -CompressionLevel Optimal

$releaseFiles = @(
    $zipPath,
    $windowsExe,
    $windowsPck,
    (Join-Path $windowsRoot 'libpokemon_ai.windows.template_release.x86_64.dll'),
    (Join-Path $windowsRoot 'onnxruntime.dll')
)
if ($AndroidSigning -ne 'none') {
    $androidApk = Join-Path $androidRoot 'PokemonTCG.apk'
    if (-not (Test-Path -LiteralPath $androidApk)) {
        throw 'Android release APK is missing.'
    }
    $namedApk = Join-Path $distRoot (
        "PokemonTCG-Android-arm64-$version-$AndroidSigning.apk"
    )
    Copy-Item -LiteralPath $androidApk -Destination $namedApk -Force
    $releaseFiles += $namedApk
}

$manifestRows = foreach ($path in $releaseFiles) {
    $item = Get-Item -LiteralPath $path
    [ordered]@{
        file = $item.Name
        size = $item.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
}
foreach ($model in Get-ChildItem -LiteralPath (Join-Path $projectRoot 'data\ai_models') -Filter '*.onnx') {
    $manifestRows += [ordered]@{
        file = "models/$($model.Name)"
        size = $model.Length
        sha256 = (Get-FileHash -LiteralPath $model.FullName -Algorithm SHA256).Hash
    }
}
$manifestPath = Join-Path $distRoot 'SHA256SUMS.json'
$manifestRows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host "RELEASE_PACKAGE_OK version=$version"
Write-Host "WINDOWS_ZIP=$zipPath"
if ($AndroidSigning -ne 'none') {
    Write-Host "ANDROID_APK=$namedApk"
}
Write-Host "CHECKSUMS=$manifestPath"
