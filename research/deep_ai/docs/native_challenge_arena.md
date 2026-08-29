# Native Challenge Arena

Native Challenge Arena is the research-only, callback-free match pool for
Challenge AI evaluation. Each native worker owns one candidate
`ChallengeController`, one baseline `ChallengeController`, and creates one
authoritative `RulesSession` per game. Python submits the complete task list
once, waits once, and only performs aggregation and report generation.

The Arena is not linked into `challenge_core` or the game export. Its source is
compiled only by the research pybind build under `research/deep_ai/native`.

## Safety and fairness contract

- The formal match state exists only in the Arena host's `RulesSession`.
- AI observations are derived exclusively from `RulesSession::view_for(actor)`.
  The Arena converts its compact `your/opponent` shape to the existing public AI
  DTO by restoring hidden-zone cardinalities, never hidden identities.
- The candidate and baseline use identical fixed evaluation options and one
  inner search worker. Parallelism is across games.
- Turn order is forced by each task. Every ordered matchup uses all four
  candidate-seat/first-player closures.
- An AI Action is matched uniquely against the current authoritative candidates.
  The Arena uses all semantic Action v4 fields (including source indices) and
  ignores only the host-owned `action_id`. The host then supplies a new
  `action_id` and submits the matched Action through `apply_action()`.
- Choice responses are checked for request ID, cardinality, membership,
  duplicates, and cancellation before `apply_choice()` validates them again.
- Controller violations are adjudicated as a loss and fail structural gates.
  Rules failures are excluded from strength statistics and fail the run.
- Decision seeds depend on game seed, authoritative revision, actor, and
  decision kind, not agent identity or worker scheduling.

## Build and run

From the repository root:

```powershell
.\research\deep_ai\tools\build_native_binding.ps1

.\research\deep_ai\tools\run_challenge_arena.ps1 `
    -Preset smoke `
    -Candidate challenge_next `
    -Baseline challenge_release_v1 `
    -Workers 8
```

The longer nightly command is:

```powershell
.\research\deep_ai\tools\run_challenge_arena.ps1 `
    -Preset nightly `
    -Candidate challenge_next `
    -Baseline challenge_release_v1 `
    -Workers 16 `
    -Output build\challenge-arena\nightly
```

`focused` accepts one or more `-CandidateDeck` and `-BaselineDeck` values.
`-TraceAll` includes public decision DTOs and controller results for every step;
without it, full traces are retained only for failures and truncations.

## Presets

| Preset | Ordered matchup workload | Default gate |
|---|---:|---|
| `smoke` | 4 matchups × 4 closures = 16 games | structural |
| `pr` | 20 matchups × 4 closures × 2 seeds = 160 games | regression |
| `nightly` | 100 matchups × 4 closures × 2 seeds = 800 games | regression |
| `release` | 100 matchups × 4 closures × 5 seeds = 2000 games | promotion |
| `focused` | selected candidate decks × baseline decks × 4 closures | none |

For different-deck full-matrix comparisons, both deck ownership directions are
in the same bootstrap block, producing eight games per unordered deck pair and
seed. Mirror-deck blocks contain four games.

## Agent specifications

An identifier resolves to
`research/deep_ai/arena/baselines/<identifier>.json` when present. Otherwise it
is treated as an agent label using the product strategy catalog. A specification
can select another strategy catalog:

```json
{
  "agent_id": "challenge_release_v1",
  "build_id": "product-0.8.0",
  "strategies_path": "godot/data/ai_strategies.json",
  "evaluation_options": {
    "engine": "turn_beam_v2",
    "node_budget": 192,
    "belief_samples": 3
  }
}
```

Candidate and baseline evaluation options must be byte-equivalent after preset
normalization. This first version implements the product `fixed_contract` mode;
`node_budget` controls mandatory tactics while the main beam search retains its
product configuration. It must not be described as a strict equal-node test.

## Reports and gates

Each output directory contains:

- `arena-games.jsonl`: one result per game, sorted by task ID;
- `arena-failures.jsonl`: structural failures, infrastructure failures, and
  truncations;
- `arena-summary.json`: record, paired bootstrap confidence interval,
  deck/matchup/seat/turn-order splits, latency, nodes, and gates;
- `arena-manifest.json`: agents, builds, Git state, content hashes, fixed search
  contract, hardware, task hash, semantic result hash, and archival full hash.

Regression gate defaults:

- zero invalid Actions, illegal Choices, controller failures, and rule failures;
- truncation rate at or below 1%;
- paired 95% score-delta lower bound above -0.02;
- candidate decision P95 no more than 1.15 times baseline P95.

Promotion additionally requires score rate at least 0.53, paired CI lower bound
above 0.50, and no sufficiently sampled candidate deck below 0.45.

## Verification

```powershell
$env:PYTHONPATH = "$PWD\research\deep_ai\python"
.\.tools\python311\python.exe -B -m unittest `
    research.deep_ai.tests.test_challenge_arena_tasks `
    research.deep_ai.tests.test_challenge_arena_stats `
    research.deep_ai.tests.test_challenge_arena_determinism -v
```

The determinism test runs the same native task list with one and four outer
workers and compares the sorted semantic result hashes.
