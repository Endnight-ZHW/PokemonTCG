# PokemonTCG Python authoring and Deep AI tools

The authoritative rules runtime is the shared C++ `ptcg_core`. Python retains
the typed card DSL, import/export tools, native binding and training
orchestration. The writable Deep AI training path is information-set AlphaZero v3:

- encoder v8;
- checkpoint v13;
- `universal_infoset_transformer_v3`;
- information-set PUCT planner v3;
- one universal model routed to all ten release decks;
- whole-game native actors, ragged Safetensors replay, persistent learner;
- batched CUDA inference for training and CPU ONNX Runtime in clients.

## Environment

Use the pinned `DL` environment from `environment.yml`. The native search
binding is built together with the Godot extension:

```powershell
.\tools\setup_ai_toolchain.ps1
.\tools\build_native_ai.ps1 -Target windows -Configuration release
```

## Frozen Challenge bootstrap

Teacher generation is separate from self-play. It uses deterministic bounded
Challenge planning, publishes atomic Safetensors shards and partitions the
train/validation set by game seed.

```powershell
conda run -n DL python -B .\python\scripts\train_deep_ai_v3.py bootstrap `
  --output .\python\data\ai_training\bootstrap-v3 `
  --workers 8 --seed 17

conda run -n DL python -B .\python\scripts\train_deep_ai_v3.py verify-replay `
  --replay .\python\data\ai_training\bootstrap-v3
```

## Training

Smoke, pilot and release modes require the native rules ABI for self-play.
Training a candidate does not itself enable
Deep or make the run promotable. Native technical readiness and all external
release evidence are checked later by the finalization gate.

```powershell
.\tools\train_deep_ai_v3.ps1 -Preset smoke
.\tools\train_deep_ai_v3.ps1 -Preset pilot
.\tools\train_deep_ai_v3.ps1 -Preset release
```

The pilot runs five teacher warm-up epochs and two deterministic 25,000-sample
cycles. Learner parameters, AdamW, GradScaler, schedule and RNG continue even
when an arena candidate is rejected; only champion changes on arena
acceptance. A validation-selected trust-region projection keeps teacher loss
within 10% of the best warm-up value while retaining the maximum safe fraction
of each mixed-pass learner update; validation samples are never used for SGD.
Candidate artifacts never modify the live runtime.

## Release safety

`deep_runtime_enabled` stays false. The v3 engineering gate covers native
trajectories, CUDA soak, replay/restart, throughput, PyTorch/ONNX parity and
Windows runtime behavior:

```powershell
.\tools\verify_native_actor_v3.ps1 -Mode rules
.\tools\verify_native_actor_v3.ps1 -Mode cuda-soak
.\tools\benchmark_ai_pipeline_v3.ps1
.\tools\export_onnx_models_v3.ps1 -Checkpoint <checkpoint-directory>
```

This iteration does not perform formal promotion or physical Android evidence.
v2 checkpoints, replay and runs are rejected explicitly; the retired trainer,
replay, bridge and migration entrypoints are not shipped.

The Godot client keeps `DeepAIRuntime.load_for_deck(deck_key)` and routes all
ten deck keys to `universal.onnx`. Any load, inference, deadline, non-finite
output, or legal-action-intersection failure falls back to Challenge AI.
