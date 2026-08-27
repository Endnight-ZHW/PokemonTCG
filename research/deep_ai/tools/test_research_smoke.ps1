[CmdletBinding()]
param([string]$Python = '')

$ErrorActionPreference = 'Stop'
$researchRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $researchRoot)
$portable = Join-Path $repoRoot '.tools\python311\python.exe'
if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = if (Test-Path -LiteralPath $portable) { $portable } else { 'python' }
}
& (Join-Path $PSScriptRoot 'build_native_binding.ps1') -Python $Python
if ($LASTEXITCODE -ne 0) { throw 'Research native binding build failed.' }
$env:PYTHONNOUSERSITE = '1'
$env:PYTHONPATH = @(
    (Join-Path $researchRoot 'build\native'),
    (Join-Path $researchRoot 'python'),
    $researchRoot
) -join [IO.Path]::PathSeparator
& $Python -B -m unittest -q tests.test_research_smoke
if ($LASTEXITCODE -ne 0) { throw 'Deep AI manual smoke workflow failed.' }
Write-Host 'DEEP_AI_RESEARCH_SMOKE_OK'
