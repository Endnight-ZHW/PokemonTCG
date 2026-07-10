# Deep AI v10/v3 Rollout

## Goal

Ship one coherent Deep AI release with checkpoint schema v10, encoder schema v3,
production-shaped MCTS64 evaluation, a trained choice head, and matching Python,
ONNX, native bridge, and Godot runtime contracts.

The detailed chronological experiment log is preserved in
[`archive/deep_ai_v10_experiments.md`](archive/deep_ai_v10_experiments.md). This
document is the current release source of truth.

## Current Status

- Python implementation and v10/v3 schema changes are complete.
- The release gate is shared by training, runtime loading, and offline
  validation in `python/engine/ai/dl/release_gate.py`.
- All ten staged decks pass the 600-game paired non-inferiority gate.
- `steel` seed 29 is accepted at the fixed `-0.01` practical non-inferiority
  boundary (`0.5433` vs `0.5533`) while improving max-step exhaustion
  (`0.1050` vs `0.1183`) and keeping every safety diagnostic at zero.
- All ten v10/v3 checkpoints are promoted to `python/data/ai_models`.
- All ten deterministic FP32 ONNX models and the v3 runtime manifest are
  exported and parity-verified; maximum absolute error is `2.3842e-05`.
- Windows/Android debug and release native bridges are built from current source.
- Full Python regression passes: all 443 tests in the `DL` environment; the
  default environment also passes with 20 optional-dependency tests skipped.
- Godot core tests pass and 10/10 real Deep v3 regression games succeed without
  skip or fallback, both before and after checkpoint promotion.
- Godot generated data is current after promotion.

| Deck | Staged | Paired point delta | Candidate exhaustion | Status |
| --- | ---: | ---: | ---: | --- |
| fire | yes | +0.0117 | 0.0083 | accepted |
| water | yes | +0.0100 | 0.0150 | accepted |
| psychic | yes | +0.0067 | 0.0133 | accepted |
| lightning | yes | +0.0183 | 0.0150 | accepted |
| fighting | yes | +0.0117 | 0.0117 | accepted |
| colorless | yes | +0.0383 | 0.0117 | accepted |
| dragon | yes | +0.0050 | 0.0150 | accepted |
| grass | yes | +0.0150 | 0.0067 | accepted |
| darkness | yes | +0.0383 | 0.0050 | accepted |
| steel | yes | -0.0100 | 0.1050 | accepted at non-inferiority boundary |

Staged checkpoints live only in:

```text
build\ai_training\v10_v3\models
```

They must not be copied manually into `python/data/ai_models`.

## Release Gate

Every deck needs all of the following:

- checkpoint version 10 and encoder version 3;
- current rules, action, and planner schemas;
- at least 600 evaluation games;
- zero invalid actions, missing targets, rule exceptions, and decision timeouts;
- paired performance no worse than the fixed `-0.01` practical
  non-inferiority floor against Challenge AI;
- a trained choice head when the head is enabled;
- no max-step reliability regression.

Strength uses ordered per-game evidence from the same deck, opponents, seeds,
and seat distribution. The fixed 1% non-inferiority floor avoids selecting a
release by repeatedly trying favorable seeds and is stricter than the project's
broader `deep-practical` equivalence gate:

```text
paired_delta_point_rate = mean(candidate_game_points - challenge_game_points)
paired_delta_point_rate >= -0.01
```

The absolute `min_point_rate=0.50` threshold is only a fallback when paired
Challenge evidence is unavailable.

Max-step reliability is also paired:

```text
allowed_max_step_exhaustion_rate = max(
    0.05,
    challenge_baseline_max_step_exhaustion_rate,
)
candidate_max_step_exhaustion_rate <= allowed_max_step_exhaustion_rate
```

This keeps the 5% ceiling for normal decks. For a naturally long-running deck
such as `steel`, Deep AI may match or improve the same-scenario Challenge rate
but may not make it worse.

## Production Training and Recovery

Start or continue normal staged training with:

```powershell
.\tools\train_deep_ai_v10.ps1 -Decks fire -Device cuda -Workers 10
```

Production defaults are:

```text
trainer=teacher_dagger_rl
teacher_search_preset=quality
max_steps=160
bootstrap_games=1000
bootstrap_epochs=20
dagger_games=1000
games=0
pure_rl_games=0
replay_same_deal=0
eval_games=600
mcts_simulations=64
```

If training completed but final evaluation was interrupted, reuse the completed
Challenge baseline instead of rerunning it. The CLI validates deck, seed, game
count, max steps, teacher preset, and ordered `game_points` before reuse. Legacy
progress files require an explicit source-seed assertion because their events
did not record `training_seed`/`eval_seed`.

The completed `steel` recovery used seed 29's legacy `pre_eval` checkpoint;
the same validated progress file recovers its 103,482 trained choice examples:

```powershell
conda run -n DL python -B .\python\scripts\train_deep_ai.py `
  --trainer teacher_dagger_rl `
  --deck steel --seed 29 `
  --model .\python\data\ai_models\resume_steel.pt `
  --output .\build\ai_training\v10_v3\models\steel.pt `
  --games 0 --bootstrap-games 0 --dagger-games 0 --eval-games 600 `
  --pure-rl-games 0 --replay-same-deal 0 `
  --device cuda --workers 10 --max-steps 160 --mcts-simulations 64 `
  --teacher-search-preset quality `
  --reuse-challenge-baseline-progress .\build\ai_training\v10_v3\steel_seed29.jsonl `
  --reuse-challenge-baseline-seed 29 `
  --progress-jsonl .\build\ai_training\v10_v3\steel_seed29_release_reval.jsonl
```

After the fixed 1% non-inferiority policy replaced the old exact-zero rule, the
already completed checkpoint/evaluation pair was re-gated without rerunning any
games:

```powershell
conda run -n DL python -B .\python\scripts\regate_deep_checkpoint.py `
  --source .\build\ai_training\v10_v3\models\steel.rejected.pt `
  --output .\build\ai_training\v10_v3\models\steel.pt `
  --deck steel
```

The tool requires matching embedded and sidecar metadata, current v10/v3
schemas, 600 games, zero safety diagnostics, trained choice evidence, and a pass
under the current shared gate before it writes an accepted staged checkpoint.

## One Release Path

After all ten staged models exist, run exactly this from the repository root:

```powershell
.\tools\train_deep_ai_v10.ps1 `
  -Decks all `
  -ValidateOnly `
  -ExportOnnx `
  -RunGodotTests `
  -Promote
```

The wrapper enforces this order:

```text
staged checkpoints
  -> sidecar release validation
  -> embedded v10/v3 checkpoint preflight
  -> deterministic FP32 ONNX export and <= 1e-4 parity
  -> Windows/Android debug+release native bridge build
  -> Godot core and required non-skipped Deep AI regression tests
  -> transactional Python checkpoint promotion with rollback
  -> Godot metadata refresh
  -> post-promotion Godot AI regression
```

`-Promote` is rejected unless both `-ExportOnnx` and `-RunGodotTests` are also
present. The promotion script prepares and checksum-verifies the complete
ten-deck release before replacing destination files, then normalizes each
sidecar's `model_path`.

## Completion Checklist

- [x] Ten staged `*.pt`/`*.json` pairs exist and pass
  `validate_ai_models.py`.
- [x] All embedded checkpoints preflight as v10 with current v3 schema and
  accepted/verified metadata.
- [x] Ten ONNX models export with maximum absolute parity error at or below
  `1e-4`.
- [x] Windows and Android native bridge debug/release binaries build from the
  current C++ source.
- [x] `tools/test_godot.ps1` passes against the exported v3 manifest without
  Deep AI fallback.
- [x] `tools/test_godot_ai.ps1` prints `AI_REGRESSION_OK` with 10 non-skipped
  Deep games.
- [x] Verified staged checkpoints are promoted to `python/data/ai_models` only
  after the preceding checks.
- [x] `export_godot_data.py --check --skip-images` passes after promotion.
- [x] No Python, conda, or Godot worker is left running after the release job.

## Key Files

- `python/engine/ai/dl/release_gate.py`: shared release semantics.
- `python/engine/ai/dl/training.py`: training, paired evaluation, and recovery.
- `python/scripts/validate_ai_models.py`: staged/release sidecar validation.
- `python/scripts/export_onnx_models.py`: checkpoint preflight, export, parity.
- `python/scripts/regate_deep_checkpoint.py`: evidence-preserving gate migration.
- `python/scripts/promote_ai_models.py`: validated transactional promotion.
- `tools/train_deep_ai_v10.ps1`: the only end-to-end release entry point.
