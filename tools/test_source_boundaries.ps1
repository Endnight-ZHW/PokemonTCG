[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Assert-SourceLimits {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$Extensions,
        [Parameter(Mandatory = $true)][int64]$MaxBytes,
        [Parameter(Mandatory = $true)][int]$MaxLines
    )

    foreach ($file in Get-ChildItem -LiteralPath $Directory -Recurse -File) {
        if ($Extensions -notcontains $file.Extension.ToLowerInvariant()) {
            continue
        }
        $lineCount = @([IO.File]::ReadLines($file.FullName)).Count
        if ($file.Length -gt $MaxBytes -or $lineCount -gt $MaxLines) {
            $relative = [IO.Path]::GetRelativePath(
                $repoRoot, $file.FullName).Replace('\', '/')
            throw (
                "Source boundary exceeded: $relative " +
                "bytes=$($file.Length)/$MaxBytes lines=$lineCount/$MaxLines"
            )
        }
    }
}

function Assert-GodotUiSourceLimits {
    $roots = @(
        'godot\scenes',
        'godot\ui',
        'godot\presentation',
        'godot\tests'
    )
    foreach ($relativeRoot in $roots) {
        $directory = Join-Path $repoRoot $relativeRoot
        foreach ($file in Get-ChildItem -LiteralPath $directory -Recurse -File -Filter '*.gd') {
            $relative = [IO.Path]::GetRelativePath(
                $repoRoot, $file.FullName).Replace('\', '/')
            $maxLines = if ($relative -eq 'godot/scenes/main/main.gd') {
                3000
            } else {
                2000
            }
            $lineCount = @([IO.File]::ReadLines($file.FullName)).Count
            if ($file.Length -gt 98304 -or $lineCount -gt $maxLines) {
                throw (
                    "Source boundary exceeded: $relative " +
                    "bytes=$($file.Length)/98304 lines=$lineCount/$maxLines"
                )
            }
        }
    }
}

function Assert-SourceManifest {
    param(
        [Parameter(Mandatory = $true)][string]$ComponentRoot,
        [Parameter(Mandatory = $true)][string[]]$Groups
    )

    $manifestPath = Join-Path $ComponentRoot 'source_manifest.json'
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $listed = @(
        foreach ($group in $Groups) {
            $property = $manifest.PSObject.Properties[$group]
            if ($null -eq $property -or $null -eq $property.Value) {
                throw "Source manifest is missing group '$group': $manifestPath"
            }
            @($property.Value) | ForEach-Object { [string]$_ }
        }
    )
    $duplicate = $listed | Group-Object | Where-Object Count -gt 1 |
        Select-Object -First 1
    if ($null -ne $duplicate) {
        throw "Duplicate source manifest entry '$($duplicate.Name)': $manifestPath"
    }
    foreach ($name in $listed) {
        if (-not (Test-Path -LiteralPath (
            Join-Path $ComponentRoot "src\$name") -PathType Leaf)) {
            throw "Missing source manifest entry target '$name': $manifestPath"
        }
    }
    $sourceRoot = Join-Path $ComponentRoot 'src'
    $actual = @(
        Get-ChildItem -LiteralPath $sourceRoot -Recurse `
            -Filter '*.cpp' -File | ForEach-Object {
                [IO.Path]::GetRelativePath($sourceRoot, $_.FullName).Replace('\', '/')
            } | Sort-Object
    )
    $expected = @($listed | Sort-Object)
    $difference = @(Compare-Object $expected $actual)
    if ($difference.Count -ne 0) {
        $first = $difference[0]
        throw (
            "Source manifest does not cover the component exactly: " +
            "$($first.InputObject) $($first.SideIndicator)"
        )
    }
}

function Get-GuardOpOwners {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $owners = @{}
    foreach ($path in $Paths) {
        $text = Get-Content -Raw -LiteralPath $path
        $guard = [regex]::Match(
            $text,
            'if\s*\(!\((?<body>[\s\S]*?)\)\)\s*return false;'
        )
        if (-not $guard.Success) {
            throw "VM dispatch guard is missing: $path"
        }
        foreach ($match in [regex]::Matches(
            $guard.Groups['body'].Value, 'op\s*==\s*"([^"]+)"')) {
            $op = $match.Groups[1].Value
            if (-not $owners.ContainsKey($op)) {
                $owners[$op] = [Collections.Generic.List[string]]::new()
            }
            $owners[$op].Add([IO.Path]::GetFileName($path))
        }
    }
    return $owners
}

function Assert-VmDispatchOwnership {
    $sourceRoot = Join-Path $repoRoot 'native\ptcg_core\src'
    $support = Get-Content -Raw -LiteralPath (
        Join-Path $sourceRoot 'ptcg_vm_support.cpp')
    $implementedBlock = [regex]::Match(
        $support,
        'IMPLEMENTED_OPS\s*=\s*\{(?<body>[\s\S]*?)\};'
    )
    if (-not $implementedBlock.Success) {
        throw 'Native VM implemented-op registry is missing.'
    }
    $implemented = @(
        [regex]::Matches(
            $implementedBlock.Groups['body'].Value, '"([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique
    )
    if ($implemented.Count -ne 80) {
        throw "Native VM registry must contain exactly 80 ops, found $($implemented.Count)."
    }

    $executeOwners = Get-GuardOpOwners -Paths @(
        Join-Path $sourceRoot 'ptcg_vm_modifier_pipeline.cpp'
        Join-Path $sourceRoot 'ptcg_vm_damage_pipeline.cpp'
        Join-Path $sourceRoot 'ptcg_vm_card_pipeline.cpp'
        Join-Path $sourceRoot 'ptcg_vm_trigger_pipeline.cpp'
    )
    $duplicate = $executeOwners.GetEnumerator() |
        Where-Object { $_.Value.Count -ne 1 } | Select-Object -First 1
    if ($null -ne $duplicate) {
        throw "VM execute op has multiple owners: $($duplicate.Key)"
    }
    $executeOps = @($executeOwners.Keys | Sort-Object)
    $difference = @(Compare-Object $implemented $executeOps)
    if ($difference.Count -ne 0) {
        throw "VM execute ownership mismatch: $($difference[0].InputObject)"
    }

    $resumeOwners = Get-GuardOpOwners -Paths @(
        Join-Path $sourceRoot 'ptcg_vm_choice_cards.cpp'
        Join-Path $sourceRoot 'ptcg_vm_choice_damage.cpp'
        Join-Path $sourceRoot 'ptcg_vm_choice_selection.cpp'
        Join-Path $sourceRoot 'ptcg_vm_choice_triggers.cpp'
    )
    $duplicateResume = $resumeOwners.GetEnumerator() |
        Where-Object { $_.Value.Count -ne 1 } | Select-Object -First 1
    if ($null -ne $duplicateResume) {
        throw "VM continuation op has multiple owners: $($duplicateResume.Key)"
    }
    foreach ($op in $resumeOwners.Keys) {
        if ($implemented -notcontains $op) {
            throw "VM continuation has no implemented execute op: $op"
        }
    }
}

Assert-SourceLimits `
    -Directory (Join-Path $repoRoot 'native\ptcg_core\src') `
    -Extensions @('.cpp', '.hpp') -MaxBytes 98304 -MaxLines 2500
Assert-SourceLimits `
    -Directory (Join-Path $repoRoot 'native\challenge_core\src') `
    -Extensions @('.cpp', '.hpp') -MaxBytes 98304 -MaxLines 2500
Assert-SourceLimits `
    -Directory (Join-Path $repoRoot 'godot\network') `
    -Extensions @('.gd') -MaxBytes 32768 -MaxLines 900
Assert-GodotUiSourceLimits

Assert-SourceManifest `
    -ComponentRoot (Join-Path $repoRoot 'native\ptcg_core') `
    -Groups @('runtime', 'product_only')
Assert-SourceManifest `
    -ComponentRoot (Join-Path $repoRoot 'native\challenge_core') `
    -Groups @('runtime')
Assert-VmDispatchOwnership

Write-Host 'SOURCE_BOUNDARIES_OK cpp=98304/2500 network_gd=32768/900 ui_test_gd=98304/2000 main_gd=98304/3000 vm_ops=80'
