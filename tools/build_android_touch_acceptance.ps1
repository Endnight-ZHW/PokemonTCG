[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$acceptanceRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'godot_test_common.ps1')
$acceptanceGodot = (Initialize-GodotTestEnvironment -RepoRoot $acceptanceRoot).Console
$acceptanceProject = Join-Path $acceptanceRoot 'godot'
$acceptanceSettings = Join-Path $acceptanceProject 'project.godot'
$acceptancePresets = Join-Path $acceptanceProject 'export_presets.cfg'
$settingsBytes = [IO.File]::ReadAllBytes($acceptanceSettings)
$presetsBytes = [IO.File]::ReadAllBytes($acceptancePresets)
$acceptanceOutput = Join-Path $acceptanceRoot 'build/android-tablet-test'
New-Item -ItemType Directory -Force -Path $acceptanceOutput | Out-Null
$acceptanceUtf8 = [Text.UTF8Encoding]::new($false)
try {
    $settingsText = $acceptanceUtf8.GetString($settingsBytes)
    $settingsText = $settingsText -replace '(?m)^run/main_scene=.*$', 'run/main_scene="res://tests/android_touch_acceptance.tscn"'
    $presetsText = $acceptanceUtf8.GetString($presetsBytes)
    $presetsText = $presetsText.Replace('package/unique_name="com.pokemontcg.game"', 'package/unique_name="com.pokemontcg.touchtest"')
    $presetsText = $presetsText.Replace('package/name="PokemonTCG"', 'package/name="PTCG Touch Test"')
    $presetsText = $presetsText.Replace('authoring/*,tests/*,tools/*,dist/*,android/*', 'authoring/*,dist/*,android/*')
    [IO.File]::WriteAllText($acceptanceSettings, $settingsText, $acceptanceUtf8)
    [IO.File]::WriteAllText($acceptancePresets, $presetsText, $acceptanceUtf8)
    & $acceptanceGodot --headless --path $acceptanceProject --import
    if ($LASTEXITCODE -ne 0) { throw 'Android acceptance import failed' }
    & $acceptanceGodot --headless --path $acceptanceProject --export-release 'Android ARM64' (Join-Path $acceptanceOutput 'PokemonTCG-Touch-Acceptance.apk')
    if ($LASTEXITCODE -ne 0) { throw 'Android acceptance export failed' }
} finally {
    [IO.File]::WriteAllBytes($acceptanceSettings, $settingsBytes)
    [IO.File]::WriteAllBytes($acceptancePresets, $presetsBytes)
}
