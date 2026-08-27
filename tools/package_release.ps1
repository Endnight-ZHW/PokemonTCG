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
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$release = Get-ReleaseManifest -RepoRoot $repoRoot
Assert-ProductReleaseContract -Manifest $release
$version = [string]$release.version

$releaseInputs = @(
    (Join-Path $repoRoot 'docs\RELEASE_NOTES.md'),
    (Join-Path $projectRoot 'data\release_manifest.json'),
    (Join-Path $projectRoot 'data\cards.json'),
    (Join-Path $projectRoot 'data\card_ir_v4.json'),
    (Join-Path $projectRoot 'data\decks.json'),
    (Join-Path $projectRoot 'data\card_images.json'),
    (Join-Path $projectRoot 'data\card_image_hashes.json')
)
foreach ($required in $releaseInputs) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing release input: $required"
    }
}

& (Join-Path $PSScriptRoot 'content.ps1') check
if ($LASTEXITCODE -ne 0) { throw 'Godot generated data preflight failed.' }

function Set-TestSigningEnvironment {
    $signingRoot = Join-Path $repoRoot '.tools\signing'
    $keystore = Join-Path $signingRoot 'pokemontcg-stage6-test.jks'
    $credentialsPath = Join-Path $signingRoot 'test-signing.json'
    New-Item -ItemType Directory -Force -Path $signingRoot | Out-Null
    if (-not (Test-Path -LiteralPath $credentialsPath)) {
        $password = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')).Substring(0, 32)
        [ordered]@{ alias = 'pokemontcg-stage6'; password = $password } |
            ConvertTo-Json |
            Set-Content -LiteralPath $credentialsPath -Encoding UTF8
    }
    $credentials = Get-Content -Raw -LiteralPath $credentialsPath | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $keystore)) {
        $keytool = Join-Path $jdkRoot 'bin\keytool.exe'
        if (-not (Test-Path -LiteralPath $keytool)) {
            throw 'JDK 17 is missing. Run tools/setup_android_toolchain.ps1 first.'
        }
        & $keytool -genkeypair -v -keystore $keystore `
            -storepass $credentials.password -keypass $credentials.password `
            -alias $credentials.alias -keyalg RSA -keysize 2048 -validity 10000 `
            -dname 'CN=PokemonTCG Local Test, OU=Local Testing, O=PokemonTCG, C=CN'
        if ($LASTEXITCODE -ne 0) { throw 'Unable to generate the local test keystore.' }
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
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
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
    if ($LASTEXITCODE -ne 0) { throw 'Release native runtime build failed.' }
    $target = if ($AndroidSigning -eq 'none') { 'windows' } else { 'all' }
    & (Join-Path $PSScriptRoot 'build_godot.ps1') `
        -Target $target -Configuration release `
        -IncludeAndroidRuntimeSmoke:($AndroidSigning -ne 'none')
    if ($LASTEXITCODE -ne 0) { throw 'Godot release export failed.' }
}

$windowsExe = Join-Path $windowsRoot 'PokemonTCG.exe'
$windowsPck = Join-Path $windowsRoot 'PokemonTCG.pck'
$windowsDll = Join-Path $windowsRoot 'libpokemon_ai.windows.template_release.x86_64.dll'
foreach ($required in @($windowsExe, $windowsPck, $windowsDll)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing release artifact: $required"
    }
}

$releaseSmoke = Start-Process -FilePath $windowsExe `
    -ArgumentList @('--', '--phase6-release-smoke') -PassThru -WindowStyle Hidden
try {
    if (-not $releaseSmoke.WaitForExit(180000)) {
        throw 'Windows release smoke timed out after 180 seconds.'
    }
    if ($releaseSmoke.ExitCode -ne 0) {
        throw "Windows release smoke failed with exit code $($releaseSmoke.ExitCode)."
    }
} finally {
    if (-not $releaseSmoke.HasExited) {
        Stop-Process -Id $releaseSmoke.Id -Force
        $releaseSmoke.WaitForExit()
    }
}
Write-Host 'WINDOWS_RELEASE_SMOKE_OK'

Assert-PathUnderRoot -Root (Join-Path $repoRoot '.tools') -Path $stagingRoot
if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}
$packageRoot = Join-Path $stagingRoot "PokemonTCG-$version"
New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
foreach ($source in @($windowsExe, $windowsPck, $windowsDll)) {
    Copy-Item -LiteralPath $source -Destination $packageRoot
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'docs\RELEASE_NOTES.md') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $projectRoot 'data\release_manifest.json') `
    -Destination (Join-Path $packageRoot 'RELEASE_MANIFEST.json')

$buildInfo = [ordered]@{
    version = $version
    created_utc = [DateTime]::UtcNow.ToString('o')
    godot = [string]$release.godot_version
    protocol = [int]$release.schemas.protocol
    rules_schema = [int]$release.schemas.godot_rules
    action_schema = [int]$release.schemas.godot_actions
    choice_view_schema = [int]$release.schemas.choice_view
    snapshot_schema = [int]$release.schemas.snapshot
    journal_schema = [int]$release.schemas.journal
    rng_schema = [int]$release.schemas.rng
    native_rules = [string]$release.native_rules.core
    native_challenge = [string]$release.native_challenge.core
    windows_arch = 'x86_64'
    android_arch = if ($AndroidSigning -eq 'none') { $null } else { 'arm64-v8a' }
    android_signing = $AndroidSigning
}
$buildInfo | ConvertTo-Json | Set-Content `
    -LiteralPath (Join-Path $packageRoot 'BUILD_INFO.json') -Encoding UTF8

$forbiddenStaging = @(
    Get-ChildItem -LiteralPath $packageRoot -Recurse -File |
        Where-Object {
            $_.Extension -ieq '.onnx' -or
            $_.FullName -match '(?i)[\\/](research|deep_ai|tests|tools)[\\/]'
        }
)
if ($forbiddenStaging.Count -ne 0) {
    throw "Windows release staging contains forbidden content: $($forbiddenStaging[0].FullName)"
}

$zipPath = Join-Path $distRoot "PokemonTCG-Windows-x86_64-$version.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -LiteralPath $packageRoot -DestinationPath $zipPath -CompressionLevel Optimal

$releaseFiles = @($zipPath, $windowsExe, $windowsPck, $windowsDll)
if ($AndroidSigning -ne 'none') {
    $androidApk = Join-Path $androidRoot 'PokemonTCG.apk'
    if (-not (Test-Path -LiteralPath $androidApk -PathType Leaf)) {
        throw 'Android release APK is missing.'
    }
    $namedApk = Join-Path $distRoot "PokemonTCG-Android-arm64-$version-$AndroidSigning.apk"
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
$manifestPath = Join-Path $distRoot 'SHA256SUMS.json'
$manifestRows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Write-Host "RELEASE_PACKAGE_OK version=$version"
Write-Host "WINDOWS_ZIP=$zipPath"
if ($AndroidSigning -ne 'none') { Write-Host "ANDROID_APK=$namedApk" }
Write-Host "CHECKSUMS=$manifestPath"
