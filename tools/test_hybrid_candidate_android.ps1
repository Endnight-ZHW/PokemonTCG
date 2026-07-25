[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunId,
    [string]$RunsRoot = '',
    [string]$DeviceSerial = '',
    [int]$TimeoutSeconds = 240,
    [switch]$KeepBuild
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceProject = Join-Path $repoRoot 'godot'
$sdkRoot = Join-Path $repoRoot '.tools\android-sdk'
$jdkRoot = Join-Path $repoRoot '.tools\jdk-17'
$downloadsRoot = Join-Path $repoRoot '.tools\downloads'
$adb = Join-Path $sdkRoot 'platform-tools\adb.exe'
$candidatePackage = 'com.pokemontcg.ai.candidate'
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
$godotPaths = Get-GodotToolchainPaths -RepoRoot $repoRoot
$godot = $godotPaths.Console
Set-PortableGodotEnvironment -ToolsRoot (Join-Path $repoRoot '.tools')

if ([string]::IsNullOrWhiteSpace($RunsRoot)) {
    $RunsRoot = Join-Path $repoRoot 'build\ai_training\runs'
}
$runsRootFull = [System.IO.Path]::GetFullPath($RunsRoot)
$runDir = [System.IO.Path]::GetFullPath((Join-Path $runsRootFull $RunId))
$relativeRun = [System.IO.Path]::GetRelativePath($runsRootFull, $runDir)
if (
    [System.IO.Path]::IsPathRooted($relativeRun) -or
    $relativeRun -eq '..' -or
    $relativeRun.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)")
) {
    throw 'RunId resolves outside the configured runs root.'
}

$candidate = Join-Path $runDir 'staging\candidate_manifest.json'
$runtime = Join-Path $runDir 'staging\godot\data\ai_models_runtime.json'
$release = Join-Path $runDir 'staging\godot\data\release_manifest.json'
$candidateModels = Join-Path $runDir 'staging\godot\data\ai_models'
$output = Join-Path $runDir 'evaluation\android_runtime.json'
foreach ($required in @(
    $candidate,
    $runtime,
    $release,
    $godot,
    $adb,
    (Join-Path $jdkRoot 'bin\java.exe'),
    (Join-Path $sourceProject 'bin\android\libonnxruntime.so'),
    (Join-Path $sourceProject 'bin\android\libpokemon_ai.android.template_debug.arm64.so')
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Android candidate verification input is missing: $required"
    }
}

function Get-AndroidProperty {
    param(
        [Parameter(Mandatory)] [string]$Serial,
        [Parameter(Mandatory)] [string]$Name
    )
    $rows = @(& $adb -s $Serial shell getprop $Name 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read Android property $Name from device $Serial."
    }
    return ($rows -join "`n").Trim()
}

function Select-NativeArm64Device {
    $deviceRows = @(& $adb devices 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to enumerate ADB devices.'
    }
    $connected = @(
        $deviceRows |
            Select-Object -Skip 1 |
            Where-Object { $_ -match "^([^\s]+)\s+device(\s|$)" } |
            ForEach-Object {
                ([regex]::Match([string]$_, '^([^\s]+)')).Groups[1].Value
            }
    )
    if (-not [string]::IsNullOrWhiteSpace($DeviceSerial)) {
        if ($DeviceSerial -notin $connected) {
            throw "Requested Android device is not connected: $DeviceSerial"
        }
        $connected = @($DeviceSerial)
    }
    foreach ($serial in $connected) {
        $abi = Get-AndroidProperty -Serial $serial -Name 'ro.product.cpu.abi'
        $nativeBridge = Get-AndroidProperty `
            -Serial $serial `
            -Name 'ro.dalvik.vm.native.bridge'
        if ($abi -eq 'arm64-v8a' -and $nativeBridge -in @('', '0')) {
            return $serial
        }
    }
    throw 'Candidate verification requires a connected native ARM64 Android device.'
}

function ConvertTo-GodotEscapedString {
    param([Parameter(Mandatory)] [string]$Value)
    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function Set-GodotEditorSetting {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Value
    )
    $escapedValue = ConvertTo-GodotEscapedString -Value $Value
    $line = "$Name = `"$escapedValue`""
    $content = if (Test-Path -LiteralPath $Path) {
        Get-Content -Raw -LiteralPath $Path
    }
    else {
        "[gd_resource type=`"EditorSettings`" format=3]`r`n`r`n[resource]`r`n"
    }
    $pattern = "(?m)^$([regex]::Escape($Name))\s*=.*$"
    if ($content -match $pattern) {
        $content = $content -replace $pattern, $line
    }
    else {
        if ($content -notmatch '(?m)^\[resource\]\s*$') {
            $content += "`r`n[resource]`r`n"
        }
        if (-not $content.EndsWith("`n")) {
            $content += "`r`n"
        }
        $content += "$line`r`n"
    }
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function Assert-PathInside {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$Path
    )
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith(
        $rootFull,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Unsafe candidate build path: $pathFull"
    }
}

$serial = Select-NativeArm64Device
$candidatePayload = Get-Content -Raw -LiteralPath $candidate | ConvertFrom-Json
$decks = @($candidatePayload.release_decks | ForEach-Object { [string]$_ })
if ($decks.Count -ne 10) {
    throw 'Android candidate verification requires the complete ten-model set.'
}
foreach ($deck in $decks) {
    $modelPath = Join-Path $candidateModels "$deck.onnx"
    if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
        throw "Candidate ONNX is missing: $modelPath"
    }
}

$buildParent = Join-Path $runDir 'staging\android_candidate_builds'
$attempt = (
    [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') +
    "-$PID"
)
$attemptRoot = Join-Path $buildParent $attempt
$projectRoot = Join-Path $attemptRoot 'godot'
$apkPath = Join-Path $attemptRoot 'PokemonTCG-candidate-smoke.apk'
Assert-PathInside -Root $runDir -Path $attemptRoot
New-Item -ItemType Directory -Force -Path $projectRoot | Out-Null

$installed = $false
try {
    $excludeDirectories = @(
        (Join-Path $sourceProject '.godot'),
        (Join-Path $sourceProject 'dist'),
        (Join-Path $sourceProject 'android')
    )
    $copyRows = @(
        & robocopy `
            $sourceProject `
            $projectRoot `
            /E `
            /NFL `
            /NDL `
            /NJH `
            /NJS `
            /NP `
            /XD $excludeDirectories `
            /XF '*.onnx'
    )
    $copyExit = $LASTEXITCODE
    if ($copyExit -gt 7) {
        throw "Unable to stage the candidate Godot project (robocopy $copyExit)."
    }

    $stageData = Join-Path $projectRoot 'data'
    $stageModels = Join-Path $stageData 'ai_models'
    New-Item -ItemType Directory -Force -Path $stageModels | Out-Null
    Copy-Item -LiteralPath $candidate -Destination (
        Join-Path $stageData 'candidate_manifest.json')
    Copy-Item -LiteralPath $release -Destination (
        Join-Path $stageData 'release_manifest.json') -Force
    foreach ($deck in $decks) {
        Copy-Item `
            -LiteralPath (Join-Path $candidateModels "$deck.onnx") `
            -Destination (Join-Path $stageModels "$deck.onnx") `
            -Force
    }
    $runtimePayload = Get-Content -Raw -LiteralPath $runtime | ConvertFrom-Json
    foreach ($deck in $decks) {
        $runtimePayload.models.$deck.onnx_path = (
            "res://data/ai_models/$deck.onnx"
        )
    }
    $runtimePayload |
        ConvertTo-Json -Depth 100 |
        Set-Content `
            -LiteralPath (Join-Path $stageData 'ai_models_runtime.json') `
            -Encoding UTF8

    $androidRoot = Join-Path $projectRoot 'android'
    $androidBuildRoot = Join-Path $androidRoot 'build'
    $templateArchive = Join-Path $godotPaths.TemplateRoot 'android_source.zip'
    if (-not (Test-Path -LiteralPath $templateArchive -PathType Leaf)) {
        throw 'Godot Android source template is missing.'
    }
    New-Item -ItemType Directory -Force -Path $androidBuildRoot | Out-Null
    Expand-Archive `
        -LiteralPath $templateArchive `
        -DestinationPath $androidBuildRoot `
        -Force
    Set-Content `
        -LiteralPath (Join-Path $androidRoot '.build_version') `
        -Value $lock.godot.full_config `
        -Encoding UTF8
    Set-Content `
        -LiteralPath (Join-Path $androidBuildRoot '.gdignore') `
        -Value '' `
        -Encoding UTF8

    $gradleZip = Join-Path $downloadsRoot (
        "gradle-$($lock.gradle.version)-bin.zip"
    )
    New-Item -ItemType Directory -Force -Path $downloadsRoot | Out-Null
    Get-VerifiedDownload `
        -Uri $lock.gradle.url `
        -Destination $gradleZip `
        -Sha256 $lock.gradle.sha256
    $wrapperProperties = Join-Path (
        $androidBuildRoot
    ) 'gradle\wrapper\gradle-wrapper.properties'
    $wrapperContent = Get-Content -Raw -LiteralPath $wrapperProperties
    $gradleUri = ([System.Uri]::new($gradleZip)).AbsoluteUri.Replace('\', '/')
    $wrapperContent = $wrapperContent -replace (
        '(?m)^distributionUrl=.*$'
    ), "distributionUrl=$gradleUri"
    if ($wrapperContent -notmatch '(?m)^networkTimeout=') {
        $wrapperContent += "`r`nnetworkTimeout=600000`r`n"
    }
    Set-Content `
        -LiteralPath $wrapperProperties `
        -Value $wrapperContent `
        -Encoding UTF8

    $gradleProperties = Join-Path $androidBuildRoot 'gradle.properties'
    $gradleContent = Get-Content -Raw -LiteralPath $gradleProperties
    foreach ($row in @(
        @('org.gradle.jvmargs', '-Xmx8192m -Dfile.encoding=UTF-8'),
        @('org.gradle.workers.max', '1'),
        @('org.gradle.daemon', 'false')
    )) {
        $name = [string]$row[0]
        $value = [string]$row[1]
        $pattern = "(?m)^$([regex]::Escape($name))=.*$"
        if ($gradleContent -match $pattern) {
            $gradleContent = $gradleContent -replace $pattern, "$name=$value"
        }
        else {
            $gradleContent += "`r`n$name=$value`r`n"
        }
    }
    Set-Content `
        -LiteralPath $gradleProperties `
        -Value $gradleContent `
        -Encoding UTF8

    $env:JAVA_HOME = $jdkRoot
    $env:ANDROID_HOME = $sdkRoot
    $env:ANDROID_SDK_ROOT = $sdkRoot
    $env:GRADLE_USER_HOME = Join-Path $repoRoot '.tools\gradle-home'
    $env:Path = (
        "$(Join-Path $jdkRoot 'bin');" +
        "$(Join-Path $sdkRoot 'platform-tools');$env:Path"
    )
    New-Item `
        -ItemType Directory `
        -Force `
        -Path (Split-Path -Parent $godotPaths.EditorSettings) |
        Out-Null
    Set-GodotEditorSetting `
        -Path $godotPaths.EditorSettings `
        -Name 'export/android/android_sdk_path' `
        -Value ([System.IO.Path]::GetFullPath($sdkRoot))
    Set-GodotEditorSetting `
        -Path $godotPaths.EditorSettings `
        -Name 'export/android/java_sdk_path' `
        -Value ([System.IO.Path]::GetFullPath($jdkRoot))

    & $godot `
        --headless `
        --path $projectRoot `
        --export-debug `
        'Android ARM64 Deep Candidate Smoke' `
        $apkPath
    if ($LASTEXITCODE -ne 0) {
        throw "Candidate Android export failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) {
        throw 'Candidate Android export did not produce an APK.'
    }

    $installRows = @(& $adb -s $serial install -r $apkPath 2>&1)
    $installText = $installRows -join "`n"
    if ($LASTEXITCODE -ne 0) {
        if ($installText.Contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')) {
            & $adb -s $serial uninstall $candidatePackage | Out-Host
            & $adb -s $serial install $apkPath | Out-Host
            if ($LASTEXITCODE -ne 0) {
                throw 'Unable to clean-install the isolated candidate APK.'
            }
        }
        else {
            throw "Unable to install candidate APK.`n$installText"
        }
    }
    $installed = $true

    & $adb -s $serial logcat -c
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to clear Android logcat.'
    }
    & $adb -s $serial shell am force-stop $candidatePackage
    & $adb -s $serial shell monkey -p $candidatePackage 1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to launch the candidate runtime smoke.'
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(
        [Math]::Max(30, $TimeoutSeconds)
    )
    $logRows = @()
    $complete = $false
    do {
        Start-Sleep -Seconds 2
        $logRows = @(
            & $adb -s $serial logcat -d -v brief `
                'godot:V' 'GodotActivity:V' 'AndroidRuntime:E' '*:S'
        )
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to read Android candidate logcat.'
        }
        $logText = $logRows -join "`n"
        if ($logText.Contains('CANDIDATE_RUNTIME_SMOKE passed=')) {
            $complete = $true
            break
        }
        if ($logText -match 'FATAL EXCEPTION|Fatal signal|SIGABRT|native crash') {
            $tail = ($logRows | Select-Object -Last 120) -join "`n"
            throw "Android candidate runtime crashed.`n$tail"
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $complete) {
        $tail = ($logRows | Select-Object -Last 120) -join "`n"
        throw "Android candidate runtime timed out.`n$tail"
    }

    $chunks = @{}
    $expectedChunks = 0
    foreach ($line in $logRows) {
        $match = [regex]::Match(
            [string]$line,
            'CANDIDATE_RUNTIME_EVIDENCE_CHUNK\s+(\d+)/(\d+)\s+([A-Za-z0-9+/=]+)'
        )
        if (-not $match.Success) {
            continue
        }
        $index = [int]$match.Groups[1].Value
        $expectedChunks = [int]$match.Groups[2].Value
        $chunks[$index] = $match.Groups[3].Value
    }
    if (
        $expectedChunks -le 0 -or
        $chunks.Count -ne $expectedChunks
    ) {
        throw "Android candidate evidence chunks are incomplete ($($chunks.Count)/$expectedChunks)."
    }
    $encoded = (
        1..$expectedChunks |
            ForEach-Object { [string]$chunks[$_] }
    ) -join ''
    $jsonText = [System.Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($encoded)
    )
    $evidence = $jsonText | ConvertFrom-Json
    $expectedCandidateSha = (
        Get-FileHash -LiteralPath $candidate -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if (
        [string]$evidence.kind -ne 'candidate_runtime_inference_v1' -or
        [string]$evidence.platform -ne 'android' -or
        [string]$evidence.architecture -notin @('arm64', 'arm64-v8a', 'aarch64') -or
        [string]$evidence.candidate_manifest_sha256 -ne $expectedCandidateSha
    ) {
        throw 'Android candidate evidence identity is invalid.'
    }
    New-Item -ItemType Directory -Force -Path (
        Split-Path -Parent $output) | Out-Null
    [System.IO.File]::WriteAllText(
        $output,
        ($evidence | ConvertTo-Json -Depth 100) + "`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    if (-not [bool]$evidence.passed) {
        throw (
            'Android candidate load/infer failed: ' +
            (@($evidence.errors) -join ',')
        )
    }
    Write-Host (
        "HYBRID_ANDROID_RUNTIME_OK run_id=$RunId serial=$serial " +
        "models=$($evidence.model_count) output=$output"
    )
}
finally {
    if ($installed) {
        & $adb -s $serial uninstall $candidatePackage | Out-Null
    }
    if (-not $KeepBuild -and (Test-Path -LiteralPath $attemptRoot)) {
        Assert-PathInside -Root $runDir -Path $attemptRoot
        Remove-Item -LiteralPath $attemptRoot -Recurse -Force
    }
}
