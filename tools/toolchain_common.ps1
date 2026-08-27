$ErrorActionPreference = 'Stop'

function Get-ToolchainLock {
    param([Parameter(Mandatory)] [string]$RepoRoot)
    $path = Join-Path $RepoRoot 'tools\toolchain.lock.json'
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Get-GodotToolchainPaths {
    param([Parameter(Mandatory)] [string]$RepoRoot)
    $lock = Get-ToolchainLock -RepoRoot $RepoRoot
    $toolsRoot = Join-Path $RepoRoot '.tools'
    $version = [string]$lock.godot.version
    $series = ($version -split '-')[0]
    $godotRoot = Join-Path $toolsRoot "godot-$series"
    return [pscustomobject]@{
        Series = $series
        Root = $godotRoot
        Editor = Join-Path $godotRoot "Godot_v$($version)_win64.exe"
        Console = Join-Path $godotRoot "Godot_v$($version)_win64_console.exe"
        EditorSettings = Join-Path `
            $toolsRoot `
            "appdata\Godot\editor_settings-$series.tres"
        TemplateRoot = Join-Path `
            $toolsRoot `
            "appdata\Godot\export_templates\$($lock.godot.full_config)"
    }
}

function Get-ReleaseManifest {
    param([Parameter(Mandatory)] [string]$RepoRoot)
    $path = Join-Path $RepoRoot 'godot\data\release_manifest.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Release manifest is missing: $path"
    }
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $decks = @($manifest.release_decks)
    if ($decks.Count -eq 0) {
        throw 'Release manifest contains no release decks.'
    }
    if (@($decks | Sort-Object -Unique).Count -ne $decks.Count) {
        throw 'Release manifest contains duplicate release deck keys.'
    }
    return $manifest
}

function Assert-ProductReleaseContract {
    param([Parameter(Mandatory)] $Manifest)
    if (
        [string]$Manifest.version -ne '0.7.0' -or
        [int]$Manifest.android_version_code -ne 8 -or
        [int]$Manifest.schemas.godot_actions -ne 4 -or
        [int]$Manifest.schemas.choice_view -ne 2 -or
        [int]$Manifest.schemas.protocol -ne 6 -or
        [int]$Manifest.schemas.snapshot -ne 3 -or
        [int]$Manifest.schemas.journal -ne 1 -or
        [int]$Manifest.schemas.rng -ne 2 -or
        -not [bool]$Manifest.native_challenge.production_ready
    ) {
        throw 'Release manifest does not match the product contract.'
    }
}

function Assert-PathUnderRoot {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [string]$Path
    )
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $resolvedTarget = [System.IO.Path]::GetFullPath($Path)
    if (-not $resolvedTarget.StartsWith(
        $resolvedRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing filesystem operation outside $resolvedRoot`: $resolvedTarget"
    }
}

function Test-ArchiveDigest {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [string]$Sha256 = '',
        [string]$Sha1 = ''
    )
    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $Sha256.ToLowerInvariant()) {
            throw "SHA-256 mismatch for $Path. Expected $Sha256, got $actual"
        }
    }
    if ($Sha1) {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToLowerInvariant()
        if ($actual -ne $Sha1.ToLowerInvariant()) {
            throw "SHA-1 mismatch for $Path. Expected $Sha1, got $actual"
        }
    }
}

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [string]$Destination,
        [string]$Sha256 = '',
        [string]$Sha1 = '',
        [switch]$Force
    )
    if ($Force -or -not (Test-Path -LiteralPath $Destination)) {
        Write-Host "Downloading $Uri"
        Invoke-WebRequest -Uri $Uri -OutFile $Destination
    }
    Test-ArchiveDigest -Path $Destination -Sha256 $Sha256 -Sha1 $Sha1
}

function Set-PortableGodotEnvironment {
    param([Parameter(Mandatory)] [string]$ToolsRoot)
    $env:APPDATA = Join-Path $ToolsRoot 'appdata'
    $env:GRADLE_USER_HOME = Join-Path $ToolsRoot 'gradle-home'
    New-Item -ItemType Directory -Force -Path $env:APPDATA, $env:GRADLE_USER_HOME | Out-Null
}
