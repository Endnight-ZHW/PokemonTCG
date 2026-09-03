# Strategic Intent v3 evaluation

## Scope

The candidate implements the first staged `strategic_intent_v3` release:

- public-information belief probabilities rather than authoritative hidden
  identities;
- prize clock, attacker pipeline, energy schedule, resource ledger and threat
  facts;
- persistent match plans and the initial take-prize, prevent-loss,
  prepare-attacker and establish-engine intents;
- goal-directed complete-turn compilation with authoritative `RulesSession`
  execution, state deduplication/partial-order reduction and D0-D3 gates;
- paired opponent worst-response and own-recovery evaluation across hidden-
  information determinizations;
- full-sequence safety validation and transactional `turn_beam_v2` fallback.

The frozen pre-refactor baseline is commit
`e8690e9ee39993dc85f79b2da5fa879e00e8ae13` (`challenge_pre_v3`). Candidate
and baseline use the same strategy catalog, node budget, belief budget,
watchdog, decks and paired seeds. Only the engine differs.

## Results

Structural smoke (`build/challenge-arena/strategic-v3-smoke`):

- 16 games;
- zero invalid actions, illegal choices, controller failures, persistent
  timeouts or truncations;
- structural gate passed.

Full-budget all-deck mirror gate
(`build/challenge-arena/strategic-v3-all-r3`):

- 40 games, one complete four-game seat/first-player closure for each of the
  ten release decks;
- candidate score rate: **0.425**;
- paired 95% confidence interval: **[0.350, 0.500]**;
- zero invalid actions, illegal choices, structural errors, persistent
  timeouts or truncations;
- candidate nodes: 1,054,268; baseline nodes: 988,994;
- candidate total decision time: 922.6 s; baseline: 796.4 s;
- search P95 ratio: 0.978 (diagnostic, non-gating).

Default-engine regression (`build/challenge-arena/turn-beam-default-regression`):

- 40 all-deck mirror games with the current binary and frozen baseline both
  explicitly using `turn_beam_v2`;
- score rate and paired interval: **0.500 [0.500, 0.500]**;
- zero structural errors, truncations or persistent timeouts.

At that stage, keeping `turn_beam_v2` as the product default preserved the
pre-refactor behavior while v3 remained experimental.

The initial result exposed four correctness problems in the migration layer:

- v3 compared against a ranked-action proxy instead of the actual complete v2
  plan for the same state;
- active-Pokémon knockouts were incorrectly classified as match catastrophe;
- a high-scoring unfinished search node could overwrite a complete executable
  plan for the same root action;
- response evaluation stopped after the opponent reply and could not measure
  whether the candidate retained a useful recovery turn.

These were corrected together with robust terminal-win reproduction, complete
sequence replay, plan-cache preconditions, paired scenario seeds, bounded
energy-allocation planning at the first attachment commitment, and exact early
rejection when a candidate can no longer satisfy its worst-sample threshold.

## Promotion result

Final all-ten-deck mirror gate
(`build/challenge-arena/strategic-v3-all10-promotion-r33`):

- 40 games, one complete four-game closure for every release deck;
- candidate record: **23-17**, score rate **0.575**;
- paired 95% confidence interval: **[0.525, 0.650]**;
- colorless, fire, and fighting: **3-1** each; all other decks: **2-2**;
- zero invalid actions, illegal choices, structural errors, persistent
  timeouts, or truncations;
- candidate nodes: 1,110,487; baseline nodes: 1,025,600 (ratio **1.083**);
- search P95 ratio: **1.115**, below the 1.15 advisory limit;
- the Arena promotion gate passed every check.

Independent-seed focused replication
(`build/challenge-arena/strategic-v3-seed917-rep2-r29`) produced **22-18
(0.550)** with zero structural errors and performance status `ok`. The added
wins came from different fire and fighting energy-allocation plans, providing
evidence that the gain is not tied to one shuffle seed.

## Conclusion

The final candidate is rules-correct, measurably stronger than the frozen v2
baseline, has no observed per-deck regression in the all-deck closure, and
stays within the performance advisory. `strategic_intent_v3` is therefore the
product default; `turn_beam_v2` remains the transactional fallback and the
explicit compatibility engine.

## Full-deck inspection follow-up (2026-09-03)

The owner-only full-deck browse integration was evaluated separately after the
promotion above. A naive implementation injected the exact inspected
deck/prize split into every action rollout. On the fixed Psychic mirror closure
this changed the candidate from 2-2 with inspection disabled to 0-4 with exact
action-search memory. Keeping exact information authoritative for real search
choices while retaining belief sampling for Psychic action rollouts restored
that closure to 2-2.

The retained strategy changes are conservative: last-accessible key-component
scoring, rejection of a provably prize-locked evolution line, and removal of
pure support engines from the combat attacker pipeline. A 40-game same-binary
ablation against `use_strategy_optimization=false` finished 20-20 with zero
structural errors or truncations. Against the frozen pre-v3 implementation one
40-game seed finished 23-17 (0.575, paired interval 0.500-0.650), but an
independent full 80-game run finished 40-40 (0.500, interval 0.4375-0.5625).
Several broader energy-ordering and per-deck routing candidates also failed
independent blind tests and were removed.

Therefore the follow-up establishes that the browse integration no longer
causes the observed Psychic regression, but it does **not** establish a new
statistically significant overall strength increase beyond the historical v3
promotion result. No promotion claim should be made from the inspection-only
ablation.

Reproduction command:

```powershell
.\research\deep_ai\tools\run_challenge_arena.ps1 `
    -Preset focused `
    -Candidate strategic_intent_v3 `
    -CandidateEngine strategic_intent_v3 `
    -Baseline challenge_pre_v3 `
    -BaselineEngine turn_beam_v2 `
    -ComparisonMode implementation-only `
    -MirrorOnly `
    -CandidateDeck fire,water,psychic,lightning,fighting,colorless,dragon,grass,steel,darkness `
    -BaselineDeck fire,water,psychic,lightning,fighting,colorless,dragon,grass,steel,darkness `
    -Replicates 1 `
    -MaxDecisions 1024 `
    -Workers 8 `
    -Gate promotion `
    -Output build\challenge-arena\strategic-v3-all10-promotion-r33
```
