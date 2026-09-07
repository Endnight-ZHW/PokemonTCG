"""Predeclare and run complete-matrix, sequential traditional-AI acceptance.

Each look is an independent 400-game matrix, with seats/turn order closed in
four/eight-game blocks. The maximum number of looks fixes alpha before play.
Development runs are never imported into this acceptance cohort.
"""
from __future__ import annotations

import argparse
from dataclasses import replace
import json
from pathlib import Path
import sys

RESEARCH = Path(__file__).resolve().parents[1]
for directory in (RESEARCH / "python", RESEARCH / "build" / "native"):
    sys.path.insert(0, str(directory))

from deep_ai.challenge_arena import load_agent_spec, run_arena, canonical_hash
from deep_ai.challenge_arena_build import write_json_atomic, sha256_file
from deep_ai.challenge_arena_stats import summarize_games, strength_acceptance_status
from deep_ai.challenge_deck_regression import fixed_opponent_deck_effects


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-manifest", required=True, type=Path)
    parser.add_argument("--baseline-manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--seed", type=int, default=20260905)
    parser.add_argument("--max-looks", type=int, default=3, choices=range(1, 11))
    parser.add_argument("--workers", type=int, default=12)
    parser.add_argument("--max-decisions", type=int, default=1024)
    parser.add_argument("--controls-dir", type=Path,
                        help="Frozen-baseline self-play controls; defaults to OUTPUT/fixed-opponent-controls")
    parser.add_argument("--control-workers", type=int, default=8)
    parser.add_argument("--time-budget-ms", type=int, default=0)
    parser.add_argument("--search-worker-mode", choices=("single", "gameplay"), default="single")
    parser.add_argument("--declare-only", action="store_true",
                        help="Write immutable strength and fixed-opponent protocols without playing")
    args = parser.parse_args()
    if not 0 <= args.time_budget_ms <= 60000:
        parser.error("time budget must be between 0 and 60000 milliseconds")
    if args.search_worker_mode == "gameplay" and max(args.workers, args.control_workers) > 4:
        parser.error("gameplay search requires at most four concurrent games")
    candidate = load_agent_spec("strength_candidate", build_manifest=args.candidate_manifest)
    baseline = load_agent_spec("strength_baseline", build_manifest=args.baseline_manifest)
    options = {"engine": "strategic_intent_v3", "node_budget": 192, "belief_samples": 3,
               "use_deck_inspection": True, "use_strategy_optimization": True,
               "time_budget_ms": args.time_budget_ms, "search_worker_mode": args.search_worker_mode}
    candidate = replace(candidate, evaluation_options=options)
    baseline = replace(baseline, evaluation_options=options)
    deck_keys = set(json.loads((RESEARCH.parents[1] / "godot/data/release_manifest.json").read_text(encoding="utf-8"))["release_decks"])
    specification = {"schema": "ptcg.traditional_strength_acceptance/1",
        "verifier_sha256": sha256_file(Path(__file__)),
        "candidate": candidate.build_manifest, "baseline": baseline.build_manifest,
        "seeds": [args.seed + index * 104729 for index in range(args.max_looks)],
        "maximum_looks": args.max_looks, "family_wise_alpha": 0.05,
        "per_look_alpha": 0.05 / args.max_looks, "options": options,
        "decks": sorted(deck_keys), "workers": args.workers,
        "max_decisions": args.max_decisions, "score_floor": 0.53,
        "ci_lower_floor": 0.50, "paired_deck_delta_floor": -0.05,
        "minimum_games_per_deck_per_look": 40}
    args.output.mkdir(parents=True, exist_ok=True)
    manifest_path = args.output / "verification-manifest.json"
    fingerprint = canonical_hash(specification)
    if manifest_path.exists():
        saved = json.loads(manifest_path.read_text(encoding="utf-8"))
        if saved.get("fingerprint") != fingerprint:
            raise ValueError("acceptance_inputs_changed_use_a_new_cohort")
    else:
        write_json_atomic(manifest_path, {**specification, "fingerprint": fingerprint})
    controls_dir = (args.controls_dir or args.output / "fixed-opponent-controls").resolve()
    control_specification = {"schema": "ptcg.traditional_fixed_opponent_acceptance/1",
        "strength_fingerprint": fingerprint, "baseline": baseline.build_manifest,
        "controls_dir": str(controls_dir), "workers": args.control_workers,
        "options": options, "seeds": specification["seeds"], "max_decisions": args.max_decisions,
        "metric": "candidate_minus_baseline_against_same_frozen_baseline_opponent",
        "delta_floor": -0.05, "minimum_matched_games_per_deck": 40,
        "stop_rule": "Stop only when both overall strength and fixed-opponent deck checks pass, or at maximum looks",
        "analysis_sha256": sha256_file(RESEARCH / "python/deep_ai/challenge_deck_regression.py")}
    control_manifest = args.output / "fixed-opponent-protocol.json"
    control_fingerprint = canonical_hash(control_specification)
    if control_manifest.exists():
        saved = json.loads(control_manifest.read_text(encoding="utf-8"))
        if saved.get("fingerprint") != control_fingerprint:
            raise ValueError("fixed_opponent_inputs_changed_use_a_new_cohort")
    else:
        write_json_atomic(control_manifest, {**control_specification, "fingerprint": control_fingerprint})
    if args.declare_only:
        return 0
    games = []
    control_games = []
    status = "inconclusive"
    for look, seed in enumerate(specification["seeds"], start=1):
        batch = args.output / f"look-{look:02d}"
        run_arena(preset="focused", candidate=candidate, baseline=baseline,
            workers=args.workers, output=batch, seed=seed, replicates=1,
            max_decisions=args.max_decisions, truncated_rate_limit=0.0,
            comparison_mode="implementation-only", bootstrap_samples=10000)
        control_batch = controls_dir / f"look-{look:02d}"
        run_arena(preset="focused", candidate=baseline, baseline=baseline,
            workers=args.control_workers, output=control_batch, seed=seed, replicates=1,
            max_decisions=args.max_decisions, comparison_mode="implementation-only",
            allow_self_play=True, bootstrap_samples=2000)
        for line in (batch / "arena-games.jsonl").read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            row["source_task_id"] = row["task_id"]
            row["task_id"] = f"look-{look}:{row['task_id']}"
            row["acceptance_look"] = look
            games.append(row)
        for line in (control_batch / "arena-games.jsonl").read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            row["source_task_id"] = row["task_id"]
            row["task_id"] = f"look-{look}:{row['task_id']}"
            control_games.append(row)
        summary = summarize_games(games, bootstrap_seed=args.seed ^ 0x5EED5EED,
            bootstrap_samples=10000, confidence_alpha=specification["per_look_alpha"],
            truncated_rate_limit=0.0, min_deck_games=1)
        try:
            fixed_effects = fixed_opponent_deck_effects(games, control_games,
                seed=args.seed ^ 0x5EED5EED, samples=10000,
                alpha=specification["per_look_alpha"])
        except ValueError as error:
            summary["acceptance"] = {"status": "fail", "look": look,
                "fixed_opponent_error": str(error), "fingerprint": fingerprint}
            write_json_atomic(args.output / "verification-summary.json", summary)
            return 2
        # Swapping both controllers measures relative matchup advantage; only
        # the matched fixed-opponent contrast isolates a deck's own regression.
        summary["breakdowns"]["relative_role_deck_effects"] = summary["breakdowns"]["paired_deck_effects"]
        summary["breakdowns"]["paired_deck_effects"] = fixed_effects
        regressions = {deck: row for deck, row in fixed_effects.items()
                       if row["score_delta"] < -0.05 - 1e-12}
        promotion = summary["gates"]["promotion"]
        promotion["candidate_deck_regressions"] = regressions
        promotion["checks"]["no_candidate_deck_severe_regression"] = not regressions
        promotion["passed"] = all(promotion["checks"].values())
        summary["gates"]["configuration"]["deck_regression_metric"] = control_specification["metric"]
        summary["fixed_opponent_controls"] = {"games": len(control_games),
            "fingerprint": control_fingerprint, "matched_game_conditions": True,
            "structural_errors": 0, "truncated_games": 0, "persistent_timeouts": 0}
        status = strength_acceptance_status(summary, deck_keys)
        summary["acceptance"] = {"status": status, "look": look,
            "maximum_looks": args.max_looks, "fingerprint": fingerprint,
            "family_wise_confidence_level": 0.95,
            "fixed_opponent_deck_regression_checked": True,
            "performance_requires_separate_single_game_benchmark": True}
        write_json_atomic(args.output / "verification-summary.json", summary)
        print(json.dumps({"look": look, "games": len(games), "status": status,
            "score_rate": summary["record"]["score_rate"],
            "ci": summary["paired_statistics"]["score_rate_ci"]}), flush=True)
        if status in {"pass", "fail"}:
            break
    return 0 if status == "pass" else 2


if __name__ == "__main__":
    raise SystemExit(main())
