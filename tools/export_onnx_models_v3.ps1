[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Checkpoint,
    [string]$Output = 'build\ai_models_v3\universal.onnx',
    [string]$Manifest = 'build\ai_models_v3\ai_models_runtime.json',
    [string]$CondaEnv = 'DL',
    [string]$EvidenceSha256 = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$conda = Get-Command conda.exe -ErrorAction Stop
$script = Join-Path $repoRoot 'python\scripts\export_onnx_models_v3.py'
$checkpointPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $Checkpoint))
$outputPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $Output))
$manifestPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $Manifest))
& $conda.Source run -n $CondaEnv python -B $script `
    --checkpoint $checkpointPath `
    --output $outputPath `
    --manifest $manifestPath `
    --evidence-sha256 $EvidenceSha256
if ($LASTEXITCODE -ne 0) {
    throw "Deep AI v3 ONNX export failed with exit code $LASTEXITCODE"
}
