[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaselineProject,
    [string]$Output = 'build/project-audit/performance.json',
    [ValidateRange(3, 20)][int]$Runs = 3
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$godot = (Get-GodotToolchainPaths -RepoRoot $repoRoot).Console
Set-PortableGodotEnvironment -ToolsRoot (Join-Path $repoRoot '.tools')
$baseline = (Resolve-Path -LiteralPath $BaselineProject).Path
$candidate = Join-Path $repoRoot 'godot'
if ($baseline -eq $candidate) { throw 'Baseline and candidate must be separate projects.' }
$reports = @()
for ($round = 0; $round -lt $Runs; $round++) {
    $order = if ($round % 2 -eq 0) { @('baseline', 'candidate') } else { @('candidate', 'baseline') }
    foreach ($role in $order) {
        $project = if ($role -eq 'baseline') { $baseline } else { $candidate }
        $captured = Invoke-GodotCapture -Executable $godot -ArgumentList @(
            '--headless', '--path', $project, '--script', 'res://tests/project_performance_probe.gd'
        )
        $exitCode = $LASTEXITCODE
        $joined = $captured -join "`n"
        $row = $captured | Where-Object { [string]$_ -like 'PROJECT_PERFORMANCE_JSON=*' } | Select-Object -Last 1
        if ($exitCode -ne 0 -or $joined -match '(?m)^(SCRIPT ERROR|ERROR|WARNING):' -or $null -eq $row) {
            throw "Performance probe failed ($role round=$round): $joined"
        }
        $reports += [ordered]@{ round = $round + 1; role = $role
            metrics = ([string]$row).Substring('PROJECT_PERFORMANCE_JSON='.Length) | ConvertFrom-Json }
        Write-Host "PERFORMANCE_SAMPLE_OK round=$($round + 1) role=$role"
    }
}
$outputPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $Output))
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputPath) | Out-Null
[ordered]@{ schema = 'ptcg.project_performance_comparison/1'; rounds = $Runs
    baseline_project = $baseline; candidate_project = $candidate
    frame_measurement = 'Headless frame intervals include scheduler delay; no GPU rendering is measured.'
    samples = $reports } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outputPath -Encoding utf8
Write-Host "PROJECT_PERFORMANCE_OK output=$outputPath"
