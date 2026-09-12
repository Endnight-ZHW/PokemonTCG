. (Join-Path $PSScriptRoot 'toolchain_common.ps1')

function Initialize-GodotTestEnvironment {
    param([Parameter(Mandatory)] [string]$RepoRoot)

    $paths = Get-GodotToolchainPaths -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $paths.Console -PathType Leaf)) {
        throw "Godot is missing: $($paths.Console). Run tools/setup_godot_toolchain.ps1 first."
    }
    Set-PortableGodotEnvironment -ToolsRoot (Join-Path $RepoRoot '.tools')
    return $paths
}
