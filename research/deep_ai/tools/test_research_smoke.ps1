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
& (Join-Path $PSScriptRoot 'build_challenge_agent.ps1') `
    -AgentId 'challenge_next' -BuildId 'working-tree' -Python $Python
if ($LASTEXITCODE -ne 0) { throw 'Research current Agent build failed.' }
$env:PYTHONNOUSERSITE = '1'
$env:PYTHONPATH = @(
    (Join-Path $researchRoot 'build\native'),
    (Join-Path $researchRoot 'python'),
    $researchRoot
) -join [IO.Path]::PathSeparator
& $Python -B -m unittest -q `
    tests.test_research_smoke `
    tests.test_challenge_arena_tasks `
    tests.test_challenge_arena_stats `
    tests.test_challenge_arena_build `
    tests.test_challenge_arena_store `
    tests.test_challenge_arena_determinism `
    tests.test_challenge_controller `
    tests.test_challenge_agent_protocol `
    tests.test_deep_arena_fairness
if ($LASTEXITCODE -ne 0) { throw 'Deep AI manual smoke workflow failed.' }
Write-Host 'DEEP_AI_RESEARCH_SMOKE_OK'
