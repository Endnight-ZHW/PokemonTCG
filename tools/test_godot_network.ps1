[CmdletBinding()]
param(
    [int]$RelayPort = 18766
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path $repoRoot 'godot'
$pythonRoot = Join-Path $repoRoot 'python'
$godot = Join-Path $repoRoot '.tools\godot-4.7\Godot_v4.7-stable_win64_console.exe'
$python = Join-Path $repoRoot '.tools\python311\python.exe'
$tempRoot = Join-Path $repoRoot '.test_tmp\godot-network'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
Set-PortableGodotEnvironment -ToolsRoot (Join-Path $repoRoot '.tools')
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$relayOut = Join-Path $tempRoot 'relay.stdout.log'
$relayErr = Join-Path $tempRoot 'relay.stderr.log'
$relay = Start-Process `
    -FilePath $python `
    -ArgumentList @(
        (Join-Path $pythonRoot 'relay_server.py'),
        '--host', '127.0.0.1',
        '--port', $RelayPort
    ) `
    -WorkingDirectory $pythonRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $relayOut `
    -RedirectStandardError $relayErr `
    -PassThru
try {
    Start-Sleep -Milliseconds 500
    if ($relay.HasExited) {
        throw "Relay server exited before regression test.`n$(Get-Content -Raw $relayErr)"
    }
    $output = & $godot `
        --headless `
        --path $projectRoot `
        --script 'res://tests/network_regression.gd' `
        -- `
        "--relay-url=ws://127.0.0.1:$RelayPort" 2>&1
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    $output | ForEach-Object { Write-Host $_ }
    $joined = $output -join "`n"
    if ($exitCode -ne 0 -or $joined -notmatch 'NETWORK_REGRESSION_OK') {
        throw "Godot network regression failed with exit code $exitCode."
    }
    if ($joined -match '(?m)^(SCRIPT ERROR|ERROR:)') {
        throw 'Godot emitted script/runtime errors during network regression.'
    }
}
finally {
    if (-not $relay.HasExited) {
        Stop-Process -Id $relay.Id -Force
        $relay.WaitForExit()
    }
}
