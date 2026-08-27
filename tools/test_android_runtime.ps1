[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ApkPath,
    [Parameter(Mandatory)]
    [string]$SmokeApkPath,
    [string]$PackageName = 'com.pokemontcg.game',
    [int]$TimeoutSeconds = 180,
    [switch]$RequireDevice,
    [switch]$AllowAndroidCleanInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$sdkRoot = Join-Path $repoRoot '.tools\android-sdk'
$jdkRoot = Join-Path $repoRoot '.tools\jdk-17'
$adb = Join-Path $sdkRoot 'platform-tools\adb.exe'
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
$release = Get-ReleaseManifest -RepoRoot $repoRoot
Assert-ProductReleaseContract -Manifest $release
$buildToolsVersion = ($lock.android.build_tools -split ';')[-1]
$aapt = Join-Path $sdkRoot "build-tools\$buildToolsVersion\aapt.exe"
$apksigner = Join-Path $sdkRoot "build-tools\$buildToolsVersion\apksigner.bat"
$jar = Join-Path $jdkRoot 'bin\jar.exe'
$env:JAVA_HOME = $jdkRoot
$env:Path = "$(Join-Path $jdkRoot 'bin');$env:Path"

foreach ($required in @($ApkPath, $SmokeApkPath, $adb, $aapt, $apksigner, $jar)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Android verification input is missing: $required"
    }
}

function Get-ApkIdentity {
    param([Parameter(Mandatory)] [string]$Path)
    $rows = @(& $aapt dump badging $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect Android APK: $Path" }
    $packageRow = [string]($rows | Where-Object { $_ -like 'package:*' } | Select-Object -First 1)
    $match = [regex]::Match(
        $packageRow,
        "^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'"
    )
    if (-not $match.Success) { throw "Unable to parse Android APK identity: $Path" }
    return [pscustomobject]@{
        PackageName = $match.Groups[1].Value
        VersionCode = $match.Groups[2].Value
        VersionName = $match.Groups[3].Value
    }
}

function Get-ApkSignerDigests {
    param([Parameter(Mandatory)] [string]$Path)
    $rows = @(& $apksigner verify --verbose --print-certs $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Android APK signature verification failed: $Path" }
    $digests = @(
        $rows | ForEach-Object {
            $match = [regex]::Match(
                [string]$_,
                '^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)$'
            )
            if ($match.Success) { $match.Groups[1].Value.ToLowerInvariant() }
        } | Sort-Object -Unique
    )
    if ($digests.Count -eq 0) { throw "Android APK has no signer digest: $Path" }
    return $digests
}

function Get-ApkEntries {
    param([Parameter(Mandatory)] [string]$Path)
    $rows = @(& $jar tf $Path)
    if ($LASTEXITCODE -ne 0) { throw "Unable to list Android APK: $Path" }
    return $rows
}

function Get-ApkNativeHashes {
    param([Parameter(Mandatory)] [string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Path))
    try {
        $result = [ordered]@{}
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if ($name -notmatch '^lib/arm64-v8a/libpokemon_ai\..*\.so$') { continue }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $result[$name] = (
                    $sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }
                ) -join ''
            } finally {
                $sha.Dispose()
                $stream.Dispose()
            }
        }
        return $result
    } finally {
        $archive.Dispose()
    }
}

function Get-ApkCommandLine {
    param([Parameter(Mandatory)] [string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Path))
    try {
        $entry = $archive.GetEntry('assets/_cl_')
        if ($null -eq $entry) { return '' }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $archive.Dispose()
    }
}

function Install-AndroidPackage {
    param([Parameter(Mandatory)] [string]$Serial, [Parameter(Mandatory)] [string]$Path)
    $rows = @(& $adb -s $Serial install -r $Path 2>&1)
    $exitCode = $LASTEXITCODE
    $text = $rows -join "`n"
    $rows | Out-Host
    if (
        $exitCode -ne 0 -and $AllowAndroidCleanInstall -and
        $text.Contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')
    ) {
        & $adb -s $Serial uninstall $PackageName | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Unable to uninstall $PackageName from $Serial." }
        & $adb -s $Serial install $Path | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Unable to install Android APK on $Serial." }
        return
    }
    if ($exitCode -ne 0) {
        $hint = if ($text.Contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')) {
            ' Re-run with -AllowAndroidCleanInstall to replace the incompatible local package.'
        } else { '' }
        throw "Unable to install Android APK on $Serial.$hint"
    }
}

$releaseIdentity = Get-ApkIdentity -Path $ApkPath
$smokeIdentity = Get-ApkIdentity -Path $SmokeApkPath
foreach ($identity in @($releaseIdentity, $smokeIdentity)) {
    if (
        $identity.PackageName -ne $PackageName -or
        $identity.VersionCode -ne [string]$release.android_version_code -or
        $identity.VersionName -ne [string]$release.version
    ) {
        throw 'Android APK identity does not match the canonical release manifest.'
    }
}
$releaseSigners = @(Get-ApkSignerDigests -Path $ApkPath)
$smokeSigners = @(Get-ApkSignerDigests -Path $SmokeApkPath)
if (($releaseSigners -join "`n") -ne ($smokeSigners -join "`n")) {
    throw 'Release and smoke APK signer certificates differ.'
}

foreach ($path in @($ApkPath, $SmokeApkPath)) {
    $entries = @(Get-ApkEntries -Path $path)
    $nativeLibraries = @($entries | Where-Object {
        $_ -match '^lib/arm64-v8a/libpokemon_ai\..*\.so$'
    })
    if ($nativeLibraries.Count -ne 1) {
        throw "Android APK must contain exactly one product native library: $path"
    }
    $forbidden = @($entries | Where-Object {
        $_ -match '(?i)(\.onnx$|onnxruntime|(^|/)(research|deep_ai)(/|$))'
    })
    if ($forbidden.Count -ne 0) {
        throw "Android APK contains forbidden research content: $($forbidden[0])"
    }
}
$releaseHashes = Get-ApkNativeHashes -Path $ApkPath
$smokeHashes = Get-ApkNativeHashes -Path $SmokeApkPath
if (
    ($releaseHashes.Keys -join "`n") -ne ($smokeHashes.Keys -join "`n") -or
    @($releaseHashes.Keys | Where-Object { $releaseHashes[$_] -ne $smokeHashes[$_] }).Count -ne 0
) {
    throw 'Release and smoke APK native payloads differ.'
}
if (-not (Get-ApkCommandLine -Path $SmokeApkPath).Contains('--phase6-release-smoke')) {
    throw 'Android smoke APK does not contain the release smoke flag.'
}
Write-Host 'ANDROID_PRODUCT_STATIC_OK abi=arm64-v8a onnx_assets=0'

$deviceRows = @(& $adb devices 2>&1)
if ($LASTEXITCODE -ne 0) { throw 'Unable to query Android devices.' }
$devices = @(
    $deviceRows | Select-Object -Skip 1 | ForEach-Object {
        if ([string]$_ -match '^([^\s]+)\s+device$') { $Matches[1] }
    }
)
$arm64Devices = @(
    $devices | Where-Object {
        ((@(& $adb -s $_ shell getprop ro.product.cpu.abi) -join "`n").Trim()) -eq 'arm64-v8a'
    }
)
if ($arm64Devices.Count -eq 0) {
    if ($RequireDevice) { throw 'No native arm64-v8a Android device is connected.' }
    Write-Host 'ANDROID_RUNTIME_SKIPPED reason=no_native_arm64_device'
    return
}

$serial = [string]$arm64Devices[0]
Install-AndroidPackage -Serial $serial -Path $SmokeApkPath
& $adb -s $serial logcat -c | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unable to clear Android logcat.' }
& $adb -s $serial shell am force-stop $PackageName | Out-Null
& $adb -s $serial shell monkey -p $PackageName 1 | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Unable to launch Android smoke APK.' }

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$logText = ''
do {
    Start-Sleep -Milliseconds 750
    $logText = (@(& $adb -s $serial logcat -d 2>&1) -join "`n")
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read Android logcat.' }
    if ($logText.Contains('PHASE6_EXPORT_RELEASE_OK')) {
        Write-Host "ANDROID_PRODUCT_RUNTIME_OK serial=$serial challenge=native"
        & $adb -s $serial shell am force-stop $PackageName | Out-Null
        return
    }
    if ($logText -match 'PHASE6_EXPORT_RELEASE_FAILED|Error loading extension|SCRIPT ERROR') {
        throw "Android release smoke failed.`n$($logText.Split("`n") | Select-Object -Last 120 | Out-String)"
    }
} while ([DateTime]::UtcNow -lt $deadline)

throw "Android release smoke timed out after $TimeoutSeconds seconds."
