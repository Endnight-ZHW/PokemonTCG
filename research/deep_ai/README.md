# Deep AI research

This directory is an opt-in research project. It is not imported by the game,
the default client build or release packaging. Challenge Arena validation runs
in regular CI; training and model export remain manual.

The Python teacher and Godot both call the same dependency-free
`native/challenge_core/ChallengeController`. Generated replay, checkpoints and
ONNX files stay under `research/deep_ai/build` unless an explicit output path is
provided.

The research-only `python/engine` package contains the Python state/DTO adapter
needed by teacher and replay experiments. It is private to this opt-in project;
the product release runtime does not import it. The adjacent research-local
`python/data` adapter reads the committed `godot/data/cards.json` and
`godot/data/decks.json` catalogs directly; no root Python package or product
`PYTHONPATH` entry is required.

On Windows, install the pinned environment with `tools/setup_ai_toolchain.ps1`,
then run the manual smoke workflow:

```powershell
.\tools\test_research_smoke.ps1
```

That workflow builds the pybind research binding, samples the shared Challenge
teacher, round-trips replay, performs one CPU learner step, and checks Torch to
ONNX numerical parity. Longer actor, learner and dashboard workflows remain
explicit commands under `tools/`.

## Native Challenge Arena

The research binding also contains a fully native Challenge-vs-Challenge Arena.
On Windows the trusted mode runs both sides as versioned external Agent
processes. Formal evaluation compares the working tree with the frozen current
champion and the historical 0.8.0 anchor; the default structural smoke compares
with 0.8.0 (`d4f20ee9775b7e8c80a1994e5c9aa5f1e11c9864`). Native workers own both Agent
processes and the single authoritative `RulesSession` for each game. Run the
cross-version structural smoke:

```powershell
.\tools\run_challenge_arena.ps1 -Preset smoke -Workers 8
```

The command incrementally rebuilds and verifies the binding and both Agents,
then writes checksummed resumable shards, per-game JSONL, failure-only traces,
complete-block empirical Bernstein confidence sequences, neutral timeout attempts,
diagnostic-only performance splits, explicit reliability/strength gate status,
and a reproducibility manifest under `build/challenge-arena/<preset>`. See
[`docs/native_challenge_arena.md`](docs/native_challenge_arena.md) for presets,
agent specifications, fairness constraints, and promotion criteria.

Challenge and Deep v3 now share immutable protocols, result validation, resumable
evidence, fixed-opponent anchor controls and one promotion decision. Formal runs
allow up to 40,000 games per comparison, stopping early when evidence suffices.
The ordinary research smoke also runs the deterministic simulation calibration.

## Maintenance and regression

The supported learned model uses `encoder_v3`, the V8 information-set encoder,
and the v3 actor/learner/replay contract. The unreferenced older action-state
encoder and its effect-alias adapter have been removed. The Python engine/DTO
adapter remains necessary for the current teacher and replay workflows.

Keep the active frozen champion and 0.8.0 anchor specifications. Superseded
experiment specifications and evaluation reports are removed. All evaluation
presets use the shared protocol, journal and report without format adapters. For decision
parity, use `scripts/compare_challenge_decisions.py` with frozen baseline and
candidate agents; `scripts/benchmark_challenge_decisions.py` measures repeated
fixed requests. Use `scripts/check_challenge_memory.py` for the native lifetime
fixtures. Controller tests cover plan reuse, public knowledge, cancellation,
match reset and fallback. The manual smoke also checks replay, a CPU learner
step and ONNX parity.

Generated replays, checkpoints and exported models under `build/` must be
preserved during repository cleanup. Only identified compiler outputs and
reproducible old audits are disposable. New measurements belong in ignored
output directories; update this README or the Arena guide for lasting changes.
