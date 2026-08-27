[CmdletBinding()]
param(
    [ValidateRange(1, 64)][int]$Jobs = 4,
    [string]$Python = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$portablePython = Join-Path $repoRoot '.tools\python311\python.exe'
if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = if (Test-Path -LiteralPath $portablePython) {
        $portablePython
    } else {
        'python'
    }
}
$pythonCommand = if (Test-Path -LiteralPath $Python -PathType Leaf) {
    (Resolve-Path -LiteralPath $Python).Path
} else {
    (Get-Command $Python -ErrorAction Stop).Source
}
$sourceRoot = Join-Path $repoRoot 'native\challenge_core'
$generated = Join-Path $repoRoot '.test_tmp\challenge_core\challenge_tactics.bin'
& $pythonCommand -B `
    (Join-Path $repoRoot 'python\scripts\generate_challenge_tactics_cpp.py') `
    --output $generated
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to generate the Challenge tactics C++ fixture.'
}

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
$vsDevCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
$arguments = @(
    '-m', 'SCons', "-j$Jobs", "--directory=$sourceRoot"
) | ForEach-Object {
    if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
}
$command = (
    "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && " +
    "`"$pythonCommand`" $($arguments -join ' ')"
)
& cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) {
    throw 'Challenge core build failed.'
}
& (Join-Path $sourceRoot 'bin\challenge_core_tests.exe') $generated
if ($LASTEXITCODE -ne 0) {
    throw 'Challenge core tactics failed.'
}
