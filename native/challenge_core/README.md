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

Known opponent hand identities are conditional belief constraints rather than
ordinary sampled cards. A fully hidden hand uses the configured three belief
samples; once at least one identity remains known, two conditional samples
cover the hidden remainder and next draw; a fully known hand with an empty deck
uses one. Known-card reply actions receive a ranking-only certainty bonus so
they survive the bounded reply frontier, while leaf evaluation distinguishes
immediately accessible hand resources from deck outs. Turn-plan cache
preconditions include a hash of the known opponent hand and invalidate when
that knowledge changes.
