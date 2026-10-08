[CmdletBinding()]
param(
    [ValidateSet('all', 'inspector', 'choice')]
    [string]$View = 'all',
    [switch]$ReportOnly
)

$ErrorActionPreference = 'Stop'
$reviewRepoRoot = Split-Path -Parent $PSScriptRoot
$reviewCases = @{
    inspector = @{ Output = 'card-detail-integration'; Script = 'card_detail_redesign_contract'; Marker = 'CARD_DETAIL_REDESIGN_OK' }
    choice = @{ Output = 'choice-detail-integration'; Script = 'choice_card_detail_contract'; Marker = 'CHOICE_CARD_DETAIL_OK' }
}
$reviewComparisons = @{
    '01-front-1600.png' = '01-front-1600.png'
    '05-battle-full-1600.png' = '02-battle-detail-1600.png'
    '02-attachments-bottom.png' = '04-battle-attachments-bottom.png'
    '06-sidebar-1600x900.png' = '12-expanded-svi-maus.png'
    '06-sidebar-1920x1080.png' = '13-expanded-1920x1080.png'
    '06-sidebar-1280x720.png' = '05-sidebar-1280x720.png'
    '06-sidebar-1024x768.png' = '05-sidebar-1024x768.png'
    '03-svi-maus-1024x768.png' = '07-compact-long.png'
    '03-sv1-189-1024x768.png' = '08-compact-trainer.png'
    '03-svg2-lume-1024x768.png' = '09-compact-energy.png'
}
$reviewViews = if ($View -eq 'all') { @('inspector', 'choice') } else { @($View) }
$reviewTemplate = Get-Content -LiteralPath (Join-Path $reviewRepoRoot 'godot/tools/reviews/card_details.html') -Raw
if (-not $ReportOnly) {
    . (Join-Path $PSScriptRoot 'godot_test_common.ps1')
    $reviewGodot = (Initialize-GodotTestEnvironment -RepoRoot $reviewRepoRoot).Console
}

foreach ($reviewView in $reviewViews) {
    $reviewCase = $reviewCases[$reviewView]
    $reviewOutput = Join-Path $reviewRepoRoot ('build/' + $reviewCase.Output)
    New-Item -ItemType Directory -Force -Path $reviewOutput | Out-Null
    if (-not $ReportOnly) {
        $reviewStdout = Join-Path $reviewOutput 'capture.log'
        $reviewStderr = Join-Path $reviewOutput 'capture-errors.log'
        $reviewArguments = @('--minimized', '--path', ('"' + (Join-Path $reviewRepoRoot 'godot') + '"'), '--script', ('res://tests/' + $reviewCase.Script + '.gd'))
        $reviewProcess = Start-Process -FilePath $reviewGodot -ArgumentList $reviewArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $reviewStdout -RedirectStandardError $reviewStderr
        try {
            if (-not $reviewProcess.WaitForExit(200000)) {
                Stop-Process -Id $reviewProcess.Id
                throw "Card detail capture exceeded 200 seconds: $reviewView"
            }
            $reviewProcess.Refresh()
            $reviewLog = Get-Content -LiteralPath $reviewStdout -Raw
            $reviewErrors = Get-Content -LiteralPath $reviewStderr -Raw
            if ($reviewProcess.ExitCode -ne 0 -or $reviewLog -notmatch [regex]::Escape($reviewCase.Marker) -or $reviewErrors -match '(?m)^(SCRIPT ERROR|ERROR):') {
                Write-Output $reviewLog
                Write-Output $reviewErrors
                throw "Card detail checks failed: $reviewView"
            }
            Write-Output $reviewLog
        } finally {
            $reviewProcess.Dispose()
        }
    }
    $reviewReport = Get-Content -LiteralPath (Join-Path $reviewOutput 'validation-graphics.json') -Raw
    $reviewData = $reviewReport | ConvertFrom-Json
    if ($null -eq $reviewData.captures -or $null -eq $reviewData.failures) {
        throw "Invalid capture report: $reviewOutput"
    }
    # Approved drafts and the user's reference image are optional local files.
    # A fresh checkout must still produce a usable screenshot gallery.
    $reviewReferences = @{}
    foreach ($reviewCapture in $reviewData.captures) {
        $reviewReference = ''
        if ($reviewView -eq 'inspector' -and $reviewComparisons.ContainsKey($reviewCapture)) {
            $reviewReference = '../card-detail-design/' + $reviewComparisons[$reviewCapture]
        } elseif ($reviewView -eq 'choice') {
            $reviewReference = 'before-search.png'
        }
        if ($reviewReference -and (Test-Path -LiteralPath (Join-Path $reviewOutput $reviewReference) -PathType Leaf)) {
            $reviewReferences[$reviewCapture] = $reviewReference
        }
    }
    $reviewData | Add-Member -NotePropertyName references -NotePropertyValue $reviewReferences -Force
    $reviewReport = $reviewData | ConvertTo-Json -Depth 12
    $reviewHtml = $reviewTemplate.Replace('__VIEW__', $reviewView).Replace('__REPORT__', $reviewReport.Replace('</', '<\/'))
    [System.IO.File]::WriteAllText((Join-Path $reviewOutput 'review.html'), $reviewHtml, [System.Text.UTF8Encoding]::new($false))
    Write-Output (Join-Path $reviewOutput 'review.html')
}
