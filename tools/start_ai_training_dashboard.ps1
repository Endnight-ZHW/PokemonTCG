[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8767,
    [string]$CondaEnv = 'DL',
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$serverScript = Join-Path $repoRoot 'python\scripts\ai_training_dashboard.py'
if (-not (Test-Path -LiteralPath $serverScript)) {
    throw "Training dashboard server is missing: $serverScript"
}

$arguments = @(
    'run',
    '--no-capture-output',
    '-n',
    $CondaEnv,
    'python',
    $serverScript,
    '--host',
    '127.0.0.1',
    '--port',
    [string]$Port
)
if (-not $NoBrowser) {
    $arguments += '--open-browser'
}

$conda = (Get-Command conda.exe -ErrorAction Stop).Source
Write-Host "Starting Deep AI training dashboard at http://127.0.0.1:$Port/"
& $conda @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Training dashboard exited with code $LASTEXITCODE"
}

