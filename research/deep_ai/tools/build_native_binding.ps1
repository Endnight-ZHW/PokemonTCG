[CmdletBinding()]
param(
    [string]$Python = '',
    [ValidateRange(1, 64)]
    [int]$Jobs = 4
)

$ErrorActionPreference = 'Stop'
$researchRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $researchRoot)
. (Join-Path $repoRoot 'tools\toolchain_common.ps1')
$Python = Resolve-ProjectPython -RepoRoot $repoRoot -Python $Python
& $Python -c 'import pybind11, SCons' 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'The selected research Python needs pybind11 and SCons.'
}
$source = Join-Path $researchRoot 'native\python'
$output = Join-Path $researchRoot 'build\native'
$vsDevCmd = Get-VisualCppDevCommand
if (-not (Test-Path -LiteralPath $vsDevCmd)) {
    throw 'Visual C++ Build Tools are required for the research binding.'
}
$compilerCommand = "`"$vsDevCmd`" -arch=x64 -host_arch=x64 >nul && cl.exe 2>&1"
$compilerOutput = & cmd.exe /d /s /c $compilerCommand
$compiler = (($compilerOutput | Where-Object {
    [string]$_ -match 'Compiler Version'
} | Select-Object -First 1) -join ' ').Trim()
if ([string]::IsNullOrWhiteSpace($compiler)) {
    $compiler = ([string]($compilerOutput | Select-Object -First 1)).Trim()
}
if ([string]::IsNullOrWhiteSpace($compiler)) {
    $compiler = 'unknown-msvc'
}
$command = (
    "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && " +
    "`"$Python`" -m SCons -j$Jobs --directory=`"$source`" " +
    "output_root=`"$output`""
)
& cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) { throw 'Research native binding build failed.' }
$binding = Join-Path $output 'ptcg_ai_core.pyd'
$sidecar = Join-Path $output 'ptcg_ai_core.build.json'
$manifestScript = Join-Path $researchRoot 'scripts\challenge_arena_build.py'
& $Python -B $manifestScript write-binding `
    --repo-root $repoRoot `
    --binding $binding `
    --output $sidecar `
    --compiler $compiler | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Research native binding manifest failed.' }
Write-Host "RESEARCH_NATIVE_BINDING_OK path=$output"
