[CmdletBinding()]
param([ValidateRange(1, 64)][int]$Jobs = 4)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$python = Join-Path $repoRoot '.tools\python311\python.exe'
$sourceRoot = Join-Path $repoRoot 'godot\native\ptcg_core'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = if (Test-Path -LiteralPath $vswhere) {
    & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
}
$vsDevCmd = if ($vsPath) {
    Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
} else {
    ''
}
if (-not (Test-Path -LiteralPath $python)) {
    throw 'Pinned Python/SCons toolchain is missing.'
}
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
    "`"$python`" $($args -join ' ')"
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
