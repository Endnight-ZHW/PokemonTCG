[CmdletBinding()]
param([ValidateRange(1, 64)][int]$Jobs = 4)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$portablePython = Join-Path $repoRoot '.tools\python311\python.exe'
$pythonCommand = if (Test-Path -LiteralPath $portablePython) {
    $portablePython
} else {
    (Get-Command python -ErrorAction Stop).Source
}
$sourceRoot = Join-Path $repoRoot 'native\challenge_core'
$jsonHeader = Join-Path $repoRoot '.tools\native\nlohmann-json\include\nlohmann\json.hpp'
if (-not (Test-Path -LiteralPath $jsonHeader)) {
    & (Join-Path $PSScriptRoot 'setup_native_ai_deps.ps1')
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
$vsDevCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
$arguments = @('-m', 'SCons', "-j$Jobs", "--directory=$sourceRoot") | ForEach-Object {
    if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
}
$command = "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && `"$pythonCommand`" $($arguments -join ' ')"
& cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) {
    throw 'Challenge core build failed.'
}

& (Join-Path $sourceRoot 'bin\challenge_core_tests.exe') `
    (Join-Path $repoRoot 'godot\data\ai_strategies.json') `
    (Join-Path $repoRoot 'godot\data\cards.json') `
    (Join-Path $sourceRoot 'tests\fixtures\challenge_tactics.json')
if ($LASTEXITCODE -ne 0) {
    throw 'Challenge core tactics failed.'
}
