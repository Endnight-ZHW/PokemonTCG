[CmdletBinding()]
param(
    [string[]]$Decks = @('all'),
    [string]$OutputRoot = 'build\ai_training\v10_v3',
    [string]$CondaEnv = 'DL',
    [string]$Device = 'cuda',
    [ValidateSet('hybrid', 'fast', 'quality', 'minimax_fast', 'minimax')]
    [string]$TeacherSearchPreset = 'quality',
    [int]$Workers = 10,
    [int]$Games = -1,
    [int]$BootstrapGames = -1,
    [int]$DaggerGames = -1,
    [int]$EvalGames = -1,
    [int]$PureRlGames = -1,
    [int]$ReplaySameDeal = -1,
    [int]$RolloutBatchGames = -1,
    [int]$UpdatesPerRollout = -1,
    [int]$BootstrapEpochs = -1,
    [int]$SelfPlayEpochs = -1,
    [int]$BatchSize = -1,
    [int]$MaxSteps = -1,
    [int]$MctsSimulations = -1,
    [switch]$Smoke,
    [switch]$ValidateOnly,
    [switch]$ExportOnnx,
    [switch]$RunGodotTests,
    [switch]$Promote,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $repoRoot 'build'
$outputRootPath = if ([IO.Path]::IsPathRooted($OutputRoot)) {
    [IO.Path]::GetFullPath($OutputRoot)
} else {
    [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputRoot))
}
$modelRoot = Join-Path $outputRootPath 'models'
$releaseStagingRoot = Join-Path $outputRootPath 'release_staging'
$runtimeStageRoot = Join-Path $releaseStagingRoot 'godot\data\ai_models'
$promotionTransactionRoot = Join-Path $outputRootPath 'promotion_transaction'
$condaExe = (Get-Command conda.exe -ErrorAction Stop).Source
. (Join-Path $PSScriptRoot 'toolchain_common.ps1')
$release = Get-ReleaseManifest -RepoRoot $repoRoot
Assert-PathUnderRoot -Root $buildRoot -Path $outputRootPath
New-Item -ItemType Directory -Force -Path $modelRoot | Out-Null

if ($Promote -and (-not $ExportOnnx -or -not $RunGodotTests)) {
    throw '-Promote requires both -ExportOnnx and -RunGodotTests so release artifacts are checked before promotion.'
}

$releaseDecks = @($release.release_decks | ForEach-Object { [string]$_ })
$requestedDecks = @()
foreach ($deck in $Decks) {
    if ($deck -eq 'all') {
        $requestedDecks = $releaseDecks
        break
    }
    if ($releaseDecks -notcontains $deck) {
        throw "Unknown deck '$deck'. Expected one of: $($releaseDecks -join ', '), all"
    }
    $requestedDecks += $deck
}
$requestedDecks = @($requestedDecks | Select-Object -Unique)
if ($requestedDecks.Count -eq 0) {
    throw 'No decks requested.'
}

function Test-AcceptedV10Model {
    param(
        [string]$SidecarPath,
        [string]$DeckKey
    )
    if (-not (Test-Path -LiteralPath $SidecarPath)) {
        return $false
    }
    try {
        $payload = Get-Content -LiteralPath $SidecarPath -Raw | ConvertFrom-Json
        $metadata = $payload.metadata
        return (
            $metadata.accepted -eq $true -and
            $metadata.verified -eq $true -and
            [string]$metadata.deck -ceq $DeckKey -and
            [int]$metadata.rules_version -eq [int]$release.schemas.python_rules -and
            [int]$metadata.action_version -eq [int]$release.schemas.python_actions -and
            [int]$metadata.encoder_version -eq [int]$release.schemas.encoder -and
            [int]$metadata.planner_version -eq [int]$release.schemas.planner
        )
    } catch {
        return $false
    }
}

function Invoke-NativeCommand {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$LogPath = ''
    )
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $process = Start-Process `
            -FilePath $FilePath `
            -ArgumentList $ArgumentList `
            -NoNewWindow `
            -PassThru `
            -Wait `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath
        $lines = @()
        if (Test-Path -LiteralPath $stdoutPath) {
            $lines += Get-Content -LiteralPath $stdoutPath
        }
        if (Test-Path -LiteralPath $stderrPath) {
            $lines += Get-Content -LiteralPath $stderrPath
        }
        foreach ($line in $lines) {
            Write-Host $line
        }
        if ($LogPath) {
            $lines | Set-Content -LiteralPath $LogPath -Encoding UTF8
        }
        $script:LastNativeExitCode = $process.ExitCode
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Select-ConfiguredInt {
    param([int]$Value, [int]$Default)
    if ($Value -ge 0) {
        return $Value
    }
    return $Default
}

$trainingArgs = @(
    '--trainer', 'teacher_dagger_rl',
    '--no-warm-start',
    '--device', $Device,
    '--teacher-search-preset', $TeacherSearchPreset,
    '--workers', [string][Math]::Max(1, $Workers),
    '--min-point-rate', '0.50',
    '--min-delta-point-rate', '-0.01',
    '--max-step-exhaustion-rate', '0.05'
)
if ($Smoke) {
    $trainingArgs += @(
        '--games', '1',
        '--bootstrap-games', '4',
        '--dagger-games', '2',
        '--eval-games', '2',
        '--pure-rl-games', '0',
        '--replay-same-deal', '0',
        '--rollout-batch-games', '1',
        '--updates-per-rollout', '1',
        '--max-steps', '40',
        '--mcts-simulations', '1'
    )
} else {
    $trainingArgs += @(
        '--games', [string](Select-ConfiguredInt -Value $Games -Default 0),
        '--bootstrap-games', [string](Select-ConfiguredInt -Value $BootstrapGames -Default 1000),
        '--dagger-games', [string](Select-ConfiguredInt -Value $DaggerGames -Default 1000),
        '--eval-games', [string](Select-ConfiguredInt -Value $EvalGames -Default 600),
        '--pure-rl-games', [string](Select-ConfiguredInt -Value $PureRlGames -Default 0),
        '--replay-same-deal', [string](Select-ConfiguredInt -Value $ReplaySameDeal -Default 0),
        '--rollout-batch-games', [string](Select-ConfiguredInt -Value $RolloutBatchGames -Default 16),
        '--updates-per-rollout', [string](Select-ConfiguredInt -Value $UpdatesPerRollout -Default 2),
        '--bootstrap-epochs', [string](Select-ConfiguredInt -Value $BootstrapEpochs -Default 20),
        '--self-play-epochs', [string](Select-ConfiguredInt -Value $SelfPlayEpochs -Default 10),
        '--batch-size', [string](Select-ConfiguredInt -Value $BatchSize -Default 256),
        '--max-steps', [string](Select-ConfiguredInt -Value $MaxSteps -Default 160),
        '--mcts-simulations', [string](Select-ConfiguredInt -Value $MctsSimulations -Default 64)
    )
}

if ($ValidateOnly) {
    Write-Host 'ValidateOnly mode: skipping training.'
} else {
    foreach ($deck in $requestedDecks) {
        $modelPath = Join-Path $modelRoot "$deck.pt"
        $sidecarPath = Join-Path $modelRoot "$deck.json"
        $progressPath = Join-Path $outputRootPath "$deck.jsonl"
        $consolePath = Join-Path $outputRootPath "$deck.console.log"
        if (-not $Force -and (Test-AcceptedV10Model -SidecarPath $sidecarPath -DeckKey $deck)) {
            Write-Host "[$deck] accepted v10/v3 model already exists; skipping."
            continue
        }
        Write-Host "[$deck] training v10/v3 -> $modelPath"
        $deckArgs = @(
            'run', '-n', $CondaEnv,
            'python', '-B', '.\python\scripts\train_deep_ai.py',
            '--deck', $deck,
            '--output', $modelPath,
            '--progress-jsonl', $progressPath
        ) + $trainingArgs
        Invoke-NativeCommand -FilePath $condaExe -ArgumentList $deckArgs -LogPath $consolePath
        $exitCode = $script:LastNativeExitCode
        if ($exitCode -ne 0) {
            throw "[$deck] training failed with exit code $exitCode. See $consolePath"
        }
    }
}

$hasAllStagedModels = $true
foreach ($deck in $releaseDecks) {
    if (
        -not (Test-Path -LiteralPath (Join-Path $modelRoot "$deck.pt")) -or
        -not (Test-Path -LiteralPath (Join-Path $modelRoot "$deck.json"))
    ) {
        $hasAllStagedModels = $false
        break
    }
}

if ($Smoke) {
    Write-Host 'Smoke mode: skipping full 600-game release validation.'
} elseif ($hasAllStagedModels) {
    Write-Host "Validating staged v10/v3 models in $modelRoot"
    Invoke-NativeCommand -FilePath $condaExe -ArgumentList @(
        'run', '-n', $CondaEnv,
        'python', '-B', '.\python\scripts\validate_ai_models.py',
        '--model-dir', $modelRoot
    )
    $exitCode = $script:LastNativeExitCode
    if ($exitCode -ne 0) {
        throw "Staged v10/v3 models failed release validation."
    }
} else {
    Write-Host 'Not all release deck checkpoints are staged yet; skipping full release validation.'
}

if ($ExportOnnx) {
    if (-not $hasAllStagedModels) {
        throw 'ONNX export requires staged checkpoints for all release decks.'
    }
    Write-Host "Exporting ONNX runtime artifacts to $runtimeStageRoot"
    Invoke-NativeCommand -FilePath $condaExe -ArgumentList @(
        'run', '-n', $CondaEnv,
        'python', '-B', '.\python\scripts\export_onnx_models.py',
        '--checkpoint-root', $modelRoot,
        '--output-root', $runtimeStageRoot
    )
    $exitCode = $script:LastNativeExitCode
    if ($exitCode -ne 0) {
        throw 'ONNX export failed.'
    }
}

$promotionPending = $false
try {
    if ($ExportOnnx -and $RunGodotTests) {
        # A previous shell/process interruption may have left a fully journaled
        # pending install.  Always restore the last committed release first.
        Invoke-NativeCommand -FilePath $condaExe -ArgumentList @(
            'run', '-n', $CondaEnv,
            'python', '-B', '.\python\scripts\promote_ai_models.py',
            '--rollback', '--transaction-root', $promotionTransactionRoot
        )
        $exitCode = $script:LastNativeExitCode
        if ($exitCode -ne 0) {
            throw 'Unable to recover the previous Deep AI promotion transaction.'
        }

        Write-Host 'Installing the verified PT/sidecar/ONNX/runtime bundle as one pending validation transaction.'
        $promotionPending = $true
        Invoke-NativeCommand -FilePath $condaExe -ArgumentList @(
            'run', '-n', $CondaEnv,
            'python', '-B', '.\python\scripts\promote_ai_models.py',
            '--source', $modelRoot,
            '--runtime-source', $runtimeStageRoot,
            '--transaction-root', $promotionTransactionRoot,
            '--defer-commit'
        )
        $exitCode = $script:LastNativeExitCode
        if ($exitCode -ne 0) {
            throw 'Combined Deep AI release promotion failed.'
        }
    }

    if ($RunGodotTests) {
        Write-Host 'Building native ONNX bridge for Windows and Android.'
        & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build_native_ai.ps1') `
            -Target all -Configuration all
        if ($LASTEXITCODE -ne 0) {
            throw 'Native ONNX bridge build failed.'
        }
        if ($promotionPending) {
            Write-Host 'Running Godot tests against the recoverable pending release.'
        } else {
            Write-Host 'Running Godot tests against the current committed release.'
        }
        & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test_godot.ps1')
        if ($LASTEXITCODE -ne 0) {
            throw 'Godot tests failed.'
        }
        & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test_godot_ai.ps1') `
            -RequireDeepRuntime
        if ($LASTEXITCODE -ne 0) {
            throw 'Godot AI regression failed.'
        }
        if ($promotionPending) {
            Write-Host 'Exporting Windows/Android debug builds from the pending release.'
            & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build_godot.ps1') `
                -Target all -Configuration debug
            if ($LASTEXITCODE -ne 0) {
                throw 'Godot Windows/Android pending release export failed.'
            }
            & (Join-Path $PSScriptRoot 'smoke_godot_build.ps1') `
                -RequireAndroidDevice:$Promote
            if ($LASTEXITCODE -ne 0) {
                throw 'Exported pending release smoke failed.'
            }
        }
    }

    if ($Promote) {
        Invoke-NativeCommand -FilePath $condaExe -ArgumentList @(
            'run', '-n', $CondaEnv,
            'python', '-B', '.\python\scripts\promote_ai_models.py',
            '--commit', '--transaction-root', $promotionTransactionRoot
        )
        $exitCode = $script:LastNativeExitCode
        if ($exitCode -ne 0) {
            throw 'Unable to commit the verified Deep AI promotion transaction.'
        }
        $promotionPending = $false

        Write-Host 'Refreshing Godot model metadata after promotion.'
        Invoke-NativeCommand -FilePath $condaExe -ArgumentList @(
            'run', '-n', $CondaEnv,
            'python', '-B', '.\python\scripts\export_godot_data.py',
            '--skip-images'
        )
        $exitCode = $script:LastNativeExitCode
        if ($exitCode -ne 0) {
            throw 'Godot data refresh failed after Deep AI promotion.'
        }

        Invoke-NativeCommand -FilePath $condaExe -ArgumentList @(
            'run', '-n', $CondaEnv,
            'python', '-B', '.\python\scripts\export_godot_data.py',
            '--check', '--skip-images'
        )
        $exitCode = $script:LastNativeExitCode
        if ($exitCode -ne 0) {
            throw 'Godot generated data is stale after Deep AI promotion.'
        }
    } elseif ($promotionPending) {
        Write-Host 'Validation-only run passed; restoring the current committed release.'
        Invoke-NativeCommand -FilePath $condaExe -ArgumentList @(
            'run', '-n', $CondaEnv,
            'python', '-B', '.\python\scripts\promote_ai_models.py',
            '--rollback', '--transaction-root', $promotionTransactionRoot
        )
        $exitCode = $script:LastNativeExitCode
        if ($exitCode -ne 0) {
            throw 'Unable to restore the committed release after staged validation.'
        }
        $promotionPending = $false
    }
} catch {
    $originalError = $_
    if ($promotionPending) {
        Write-Warning 'Rolling back the pending Deep AI release transaction.'
        Invoke-NativeCommand -FilePath $condaExe -ArgumentList @(
            'run', '-n', $CondaEnv,
            'python', '-B', '.\python\scripts\promote_ai_models.py',
            '--rollback', '--transaction-root', $promotionTransactionRoot
        )
        if ($script:LastNativeExitCode -ne 0) {
            throw "Deep AI validation failed and automatic rollback also failed. Original error: $originalError"
        }
    }
    throw $originalError
}

Write-Host 'Deep AI v10/v3 pipeline finished.'
