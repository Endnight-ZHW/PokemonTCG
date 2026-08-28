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
        [string]$Manifest.version -ne '0.8.0' -or
        [int]$Manifest.android_version_code -ne 9 -or
        [int]$Manifest.schemas.card_ir -ne 4 -or
        [int]$Manifest.schemas.godot_actions -ne 4 -or
        [int]$Manifest.schemas.choice_view -ne 2 -or
        [int]$Manifest.schemas.protocol -ne 6 -or
        [int]$Manifest.schemas.snapshot -ne 3 -or
        [int]$Manifest.schemas.journal -ne 1 -or
        [int]$Manifest.schemas.rng -ne 2 -or
        [int]$Manifest.native_rules.card_ir_version -ne 4 -or
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
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/')) + $separator
    $resolvedTarget = [System.IO.Path]::GetFullPath($Path)
    $comparison = if ($env:OS -eq 'Windows_NT') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    if (-not $resolvedTarget.StartsWith(
        $resolvedRoot,
        $comparison
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
        [switch]$Force,
        [ValidateRange(1, 10)] [int]$MaxAttempts = 6,
        [ValidateRange(0, 60)] [int]$RetryDelaySeconds = 5
    )

    if (-not $Force -and (Test-Path -LiteralPath $Destination)) {
        try {
            Test-ArchiveDigest -Path $Destination -Sha256 $Sha256 -Sha1 $Sha1
            return
        } catch {
            Write-Warning "Cached download failed verification and will be replaced: $Destination"
        }
    }

    $partial = "$Destination.part"
    if ($Force -and (Test-Path -LiteralPath $partial)) {
        Remove-Item -LiteralPath $partial -Force
    }
    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $curl) {
        $curl = Get-Command curl -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $downloadCompleted = $false
        try {
            if (
                (Test-Path -LiteralPath $partial) -and
                (-not [string]::IsNullOrWhiteSpace($Sha256) -or
                    -not [string]::IsNullOrWhiteSpace($Sha1))
            ) {
                try {
                    Test-ArchiveDigest -Path $partial -Sha256 $Sha256 -Sha1 $Sha1
                    Move-Item -LiteralPath $partial -Destination $Destination -Force
                    return
                } catch {
                    # A valid partial is promoted above. Otherwise curl resumes it.
                }
            }
            Write-Host "Downloading $Uri (attempt $attempt/$MaxAttempts)"
            if ($null -ne $curl) {
                & $curl.Source `
                    --fail `
                    --location `
                    --silent `
                    --show-error `
                    --connect-timeout 30 `
                    --continue-at - `
                    --output $partial `
                    $Uri
                $curlExitCode = $LASTEXITCODE
                if ($curlExitCode -ne 0) {
                    if ($curlExitCode -eq 33 -and (Test-Path -LiteralPath $partial)) {
                        Remove-Item -LiteralPath $partial -Force
                    }
                    throw "curl exited with code $curlExitCode"
                }
            } else {
                if (Test-Path -LiteralPath $partial) {
                    Remove-Item -LiteralPath $partial -Force
                }
                Invoke-WebRequest -Uri $Uri -OutFile $partial
            }
            $downloadCompleted = $true
            Test-ArchiveDigest -Path $partial -Sha256 $Sha256 -Sha1 $Sha1
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            return
        } catch {
            $failure = $_.Exception.Message
            if ($downloadCompleted -and (Test-Path -LiteralPath $partial)) {
                Remove-Item -LiteralPath $partial -Force
            }
            if ($attempt -eq $MaxAttempts) {
                if (Test-Path -LiteralPath $partial) {
                    Remove-Item -LiteralPath $partial -Force
                }
                throw "Failed to download and verify $Uri after $MaxAttempts attempts: $failure"
            }
            $delay = $RetryDelaySeconds * $attempt
            $resumeBytes = if (Test-Path -LiteralPath $partial) {
                (Get-Item -LiteralPath $partial).Length
            } else {
                0
            }
            Write-Warning "Download attempt $attempt/$MaxAttempts failed: $failure. Retrying in $delay seconds (resume_bytes=$resumeBytes)."
            if ($delay -gt 0) {
                Start-Sleep -Seconds $delay
            }
        }
    }
}

function Set-PortableGodotEnvironment {
    param([Parameter(Mandatory)] [string]$ToolsRoot)
    $env:APPDATA = Join-Path $ToolsRoot 'appdata'
    $env:GRADLE_USER_HOME = Join-Path $ToolsRoot 'gradle-home'
    New-Item -ItemType Directory -Force -Path $env:APPDATA, $env:GRADLE_USER_HOME | Out-Null
}
