[CmdletBinding()]
param([switch]$SkipBuild)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$release = Get-ReleaseManifest -RepoRoot $repoRoot
$lock = Get-ToolchainLock -RepoRoot $repoRoot
Assert-ProductReleaseContract -Manifest $release
$version = [string]$release.version
$isWindowsHost = $env:OS -eq 'Windows_NT'
$suffix = if ($isWindowsHost) { '.exe' } else { '' }
$platform = if ($isWindowsHost) { 'Windows' } else { 'Linux' }
$relayRoot = Join-Path $repoRoot 'native/relay_server'
$binary = Join-Path $relayRoot "bin/ptcg_relay_server$suffix"
$stagingParent = Join-Path $repoRoot '.tools/relay-release-staging'
$packageRoot = Join-Path $stagingParent "PokemonTCG-Relay-$version"
$distRoot = Join-Path $repoRoot 'dist/relay'

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build_relay.ps1') -Configuration release
    if ($LASTEXITCODE -ne 0) { throw 'Relay release build failed.' }
}
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "Relay release binary is missing: $binary"
}
Assert-PathUnderRoot -Root (Join-Path $repoRoot '.tools') -Path $stagingParent
if (Test-Path -LiteralPath $stagingParent) {
    Remove-Item -LiteralPath $stagingParent -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $packageRoot, $distRoot | Out-Null
Copy-Item -LiteralPath $binary -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $repoRoot 'deploy/relay/README.md') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $repoRoot 'deploy/relay/Caddyfile.example') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $repoRoot 'deploy/relay/nginx.conf.example') -Destination $packageRoot
Copy-Item -LiteralPath (Join-Path $repoRoot 'deploy/relay/THIRD_PARTY_NOTICES.txt') -Destination $packageRoot
[ordered]@{
    version = $version
    protocol = 6
    platform = $platform
    architecture = 'x86_64'
    boost = [string]$lock.native.boost.version
    nlohmann_json = [string]$lock.native.nlohmann_json.version
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $packageRoot 'RELAY_BUILD_INFO.json') -Encoding UTF8

if ($isWindowsHost) {
    $archive = Join-Path $distRoot "PokemonTCG-Relay-Windows-x86_64-$version.zip"
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    Compress-Archive -LiteralPath $packageRoot -DestinationPath $archive -CompressionLevel Optimal
} else {
    $archive = Join-Path $distRoot "PokemonTCG-Relay-Linux-x86_64-$version.tar.gz"
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    & tar -czf $archive -C $stagingParent (Split-Path -Leaf $packageRoot)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create Relay tarball.' }
}
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "RELAY_PACKAGE_OK platform=$platform version=$version sha256=$hash"
Write-Host "RELAY_ARCHIVE=$archive"
