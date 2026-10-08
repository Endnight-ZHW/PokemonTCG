. (Join-Path $PSScriptRoot 'toolchain_common.ps1')

function Initialize-GodotTestEnvironment {
    param([Parameter(Mandatory)] [string]$RepoRoot)

    $paths = Get-GodotToolchainPaths -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $paths.Console -PathType Leaf)) {
        throw "Godot is missing: $($paths.Console). Run tools/setup_godot_toolchain.ps1 first."
    }
    Set-PortableGodotEnvironment -ToolsRoot (Join-Path $RepoRoot '.tools')
    # UI contracts can exercise real settings saves. Keep their user:// files
    # separate from the portable editor/client as well as the installed game.
    $env:APPDATA = Join-Path $RepoRoot '.test_tmp\godot-userdata'
    New-Item -ItemType Directory -Force -Path $env:APPDATA | Out-Null
    return $paths
}
