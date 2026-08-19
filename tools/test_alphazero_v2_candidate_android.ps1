[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunDir,
    [string]$EvidenceOutput = '',
    [ValidateSet('test', 'production')]
    [string]$AndroidSigning = 'test',
    [switch]$RequireDevice,
    [switch]$AllowCleanInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$jdkRoot = Join-Path $repoRoot '.tools\jdk-17'
$run = [IO.Path]::GetFullPath($RunDir)
$release = Join-Path $run 'release_staging\godot\data\release_manifest.json'
$runtime = Join-Path $run 'release_staging\godot\data\ai_models_runtime.json'
$model = Join-Path $run 'release_staging\godot\data\ai_models\universal.onnx'
$training = Join-Path $run 'release-evidence.json'
foreach ($required in @($release, $runtime, $model, $training)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "AlphaZero v2 candidate artifact is missing: $required"
    }
}

$candidateRelease = Get-Content -LiteralPath $release -Raw | ConvertFrom-Json
$trainingEvidence = Get-Content -LiteralPath $training -Raw | ConvertFrom-Json
if (
    [bool]$candidateRelease.deep_runtime_enabled -or
    -not [bool]$candidateRelease.native_ai.production_ready -or
    [string]$trainingEvidence.schema -ne 'alphazero_v2_training_evidence/1' -or
    -not [bool]$trainingEvidence.accepted -or
    -not [bool]$trainingEvidence.native_core_available -or
    -not [bool]$trainingEvidence.native_core_ready
) {
    throw (
        'Android candidate requires an accepted, production-ready training run ' +
        'whose staged release switch remains disabled.'
    )
}
$temporaryRelease = Join-Path $run 'staging\android_candidate_release_enabled.json'
$candidateRelease.deep_runtime_enabled = $true
$candidateRelease.model_count = 1
New-Item -ItemType Directory -Force `
    -Path (Split-Path -Parent $temporaryRelease) | Out-Null
[IO.File]::WriteAllText(
    $temporaryRelease,
    ($candidateRelease | ConvertTo-Json -Depth 100) + "`n",
    [Text.UTF8Encoding]::new($false)
)
if ([string]::IsNullOrWhiteSpace($EvidenceOutput)) {
    $EvidenceOutput = Join-Path $run 'evidence\android_runtime.json'
}
if ($AndroidSigning -eq 'test') {
    $signingRoot = Join-Path $repoRoot '.tools\signing'
    $keystore = Join-Path $signingRoot 'pokemontcg-stage6-test.jks'
    $credentialsPath = Join-Path $signingRoot 'test-signing.json'
    New-Item -ItemType Directory -Force -Path $signingRoot | Out-Null
    if (-not (Test-Path -LiteralPath $credentialsPath -PathType Leaf)) {
        $password = (
            [guid]::NewGuid().ToString('N') +
            [guid]::NewGuid().ToString('N')
        ).Substring(0, 32)
        [IO.File]::WriteAllText(
            $credentialsPath,
            ([ordered]@{
                alias = 'pokemontcg-stage6'
                password = $password
            } | ConvertTo-Json) + "`n",
            [Text.UTF8Encoding]::new($false)
        )
    }
    $credentials = Get-Content -Raw -LiteralPath $credentialsPath |
        ConvertFrom-Json
    if (-not (Test-Path -LiteralPath $keystore -PathType Leaf)) {
        $keytool = Join-Path $jdkRoot 'bin\keytool.exe'
        if (-not (Test-Path -LiteralPath $keytool -PathType Leaf)) {
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
            throw 'Unable to generate the local Android test keystore.'
        }
    }
    $env:GODOT_ANDROID_KEYSTORE_RELEASE_PATH = $keystore
    $env:GODOT_ANDROID_KEYSTORE_RELEASE_USER = [string]$credentials.alias
    $env:GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD = [string]$credentials.password
    Write-Host 'ANDROID_SIGNING_MODE=test (local non-production key)'
}
else {
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
    if (
        -not (
            Test-Path -LiteralPath `
                $env:GODOT_ANDROID_KEYSTORE_RELEASE_PATH -PathType Leaf
        )
    ) {
        throw 'The production Android release keystore does not exist.'
    }
    Write-Host 'ANDROID_SIGNING_MODE=production'
}

$backup = Join-Path $run ('staging\android-test-backup-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $backup | Out-Null
$live = @(
    @{ Candidate = $temporaryRelease; Target = (Join-Path $repoRoot 'release_manifest.json'); Name = 'root-release.json' },
    @{ Candidate = $temporaryRelease; Target = (Join-Path $repoRoot 'godot\data\release_manifest.json'); Name = 'godot-release.json' },
    @{ Candidate = $runtime; Target = (Join-Path $repoRoot 'godot\data\ai_models_runtime.json'); Name = 'runtime.json' },
    @{ Candidate = $model; Target = (Join-Path $repoRoot 'godot\data\ai_models\universal.onnx'); Name = 'universal.onnx' },
    @{ Candidate = $training; Target = (Join-Path $repoRoot 'godot\data\candidate_manifest.json'); Name = 'candidate-manifest.json' }
)
try {
    foreach ($row in $live) {
        $row.Backup = Join-Path $backup $row.Name
        $row.HadTarget = Test-Path -LiteralPath $row.Target -PathType Leaf
        if ($row.HadTarget) {
            Copy-Item -LiteralPath $row.Target -Destination $row.Backup
        }
        Copy-Item -LiteralPath $row.Candidate -Destination $row.Target -Force
    }
    & (Join-Path $PSScriptRoot 'build_godot.ps1') `
        -Target android -Configuration release `
        -IncludeAndroidRuntimeSmoke $true `
        -IncludeAndroidCandidateSmoke $true
    if ($LASTEXITCODE -ne 0) {
        throw 'Android AlphaZero v2 candidate build failed.'
    }
    & (Join-Path $PSScriptRoot 'test_android_runtime.ps1') `
        -ApkPath (Join-Path $repoRoot 'godot\dist\release\android\PokemonTCG.apk') `
        -SmokeApkPath (Join-Path $repoRoot 'godot\dist\release\android\PokemonTCG-smoke.apk') `
        -CandidateSmokeApkPath (Join-Path $repoRoot 'godot\dist\release\android\PokemonTCG-candidate-smoke.apk') `
        -AndroidEvidenceOutput $EvidenceOutput `
        -ExpectedModels 1 `
        -RequireDevice:$RequireDevice `
        -AllowCleanInstall:$AllowCleanInstall
    if ($LASTEXITCODE -ne 0) {
        throw 'Android AlphaZero v2 candidate runtime failed.'
    }
}
finally {
    foreach ($row in $live) {
        if ($row.HadTarget) {
            Copy-Item -LiteralPath $row.Backup -Destination $row.Target -Force
        }
        elseif (Test-Path -LiteralPath $row.Target -PathType Leaf) {
            Remove-Item -LiteralPath $row.Target -Force
        }
    }
}
if ($RequireDevice) {
    if (-not (Test-Path -LiteralPath $EvidenceOutput -PathType Leaf)) {
        throw 'Android physical-device verification did not produce release evidence.'
    }
    Write-Host "ALPHAZERO_V2_ANDROID_RUNTIME_OK models=1 abi=arm64-v8a evidence=$EvidenceOutput"
}
else {
    Write-Host (
        'ALPHAZERO_V2_ANDROID_BUILD_OK models=1 abi=arm64-v8a; ' +
        'physical-device evidence not claimed'
    )
}
