[CmdletBinding()]
param(
    [switch]$Check,
    [string]$CondaEnv = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$python = Join-Path $repoRoot '.tools\python311\python.exe'
$env:PYTHONNOUSERSITE = '1'
$arguments = @('-B', (Join-Path $repoRoot 'python\scripts\export_onnx_models.py'))
if ($Check) {
    $arguments += '--check'
}
if (-not [string]::IsNullOrWhiteSpace($CondaEnv)) {
    $conda = Get-Command conda -ErrorAction SilentlyContinue
    if (-not $conda) {
        throw "Conda is required when -CondaEnv $CondaEnv is used."
    }
    & $conda.Source run -n $CondaEnv python @arguments
} else {
    if (-not (Test-Path -LiteralPath $python)) {
        throw 'AI Python toolchain is missing. Run tools/setup_ai_toolchain.ps1 first.'
    }
    & $python @arguments
}
if ($LASTEXITCODE -ne 0) {
    throw "ONNX export failed with exit code $LASTEXITCODE"
}
