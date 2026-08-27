[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$godot = (Get-GodotToolchainPaths -RepoRoot $repoRoot).Console
Set-PortableGodotEnvironment -ToolsRoot $toolsRoot
if (-not (Test-Path -LiteralPath $godot)) {
    throw 'Godot is not installed. Run setup_godot_toolchain.ps1 first.'
}

function Invoke-GodotContract {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][string]$Marker
    )
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $godot `
            --headless `
            --path (Join-Path $repoRoot 'godot') `
            --script $Script 2>&1
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $output | ForEach-Object { Write-Host $_ }
    $joined = $output -join "`n"
    $fatal = '(?m)^(SCRIPT ERROR|ERROR): (?!Failed to read the root certificate store\.)'
    if ($LASTEXITCODE -ne 0 -or $joined -match $fatal -or $joined -notmatch $Marker) {
        throw "Godot Challenge contract failed: $Script"
    }
}

Invoke-GodotContract `
    -Script 'res://tests/ai_regression.gd' `
    -Marker 'AI_REGRESSION_OK'
Write-Host 'GODOT_CHALLENGE_VERIFICATION_OK'
