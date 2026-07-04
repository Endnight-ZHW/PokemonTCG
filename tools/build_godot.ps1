[CmdletBinding()]
param(
    [ValidateSet('windows', 'android', 'all')]
    [string]$Target = 'all',
    [ValidateSet('debug', 'release')]
    [string]$Configuration = 'debug'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path $repoRoot 'godot'
$godot = Join-Path $repoRoot '.tools\godot-4.7\Godot_v4.7-stable_win64_console.exe'
$jdkRoot = Join-Path $repoRoot '.tools\jdk-17'
$sdkRoot = Join-Path $repoRoot '.tools\android-sdk'
$downloadsRoot = Join-Path $repoRoot '.tools\downloads'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
Set-PortableGodotEnvironment -ToolsRoot (Join-Path $repoRoot '.tools')

if (-not (Test-Path -LiteralPath $godot)) {
    throw 'Godot 4.7 is not installed. Run tools/setup_godot_toolchain.ps1 first.'
}

function Invoke-GodotExport {
    param(
        [string]$Preset,
        [string]$Output,
        [switch]$InstallAndroidBuildTemplate
    )
    $outputPath = Join-Path $projectRoot $Output
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputPath) | Out-Null
    $flag = if ($Configuration -eq 'release') { '--export-release' } else { '--export-debug' }
    $arguments = @('--headless', '--path', $projectRoot)
    if ($InstallAndroidBuildTemplate) {
        $arguments += '--install-android-build-template'
    }
    $arguments += @($flag, $Preset, $outputPath)
    & $godot @arguments
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "Godot export failed for $Preset with exit code $exitCode"
    }
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
    } else {
        "[gd_resource type=`"EditorSettings`" format=3]`r`n`r`n[resource]`r`n"
    }
    $pattern = "(?m)^$([regex]::Escape($Name))\s*=.*$"
    if ($content -match $pattern) {
        $content = $content -replace $pattern, $line
    } else {
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

function Set-GodotAndroidEditorSettings {
    param(
        [Parameter(Mandatory)] [string]$ToolsRoot,
        [Parameter(Mandatory)] [string]$AndroidSdkRoot,
        [Parameter(Mandatory)] [string]$JavaSdkRoot
    )
    $settingsPath = Join-Path $ToolsRoot 'appdata\Godot\editor_settings-4.7.tres'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settingsPath) | Out-Null
    Set-GodotEditorSetting `
        -Path $settingsPath `
        -Name 'export/android/android_sdk_path' `
        -Value ([System.IO.Path]::GetFullPath($AndroidSdkRoot))
    Set-GodotEditorSetting `
        -Path $settingsPath `
        -Name 'export/android/java_sdk_path' `
        -Value ([System.IO.Path]::GetFullPath($JavaSdkRoot))
    Write-Host "ANDROID_EDITOR_SETTINGS_OK path=$settingsPath"
}

if ($Target -in @('windows', 'all')) {
    $windowsOutput = if ($Configuration -eq 'release') {
        'dist/release/windows/PokemonTCG.exe'
    } else {
        'dist/windows/PokemonTCG.exe'
    }
    Invoke-GodotExport -Preset 'Windows Desktop' -Output $windowsOutput
}

if ($Target -in @('android', 'all')) {
    if (-not (Test-Path -LiteralPath (Join-Path $jdkRoot 'bin\java.exe'))) {
        throw 'JDK 17 is not installed. Run tools/setup_android_toolchain.ps1 first.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $sdkRoot 'platform-tools\adb.exe'))) {
        throw 'Android SDK is not installed. Run tools/setup_android_toolchain.ps1 first.'
    }
    $env:JAVA_HOME = $jdkRoot
    $env:ANDROID_HOME = $sdkRoot
    $env:ANDROID_SDK_ROOT = $sdkRoot
    $env:GRADLE_USER_HOME = Join-Path $repoRoot '.tools\gradle-home'
    $env:Path = "$(Join-Path $jdkRoot 'bin');$(Join-Path $sdkRoot 'platform-tools');$env:Path"
    Set-GodotAndroidEditorSettings `
        -ToolsRoot (Join-Path $repoRoot '.tools') `
        -AndroidSdkRoot $sdkRoot `
        -JavaSdkRoot $jdkRoot
    $androidRoot = Join-Path $projectRoot 'android'
    $androidBuildRoot = Join-Path $androidRoot 'build'
    $buildVersionPath = Join-Path $androidRoot '.build_version'
    $installedBuildVersion = if (Test-Path -LiteralPath $buildVersionPath) {
        (Get-Content -Raw -LiteralPath $buildVersionPath).Trim()
    } else {
        ''
    }
    $needsTemplate = (
        -not (Test-Path -LiteralPath (Join-Path $androidBuildRoot 'build.gradle')) -or
        $installedBuildVersion -ne $lock.godot.full_config
    )
    if ($needsTemplate) {
        $templateArchive = Join-Path $env:APPDATA 'Godot\export_templates\4.7.stable\android_source.zip'
        if (-not (Test-Path -LiteralPath $templateArchive)) {
            throw 'Godot Android source template is missing. Re-run tools/setup_godot_toolchain.ps1.'
        }
        New-Item -ItemType Directory -Force -Path $androidRoot | Out-Null
        New-Item -ItemType Directory -Force -Path $androidBuildRoot | Out-Null
        Expand-Archive -LiteralPath $templateArchive -DestinationPath $androidBuildRoot -Force
        Set-Content -LiteralPath $buildVersionPath -Value $lock.godot.full_config -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $androidBuildRoot '.gdignore') -Value '' -Encoding UTF8
    }

    $gradleZip = Join-Path $downloadsRoot "gradle-$($lock.gradle.version)-bin.zip"
    New-Item -ItemType Directory -Force -Path $downloadsRoot | Out-Null
    Get-VerifiedDownload -Uri $lock.gradle.url -Destination $gradleZip `
        -Sha256 $lock.gradle.sha256
    $wrapperProperties = Join-Path $projectRoot 'android\build\gradle\wrapper\gradle-wrapper.properties'
    if (Test-Path -LiteralPath $wrapperProperties) {
        $gradleUri = ([System.Uri]::new($gradleZip)).AbsoluteUri.Replace('\', '/')
        $wrapperContent = Get-Content -Raw -LiteralPath $wrapperProperties
        $wrapperContent = $wrapperContent -replace '(?m)^distributionUrl=.*$', "distributionUrl=$gradleUri"
        if ($wrapperContent -notmatch '(?m)^networkTimeout=') {
            $wrapperContent += "`r`nnetworkTimeout=600000`r`n"
        }
        Set-Content -LiteralPath $wrapperProperties -Value $wrapperContent -Encoding UTF8
    }
    $gradleProperties = Join-Path $projectRoot 'android\build\gradle.properties'
    if (Test-Path -LiteralPath $gradleProperties) {
        $gradleContent = Get-Content -Raw -LiteralPath $gradleProperties
        $requiredGradleProperties = [ordered]@{
            'org.gradle.jvmargs' = '-Xmx8192m -Dfile.encoding=UTF-8'
            'org.gradle.workers.max' = '1'
            'org.gradle.daemon' = 'false'
        }
        foreach ($propertyName in $requiredGradleProperties.Keys) {
            $propertyValue = $requiredGradleProperties[$propertyName]
            $propertyPattern = "(?m)^$([regex]::Escape($propertyName))=.*$"
            if ($gradleContent -match $propertyPattern) {
                $gradleContent = $gradleContent -replace $propertyPattern, "$propertyName=$propertyValue"
            } else {
                $gradleContent += "`r`n$propertyName=$propertyValue`r`n"
            }
        }
        Set-Content -LiteralPath $gradleProperties -Value $gradleContent -Encoding UTF8
    }
    $androidOutput = if ($Configuration -eq 'release') {
        'dist/release/android/PokemonTCG.apk'
    } else {
        'dist/android/PokemonTCG.apk'
    }
    Invoke-GodotExport `
        -Preset 'Android ARM64' `
        -Output $androidOutput
}
