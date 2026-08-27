[CmdletBinding()]
param([int]$Port = 18769)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'build_relay.ps1') -Configuration release
$isWindowsHost = $env:OS -eq 'Windows_NT'
$suffix = if ($isWindowsHost) { '.exe' } else { '' }
$relayRoot = Join-Path $repoRoot 'native/relay_server'
$relayBinary = Join-Path $relayRoot "bin/ptcg_relay_server$suffix"
$benchmark = Join-Path $relayRoot "bin/relay_benchmark$suffix"
$tempRoot = Join-Path $repoRoot '.test_tmp/relay-benchmark'
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
$start = @{
    FilePath = $relayBinary
    ArgumentList = @(
        '--host', '127.0.0.1', '--port', $Port, '--threads', 2,
        '--max-rooms', 100, '--trusted-proxy', '127.0.0.1'
    )
    WorkingDirectory = $relayRoot
    RedirectStandardOutput = (Join-Path $tempRoot 'relay.stdout.log')
    RedirectStandardError = (Join-Path $tempRoot 'relay.stderr.log')
    PassThru = $true
}
if ($isWindowsHost) { $start.WindowStyle = 'Hidden' }
$relay = Start-Process @start
try {
    $ready = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if ($relay.HasExited) { throw 'Relay exited before benchmark.' }
        try {
            if ((Invoke-RestMethod -Uri "http://127.0.0.1:$Port/healthz" -TimeoutSec 1).status -eq 'ok') {
                $ready = $true
                break
            }
        } catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $ready) { throw 'Relay benchmark health check timed out.' }
    $cpuBefore = $relay.TotalProcessorTime.TotalMilliseconds
    & $benchmark '127.0.0.1' $Port
    if ($LASTEXITCODE -ne 0) { throw 'Relay load benchmark failed.' }
    $relay.Refresh()
    $cpuMs = $relay.TotalProcessorTime.TotalMilliseconds - $cpuBefore
    Write-Host "RELAY_BENCHMARK_SERVER_CPU_MS=$([Math]::Round($cpuMs, 3))"
} finally {
    if (-not $relay.HasExited) {
        Stop-Process -Id $relay.Id -Force
        $relay.WaitForExit()
    }
}
