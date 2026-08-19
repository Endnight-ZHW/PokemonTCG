# PokemonTCG Python engine and Deep AI

Python remains the authoritative rules reference and the orchestration layer
for training. The only executable Deep AI training path is information-set
AlphaZero v2:

- encoder v7;
- checkpoint v12;
- `universal_infoset_transformer_v2`;
- information-set PUCT planner v2;
- one universal model routed to all ten release decks;
- batched CUDA inference for training and CPU ONNX Runtime in clients.

## Environment

Use the pinned `DL` environment from `environment.yml`. The native search
binding is built together with the Godot extension:

```powershell
.\tools\setup_ai_toolchain.ps1
.\tools\build_native_ai.ps1 -Target windows -Configuration release
```

## Frozen Challenge bootstrap

Teacher generation is intentionally separate from the 24-hour training
budget. It produces 1,100 games across the 55 unordered deck matchups and
stores source fingerprints with a game-seed-level 90/10 split.

```powershell
conda run -n DL python -B .\python\scripts\train_deep_ai.py bootstrap `
  --output .\python\data\ai_training\bootstrap-v2.pt `
  --workers 16 --seed 17

conda run -n DL python -B .\python\scripts\train_deep_ai.py verify-cache `
  --cache .\python\data\ai_training\bootstrap-v2.pt
```

## Training

Smoke mode permits the slow Python correctness fallback. Release mode requires
the native ABI for self-play, but training a candidate does not itself enable
Deep or make the run promotable. Native technical readiness and all external
release evidence are checked later by the finalization gate.

```powershell
.\tools\train_deep_ai_v2.ps1 -Preset smoke -AllowPythonFallback
.\tools\train_deep_ai_v2.ps1 -Preset release
```

The trainer runs warm-up, five self-play generations, candidate arenas, the
final Challenge league, checkpoint save, ONNX export, and PyTorch/ONNX parity
verification. Candidate artifacts are written under
`release_staging`; they never modify the live runtime. A successful league
leaves the run in `pending_evidence`, not `passed`.

## Release safety

`deep_runtime_enabled` stays false until every gate passes. After release-scale
rules, information-set, historical performance, Windows and physical Android
evidence exists, create the final self-contained evidence bundle:

```powershell
python .\python\scripts\finalize_alphazero_v2_evidence.py `
  --run-dir <run> `
  --rules-parity <rules.json> `
  --infoset-security <infoset.json> `
  --performance <performance.json> `
  --windows-runtime <windows.json> `
  --android-runtime <android.json>
```

The finalizer copies and hashes every input, revalidates the 6,000-game league,
and only enables the candidate manifests inside the run directory when every
check passes. Live files remain unchanged. Promotion through
`promote_alphazero_v2.py` revalidates that final bundle, current native
technical readiness, universal routes, checkpoint and ONNX hashes, then writes
the model and both release manifests through a rollback-capable transaction.

The Godot client keeps `DeepAIRuntime.load_for_deck(deck_key)` and routes all
ten deck keys to `universal.onnx`. Any load, inference, deadline, non-finite
output, or legal-action-intersection failure falls back to Challenge AI.
