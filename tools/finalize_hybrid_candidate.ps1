[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunId,
    [string]$RunsRoot = '',
    [string]$AndroidRuntimeEvidence = '',
    [string]$CondaEnv = 'DL'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($RunsRoot)) {
    $RunsRoot = Join-Path $repoRoot 'build\ai_training\runs'
}
$runsRootFull = [System.IO.Path]::GetFullPath($RunsRoot)
$runDir = [System.IO.Path]::GetFullPath((Join-Path $runsRootFull $RunId))
$relative = [System.IO.Path]::GetRelativePath($runsRootFull, $runDir)
if (
    [System.IO.Path]::IsPathRooted($relative) -or
    $relative -eq '..' -or
    $relative.StartsWith("..$([System.IO.Path]::DirectorySeparatorChar)")
) {
    throw 'RunId resolves outside the configured runs root.'
}

$arguments = @(
    'run',
    '--no-capture-output',
    '-n',
    $CondaEnv,
    'python',
    (Join-Path $repoRoot 'python\scripts\finalize_hybrid_evidence.py'),
    '--run-dir', $runDir
)
if (-not [string]::IsNullOrWhiteSpace($AndroidRuntimeEvidence)) {
    $arguments += @(
        '--android-runtime',
        [System.IO.Path]::GetFullPath($AndroidRuntimeEvidence)
    )
}
$conda = (Get-Command conda.exe -ErrorAction Stop).Source
& $conda @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Hybrid candidate evidence finalization failed with exit code $LASTEXITCODE."
}
