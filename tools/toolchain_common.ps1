$ErrorActionPreference = 'Stop'

function Get-ToolchainLock {
    param([Parameter(Mandatory)] [string]$RepoRoot)
    $path = Join-Path $RepoRoot 'tools\toolchain.lock.json'
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
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
