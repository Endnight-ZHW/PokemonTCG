[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$python = Join-Path $repoRoot '.tools\python311\python.exe'
$env:PYTHONNOUSERSITE = '1'
if (-not (Test-Path -LiteralPath $python)) {
    throw 'AI Python toolchain is missing. Run tools/setup_ai_toolchain.ps1 first.'
}
$arguments = @('-B', (Join-Path $repoRoot 'scripts\export_onnx_models.py'))
if ($Check) {
    $arguments += '--check'
}
& $python @arguments
if ($LASTEXITCODE -ne 0) {
    throw "ONNX export failed with exit code $LASTEXITCODE"
}
