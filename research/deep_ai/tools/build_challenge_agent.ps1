[CmdletBinding()]
param(
    [string]$GitRef = '',
    [string]$AgentId = 'challenge_next',
    [string]$BuildId = '',
    [string]$Python = '',
    [ValidateRange(1, 64)]
    [int]$Jobs = 4
)

$ErrorActionPreference = 'Stop'
$researchRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $researchRoot)
. (Join-Path $repoRoot 'tools\toolchain_common.ps1')
$Python = Resolve-ProjectPython -RepoRoot $repoRoot -Python $Python
& $Python -c 'import SCons' 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'The selected Python needs SCons.'
}
$jsonHeader = Join-Path $repoRoot '.tools\native\nlohmann-json\include\nlohmann\json.hpp'
if (-not (Test-Path -LiteralPath $jsonHeader)) {
    & (Join-Path $repoRoot 'tools\setup_relay_deps.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'nlohmann-json setup failed.' }
}
$buildRoot = [IO.Path]::GetFullPath((Join-Path $researchRoot 'build'))
$worktreeRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot 'arena-agent-worktrees'))
$sourceRoot = $repoRoot
$resolvedRef = (& git -C $repoRoot rev-parse HEAD).Trim()
$temporaryWorktree = ''
if (-not [string]::IsNullOrWhiteSpace($GitRef)) {
    $resolvedRef = (& git -C $repoRoot rev-parse "$GitRef^{commit}").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($resolvedRef)) {
        throw "Unable to resolve Arena Agent Git ref: $GitRef"
    }
    $temporaryWorktree = [IO.Path]::GetFullPath((Join-Path $worktreeRoot $resolvedRef))
    if (-not $temporaryWorktree.StartsWith($worktreeRoot + [IO.Path]::DirectorySeparatorChar)) {
        throw 'Arena Agent worktree escaped the research build directory.'
    }
    New-Item -ItemType Directory -Force -Path $worktreeRoot | Out-Null
    if (Test-Path -LiteralPath $temporaryWorktree) {
        git -C $repoRoot worktree remove --force $temporaryWorktree 2>$null
    }
    git -C $repoRoot worktree add --detach $temporaryWorktree $resolvedRef
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create Arena Agent worktree.' }
    $sourceRoot = $temporaryWorktree
}
try {
    if ([string]::IsNullOrWhiteSpace($BuildId)) {
        $BuildId = if ([string]::IsNullOrWhiteSpace($GitRef)) {
            "$resolvedRef-working-tree"
        } else {
            $resolvedRef
        }
    }
    $manifestScript = Join-Path $researchRoot 'scripts\challenge_arena_build.py'
    $sourceStrategies = Join-Path $sourceRoot 'godot\data\ai_strategies.json'
    $agentSource = Join-Path $researchRoot 'native\agent'
    $vsDevCmd = Get-VisualCppDevCommand
    if (-not (Test-Path -LiteralPath $vsDevCmd)) {
        throw 'Visual C++ Build Tools are required for Arena Agent builds.'
    }
    $compilerCommand = "`"$vsDevCmd`" -arch=x64 -host_arch=x64 >nul && cl.exe 2>&1"
    $compilerOutput = & cmd.exe /d /s /c $compilerCommand
    $compiler = (($compilerOutput | Where-Object {
        [string]$_ -match 'Compiler Version'
    } | Select-Object -First 1) -join ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($compiler)) {
        $compiler = ([string]($compilerOutput | Select-Object -First 1)).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($compiler)) {
        $compiler = 'unknown-msvc'
    }
    $inputJson = & $Python -B $manifestScript agent-input `
        --repo-root $repoRoot --source-root $sourceRoot --compiler $compiler
    if ($LASTEXITCODE -ne 0) { throw 'Unable to hash Arena Agent inputs.' }
    $input = $inputJson | ConvertFrom-Json
    $implementationHash = [string]$input.implementation_hash
    $buildInputHash = [string]$input.build_input_hash
    $artifactAgentKey = ($AgentId -replace '[^A-Za-z0-9._-]', '_').Trim('.')
    if ([string]::IsNullOrWhiteSpace($artifactAgentKey)) {
        $artifactAgentKey = 'agent'
    }
    $embeddedBuildId = $BuildId -replace '[^A-Za-z0-9._-]', '_'
    $artifactRoot = [IO.Path]::GetFullPath((Join-Path `
        $buildRoot "arena-agents\$artifactAgentKey\$buildInputHash"))
    if (-not $artifactRoot.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar)) {
        throw 'Arena Agent artifact escaped the research build directory.'
    }
    New-Item -ItemType Directory -Force -Path $artifactRoot | Out-Null
    $executable = Join-Path $artifactRoot 'ptcg_challenge_agent.exe'
    $strategies = Join-Path $artifactRoot 'ai_strategies.json'
    $sidecar = Join-Path $artifactRoot 'agent.build.json'
    $command = (
        "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && " +
        "`"$Python`" -m SCons -j$Jobs --directory=`"$agentSource`" " +
        "repository_root=`"$repoRoot`" source_root=`"$sourceRoot`" " +
        "output_root=`"$artifactRoot`" implementation_hash=$implementationHash " +
        "build_id=$embeddedBuildId"
    )
    & cmd.exe /d /s /c $command
    if ($LASTEXITCODE -ne 0) { throw 'Arena Agent native build failed.' }
    Copy-Item -LiteralPath $sourceStrategies -Destination $strategies -Force
    & $Python -B $manifestScript write-agent `
        --repo-root $repoRoot `
        --source-root $sourceRoot `
        --executable $executable `
        --strategies $strategies `
        --output $sidecar `
        --git-ref $resolvedRef `
        --build-id $BuildId `
        --compiler $compiler | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Arena Agent manifest failed.' }
    Write-Output $sidecar
} finally {
    if (-not [string]::IsNullOrWhiteSpace($temporaryWorktree)) {
        $resolvedTarget = [IO.Path]::GetFullPath($temporaryWorktree)
        if (-not $resolvedTarget.StartsWith($worktreeRoot + [IO.Path]::DirectorySeparatorChar)) {
            throw 'Refusing to remove Arena Agent worktree outside build root.'
        }
        git -C $repoRoot worktree remove --force $resolvedTarget 2>$null
        git -C $repoRoot worktree prune 2>$null
    }
}
