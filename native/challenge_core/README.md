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

Owner-only `ChoiceView.presentation.browse_card_refs` is consumed only for a
full-deck search belonging to the acting player. It fixes the current deck
multiset, infers the complementary prize multiset, and keeps that prize
knowledge for later decisions in the same match. The memory is discarded as
soon as it can no longer be reconciled exactly with the public state. Browse
refs never expand `ChoiceView.options` and therefore cannot become a legal
selection. Real search choices use the exact split to prefer a last accessible
key component and to avoid a setup Basic whose complete relevant evolution
line is provably prize-locked. When exact memory participates in action search,
its known-prize fingerprint is part of turn-plan cache preconditions, so a plan
made before inspection cannot bypass newly learned information.

Fixed-budget action search uses an adaptive information policy. Most deck
plans determinize the exact inspected deck/prize multisets, while the Psychic
discard/engine plan keeps sampling hidden draws; paired evaluation found that
collapsing that plan to one exact split changed its mirror closure from 2-2 to
0-4. Real choices still use the exact memory in both cases. The diagnostic
request field `use_deck_inspection_action_search` overrides this automatic
policy. `use_deck_inspection=false` disables the whole behavior for paired
Arena A/B tests; the game client enables inspection by default.

## Strategic intent v3

`planner_v3/` contains the strategic replacement described by the design:
public-information belief summaries, prize clocks, attacker pipelines, energy
scheduling, persistent match plans, intent selection, goal-directed complete-
turn compilation, partial-order pruning, opponent worst-response plus recovery
scenarios, and full-sequence safety validation. The engine id is
`strategic_intent_v3`; low-confidence plans fall back transactionally to the
frozen `turn_beam_v2` path.

The optimized attacker pipeline excludes a pure support engine with no
attacker evolution from `next_slot`/`backup_slot`, while still counting every
Benched Pokemon as protection against an immediate board-out. The behavior and
the prize-aware choice adjustments are controlled by the evaluation-only
`use_strategy_optimization` treatment (enabled by the game client).

`strategic_intent_v3` is the product default after passing the all-ten-deck
paired mirror promotion gate at 0.575 [0.525, 0.650], with zero structural
errors and an acceptable 1.115 search-P95 ratio. `turn_beam_v2` remains the
explicit compatibility/fallback engine and the frozen Arena baseline.

## Decision execution and regression checks

The controller captures public information once. A valid strategic continuation,
unique legal action, or rules-proven immediate win returns before requesting the
legacy policy. Otherwise an internal C++ supplier computes that policy once;
the strategic planner still uses its complete action/sequence as the comparison
baseline. Cache consumption/replacement is staged per entry and committed for
the selected policy. No recursive controller call or whole-cache rollback is
needed. Known-hand/prize fingerprints, action-cycle protection, and full-sequence
safety validation remain part of the decision contract.

Real and simulated choices share one typed dispatcher. Fixed sequence replays
match legal actions directly by their stable signatures without scoring the
entire action set. Atomic rules transitions share one implementation, while each
traversal retains its original seed derivation and termination rules. Legacy
reply/recovery scenarios are computed lazily at most once per sample within a
single strategic decision; neither results nor sampled states escape that call.

Counter field names remain compatible and report work actually performed.
`strategic_shadow_legacy=false` and `strategic_shadow_nodes=0` describe a skipped
legacy policy; `strategic_shadow_ms` reports its execution time when needed.
Node-dependent diagnostic hashes can change even when actions remain identical.

`research/deep_ai/tests/test_challenge_controller.py` exercises the complete
native controller, including plan reuse/invalidation, public hand knowledge,
generation cancellation, match reset, and fallback. The research tool
`scripts/compare_challenge_decisions.py` runs two frozen external agents against
the same public requests, applies only the baseline's decisions, and fails on
the first action/choice divergence. Its output is separate from paired Arena
strength/performance reports. See `docs/TRADITIONAL_AI_SIMPLIFICATION.md` at the
repository root for the implementation audit and validation results.
