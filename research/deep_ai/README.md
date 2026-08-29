# Deep AI research

This directory is an opt-in research project. It is not imported by the game,
the default build, release packaging, or regular CI.

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
processes: the current working tree is compared with the frozen 0.8.0 commit
`d4f20ee9775b7e8c80a1994e5c9aa5f1e11c9864`. Native workers own both Agent
processes and the single authoritative `RulesSession` for each game. Run the
cross-version structural smoke:

```powershell
.\tools\run_challenge_arena.ps1 -Preset smoke -Workers 8
```

The command incrementally rebuilds and verifies the binding and both Agents,
then writes checksummed resumable shards, per-game JSONL, failure-only traces,
paired bootstrap statistics, performance splits, explicit gate status, and a
reproducibility manifest under `build/challenge-arena/<preset>`. See
[`docs/native_challenge_arena.md`](docs/native_challenge_arena.md) for presets,
agent specifications, fairness constraints, and promotion criteria.
