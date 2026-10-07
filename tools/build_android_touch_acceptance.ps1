[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Configuration = 'release',
    [string]$OutputDirectory = 'build/android-tablet-test',
    [ValidateRange(0, 1800)]
    [int]$SoakSeconds = 0,
    [ValidateSet('', 'gl_compatibility', 'mobile')]
    [string]$RenderingMethod = ''
)

$ErrorActionPreference = 'Stop'
$acceptanceRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'godot_test_common.ps1')
$acceptanceGodot = (Initialize-GodotTestEnvironment -RepoRoot $acceptanceRoot).Console
$acceptanceProject = Join-Path $acceptanceRoot 'godot'
$acceptanceSettings = Join-Path $acceptanceProject 'project.godot'
$acceptancePresets = Join-Path $acceptanceProject 'export_presets.cfg'
$settingsBytes = [IO.File]::ReadAllBytes($acceptanceSettings)
$presetsBytes = [IO.File]::ReadAllBytes($acceptancePresets)
$acceptanceOutput = Join-Path $acceptanceRoot $OutputDirectory
Assert-PathUnderRoot -Root $acceptanceRoot -Path $acceptanceOutput
New-Item -ItemType Directory -Force -Path $acceptanceOutput | Out-Null
$acceptanceUtf8 = [Text.UTF8Encoding]::new($false)
try {
    $settingsText = $acceptanceUtf8.GetString($settingsBytes)
    $settingsText = $settingsText -replace '(?m)^run/main_scene=.*$', 'run/main_scene="res://tests/android_touch_acceptance.tscn"'
    if ($RenderingMethod) {
        $settingsText = $settingsText -replace '(?m)^renderer/rendering_method.mobile=.*$', "renderer/rendering_method.mobile=`"$RenderingMethod`""
    }
    $presetsText = $acceptanceUtf8.GetString($presetsBytes)
    $presetsText = $presetsText.Replace('package/unique_name="com.pokemontcg.game"', 'package/unique_name="com.pokemontcg.touchtest"')
    $presetsText = $presetsText.Replace('package/name="PokemonTCG"', 'package/name="PTCG Touch Test"')
    $presetsText = $presetsText.Replace('authoring/*,tests/*,tools/*,dist/*,android/*', 'authoring/*,dist/*,android/*')
    $presetsText = $presetsText -replace '(?m)^command_line/extra_args=.*$', "command_line/extra_args=`"-- --tablet-soak-seconds=$SoakSeconds`""
    [IO.File]::WriteAllText($acceptanceSettings, $settingsText, $acceptanceUtf8)
    [IO.File]::WriteAllText($acceptancePresets, $presetsText, $acceptanceUtf8)
    & $acceptanceGodot --headless --path $acceptanceProject --import
    if ($LASTEXITCODE -ne 0) { throw 'Android acceptance import failed' }
    $exportFlag = if ($Configuration -eq 'debug') { '--export-debug' } else { '--export-release' }
    & $acceptanceGodot --headless --path $acceptanceProject $exportFlag 'Android ARM64' (Join-Path $acceptanceOutput 'PokemonTCG-Touch-Acceptance.apk')
    if ($LASTEXITCODE -ne 0) { throw 'Android acceptance export failed' }
} finally {
    [IO.File]::WriteAllBytes($acceptanceSettings, $settingsBytes)
    [IO.File]::WriteAllBytes($acceptancePresets, $presetsBytes)
}
