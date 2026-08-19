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
    $path = Join-Path $RepoRoot 'release_manifest.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Release manifest is missing: $path"
    }
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $decks = @($manifest.release_decks)
    $modelCount = [int]$manifest.model_count
    if ($decks.Count -eq 0 -or $modelCount -notin @(0, 1)) {
        throw 'Release manifest has an invalid universal model count.'
    }
    if (@($decks | Sort-Object -Unique).Count -ne $decks.Count) {
        throw 'Release manifest contains duplicate release deck keys.'
    }
    return $manifest
}

function Assert-ReleaseDeepFallbackContract {
    param([Parameter(Mandatory)] $Manifest)
    $modelCount = [int]$Manifest.model_count
    if ([string]$Manifest.deep_fallback -ne 'challenge') {
        throw 'Release manifest Deep fallback must be challenge.'
    }
    if ([bool]$Manifest.deep_runtime_enabled) {
        $planner = $Manifest.deep_planner
        $evidence = [string]$planner.evidence_sha256
        if (
            $modelCount -ne 1 -or
            [int]$Manifest.format_version -ne 4 -or
            [int]$Manifest.schemas.deep_planner -ne 2 -or
            [int]$planner.schema_version -ne 2 -or
            [string]$planner.planner_id -ne 'infoset_puct_v2' -or
            [string]$Manifest.deep_model.variant -ne 'universal_infoset_transformer_v2' -or
            -not [bool]$Manifest.deep_model.universal -or
            -not [bool]$Manifest.native_ai.production_ready -or
            $evidence -notmatch '^[0-9a-f]{64}$'
        ) {
            throw 'Enabled Deep release manifest is incomplete or incompatible.'
        }
    }
    elseif ($modelCount -ne 0) {
        throw 'Disabled Deep release manifest has an inconsistent model count.'
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
