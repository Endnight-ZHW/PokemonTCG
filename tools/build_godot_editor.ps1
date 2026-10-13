[CmdletBinding()]
param(
    [ValidateRange(1, 64)] [int]$Jobs = 4,
    [string]$Python = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
$build = $lock.godot.editor_build
$paths = Get-GodotToolchainPaths -RepoRoot $repoRoot
$patchPath = Join-Path $repoRoot $build.patch
$patchHash = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
$recipeHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($patchHash -ne $build.patch_sha256) { throw 'Godot shutdown patch checksum mismatch.' }
$stampPath = Join-Path $paths.Root 'BUILD_PATCHES.json'
$cacheValid = $false
if (-not $Force -and (Test-Path -LiteralPath $stampPath)) {
    try {
        $stamp = Get-Content -Raw -LiteralPath $stampPath | ConvertFrom-Json
        $cacheValid = (
            $stamp.schema -eq 'ptcg.godot-editor-build/1' -and
            $stamp.source_sha256 -eq $build.source_sha256 -and
            $stamp.patch_sha256 -eq $patchHash -and
            $stamp.recipe_sha256 -eq $recipeHash -and
            $stamp.editor_sha256 -eq (Get-FileHash $paths.Editor -Algorithm SHA256).Hash.ToLowerInvariant() -and
            $stamp.console_sha256 -eq (Get-FileHash $paths.Console -Algorithm SHA256).Hash.ToLowerInvariant()
        )
    } catch { $cacheValid = $false }
}
if ($cacheValid) {
    Write-Host 'GODOT_PATCHED_EDITOR_OK cached=1'
    return
}

$Python = Resolve-ProjectPython -RepoRoot $repoRoot -Python $Python
& $Python -c 'import SCons'
if ($LASTEXITCODE -ne 0) { throw 'Building the pinned Godot editor requires SCons.' }
$vsDevCmd = Get-VisualCppDevCommand
if (-not (Test-Path -LiteralPath $vsDevCmd)) { throw 'Godot editor requires Visual C++ Build Tools.' }
$toolsRoot = Join-Path $repoRoot '.tools'
$downloads = Join-Path $toolsRoot 'downloads'
$sourceContainer = Join-Path $toolsRoot 'native'
$sourceRoot = Join-Path $sourceContainer $build.archive_directory
$sourceStamp = Join-Path $sourceRoot '.ptcg-source-patch'
New-Item -ItemType Directory -Force -Path $downloads, $paths.Root | Out-Null
$archive = Join-Path $downloads "godot-$($lock.godot.version)-source.zip"
Get-VerifiedDownload -Uri $build.source_url -Destination $archive -Sha256 $build.source_sha256
$sourceIdentity = "$($build.source_sha256):$patchHash"
$sourceReady = (Test-Path -LiteralPath $sourceStamp) -and
    ((Get-Content -Raw -LiteralPath $sourceStamp).Trim() -eq $sourceIdentity)
if ($Force -or -not $sourceReady) {
    Assert-PathUnderRoot -Root $sourceContainer -Path $sourceRoot
    if (Test-Path -LiteralPath $sourceRoot) { Remove-Item -LiteralPath $sourceRoot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $sourceContainer | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $sourceContainer
    Assert-PathUnderRoot -Root $sourceContainer -Path $sourceRoot
    # Resolve patch paths under the extracted, pinned source tree, not the game.
    $patchDirectory = [IO.Path]::GetRelativePath($repoRoot, $sourceRoot).Replace('\', '/')
    & git -c core.autocrlf=false -C $repoRoot apply --check "--directory=$patchDirectory" $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'Godot shutdown patch does not match the pinned source.' }
    & git -c core.autocrlf=false -C $repoRoot apply "--directory=$patchDirectory" $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'Unable to apply the Godot shutdown patch.' }
    Set-Content -LiteralPath $sourceStamp -Value $sourceIdentity -Encoding ascii
}

# The project uses Compatibility rendering. The development editor does not
# require the external Direct3D 12 SDK or Rust AccessKit driver; runtime export
# templates remain the separately verified official release templates.
$arguments = @('-m', 'SCons', "-j$Jobs", "--directory=$sourceRoot",
    'platform=windows', 'target=editor', 'arch=x86_64', 'accesskit=no',
    'd3d12=no', 'debug_symbols=no', 'optimize=speed', 'lto=none')
$quotedArguments = $arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
$command = "`"$vsDevCmd`" -arch=x64 -host_arch=x64 && `"$Python`" $($quotedArguments -join ' ')"
& cmd.exe /d /s /c $command
if ($LASTEXITCODE -ne 0) { throw 'Patched Godot editor build failed.' }
Copy-Item -LiteralPath (Join-Path $sourceRoot 'bin/godot.windows.editor.x86_64.exe') -Destination $paths.Editor -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'bin/godot.windows.editor.x86_64.console.exe') -Destination $paths.Console -Force
@{
    schema = 'ptcg.godot-editor-build/1'
    source_sha256 = $build.source_sha256
    patch_sha256 = $patchHash
    recipe_sha256 = $recipeHash
    editor_sha256 = (Get-FileHash $paths.Editor -Algorithm SHA256).Hash.ToLowerInvariant()
    console_sha256 = (Get-FileHash $paths.Console -Algorithm SHA256).Hash.ToLowerInvariant()
} | ConvertTo-Json | Set-Content -LiteralPath $stampPath -Encoding utf8NoBOM
Write-Host 'GODOT_PATCHED_EDITOR_OK cached=0'
