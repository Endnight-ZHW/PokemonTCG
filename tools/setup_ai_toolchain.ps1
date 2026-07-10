[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$pythonRoot = Join-Path $toolsRoot 'python311'
$pythonExe = Join-Path $pythonRoot 'python.exe'
$env:PYTHONNOUSERSITE = '1'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot

$conda = Get-Command conda -ErrorAction SilentlyContinue
if (-not $conda) {
    throw 'Conda is required to create the project-local Python 3.11 environment.'
}

if ($Force -and (Test-Path -LiteralPath $pythonRoot)) {
    Assert-PathUnderRoot -Root $toolsRoot -Path $pythonRoot
    & $conda.Source env remove --prefix $pythonRoot --yes
}

if (-not (Test-Path -LiteralPath $pythonExe)) {
    & $conda.Source create --prefix $pythonRoot --yes "python=$($lock.python.version)" pip
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to create the project-local Python environment.'
    }
}

$actualPython = (& $pythonExe -c 'import platform; print(platform.python_version())').Trim()
if ($LASTEXITCODE -ne 0 -or $actualPython -ne [string]$lock.python.version) {
    throw "Pinned Python $($lock.python.version) is required; found '$actualPython'. Re-run with -Force."
}

& $pythonExe -m pip install --disable-pip-version-check --upgrade `
    "numpy==$($lock.python.numpy)" `
    "scons==$($lock.python.scons)" `
    "websockets==$($lock.python.websockets)" `
    "pygame==$($lock.python.pygame)" `
    "requests==$($lock.python.requests)" `
    "pillow==$($lock.python.pillow)" `
    "onnx==$($lock.python.onnx)" `
    "onnxruntime==$($lock.python.onnxruntime)"
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to install ONNX build dependencies.'
}

& $pythonExe -m pip install --disable-pip-version-check `
    "torch==$($lock.python.torch)" `
    --index-url 'https://download.pytorch.org/whl/cpu'
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to install the pinned CPU PyTorch build.'
}

Write-Host "Python: $pythonExe"
& $pythonExe -c @'
import onnx
import onnxruntime
import numpy
import SCons
import torch
print(f"torch={torch.__version__}")
print(f"numpy={numpy.__version__}")
print(f"onnx={onnx.__version__}")
print(f"onnxruntime={onnxruntime.__version__}")
print(f"scons={SCons.__version__}")
'@
