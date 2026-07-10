[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ApkPath,
    [string]$SmokeApkPath = '',
    [Parameter(Mandatory)]
    [int]$ExpectedModels,
    [string]$PackageName = 'com.pokemontcg.game',
    [int]$TimeoutSeconds = 180,
    [switch]$RequireDevice,
    [switch]$AllowCleanInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$sdkRoot = Join-Path $repoRoot '.tools\android-sdk'
$jdkRoot = Join-Path $repoRoot '.tools\jdk-17'
$adb = Join-Path $sdkRoot 'platform-tools\adb.exe'
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
$release = Get-ReleaseManifest -RepoRoot $repoRoot
$releaseDecks = @($release.release_decks | ForEach-Object { [string]$_ })
$buildToolsVersion = ($lock.android.build_tools -split ';')[-1]
$aapt = Join-Path $sdkRoot "build-tools\$buildToolsVersion\aapt.exe"
$apksigner = Join-Path $sdkRoot "build-tools\$buildToolsVersion\apksigner.bat"
$java = Join-Path $jdkRoot 'bin\java.exe'
$env:JAVA_HOME = $jdkRoot
$env:Path = "$(Join-Path $jdkRoot 'bin');$env:Path"
if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) {
    throw "Android runtime APK is missing: $ApkPath"
}
foreach ($requiredTool in @($adb, $aapt, $apksigner, $java)) {
    if (-not (Test-Path -LiteralPath $requiredTool -PathType Leaf)) {
        throw "Android verification tool is missing: $requiredTool"
    }
}
if ($ExpectedModels -le 0) {
    throw 'ExpectedModels must be positive.'
}
if ($ExpectedModels -ne $releaseDecks.Count) {
    throw 'ExpectedModels does not match release_manifest.json.'
}

function Install-AndroidPackage {
    param(
        [Parameter(Mandatory)] [string]$Serial,
        [Parameter(Mandatory)] [string]$Path,
        [switch]$PermitCleanInstall
    )
    $installRows = @(& $adb -s $Serial install -r $Path 2>&1)
    $installExitCode = $LASTEXITCODE
    $installText = $installRows -join "`n"
    $installRows | Out-Host
    if (
        $installExitCode -ne 0 -and
        $PermitCleanInstall -and
        $installText.Contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')
    ) {
        Write-Host "ANDROID_CLEAN_INSTALL package=$PackageName reason=signature_mismatch"
        & $adb -s $Serial uninstall $PackageName | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to remove the incompatible test package $PackageName from device $Serial."
        }
        & $adb -s $Serial install $Path | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to clean-install Android APK on device $Serial."
        }
        return
    }
    if ($installExitCode -ne 0) {
        $hint = if ($installText.Contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')) {
            ' Re-run with -AllowCleanInstall to remove only the existing package with the incompatible signature.'
        }
        else {
            ''
        }
        throw "Unable to install Android APK on device $Serial.$hint"
    }
}

function Get-AndroidProperty {
    param(
        [Parameter(Mandatory)] [string]$Serial,
        [Parameter(Mandatory)] [string]$Name
    )
    $rows = @(& $adb -s $Serial shell getprop $Name 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Unable to read Android property $Name from device $Serial."
    }
    return ($rows -join "`n").Trim()
}

function Get-ApkRuntimeHashes {
    param([Parameter(Mandatory)] [string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead(
        [System.IO.Path]::GetFullPath($Path)
    )
    try {
        $hashes = [ordered]@{}
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            $isRuntimeInput = (
                $name.StartsWith('lib/arm64-v8a/', [System.StringComparison]::Ordinal) -or
                $name -match '^assets/data/ai_models/[^/]+\.onnx$' -or
                $name -in @(
                    'assets/data/ai_models.json',
                    'assets/data/ai_models_runtime.json',
                    'assets/data/release_manifest.json'
                )
            )
            if (-not $isRuntimeInput) {
                continue
            }
            $stream = $entry.Open()
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $hashes[$name] = (
                    $sha.ComputeHash($stream) |
                        ForEach-Object { $_.ToString('x2') }
                ) -join ''
            }
            finally {
                $sha.Dispose()
                $stream.Dispose()
            }
        }
        return $hashes
    }
    finally {
        $archive.Dispose()
    }
}

function Get-ApkIdentity {
    param([Parameter(Mandatory)] [string]$Path)
    $rows = @(& $aapt dump badging $Path 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Unable to inspect Android APK identity: $Path"
    }
    $packageRow = [string]($rows | Where-Object { $_ -like 'package:*' } | Select-Object -First 1)
    $match = [regex]::Match(
        $packageRow,
        "^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'"
    )
    if (-not $match.Success) {
        throw "Unable to parse Android APK package identity: $Path"
    }
    return [pscustomobject]@{
        PackageName = $match.Groups[1].Value
        VersionCode = $match.Groups[2].Value
        VersionName = $match.Groups[3].Value
    }
}

function Get-ApkSignerDigests {
    param([Parameter(Mandatory)] [string]$Path)
    $rows = @(& $apksigner verify --verbose --print-certs $Path 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Android APK signature verification failed: $Path"
    }
    $digests = @(
        $rows |
            ForEach-Object {
                $match = [regex]::Match(
                    [string]$_,
                    '^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)$'
                )
                if ($match.Success) {
                    $match.Groups[1].Value.ToLowerInvariant()
                }
            } |
            Sort-Object -Unique
    )
    if ($digests.Count -eq 0) {
        throw "Android APK has no signer certificate digest: $Path"
    }
    return $digests
}

function Get-ApkCommandLineText {
    param([Parameter(Mandatory)] [string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead(
        [System.IO.Path]::GetFullPath($Path)
    )
    try {
        $entry = $archive.GetEntry('assets/_cl_')
        if ($null -eq $entry) {
            throw "Android APK has no assets/_cl_: $Path"
        }
        $stream = $entry.Open()
        $memory = [System.IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            return [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
        }
        finally {
            $memory.Dispose()
            $stream.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
}

if ([string]::IsNullOrWhiteSpace($SmokeApkPath)) {
    throw 'Android ARM64 inference requires the dedicated release-smoke APK.'
}
if (-not (Test-Path -LiteralPath $SmokeApkPath -PathType Leaf)) {
    throw "Android release-smoke APK is missing: $SmokeApkPath"
}

$releaseIdentity = Get-ApkIdentity -Path $ApkPath
$smokeIdentity = Get-ApkIdentity -Path $SmokeApkPath
if (
    $releaseIdentity.PackageName -ne $PackageName -or
    $smokeIdentity.PackageName -ne $PackageName -or
    $releaseIdentity.VersionCode -ne $smokeIdentity.VersionCode -or
    $releaseIdentity.VersionName -ne $smokeIdentity.VersionName -or
    $releaseIdentity.VersionCode -ne [string]$release.android_version_code -or
    $releaseIdentity.VersionName -ne [string]$release.version
) {
    throw 'Release/smoke APK identity does not match the release manifest.'
}
$releaseSigners = @(Get-ApkSignerDigests -Path $ApkPath)
$smokeSigners = @(Get-ApkSignerDigests -Path $SmokeApkPath)
if (($releaseSigners -join "`n") -ne ($smokeSigners -join "`n")) {
    throw 'Release and smoke APK signer certificates do not match.'
}
Write-Host (
    "ANDROID_SMOKE_IDENTITY_MATCH package=$PackageName " +
    "versionCode=$($releaseIdentity.VersionCode) signers=$($releaseSigners.Count)"
)

$releaseHashes = Get-ApkRuntimeHashes -Path $ApkPath
$smokeHashes = Get-ApkRuntimeHashes -Path $SmokeApkPath
$releaseKeys = @($releaseHashes.Keys | Sort-Object)
$smokeKeys = @($smokeHashes.Keys | Sort-Object)
if (($releaseKeys -join "`n") -ne ($smokeKeys -join "`n")) {
    throw 'Release and smoke APK runtime payloads contain different files.'
}
foreach ($name in $releaseKeys) {
    if ($releaseHashes[$name] -ne $smokeHashes[$name]) {
        throw "Release and smoke APK runtime payload differs: $name"
    }
}
$modelFiles = @($releaseKeys | Where-Object { $_ -match '^assets/data/ai_models/[^/]+\.onnx$' })
if ($modelFiles.Count -ne $ExpectedModels) {
    throw "Android runtime payload contains $($modelFiles.Count) models; expected $ExpectedModels."
}
$apkModelKeys = @(
    $modelFiles |
        ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) } |
        Sort-Object
)
if (Compare-Object @($releaseDecks | Sort-Object) $apkModelKeys) {
    throw 'Android runtime payload model set does not match release_manifest.json.'
}
foreach ($requiredRuntimeInput in @(
    'assets/data/ai_models.json',
    'assets/data/ai_models_runtime.json',
    'assets/data/release_manifest.json',
    'lib/arm64-v8a/libonnxruntime.so'
)) {
    if ($requiredRuntimeInput -notin $releaseKeys) {
        throw "Android runtime payload is missing $requiredRuntimeInput."
    }
}
$nativeModelLibraries = @(
    $releaseKeys |
        Where-Object {
            $_ -match '^lib/arm64-v8a/libpokemon_ai\.android\.template_(debug|release)\.arm64\.so$'
        }
)
if ($nativeModelLibraries.Count -ne 1) {
    throw 'Android runtime payload must contain exactly one native Pokemon AI library.'
}
$sourcePayloads = [ordered]@{
    'assets/data/ai_models.json' = Join-Path $repoRoot 'godot\data\ai_models.json'
    'assets/data/ai_models_runtime.json' = Join-Path $repoRoot 'godot\data\ai_models_runtime.json'
    'assets/data/release_manifest.json' = Join-Path $repoRoot 'godot\data\release_manifest.json'
    'lib/arm64-v8a/libonnxruntime.so' = Join-Path $repoRoot 'godot\bin\android\libonnxruntime.so'
}
foreach ($deckKey in $releaseDecks) {
    $sourcePayloads["assets/data/ai_models/$deckKey.onnx"] = `
        Join-Path $repoRoot "godot\data\ai_models\$deckKey.onnx"
}
$nativeModelEntry = [string]$nativeModelLibraries[0]
$sourcePayloads[$nativeModelEntry] = Join-Path `
    $repoRoot `
    ("godot\bin\android\" + [IO.Path]::GetFileName($nativeModelEntry))
foreach ($entryName in $sourcePayloads.Keys) {
    $sourcePath = [string]$sourcePayloads[$entryName]
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Android runtime source payload is missing: $sourcePath"
    }
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($releaseHashes[$entryName] -ne $sourceHash) {
        throw "Android APK payload is stale or mismatched: $entryName"
    }
}
Write-Host "ANDROID_APK_SOURCE_MATCH models=$ExpectedModels runtime_inputs=$($sourcePayloads.Count)"
$releaseCommandLine = Get-ApkCommandLineText -Path $ApkPath
$smokeCommandLine = Get-ApkCommandLineText -Path $SmokeApkPath
if ($releaseCommandLine.Contains('--phase6-release-smoke')) {
    throw 'Production Android APK must not contain the release-smoke startup flag.'
}
if (-not $smokeCommandLine.Contains('--phase6-release-smoke')) {
    throw 'Android release-smoke APK does not contain the phase6 startup flag.'
}
Write-Host "ANDROID_SMOKE_PAYLOAD_MATCH models=$ExpectedModels runtime_files=$($releaseKeys.Count)"

function Invoke-AndroidDeviceSmoke {
$deviceRows = & $adb devices
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to enumerate ADB devices.'
}
$connectedDevices = @(
    $deviceRows |
        Select-Object -Skip 1 |
        Where-Object { $_ -match "^([^\s]+)\s+device(\s|$)" } |
        ForEach-Object { ([regex]::Match($_, '^([^\s]+)')).Groups[1].Value }
)
if ($connectedDevices.Count -eq 0) {
    if ($RequireDevice) {
        throw 'Android ARM64 runtime smoke requires a connected ADB device.'
    }
    Write-Host 'ANDROID_DEVICE_SKIPPED no connected ADB device; ARM64 inference not claimed'
    return
}

$nativeArm64Devices = @()
$deviceDescriptions = @()
foreach ($candidate in $connectedDevices) {
    $abi = Get-AndroidProperty -Serial $candidate -Name 'ro.product.cpu.abi'
    $nativeBridge = Get-AndroidProperty `
        -Serial $candidate `
        -Name 'ro.dalvik.vm.native.bridge'
    $deviceDescriptions += "$candidate(abi=$abi,bridge=$nativeBridge)"
    if ($abi -eq 'arm64-v8a' -and $nativeBridge -in @('', '0')) {
        $nativeArm64Devices += $candidate
    }
}
if ($nativeArm64Devices.Count -eq 0) {
    $details = $deviceDescriptions -join ', '
    if ($RequireDevice) {
        throw "Android ARM64 runtime smoke requires a native arm64-v8a device; connected: $details"
    }
    Write-Host "ANDROID_DEVICE_SKIPPED no native arm64-v8a device; connected=$details; ARM64 inference not claimed"
    return
}

$serial = [string]$nativeArm64Devices[0]
Write-Host "ANDROID_DEVICE_SELECTED serial=$serial abi=arm64-v8a native=1"
Install-AndroidPackage `
    -Serial $serial `
    -Path $SmokeApkPath `
    -PermitCleanInstall:$AllowCleanInstall

& $adb -s $serial logcat -c
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to clear Android logcat before release smoke.'
}
& $adb -s $serial shell am force-stop $PackageName
& $adb -s $serial shell monkey -p $PackageName 1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to launch Android phase6 release smoke.'
}

$deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(10, $TimeoutSeconds))
$logText = ''
do {
    Start-Sleep -Seconds 2
    $logRows = & $adb -s $serial logcat -d -v brief `
        'godot:V' 'GodotActivity:V' 'AndroidRuntime:E' '*:S'
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to read Android release smoke logcat.'
    }
    $logText = $logRows -join "`n"
    if (
        $logText.Contains('PHASE6_EXPORT_RELEASE_OK') -and
        $logText.Contains("models=$ExpectedModels")
    ) {
        break
    }
    if (
        $logText -match (
            'FATAL EXCEPTION|Fatal signal|SIGABRT|native crash|' +
            'PHASE6_EXPORT_RELEASE_FAILED|Error loading extension'
        )
    ) {
        $tail = ($logRows | Select-Object -Last 120) -join "`n"
        throw "Android crashed during release model smoke.`n$tail"
    }
} while ([DateTime]::UtcNow -lt $deadline)

if (
    -not $logText.Contains('PHASE6_EXPORT_RELEASE_OK') -or
    -not $logText.Contains("models=$ExpectedModels")
) {
    $tail = (($logText -split "`n") | Select-Object -Last 120) -join "`n"
    throw "Android release model smoke timed out after $TimeoutSeconds seconds.`n$tail"
}
Write-Host "ANDROID_RELEASE_MODELS_OK serial=$serial models=$ExpectedModels finite=1"

# The phase6 command intentionally exits. Relaunch normally and verify that the
# packaged application also remains alive after startup.
Install-AndroidPackage -Serial $serial -Path $ApkPath
& $adb -s $serial shell am force-stop $PackageName
& $adb -s $serial shell monkey -p $PackageName 1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to launch Android application after release smoke.'
}
Start-Sleep -Seconds 3
$pidValue = (& $adb -s $serial shell pidof $PackageName).Trim()
if (-not $pidValue) {
    throw 'Android application did not stay running after normal launch.'
}
Write-Host "ANDROID_STARTUP_OK serial=$serial pid=$pidValue"
}

Invoke-AndroidDeviceSmoke
