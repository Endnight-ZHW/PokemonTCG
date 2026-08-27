[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$nativeRoot = Join-Path $toolsRoot 'native'
$downloadsRoot = Join-Path $toolsRoot 'downloads'
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
New-Item -ItemType Directory -Force -Path $nativeRoot, $downloadsRoot | Out-Null

$boostVersionPath = ([string]$lock.native.boost.version).Replace('.', '_')
$boostRoot = Join-Path $nativeRoot "boost_$boostVersionPath"
$boostHeader = Join-Path (Join-Path $boostRoot 'boost') 'beast.hpp'
$boostArchive = Join-Path $downloadsRoot "boost-$([string]$lock.native.boost.version).tar.gz"
if ($Force -and (Test-Path -LiteralPath $boostRoot)) {
    Assert-PathUnderRoot -Root $nativeRoot -Path $boostRoot
    Remove-Item -LiteralPath $boostRoot -Recurse -Force
}
if (-not (Test-Path -LiteralPath $boostHeader)) {
    Get-VerifiedDownload -Uri ([string]$lock.native.boost.url) `
        -Destination $boostArchive -Sha256 ([string]$lock.native.boost.sha256)
    $tar = if ($env:OS -eq 'Windows_NT') { 'tar.exe' } else { 'tar' }
    & $tar -xf $boostArchive -C $nativeRoot
    if ($LASTEXITCODE -ne 0) { throw 'Unable to extract Boost.' }
}

$jsonRoot = Join-Path $nativeRoot 'nlohmann-json'
$jsonHeader = Join-Path (Join-Path (Join-Path $jsonRoot 'include') 'nlohmann') 'json.hpp'
if ($Force -and (Test-Path -LiteralPath $jsonRoot)) {
    Assert-PathUnderRoot -Root $nativeRoot -Path $jsonRoot
    Remove-Item -LiteralPath $jsonRoot -Recurse -Force
}
if (-not (Test-Path -LiteralPath $jsonHeader)) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $jsonHeader) | Out-Null
    Get-VerifiedDownload -Uri ([string]$lock.native.nlohmann_json.url) `
        -Destination $jsonHeader -Sha256 ([string]$lock.native.nlohmann_json.sha256)
}

Write-Host "boost=$boostRoot"
Write-Host "nlohmann-json=$jsonRoot"
