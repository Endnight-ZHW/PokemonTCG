[CmdletBinding()]
param([int]$Port = 18767)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$expectedVersion = [string](
    Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'godot/data/release_manifest.json') |
        ConvertFrom-Json
).version
& (Join-Path $PSScriptRoot 'build_relay.ps1') -Configuration debug
$isWindowsHost = $env:OS -eq 'Windows_NT'
$suffix = if ($isWindowsHost) { '.exe' } else { '' }
$relayRoot = Join-Path $repoRoot 'native/relay_server'
$protocolTests = Join-Path $relayRoot "bin/relay_protocol_tests$suffix"
$integrationTests = Join-Path $relayRoot "bin/relay_integration_tests$suffix"
$relayBinary = Join-Path $relayRoot "bin/ptcg_relay_server$suffix"
& $protocolTests
if ($LASTEXITCODE -ne 0) { throw 'Relay protocol tests failed.' }

$tempRoot = Join-Path $repoRoot '.test_tmp/relay'
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
$relayOut = Join-Path $tempRoot 'relay.stdout.log'
$relayErr = Join-Path $tempRoot 'relay.stderr.log'
$start = @{
    FilePath = $relayBinary
    ArgumentList = @(
        '--host', '127.0.0.1', '--port', $Port, '--threads', 2,
        '--max-rooms', 100, '--trusted-proxy', '127.0.0.1'
    )
    WorkingDirectory = $relayRoot
    RedirectStandardOutput = $relayOut
    RedirectStandardError = $relayErr
    PassThru = $true
}
if ($isWindowsHost) { $start.WindowStyle = 'Hidden' }
$relay = Start-Process @start
try {
    $ready = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if ($relay.HasExited) {
            throw "Relay exited before integration tests.`n$(Get-Content -Raw $relayErr)"
        }
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/healthz" -TimeoutSec 1
            if (
                $health.status -eq 'ok' -and $health.version -eq $expectedVersion -and
                [int]$health.protocol -eq 6
            ) { $ready = $true; break }
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $ready) { throw 'Relay health check timed out.' }

    $testOut = Join-Path $tempRoot 'integration.stdout.log'
    $testErr = Join-Path $tempRoot 'integration.stderr.log'
    $testStart = @{
        FilePath = $integrationTests
        ArgumentList = @('127.0.0.1', $Port)
        RedirectStandardOutput = $testOut
        RedirectStandardError = $testErr
        PassThru = $true
    }
    if ($isWindowsHost) { $testStart.WindowStyle = 'Hidden' }
    $integration = Start-Process @testStart
    if (-not $integration.WaitForExit(60000)) {
        Stop-Process -Id $integration.Id -Force
        throw 'Relay integration tests timed out.'
    }
    Get-Content -LiteralPath $testOut | ForEach-Object { Write-Host $_ }
    if ($integration.ExitCode -ne 0) {
        throw "Relay integration tests failed.`n$(Get-Content -Raw $testErr)"
    }
    Start-Sleep -Milliseconds 100
    if ((Get-Content -Raw -LiteralPath $relayOut) -notmatch '198\.51\.100\.17') {
        throw 'Relay did not apply the trusted proxy address to its structured connection log.'
    }
} finally {
    if (-not $relay.HasExited) {
        Stop-Process -Id $relay.Id -Force
        $relay.WaitForExit()
    }
}

$ipv6Port = $Port + 1
$ipv6Out = Join-Path $tempRoot 'relay-ipv6.stdout.log'
$ipv6Err = Join-Path $tempRoot 'relay-ipv6.stderr.log'
$ipv6Start = @{
    FilePath = $relayBinary
    ArgumentList = @(
        '--host', '::1', '--port', $ipv6Port, '--threads', 2,
        '--max-rooms', 100, '--trusted-proxy', '::1'
    )
    WorkingDirectory = $relayRoot
    RedirectStandardOutput = $ipv6Out
    RedirectStandardError = $ipv6Err
    PassThru = $true
}
if ($isWindowsHost) { $ipv6Start.WindowStyle = 'Hidden' }
$ipv6Relay = Start-Process @ipv6Start
try {
    $ipv6Ready = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if ($ipv6Relay.HasExited) {
            throw "IPv6 Relay exited before its smoke test.`n$(Get-Content -Raw $ipv6Err)"
        }
        try {
            $health = Invoke-RestMethod -Uri "http://[::1]:$ipv6Port/healthz" -TimeoutSec 1 -NoProxy
            if (
                $health.status -eq 'ok' -and $health.version -eq $expectedVersion -and
                [int]$health.protocol -eq 6
            ) { $ipv6Ready = $true; break }
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $ipv6Ready) { throw 'IPv6 Relay health check timed out.' }
    & $integrationTests '::1' $ipv6Port smoke
    if ($LASTEXITCODE -ne 0) { throw 'IPv6 Relay integration smoke failed.' }
} finally {
    if (-not $ipv6Relay.HasExited) {
        Stop-Process -Id $ipv6Relay.Id -Force
        $ipv6Relay.WaitForExit()
    }
}
