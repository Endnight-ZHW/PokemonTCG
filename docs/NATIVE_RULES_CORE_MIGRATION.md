# Native ABI 2 rules-core migration

The repository now has a dependency-free, stateful `ptcg_core` boundary. The
Godot and Python adapters link the same C++ sources; neither adapter implements
rules or mutates authoritative state/RNG directly.

## Implemented foundation

- `RulesSession` owns setup, mulligans, turn order, prizes, revision,
  idempotency records, RNG, pending continuations, rollback, player views,
  Snapshot 3, fork and surrender.
- `NativeRulesSession` is registered in GDExtension and pybind under Native ABI
  2. Protocol 6, Actions 4, ChoiceView 2, Snapshot 3 and VM IR 3 remain stable.
- Protocol 6 welcome/deck-selection payloads carry an optional SHA-256 core
  fingerprint, so upgraded peers reject a mismatched IR/ABI/schema contract
  while older Protocol 6 peers remain wire-compatible.
- MatchJournal v1 records initial configuration/content fingerprints and every
  Action/Choice/command with revision, RNG, state hash and event hash. Python
  and UI Workbench replay stop at the first divergent journal entry.
- Card author data crosses immutable typed Python objects, compiles to
  source-mapped Card IR v3, and is checked by `card lint`, `card test` and
  `card status`. Release sessions pass a `{cards, card_ir}` envelope; the core
  validates its fingerprint and installs the IR commands as the authoritative
  runtime command payload.
- The migration baseline tag is
  `ptcg-rules-migration-baseline-2026-08-19`; the frozen content contract lives
  in `contracts/rules_migration_baseline.json`.

## Traditional AI runtime repair

The post-migration traditional AI regression was caused by treating a redacted
public observation as a restorable Snapshot 3. The runtime now has one
`AIRuntimeStateProjection`; Challenge requires the caller's authoritative
Action v4 set and never re-queries legality from that observation. Hidden card
identities, unrevealed setup boards, resolution continuations and idempotency
records are rejected at the worker boundary.

`RulesSession::fork_for_search(seed)` creates an isolated deterministic branch
without changing the parent. Forks share an immutable card catalog/rules kernel
and omit journals. The Godot binding also exposes a combined fork/apply call so
one candidate crosses the extension boundary once. `GameEngine` owns a
decision-scoped, instance/revision/fingerprint-checked session cache; subsequent
Choice resolution stays in its branch. Ordinary restore/apply uses one session
and lazily materializes the GDScript state DTO only when a result must be
adopted. Windows/Android Debug and Release libraries and the Python binding are
rebuilt from the same core sources.

The targeted Windows acceptance result is 2.3901ms per v2 search node weighted
across 15,904 nodes, with zero invalid actions, Choice failures, rule exceptions
or emergency fallbacks. Frozen v1 passes its unchanged calibration thresholds
(2 clean games, 7,897 simulations, 14 full-budget decisions, 68 deadlines).
Simulation fingerprints change with this repair, so prior evaluation
checkpoints cannot be promoted.

The rebuilt binary/package hashes and the exact schema-v7 provenance
fingerprints are recorded in
`contracts/release_candidates/traditional-ai-native-repair-20260821.json`.

## Commands

```powershell
./tools/test_ptcg_core.ps1
./.tools/python311/python.exe -B ./python/scripts/card_author.py lint
./.tools/python311/python.exe -B ./python/scripts/card_author.py test --card svi-chiy
./.tools/python311/python.exe -B ./python/scripts/card_author.py status --json
./tools/test_fast.ps1
./tools/test_standard.ps1
./tools/test_godot_ai.ps1
./tools/package_release.ps1 -AndroidSigning test
./tools/test_release.ps1
./.tools/python311/python.exe -B ./python/scripts/verify_native_rules_cutover.py
```

The network `AuthoritativeSession` and local/Challenge/Deep routes always use
the fail-closed native adapter. There is no runtime switch and no silent rules
fallback.

## Completed default switch and deletion gate

The user explicitly waived the 14-day internal-run requirement on 2026-08-19.
All other cutover gates passed:

- native rules are mandatory and fail closed for local, Challenge, LAN and
  Relay sessions;
- the GDScript and Python rule/VM executors and Pygame UI are physically
  removed; only binding DTOs, descriptors, card compilation and training
  orchestration remain;
- 348 full Python tests, 161 core-tier Python tests, the dependency-free C++
  suite, Godot contracts, ten Challenge games and LAN/Relay games pass;
- Windows x86_64 and Android arm64 Debug/Release native builds pass; both
  release candidates pass Windows startup and Android APK static runtime
  contracts;
- the 7-run native-search median is 2,843.60 simulations/s, 106.37% of the
  frozen native baseline;
- `native-abi2-rc1-20260819` and `native-abi2-rc2-20260819` are recorded under
  `contracts/release_candidates/`, with distinct package hashes and zero
  differential mismatches.
- the representative complex card `svi-chiy` passes its typed DSL/descriptor
  checks and two native multi-choice scenarios, so content development can
  resume through the new author workflow.

No physical Android device was connected during this local run, so device
smoke is recorded as skipped rather than passed. Deep search contracts run
against the shared core. Deep training now uses the v3 native-actor stack, but
no v3 model has been promoted;
the release Deep entry therefore remains disabled and falls back to Challenge,
as required by the migration scope.
