[CmdletBinding()]
param(
    [string]$Output = 'artifacts\native_vs_retired_deeproot_v2.json',
    [int]$Repeats = 3,
    [int]$Seed = 3907
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$tempRoot = Join-Path $toolsRoot 'tmp'
$python = Join-Path $toolsRoot 'python311\python.exe'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$godotPaths = Get-GodotToolchainPaths -RepoRoot $repoRoot
$godot = $godotPaths.Console
Set-PortableGodotEnvironment -ToolsRoot $toolsRoot

if ($Repeats -le 0) {
    throw 'Repeats must be positive.'
}
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
$worktree = Join-Path $tempRoot (
    'retired-deeproot-' + [Guid]::NewGuid().ToString('N')
)
$resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
$resolvedWorktree = [IO.Path]::GetFullPath($worktree)
if (-not $resolvedWorktree.StartsWith(
    $resolvedTempRoot + [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'Historical worktree escaped the tool temporary directory.'
}
$historicalOutput = Join-Path $tempRoot (
    'retired-deeproot-measurement-' +
    [Guid]::NewGuid().ToString('N') +
    '.json'
)
$runnerSource = Join-Path $repoRoot (
    'godot\tools\ai_baseline\deep_root_v1_benchmark_runner.gd'
)
$outputPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $Output))
if (-not $outputPath.StartsWith(
    [IO.Path]::GetFullPath($repoRoot) +
    [IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'Benchmark output must stay inside the repository.'
}

try {
    & git -C $repoRoot worktree add --detach $resolvedWorktree b0f12b5
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to create the retired DeepRoot worktree.'
    }
    $runnerDestination = Join-Path $resolvedWorktree (
        'godot\tools\ai_baseline\deep_root_v1_benchmark_runner.gd'
    )
    Copy-Item -LiteralPath $runnerSource -Destination $runnerDestination -Force
    $historicalPlanner = Join-Path $resolvedWorktree (
        'godot\ai\deep_root_ismcts.gd'
    )
    $plannerSource = Get-Content -LiteralPath $historicalPlanner -Raw
    $patchedPromotionActor = @'
		var promotion_player := -1
		if not current.pending_promotions.is_empty():
			promotion_player = int(current.pending_promotions[0])
		var actor: int = (
			promotion_player
			if promotion_player >= 0
			else current.active_player_idx
		)
'@
    $promotionPattern = (
        '(?ms)\t\tvar actor: int = \(\r?\n' +
        '\t\t\tcurrent\.pending_promotion_player\r?\n' +
        '\t\t\tif current\.pending_promotion_player >= 0\r?\n' +
        '\t\t\telse current\.active_player_idx\r?\n' +
        '\t\t\)'
    )
    if ($plannerSource -notmatch $promotionPattern) {
        throw 'Retired DeepRoot compatibility patch target is missing.'
    }
    $plannerSource = [regex]::Replace(
        $plannerSource,
        $promotionPattern,
        $patchedPromotionActor,
        1
    )
    Set-Content -LiteralPath $historicalPlanner `
        -Value $plannerSource -Encoding utf8 -NoNewline
    $importOutput = & $godot --headless `
        --path (Join-Path $resolvedWorktree 'godot') --import 2>&1
    $importOutput | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to import the retired DeepRoot project.'
    }
    $output = & $godot --headless `
        --path (Join-Path $resolvedWorktree 'godot') `
        --script 'res://tools/ai_baseline/deep_root_v1_benchmark_runner.gd' `
        -- --output $historicalOutput --repeats $Repeats --seed $Seed 2>&1
    $output | ForEach-Object { Write-Host $_ }
    $joinedOutput = $output -join "`n"
    if (
        ($LASTEXITCODE -ne 0) -or
        ($joinedOutput -notmatch
            'RETIRED_DEEP_ROOT_BENCHMARK_OK') -or
        ($joinedOutput -match '(?m)^(SCRIPT ERROR|ERROR):') -or
        (-not (Test-Path -LiteralPath $historicalOutput))
    ) {
        throw 'Retired DeepRoot isolated benchmark failed.'
    }
    $env:PYTHONPATH = Join-Path $repoRoot 'python'
    & $python -B (
        Join-Path $repoRoot (
            'python\scripts\benchmark_retired_deeproot_v2.py'
        )
    ) --historical $historicalOutput --repeats $Repeats `
        --max-depth 16 --output $outputPath
    if ($LASTEXITCODE -ne 0) {
        throw 'Native comparison with retired DeepRoot failed.'
    }
} finally {
    if (Test-Path -LiteralPath $resolvedWorktree) {
        & git -C $repoRoot worktree remove --force $resolvedWorktree
    }
    & git -C $repoRoot worktree prune
    if (Test-Path -LiteralPath $historicalOutput) {
        Remove-Item -LiteralPath $historicalOutput -Force
    }
}
