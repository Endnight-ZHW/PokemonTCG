[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$nativeRoot = Join-Path $toolsRoot 'native'
$godotCpp = Join-Path $nativeRoot 'godot-cpp'

. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$lock = Get-ToolchainLock -RepoRoot $repoRoot
New-Item -ItemType Directory -Force -Path $nativeRoot | Out-Null

if ($Force -and (Test-Path -LiteralPath $godotCpp)) {
    Assert-PathUnderRoot -Root $toolsRoot -Path $godotCpp
    Remove-Item -LiteralPath $godotCpp -Recurse -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $godotCpp 'SConstruct'))) {
    git clone https://github.com/godotengine/godot-cpp.git $godotCpp
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to clone godot-cpp.'
    }
}
git -C $godotCpp fetch --depth 1 origin $lock.native.godot_cpp_commit
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to fetch the pinned godot-cpp revision.'
}
git -C $godotCpp checkout --detach $lock.native.godot_cpp_commit
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to pin godot-cpp.'
}

Write-Host "godot-cpp=$godotCpp"
