[CmdletBinding()]
param([ValidateRange(1, 64)][int]$Jobs = 4)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'tools\toolchain_common.ps1')
$pythonCommand = Resolve-ProjectPython -RepoRoot $repoRoot
$sourceRoot = Join-Path $repoRoot 'native\challenge_core'
$jsonHeader = Join-Path $repoRoot '.tools\native\nlohmann-json\include\nlohmann\json.hpp'
if (-not (Test-Path -LiteralPath $jsonHeader)) {
    & (Join-Path $PSScriptRoot 'setup_native_ai_deps.ps1')
}

$vsDevCmd = Get-VisualCppDevCommand
if (-not (Test-Path -LiteralPath $vsDevCmd)) { throw 'Visual C++ Build Tools are missing.' }
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
