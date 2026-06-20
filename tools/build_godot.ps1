[CmdletBinding()]
param(
    [ValidateSet('windows', 'android', 'all')]
    [string]$Target = 'all',
    [ValidateSet('debug', 'release')]
    [string]$Configuration = 'debug'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path $repoRoot 'godot_client'
$godot = Join-Path $repoRoot '.tools\godot-4.7\Godot_v4.7-stable_win64_console.exe'
$jdkRoot = Join-Path $repoRoot '.tools\jdk-17'
$sdkRoot = Join-Path $repoRoot '.tools\android-sdk'
$downloadsRoot = Join-Path $repoRoot '.tools\downloads'

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

if ($Target -in @('windows', 'all')) {
    Invoke-GodotExport -Preset 'Windows Desktop' -Output 'dist/windows/PokemonTCG.exe'
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
    & $godot `
        --headless `
        --editor `
        --path $projectRoot `
        --script 'res://tools/configure_android_editor.gd' `
        -- `
        $sdkRoot `
        $jdkRoot
    $settingsExitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($settingsExitCode -ne 0) {
        throw "Unable to configure Godot Android editor settings (exit $settingsExitCode)"
    }
    $needsTemplate = -not (Test-Path -LiteralPath (Join-Path $projectRoot 'android\build\build.gradle'))
    if ($needsTemplate) {
        $templateArchive = Join-Path $env:APPDATA 'Godot\export_templates\4.7.stable\android_source.zip'
        if (-not (Test-Path -LiteralPath $templateArchive)) {
            throw 'Godot Android source template is missing. Re-run tools/setup_godot_toolchain.ps1.'
        }
        $androidBuildRoot = Join-Path $projectRoot 'android\build'
        New-Item -ItemType Directory -Force -Path $androidBuildRoot | Out-Null
        Expand-Archive -LiteralPath $templateArchive -DestinationPath $androidBuildRoot -Force
    }

    $gradleZip = Join-Path $downloadsRoot 'gradle-8.11.1-bin.zip'
    if (-not (Test-Path -LiteralPath $gradleZip)) {
        New-Item -ItemType Directory -Force -Path $downloadsRoot | Out-Null
        Invoke-WebRequest `
            -Uri 'https://services.gradle.org/distributions/gradle-8.11.1-bin.zip' `
            -OutFile $gradleZip
    }
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
        if ($gradleContent -notmatch '(?m)^org\.gradle\.daemon=') {
            $gradleContent += "`r`norg.gradle.daemon=false`r`n"
            Set-Content -LiteralPath $gradleProperties -Value $gradleContent -Encoding UTF8
        }
    }
    Invoke-GodotExport `
        -Preset 'Android ARM64' `
        -Output 'dist/android/PokemonTCG.apk'
}
