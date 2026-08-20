# ptcg_core

`ptcg_core` is the framework-independent authoritative rules library. Its
static-library boundary contains only:

- `ptcg_value`: canonical JSON-shaped values;
- `ptcg_random`: portable deterministic RNG;
- `ptcg_rules`: VM IR v3 handlers;
- `ptcg_game`: action legality and settlement;
- `ptcg_rules_session`: state, revision, choice continuation, rollback,
  Snapshot 3, player views and MatchJournal v1.

The implementation lives under `ptcg_core/src`. Both the GDExtension and
pybind builds compile it into a standalone `ptcg_core` static library, then
link their DTO-only adapters against it. The core source closure must not
include Godot, Python, pybind11, ONNX Runtime, or search/AI headers.

Native ABI 2 preserves Protocol 6, Actions 4, ChoiceView 2, Snapshot 3 and VM
IR 3. New card behavior must enter through compiled Card IR; production card
IDs are not valid rule-dispatch keys in this library.
