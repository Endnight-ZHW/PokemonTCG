[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Configuration = 'release'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$relayRoot = Join-Path $repoRoot 'native/relay_server'
$portablePython = Join-Path $repoRoot '.tools/python311/python.exe'
$python = if (Test-Path -LiteralPath $portablePython) { $portablePython } else { 'python' }

if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.tools/native/boost_1_92_0/boost/beast.hpp'))) {
    & (Join-Path $PSScriptRoot 'setup_relay_deps.ps1')
}
& $python -m SCons -C $relayRoot "configuration=$Configuration"
if ($LASTEXITCODE -ne 0) {
    throw "Relay build failed with exit code $LASTEXITCODE."
}
