[CmdletBinding()]
param(
    [string]$Python = '',
    [ValidateRange(1, 64)]
    [int]$Jobs = 4
)

$ErrorActionPreference = 'Stop'
$researchRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $researchRoot)
$portable = Join-Path $repoRoot '.tools\python311\python.exe'
if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = if (Test-Path -LiteralPath $portable) { $portable } else { 'python' }
}
& $Python -c 'import pybind11, SCons' 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'The selected research Python needs pybind11 and SCons.'
}
$source = Join-Path $researchRoot 'native\python'
$output = Join-Path $researchRoot 'build\native'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = if (Test-Path -LiteralPath $vswhere) {
    & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
}
$vsDevCmd = if ($vsPath) { Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat' } else { '' }
if (-not (Test-Path -LiteralPath $vsDevCmd)) {
    throw 'Visual C++ Build Tools are required for the research binding.'
}
$command = (
    "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && " +
    "`"$Python`" -m SCons -j$Jobs --directory=`"$source`" " +
    "output_root=`"$output`""
)
& cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) { throw 'Research native binding build failed.' }
Write-Host "RESEARCH_NATIVE_BINDING_OK path=$output"
