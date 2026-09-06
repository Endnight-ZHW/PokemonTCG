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
compatibility `turn_beam_v2` path.

The optimized attacker pipeline excludes a pure support engine with no
attacker evolution from `next_slot`/`backup_slot`, while still counting every
Benched Pokemon as protection against an immediate board-out. The behavior and
the prize-aware choice adjustments are controlled by the evaluation-only
`use_strategy_optimization` treatment (enabled by the game client).

`strategic_intent_v3` remains the product default. The strength refactor compares
against the actual v3 product controller at commit `a1d0f452`, pinned by the
`challenge_pre_strength_refactor` Arena specification. `turn_beam_v2` remains
the compatibility/fallback engine; its internal scoring also uses the corrected
facts. Historical v2-to-v3 promotion measurements are not evidence for this
new implementation. See `docs/TRADITIONAL_AI_STRENGTH_REFACTOR.md` at the
repository root for this refactor's separate acceptance results.

`strategic_combat.cpp` centralizes per-attack energy/evolution access, expected
damage, coin/mill knockout odds, reload costs and a bounded three-attack prize
route. Readiness and deck-access factors are heuristics, while selected action
sequences are settled by the authoritative rules engine. Shared readiness feeds
frequent leaf evaluation; the more expensive prize route belongs to strategic
comparison and bounded card-bundle evaluation. Choice priors order candidates
but complete resource combinations can change the selection.

Reply and recovery comparisons each allow six atomic actions and require a
completed exchange before approving a general replacement. Immediate prizes
are a preference rather than a blanket veto on setup or sacrifice lines.
Rules legality, proven wins, public-information boundaries and cycle protection
remain mandatory. Attacker commitments are re-evaluated when occupants or
resources change instead of treating a board slot as a Pokemon identity.

The optional request field `time_budget_ms` is a cooperative per-decision
deadline covering planning, replies and choice bundles. Native default `0`
disables it for reproducible fixed-work Arena runs; the Godot client supplies
`5000` when omitted. Expiry returns the best verified available action and
does not act as generation cancellation or commit an incomplete continuation.
Actual work and deadline expiry are exposed through incremental
`native_performance_counters` fields. This is not an OS-enforced hard deadline.

Lifetime regressions are captured in `tests/fixtures/legacy_replay_lifetime.json`
and `tests/fixtures/mandatory_attack_lifetime.json`. Sequence replay owns an
action value before replacing its rules session, and mandatory tactics borrow
attack definitions directly from the catalog rather than a temporary array.
The standalone research agent supports `sanitizer=address` in its SCons build;
`research/deep_ai/scripts/check_challenge_memory.py` replays both real requests
through IPC, checks legal responses and saves sanitizer output and fixture hashes.

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
