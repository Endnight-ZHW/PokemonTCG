[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectRoot = Join-Path $repoRoot 'godot'
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$godotPaths = Get-GodotToolchainPaths -RepoRoot $repoRoot
Set-PortableGodotEnvironment -ToolsRoot (Join-Path $repoRoot '.tools')
$manifestPath = Join-Path $projectRoot 'authoring\card_source_manifest.json'
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$source = $manifest.source
if ($manifest.schema -ne 'ptcg.card_sources/1' -or
    $source.repository -ne 'https://github.com/duanxr/PTCG-CHS-Datasets' -or
    $source.revision -cnotmatch '^[0-9a-f]{40}$' -or
    $source.dataset_path -ne 'ptcg_chs_infos.json') {
    throw 'Card source manifest must pin the shared Simplified Chinese dataset.'
}
$cacheRoot = Join-Path $repoRoot ".cache\card_sources\$($source.revision)"
$rawRoot = "https://raw.githubusercontent.com/duanxr/PTCG-CHS-Datasets/$($source.revision)"
$downloads = @(@{ Path = $source.dataset_path; Sha256 = $source.dataset_sha256 })
foreach ($entry in $manifest.cards.PSObject.Properties) {
    $row = $entry.Value
    if ($row.image -notmatch '^img/[0-9]+/[0-9]+\.png$') {
        throw "Invalid card image path: $($entry.Name)"
    }
    $downloads += @{ Path = $row.image; Sha256 = $row.image_sha256 }
}
foreach ($download in $downloads) {
    if ($download.Sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Missing source checksum: $($download.Path)"
    }
    $destination = Join-Path $cacheRoot $download.Path
    Assert-PathUnderRoot -Root $cacheRoot -Path $destination
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Get-VerifiedDownload -Uri "$rawRoot/$($download.Path)" -Destination $destination `
        -Sha256 $download.Sha256
}
$command = if ($Check) { 'check' } else { 'import' }
& $godotPaths.Console --headless --path $projectRoot `
    --script res://tools/sync_card_sources.gd -- $command $cacheRoot
if ($LASTEXITCODE -ne 0) { throw "Card source $command failed." }
if (-not $Check) {
    & (Join-Path $PSScriptRoot 'content.ps1') export
} else {
    & (Join-Path $PSScriptRoot 'content.ps1') check
}
