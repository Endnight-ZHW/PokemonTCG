[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$printingRepoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $PSScriptRoot 'sync_card_sources.ps1') -Check
. (Join-Path $PSScriptRoot 'godot_test_common.ps1')
$printingGodot = (Initialize-GodotTestEnvironment -RepoRoot $printingRepoRoot).Console
Invoke-GodotCheckedScript -Executable $printingGodot -ProjectRoot (Join-Path $printingRepoRoot 'godot') `
    -Script 'res://tools/card_printing_review.gd' -SuccessMarker 'CARD_PRINTING_REVIEW_OK' `
    -ContractName 'Card printing review'
Write-Output (Join-Path $printingRepoRoot 'build/card-text-audit/review.html')
