[CmdletBinding()]
param(
    [int]$RelayPort = 18766
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$expectedVersion = [string](
    Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'godot/data/release_manifest.json') |
        ConvertFrom-Json
).version
$projectRoot = Join-Path $repoRoot 'godot'
$relayRoot = Join-Path $repoRoot 'native\relay_server'
$tempRoot = Join-Path $repoRoot '.test_tmp\godot-network'

. (Join-Path $PSScriptRoot 'godot_test_common.ps1')
$godot = (Initialize-GodotTestEnvironment -RepoRoot $repoRoot).Console
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
& (Join-Path $PSScriptRoot 'build_relay.ps1') -Configuration debug
$relayBinary = Join-Path $relayRoot 'bin\ptcg_relay_server.exe'

$relayOut = Join-Path $tempRoot 'relay.stdout.log'
$relayErr = Join-Path $tempRoot 'relay.stderr.log'
$relay = Start-Process `
    -FilePath $relayBinary `
    -ArgumentList @(
        '--host', '127.0.0.1',
        '--port', $RelayPort,
        '--threads', 2,
        '--max-rooms', 100
    ) `
    -WorkingDirectory $relayRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $relayOut `
    -RedirectStandardError $relayErr `
    -PassThru
try {
    $ready = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if ($relay.HasExited) {
            throw "Relay server exited before regression test.`n$(Get-Content -Raw $relayErr)"
        }
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$RelayPort/healthz" -TimeoutSec 1
            if (
                $health.status -eq 'ok' -and $health.version -eq $expectedVersion -and
                [int]$health.protocol -eq 6
            ) {
                $ready = $true
                break
            }
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $ready) {
        throw 'Relay server did not become healthy before the regression test.'
    }
    Invoke-GodotCheckedScript -Executable $godot -ProjectRoot $projectRoot `
        -Script 'res://tests/network_regression.gd' -SuccessMarker 'NETWORK_REGRESSION_OK' `
        -ContractName 'Godot network regression' -AllowWarnings `
        -ScriptArguments @("--relay-url=ws://127.0.0.1:$RelayPort")
}
finally {
    if (-not $relay.HasExited) {
        Stop-Process -Id $relay.Id -Force
        $relay.WaitForExit()
    }
}
