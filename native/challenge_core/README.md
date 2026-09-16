# Challenge deck planner

The product engine is `deck_planner_v1`. Godot and research use the same C++
controller and rules implementation. The old v2/v3 controllers, shadow search,
mandatory heuristic overrides and post-plan replacement have been removed.
Historical agents remain external, frozen evaluation artifacts.

## Ownership

- `ChallengeController` validates requests, owns immutable catalog knowledge,
  selects the policy, coordinates cancellation and publishes results.
- `DeckPolicyRegistry` registers the ten release policies in `policies/`.
  Each policy owns its development stages, action preferences, resource retention,
  position valuation, candidate coverage and card combinations. Fire and Water
  allow another target to take the last nonterminal search slot; the other policies
  protect their highest ranked action from that replacement. This applies to replies
  and recovery too.
  Water and Psychic prefer going second;
  the other release policies prefer developing their board first.
- `TurnPlanner` uses one turn expansion for our turn, opponent replies and recovery.
  Every action and subsequent choice is settled by `RulesSession`. Opponent actions
  use the opponent's policy and observation. The selected reply is replayed in
  the original sampled world before recovery is scored. The same candidate set
  is compared in every belief sample, and only complete exchanges are retained.
- `CardEvaluator` and `planning/` supply shared card/combat facts. Policies own
  valuation; shared code contains no deck-name decision branches.
- `DecisionContext` owns per-request samples, memoization and the cooperative
  deadline. Catalog/strategy knowledge is shared immutably across requests.
- `MatchMemory` owns validated continuations, public hand knowledge constraints,
  owner deck-inspection/prize knowledge and no-progress cycle tracking.

`source_manifest.json` is the single runtime source list for both bindings and
native tests. Unknown deck keys use `generic_policy_v1`, limited to three actions
of lookahead. All ten release keys have explicit policies; missing release
strategy data fails configuration instead of silently losing deck specialization.

## Decision contract

`configure(catalog, decks, strategies)`, `decide(request, generation)`,
`cancel(generation)`, `reset_match(match_id)` and `get_contract()` retain their
binding signatures. Action 4, ChoiceView 2 and Snapshot 3 remain unchanged.
The default and only supported engine is `deck_planner_v1`; old engine ids fail
with `unsupported_engine`. Arena sends each frozen agent its own engine id.

Live and simulated choices share the same dispatcher and deck policy. Search,
discard, recovery and energy choices account for complete resource combinations.
`ResourceBundle` passes the current goal, role requirements, retained hand and
resource delta to the policy. Reservations value the last needed copy, rather
than adding the same bonus to every duplicate. Recycling to the deck uses that
destination when evaluating the combination.
A cached continuation must match the acting player, revision, public position,
known hand/prize information and strategy version/hash. Random outcomes close
its deterministic prefix. Cancellation never consumes a continuation or commits
a newly inferred prize memory.

The client supplies `time_budget_ms=5000`. The cooperative deadline covers all
search phases; it is not an OS-enforced hard deadline. A legal incumbent exists
before optional work begins. Expiry returns verified work and publishes no
unfinished continuation. Fixed-work runs use `time_budget_ms=0`, up to three
belief samples and ordered result reduction. Gameplay defaults to three sample
workers on Windows and two on Android; Arena uses one.

`node_budget=192` bounds primary turn expansion per belief sample. Up to three
completed candidates receive replies (six actions, 32 expansions) and recovery
(six actions, 24 expansions) through the same expansion function. These phases
share the deadline. Counters report actual rule actions and choices, including
reply replay and rejected transitions. Each simulated action has a revision
scoped identifier. Deterministic transitions preserve the world's random stream;
only actual random rules operations advance it. Counters include
work that did not produce a retained plan; engine-version comparisons must also
inspect these counters and latency instead of treating a node as equal CPU work.

Results expose `policy_id`, `policy_fallback`, `turn_goal`, `plan_reason`,
`completion_reason`, scores, work counters and cache hits. Full diagnostic requests
can include `position_facts`. `root_evaluations` and `reply_completion_reasons`
show comparable candidate scores and any incomplete horizon. There are no
shadow/legacy-result fields.

## Strategy authoring

Edit `godot/authoring/ai_strategies.json`. A profile explicitly opts into
`shared_defaults` using `use_shared_defaults`; its own weights take precedence.
The content compiler expands defaults. `tools/content.ps1 export` emits complete
runtime profiles and recomputes their hashes. Runtime code never depends on an
unexpanded authoring document. Card rules and deck lists are independent inputs.

Psychic keeps more hand resources and completes a held Xatu with Natu before
collecting another basic attacker, except when Cresselia can use its opening
attack or the game is closing. Its energy selector recognizes a charged Xatu
that can immediately finish the game through a legal switch. These preferences
live in the Psychic policy and its authored parameters.

Readiness forecasts respect once-per-turn ability use during the current turn
and reset that availability when predicting the owner's next turn. Regression
fixtures execute both real turn transitions to check this boundary.

## Verification

```powershell
.\tools\test_source_boundaries.ps1
.\tools\test_challenge_core.ps1
.\tools\content.ps1 test
.\tools\content.ps1 check
.\tools\test_godot_ai.ps1
.\research\deep_ai\tools\test_research_smoke.ps1
.\research\deep_ai\tools\run_challenge_arena.ps1 -Preset refactor -Candidate challenge_next -Workers 8
```

The `refactor` preset freezes three 400-game matrices: A versus the pre-refactor
C, A versus the historical H, and C versus H. Matching scenarios use identical
seeds, deck directions, seats and first-player closures. C defaults to
`challenge_refactor_before` (commit `0005e241b51288abf9557b67688c71894d21937c`);
H remains `challenge_release_v1`. Development thresholds require reliable
completion, A-C score at least 50%, and no deck's paired A-H minus C-H score below
-5 percentage points. The result is a screen, never formal promotion; existing
champion specs are not rewritten. See the Arena guide for formal evaluation.

For subsequent strategy changes, use the `strategy` preset with an explicit
`-BaselineBuildManifest` for the frozen version being protected. It uses the
same three matrices with a zero percentage point allowance for each deck.
`check_challenge_strategy.py` also protects the stronger per-deck anchor score
from prior sealed runs using the same scenarios. The latest
[strategy validation report](STRATEGY_VALIDATION.md) records the two 1200-game
screens, independent seeds, regression fixtures, builds and paired performance.
