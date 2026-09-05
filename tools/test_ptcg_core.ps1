[CmdletBinding()]
param(
    [ValidateRange(1, 64)][int]$Jobs = 4,
    [string]$Python = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'tools\toolchain_common.ps1')
$pythonCommand = Resolve-ProjectPython -RepoRoot $repoRoot -Python $Python
$sourceRoot = Join-Path $repoRoot 'native\ptcg_core'
$vsDevCmd = Get-VisualCppDevCommand
if (-not (Test-Path -LiteralPath $vsDevCmd)) {
    throw 'Visual C++ Build Tools are missing.'
}
$args = @(
    '-m', 'SCons', "-j$Jobs", "--directory=$sourceRoot"
) | ForEach-Object {
    if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
}
$command = (
    "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && " +
    "`"$pythonCommand`" $($args -join ' ')"
)
& cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) {
    throw 'ptcg_core dependency-free build failed.'
}
$testBinary = Join-Path $sourceRoot 'bin\ptcg_core_tests.exe'
if (-not (Test-Path -LiteralPath $testBinary)) {
    throw 'ptcg_core test binary is missing.'
}
& $testBinary
if ($LASTEXITCODE -ne 0) {
    throw 'ptcg_core tests failed.'
}
