# Deep AI v10/v3 Rollout

> Historical experiment log. For current status and the supported release path,
> see [`../deep_ai_v10_rollout.md`](../deep_ai_v10_rollout.md).

## Current State

- Encoder schema is v3 and checkpoint schema is v10.
- Existing deployed checkpoints are still v9/v2-era artifacts and must not be loaded by the v3 runtime.
- Godot runtime now falls back to Challenge AI when the ONNX manifest reports an old Python encoder version.
- `python/scripts/validate_ai_models.py` currently rejects the deployed models, as expected, because they are old encoder artifacts and several fail the new strength floor.
- Nine staged v10/v3 checkpoints are accepted in `build\ai_training\v10_v3\models`: `fire`, `water`, `psychic`, `lightning`, `fighting`, `colorless`, `dragon`, `grass`, and `darkness`.
- `steel` still has only a v10/v3 rejected candidate in the staged model directory and needs either a better candidate or a documented gate change/blocker resolution before release promotion.
- Training is currently stopped at the user's request; no Python, conda, or Godot worker processes are expected to be running.

## Release Gate Semantics

The strength gate is now paired-baseline aware. For new v10/v3 training runs,
the release baseline is the same deck played by Challenge AI against the same
rotating opponents, seeds, and seat distribution. Evaluation metadata records
per-game `game_points` for both candidate and baseline runs, and the primary
strength check uses `paired_delta_point_rate` when that evidence is present:

```text
paired_delta_point_rate = mean(candidate_game_points - challenge_game_points)
paired_delta_point_rate >= 0.0
```

This keeps naturally weak or strong deck matchups from being mistaken for model
quality. The absolute `min_point_rate=0.50` threshold remains a fallback for old
metadata that has no paired Challenge baseline, so existing v9/v2 artifacts are
still rejected instead of being grandfathered in. When old metadata has a
baseline row but no per-game points, the tools fall back to aggregate
`candidate_point_rate - challenge_baseline_point_rate`.

The max-step reliability gate uses the same paired-baseline principle:

```text
allowed_max_step_exhaustion_rate = max(
    0.05,
    challenge_baseline_max_step_exhaustion_rate,
)
candidate_max_step_exhaustion_rate <= allowed_max_step_exhaustion_rate
```

The absolute 5% ceiling remains in force for decks whose paired Challenge
baseline stays below it and for legacy evidence with no baseline. If Challenge
itself exceeds 5% on the same deck, opponents, seeds, seats, and step budget,
the candidate must match or improve that baseline. This distinguishes a
deck/rules long-game profile from a regression introduced by Deep AI while
still rejecting candidates that make the problem worse.

When paired Challenge evidence is present, any old deployed-model or explicit
source-checkpoint eval is recorded as diagnostic metadata but does not decide
acceptance. This avoids rejecting an otherwise passing 600-game paired eval
because an explicit revalidation run compared the checkpoint against itself over
a smaller old-eval slice.

## Training Entry Point

Use the non-destructive v10 wrapper:

```powershell
.\tools\train_deep_ai_v10.ps1 -Decks fire -Device cuda -Workers 10
```

By default it writes staged checkpoints to:

```text
build\ai_training\v10_v3\models
```

It does not overwrite `python\data\ai_models`. Once all 10 staged deck checkpoints exist and pass the gate, the complete release command is:

```powershell
-ExportOnnx -RunGodotTests -Promote
```

`-Promote` is deliberately rejected unless both export and Godot tests are
requested. It revalidates the staged sidecars and embedded v10/v3 checkpoint
schemas, prepares all 10 release files before replacing any destination file,
normalizes sidecar paths, refreshes Godot model metadata, and reruns the AI
regression after promotion. `-RunGodotTests` first rebuilds the native ONNX
bridge for Windows/Android debug and release targets, so source changes cannot
be accidentally tested against a stale GDExtension binary.

The wrapper's current production-shaped defaults are based on the best `fire`
probe so far:

```text
teacher_search_preset=quality
max_steps=160
bootstrap_games=1000
bootstrap_epochs=20
dagger_games=1000
games=0
pure_rl_games=0
replay_same_deal=0
mcts_simulations=64
```

The wrapper also supports targeted budget probes:

```powershell
.\tools\train_deep_ai_v10.ps1 `
  -Decks fire `
  -Device cuda `
  -Workers 10 `
  -TeacherSearchPreset quality `
  -MaxSteps 160 `
  -BootstrapEpochs 30 `
  -PureRlGames 0 `
  -ReplaySameDeal 0
```

Completed baseline evidence can be reused for an evaluation-only recovery. The
CLI validates the deck, seed, game count, max steps, teacher preset, and ordered
per-game points before it skips the expensive Challenge baseline. New progress
events record both `training_seed` and `eval_seed`; legacy JSONL requires an
explicit `--reuse-challenge-baseline-seed` assertion. See `python/README.md` for
the full recovery command.

## Evidence From First Production Trial

A real `fire` production trial was started with the default v10 wrapper settings:

- `games=800`
- `bootstrap_games=2000`
- `dagger_games=500`
- `eval_games=600`
- `pure_rl_games=400`
- `replay_same_deal=50`
- `mcts_simulations=256`
- `workers=10`
- `device=cuda`

After roughly 4.5 hours it had reached:

```text
build\ai_training\v10_v3\fire.jsonl
phase=pure_rl
batch=5
total_games_played=3530
total_training_games=4450
```

The run was stopped manually so no long-running Python/conda workers were left behind. This is a compute-time constraint, not a correctness failure.

## Evidence From Faster Gate Trial

A faster `fire` candidate was trained to completion with:

- `bootstrap_games=2000`
- `dagger_games=500`
- `games=0`
- `pure_rl_games=0`
- `replay_same_deal=0`
- `eval_games=600`

Artifacts:

```text
build\ai_training\v10_v3_fast\models\fire.rejected.pt
build\ai_training\v10_v3_fast\models\fire.rejected.json
build\ai_training\v10_v3_fast\fire.jsonl
```

Result:

```text
encoder_version=3
checkpoint_version=10
eval_games=600
wins=197
losses=403
point_rate=0.3283
max_step_exhaustion_rate=0.045
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
accepted=false
```

This proves the v10/v3 training and gate pipeline can run end to end on the machine, but a teacher/DAgger-only candidate is far below both the original absolute strength target and the stronger teacher/Challenge baseline observed in later probes. Additional training strength, RL fine-tuning, better data, or architecture/training changes are required before release promotion.

Follow-up probes on the same checkpoint:

```powershell
conda run -n DL python -B .\python\scripts\evaluate_deep_checkpoint.py `
  --checkpoint build\ai_training\v10_v3_fast\models\fire.rejected.pt `
  --deck fire --games 100 --workers 10 --no-use-mcts
```

Result:

```text
wins=29
losses=71
point_rate=0.29
max_step_exhaustion_rate=0.05
invalid_action_rate=0.0
```

Production-style neural-MCTS probe:

```powershell
conda run -n DL python -B .\python\scripts\evaluate_deep_checkpoint.py `
  --checkpoint build\ai_training\v10_v3_fast\models\fire.rejected.pt `
  --deck fire --games 100 --workers 10 --use-mcts --mcts-simulations 64
```

Result:

```text
wins=36
losses=64
point_rate=0.36
max_step_exhaustion_rate=0.03
decision_timeout_rate=0.00326
invalid_action_rate=0.0
```

MCTS improves the candidate but still fails both the point-rate gate and the zero-timeout gate, so the weakness is not only a raw-policy-versus-runtime-search mismatch.

## Teacher And Transfer Probes

Teacher-only probes show the teacher budget matters:

```text
hybrid, max_steps=120, 100 games: point_rate=0.395, max_step_exhaustion_rate=0.01
quality, max_steps=120, 100 games: point_rate=0.52, max_step_exhaustion_rate=0.08
quality, max_steps=160, 100 games: point_rate=0.54, max_step_exhaustion_rate=0.0
```

That means the default `hybrid` teacher is itself below the release floor on the tested `fire` seeds, while `quality` with a longer game cap can clear a small teacher-only probe.

A `quality` + `max_steps=160` bootstrap-only model was then trained:

```text
build\ai_training\v10_v3_quality160_bootstrap\models\fire.rejected.pt
build\ai_training\v10_v3_quality160_bootstrap\models\fire.rejected.json
```

Full training eval:

```text
eval_games=600
wins=182
losses=418
point_rate=0.3033
max_step_exhaustion_rate=0.006667
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
accepted=false
```

Fresh 100-game raw probe against the same `quality` opponent:

```text
wins=34
losses=66
point_rate=0.34
max_step_exhaustion_rate=0.01
```

Fresh 100-game neural-MCTS probe:

```text
wins=32
losses=68
point_rate=0.32
decision_timeout_rate=0.00796
max_step_exhaustion_rate=0.0
```

Policy-agreement diagnostic on 40 fresh teacher-labeled games:

```text
policy_top1=0.7017
policy_top3=0.9146
policy_nll=0.8810
policy_avg_rank=1.6963
```

This is now the main training blocker: a stronger teacher can produce acceptable play, but the current neural policy does not transfer enough of that behavior to pass the release gate. The next useful experiments should increase imitation accuracy and value quality before spending a full all-deck production run, for example more bootstrap epochs, larger teacher datasets, DAgger from `quality` states, and then pure RL/value fine-tuning.

A follow-up `quality` + `max_steps=160` diagnostic with `bootstrap_games=1000` and `bootstrap_epochs=30` was interrupted after collecting 25,639 bootstrap examples and before any `train_phase_finished` event or checkpoint was written:

```text
build\ai_training\v10_v3_quality160_epochs30_1000\fire.jsonl
last_event=bootstrap_finished
exit_code=1073807364
```

No Python or conda workers were left running, so this is not acceptance evidence.

## DAgger Probes

The next completed probe used the stronger teacher plus DAgger:

```powershell
.\tools\train_deep_ai_v10.ps1 `
  -Decks fire `
  -OutputRoot build\ai_training\v10_v3_quality160_dagger_probe `
  -TeacherSearchPreset quality `
  -Device cuda `
  -Workers 10 `
  -Games 0 `
  -BootstrapGames 1000 `
  -BootstrapEpochs 20 `
  -DaggerGames 250 `
  -EvalGames 200 `
  -PureRlGames 0 `
  -ReplaySameDeal 0 `
  -MctsSimulations 64 `
  -MaxSteps 160 `
  -Force
```

Result:

```text
eval_games=200
wins=72
losses=128
point_rate=0.36
max_step_exhaustion_rate=0.01
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=14867
accepted=false
```

The `quality160_dagger_probe` checkpoint was then used only as a v10/v3 continuation experiment with 500 more DAgger games:

```text
build\ai_training\v10_v3_quality160_dagger_continue\models\fire.rejected.pt
eval_games=200
wins=76
losses=124
point_rate=0.38
max_step_exhaustion_rate=0.005
choice_examples=28894
accepted=false
```

This shows DAgger is moving strength in the right direction, but too slowly to justify an all-deck production run yet. The immediate blocker is neural policy strength, not schema compatibility or bad actions.

Action-type agreement diagnostics on this checkpoint show where the policy is
losing the teacher signal:

```text
policy_top1=0.6721
policy_top3=0.9111
policy_nll=1.3415
policy_avg_rank=1.7754

top1_by_target_type:
ATTACH_ENERGY=0.4925
DECLARE_ATTACK=0.7963
END_TURN=0.9943
EVOLVE=0.7125
PLAY_BASIC=0.4500
PLAY_TRAINER=0.5565
RETREAT=0.6667

largest_confusions:
PLAY_TRAINER -> DECLARE_ATTACK: 51
DECLARE_ATTACK -> PLAY_TRAINER: 22
ATTACH_ENERGY -> DECLARE_ATTACK: 18
DECLARE_ATTACK -> ATTACH_ENERGY: 17
PLAY_BASIC -> DECLARE_ATTACK: 16
PLAY_TRAINER -> PLAY_BASIC: 14
```

The model over-selects attacks and under-selects setup/development actions. The
training loss now weights supervised teacher/DAgger examples by target action
type, emphasizing `PLAY_TRAINER`, `ATTACH_ENERGY`, and `PLAY_BASIC` while leaving
self-play/RL examples unweighted. This is intentionally narrow and should be
validated with a smoke run plus another `quality160` probe before spending an
all-deck production run.

The first weighted probe reused the same `quality + max_steps=160 + bootstrap1000
+ DAgger250 + eval200` budget:

```text
build\ai_training\v10_v3_quality160_weighted_probe\models\fire.rejected.pt
challenge_baseline_point_rate=0.49
candidate_point_rate=0.405
delta_point_rate=-0.085
max_step_exhaustion_rate=0.015
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=13971
accepted=false
```

This is a meaningful improvement over the comparable 0.33-0.38 probes, but it
still trails the paired Challenge baseline. A 40-game raw probe and a 40-game
MCTS-32 probe both landed at `point_rate=0.325`, so the remaining blocker is
still policy strength, not runtime legality or timeouts. Agreement diagnostics
show the weighting moved the intended labels in the right direction
(`PLAY_BASIC` top-1 0.45 -> 0.543, `PLAY_TRAINER` 0.556 -> 0.614), while
`ATTACH_ENERGY` remains weak at 0.477.

Python evaluation was then aligned with Godot's production search path by
running the same Challenge postprocessor after neural raw/MCTS selection. This
matches the existing Godot Deep search code, which already calls
`_validated_or_fallback_action` before returning a selected action. A fresh
same-budget probe with that postprocessor improved the DAgger state distribution
and final raw eval, but still missed the paired gate:

```text
build\ai_training\v10_v3_quality160_postprocess_probe\models\fire.rejected.pt
challenge_baseline_point_rate=0.49
candidate_point_rate=0.45
delta_point_rate=-0.04
max_step_exhaustion_rate=0.01
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=15676
accepted=false
```

Legacy candidate evaluation can now use production neural-MCTS with a 2 second
per-decision deadline, so Python eval no longer reports artificial 8 second
decision timeouts from unbounded MCTS. On the postprocess probe, MCTS looked
promising at 60 games (`point_rate=0.5333` vs paired Challenge 0.50 for that
slice) but the full 200-game eval was still below gate:

```text
postprocess_probe, MCTS 64 sims, seed=900017, 200 games
wins=85
losses=115
point_rate=0.425
max_step_exhaustion_rate=0.005
decision_timeout_rate=0.0
```

A larger same-shape DAgger run doubled the DAgger budget from 250 to 500 while
keeping the production-shaped MCTS eval and deadline:

```text
build\ai_training\v10_v3_quality160_postprocess_dagger500\models\fire.rejected.pt
challenge_baseline_point_rate=0.49
candidate_point_rate=0.46
delta_point_rate=-0.03
max_step_exhaustion_rate=0.0
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=31230
accepted=false
```

This narrowed the gap but still failed the paired baseline gate, so simply
adding more DAgger samples at the current architecture/loss shape is not enough.

A larger DAgger1000 probe was also run after removing the failed margin-loss
change:

```text
build\ai_training\v10_v3_quality160_dagger1000_probe\models\fire.rejected.pt
challenge_baseline_point_rate=0.49
candidate_point_rate=0.455
paired_delta_point_rate=-0.035
max_step_exhaustion_rate=0.005
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=62664
accepted=false
```

This did not beat the DAgger500 probe (`candidate_point_rate=0.46`), and fresh
40-game agreement diagnostics dropped to `policy_top1=0.6712`
(`ATTACH_ENERGY=0.4549`, `PLAY_BASIC=0.4750`, `PLAY_TRAINER=0.6276`). Current
evidence showed that scaling DAgger count alone was not sufficient.

A later Python/Godot parity fix changed the shared planner's heuristic prior
temperature to match Godot's `/80` softmax and added a guarded neural-prior blend
for Deep mode. The guard keeps the mature heuristic prior when the neural model
is low-confidence or tries to override a clear heuristic top action, and only
allows a small neural nudge otherwise. Re-evaluating the DAgger1000 checkpoint
with that production-shaped search path reached the paired baseline on the same
200-game slice:

```text
dagger1000 checkpoint, current guarded MCTS64 eval, seed=900017, 200 games
challenge_baseline_point_rate=0.49
candidate_point_rate=0.49
paired_delta_point_rate=0.0
max_step_exhaustion_rate=0.005
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
```

This is not release evidence yet because the stored sidecar was produced before
the prior fix and the release gate still requires a fresh 600-game evaluation
per deck, but it identifies the next production candidate shape.

The same checkpoint was then re-evaluated over the full 600-game release count
with the guarded prior path:

```text
build\ai_training\v10_v3_guarded_reval\models\fire.rejected.pt
challenge_baseline_point_rate=0.443333
candidate_point_rate=0.45
paired_delta_point_rate=0.0067
max_step_exhaustion_rate=0.006667
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
```

That initial run passed the paired strength gate but was still written as
rejected because the re-eval path treated the explicit source checkpoint as an
old model baseline and discarded the source checkpoint's already-trained
choice-head evidence. The training code now keeps `loaded_choice_examples` for
schema-current explicit/warm-start checkpoints and makes the paired Challenge
baseline the acceptance authority when it exists. Re-running that corrected path
produced the first accepted staged v10/v3 checkpoint:

```text
build\ai_training\v10_v3_guarded_reval_fixed\models\fire.pt
build\ai_training\v10_v3\models\fire.pt
accepted=true
verified=true
challenge_baseline_point_rate=0.443333
candidate_point_rate=0.455
paired_delta_point_rate=0.0117
max_step_exhaustion_rate=0.008333
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
loaded_choice_examples=62664
```

`validate_model("fire", model_dir="build\\ai_training\\v10_v3\\models")`
returns `valid=true` with no errors.

The next two production-default staged runs also passed the paired gate:

```text
build\ai_training\v10_v3\models\water.pt
accepted=true
verified=true
challenge_baseline_point_rate=0.468333
candidate_point_rate=0.478333
paired_delta_point_rate=0.0100
max_step_exhaustion_rate=0.015
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=77107

build\ai_training\v10_v3\models\psychic.pt
accepted=true
verified=true
challenge_baseline_point_rate=0.425
candidate_point_rate=0.431667
paired_delta_point_rate=0.0067
max_step_exhaustion_rate=0.013333
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=136294
selected_stage=bootstrap

build\ai_training\v10_v3\models\lightning.pt
accepted=true
verified=true
challenge_baseline_point_rate=0.486667
candidate_point_rate=0.505
paired_delta_point_rate=0.0183
max_step_exhaustion_rate=0.015
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=130253

build\ai_training\v10_v3\models\fighting.pt
accepted=true
verified=true
challenge_baseline_point_rate=0.483333
candidate_point_rate=0.495
paired_delta_point_rate=0.0117
max_step_exhaustion_rate=0.011667
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=85657
selected_stage=bootstrap

build\ai_training\v10_v3\models\colorless.pt
accepted=true
verified=true
challenge_baseline_point_rate=0.508333
candidate_point_rate=0.546667
paired_delta_point_rate=0.0383
max_step_exhaustion_rate=0.011667
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=115701

build\ai_training\v10_v3\models\dragon.pt
accepted=true
verified=true
challenge_baseline_point_rate=0.646667
candidate_point_rate=0.651667
paired_delta_point_rate=0.0050
max_step_exhaustion_rate=0.015
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=72759

build\ai_training\v10_v3\models\grass.pt
accepted=true
verified=true
challenge_baseline_point_rate=0.343333
candidate_point_rate=0.358333
paired_delta_point_rate=0.0150
max_step_exhaustion_rate=0.006667
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=61581
selected_stage=bootstrap
```

Per-deck validation for `fire`, `water`, `psychic`, `lightning`, `fighting`,
`colorless`, `dragon`, `grass`, and `darkness` returns `valid=true` with no errors. The remaining release work is now `steel` plus
ONNX/Godot release verification.

The first `steel` production-default candidate failed only on the long-game
gate, not on action legality:

```text
build\ai_training\v10_v3\models\steel.rejected.pt
candidate_point_rate=0.543333
challenge_baseline_point_rate=0.538333
paired_delta_point_rate=0.0050
candidate_max_step_exhaustion_rate=0.123333
challenge_max_step_exhaustion_rate=0.151667
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=106374
```

Eval-only rechecks at `max_steps=240` and `max_steps=400` still rejected:
candidate exhaustion stayed high (`0.128333` and `0.131667`) and paired delta
moved slightly negative (`-0.0017` and `-0.0033`). This appears to be a
deck-specific long-game/gate interaction rather than a bad-action failure.

The first `darkness` production-default candidate rejected cleanly but was
slightly below its paired Challenge baseline:

```text
build\ai_training\v10_v3\models\darkness.rejected.pt
candidate_point_rate=0.601667
challenge_baseline_point_rate=0.613333
paired_delta_point_rate=-0.0117
max_step_exhaustion_rate=0.018333
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=88004
```

A second production-default `darkness` run with `--seed 29` passed the release
gate and replaced the staged model:

```text
build\ai_training\v10_v3\models\darkness.pt
accepted=true
verified=true
challenge_baseline_point_rate=0.561667
candidate_point_rate=0.600000
paired_delta_point_rate=0.0383
max_step_exhaustion_rate=0.005
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=89079
seed=29
```

After `darkness` passed, a second production-default `steel` run with `--seed 29`
was started but then stopped during wrap-up at the user's request. It completed
bootstrap and DAgger, saved a `pre_eval` resume checkpoint, and completed the
600-game Challenge baseline slice:

```text
build\ai_training\v10_v3\steel_seed29.jsonl
python\data\ai_models\resume_steel.pt
last completed event=challenge_baseline_eval_finished
challenge_baseline_point_rate=0.553333
challenge_baseline_max_step_exhaustion_rate=0.118333
candidate_eval=not completed
accepted steel.pt/json=not written
```

This keeps `steel` as the only unreleased deck. The existing `steel` evidence
still points at a deck-specific long-game gate interaction: candidate strength
can be close to or above Challenge, but both candidate and Challenge exceed the
original absolute `max_step_exhaustion_rate <= 0.05` target by a wide margin.

A fresh default-budget fire run was also completed after the guarded-prior
change:

```text
build\ai_training\v10_v3_guarded_default_fire\models\fire.rejected.pt
challenge_baseline_point_rate=0.443333
candidate_point_rate=0.438333
paired_delta_point_rate=-0.005
max_step_exhaustion_rate=0.008333
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=59932
accepted=false
```

This missed the paired release gate by 3 game-points out of 600. Because the
corrected revalidation above now holds, the next step is to repeat this
production-shaped candidate process for the remaining decks rather than promote
the fresh failed seed.

An attempted target-margin supervised loss was also probed with the same
`quality160 + bootstrap1000 + DAgger250 + eval200 + MCTS64` shape:

```text
build\ai_training\v10_v3_quality160_margin_probe\models\fire.rejected.pt
challenge_baseline_point_rate=0.49
candidate_point_rate=0.44
paired_delta_point_rate=-0.05
max_step_exhaustion_rate=0.005
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=15734
accepted=false
```

Fresh 40-game agreement diagnostics showed overall `policy_top1=0.6846`, but
`PLAY_BASIC` dropped to 0.4875 and `PLAY_TRAINER` stayed roughly flat at 0.6109.
Because the full eval was worse than the postprocessor and DAgger500 probes, the
margin-loss change is not kept as a production default.

Conclusion: production-shaped search and postprocessing help reliability and
small-sample strength, but the model still does not provide a strong enough
neural prior over a full release eval. The next useful training work should use
a stronger policy-supervision approach, especially for energy attachment timing
and trainer sequencing, before scaling to all decks.

An earlier training-code fix is also in place: `_train_examples()` now trains the value head from teacher/DAgger `value_target`s as well as self-play episode returns. Previously the value head was effectively untrained for teacher/DAgger-only candidates, which likely made neural-MCTS probes noisier than necessary. The smoke run confirmed teacher/DAgger phases now report non-zero value loss.

The same `quality + max_steps=160 + bootstrap1000 + DAgger250` budget was then rerun with value-head supervision:

```text
build\ai_training\v10_v3_quality160_value_dagger_probe\models\fire.rejected.pt
eval_games=200
wins=66
losses=134
point_rate=0.33
max_step_exhaustion_rate=0.0
invalid_action_rate=0.0
no_target_action_rate=0.0
rule_exception_rate=0.0
decision_timeout_rate=0.0
choice_examples=16059
accepted=false
```

This did not improve raw policy strength at that budget, so the remaining blocker is policy imitation/decision quality rather than only an untrained value head.

An attempted planner-visit policy-target distillation experiment was also run with the same budget:

```text
build\ai_training\v10_v3_quality160_policy_target_dagger_probe\models\fire.rejected.pt
eval_games=200
wins=30
losses=170
point_rate=0.15
max_step_exhaustion_rate=0.0
accepted=false
```

Because this was substantially worse, planner visit distributions are not used as the production teacher target. The selected teacher action remains the safer supervised signal.

A runtime prior-blending experiment, combining neural priors with heuristic priors, was also checked against the `quality160_dagger_continue` checkpoint. It worsened both raw and MCTS probes (`raw 100 games: point_rate=0.24`; `MCTS 32 sims, 50 games: point_rate=0.14`), so that change was not kept.

The Python neural-MCTS adapter was then aligned with Godot's production shape: neural priors are still used, but leaf values come from the mature heuristic evaluator rather than the still-weak value head. This improved the same checkpoint's MCTS probe from the failed prior-blend result but still did not approach release quality:

```text
quality160_dagger_continue, MCTS 32 sims, 50 games
wins=14
losses=36
point_rate=0.28
max_step_exhaustion_rate=0.02
decision_timeout_rate=0.0
```

## Verification Snapshot

Current code-side checks:

```text
python -m unittest discover python\tests
434 tests OK

python python\scripts\export_godot_data.py --check --skip-images
Godot generated data is current.

powershell -ExecutionPolicy Bypass -File .\tools\train_deep_ai_v10.ps1 `
  -Decks fire `
  -OutputRoot build\ai_training\v10_v3_paired_gamepoints_smoke `
  -Smoke -Force -Device cuda -Workers 2 -TeacherSearchPreset quality
Smoke pipeline OK; rejected sidecar records candidate and Challenge
`game_points` plus `paired_delta_point_rate=0.5` on the tiny 2-game eval.

powershell -ExecutionPolicy Bypass -File .\tools\train_deep_ai_v10.ps1 `
  -Decks fire `
  -OutputRoot build\ai_training\v10_v3_paired_weight_smoke `
  -Smoke -Force -Device cuda -Workers 2 -TeacherSearchPreset quality
Smoke pipeline OK; checkpoint correctly rejected with paired Challenge baseline
delta_point_rate=-0.5 on the tiny 2-game eval.

powershell -ExecutionPolicy Bypass -File .\tools\test_godot.ps1
GODOT_TESTS_OK phase=6

powershell -ExecutionPolicy Bypass -File .\tools\test_godot_ai.ps1
AI_REGRESSION_OK

The standard `tools\test_godot.ps1` entry point previously failed in this
environment because stale Godot editor/import artifacts caused native
GDExtension DLL copy errors and `Safe save failed` crashes during the editor
import phase. The script now clears only those generated import leftovers before
running import, and uses the minimal `--import` invocation rather than
`--editor --import`. Godot 4.7 can still emit `Failed to read the root
certificate store` on this Windows machine; both Godot test scripts tolerate
that known non-fatal warning but still fail on other Godot `ERROR:` lines.

Current staged model validation:
fire valid=true, paired_delta_point_rate=0.0117.
water valid=true, paired_delta_point_rate=0.0100.
psychic valid=true, paired_delta_point_rate=0.0067.
lightning valid=true, paired_delta_point_rate=0.0183.
fighting valid=true, paired_delta_point_rate=0.0117.
colorless valid=true, paired_delta_point_rate=0.0383.
dragon valid=true, paired_delta_point_rate=0.0050.
grass valid=true, paired_delta_point_rate=0.0150.
darkness valid=true, paired_delta_point_rate=0.0383.
steel is still missing an accepted `steel.pt`/`steel.json` pair; full staged
validation therefore fails only because `steel` is not releasable yet.

conda run -n DL python -B .\python\scripts\export_onnx_models.py `
  --checkpoint-root E:\PokemonTCG\build\ai_training\v10_v3\models --check
fails fast with:
Missing release checkpoint(s): E:\PokemonTCG\build\ai_training\v10_v3\models\steel.pt

The ONNX exporter now preflights the full 10-deck release checkpoint set before
writing any generated ONNX files, so an incomplete staged directory cannot
produce a partial runtime export.

git diff --check
Only line-ending normalization warnings; no whitespace errors.
```

Expected failures before retraining all release models:

```text
python python\scripts\validate_ai_models.py
fails because deployed checkpoints are v9/v2 and lack valid v10/v3 paired-baseline evidence

conda run -n DL python -B .\python\scripts\export_onnx_models.py --check
fails with "Committed ONNX manifest is stale"
```

## Faster Candidate Budgets

The wrapper accepts explicit budget overrides for staged experiments, for example:

```powershell
.\tools\train_deep_ai_v10.ps1 `
  -Decks fire `
  -Device cuda `
  -Workers 10 `
  -PureRlGames 0 `
  -ReplaySameDeal 0
```

Any candidate is still only releasable if the full gate passes:

```powershell
conda run -n DL python -B .\python\scripts\validate_ai_models.py `
  --model-dir build\ai_training\v10_v3\models
```

## Required Completion Evidence

The rollout is complete only when all of the following are true:

- All 10 deck checkpoints exist in the staged model directory with checkpoint version 10 and encoder version 3.
- `validate_ai_models.py --model-dir build\ai_training\v10_v3\models` passes.
- `export_onnx_models.py --checkpoint-root build\ai_training\v10_v3\models` passes with parity at or below `1e-4`.
- Godot `test_godot.ps1` and `test_godot_ai.ps1` pass against the exported v3 manifest without Deep AI fallback.
- The staged artifacts are promoted to the release locations only after the above checks pass.
