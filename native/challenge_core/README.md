# challenge_core

`challenge_core` owns the framework-independent traditional Challenge AI. Its
public provider/controller interfaces stay in the existing headers; search
implementation details are split into:

- provider construction, performance counters and choice entry;
- determinization, action ranking and state scoring;
- post-plan tactical guards;
- energy/retreat, card/discard and general choice policies.

`source_manifest.json` is the single runtime source list consumed by the Godot
and opt-in Deep AI bindings. Search order, derived RNG seeds and performance
counter names are compatibility behavior and must remain deterministic.
