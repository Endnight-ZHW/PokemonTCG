"""Verify the fixed native-gameplay parity and performance gate.

This gate intentionally compares decision semantics rather than artifact
provenance or latency fields.  It fails closed when a required counter or
decision trace is absent, so a faster run cannot pass by silently doing less
search work.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import sys
from pathlib import Path
from typing import Any


def _read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def _required(mapping: dict[str, Any], path: str) -> Any:
    value: Any = mapping
    for component in path.split("."):
        if not isinstance(value, dict) or component not in value:
            raise ValueError(f"missing required field: {path}")
        value = value[component]
    return value


def _decision_sample_semantics(sample: dict[str, Any]) -> dict[str, Any]:
    # planner_ms is telemetry and must not enter the equivalence contract.
    return {key: value for key, value in sample.items() if key != "planner_ms"}


def _match_semantics(match: dict[str, Any]) -> dict[str, Any]:
    exact_scalar_fields = (
        "actions",
        "choices",
        "decisions",
        "turns",
        "winner",
        "engine_winner",
        "score",
        "terminal_reason",
        "terminal_message",
        "invalid_actions",
        "rule_exceptions",
        "choice_failures",
        "deep_fallbacks",
        "emergency_fallbacks",
        "max_actions_exhausted",
        "time_capped_decisions",
    )
    result = {field: match.get(field) for field in exact_scalar_fields}
    for field in (
        "action_decisions_by_strategy",
        "behavior_by_strategy",
        "decision_diagnostics_by_strategy",
        "decision_engine_counts_by_strategy",
        "decision_origin_counts_by_strategy",
        "dynamic_budget_stop_reasons",
        "failure_stage_counts_by_strategy",
        "simulation_samples_by_strategy",
        "turn_plan_cache_hit_samples",
        "turn_plan_cache_hit_samples_by_strategy",
    ):
        result[field] = match.get(field)
    depth_rows: dict[str, list[dict[str, Any]]] = {}
    raw_depth = match.get("search_depth_samples_by_strategy")
    if not isinstance(raw_depth, dict):
        raise ValueError("missing search_depth_samples_by_strategy")
    for strategy, rows in raw_depth.items():
        if not isinstance(rows, list):
            raise ValueError("invalid search depth sample collection")
        depth_rows[str(strategy)] = [
            _decision_sample_semantics(row)
            for row in rows
            if isinstance(row, dict)
        ]
        if len(depth_rows[str(strategy)]) != len(rows):
            raise ValueError("invalid search depth sample row")
    result["search_depth_samples_by_strategy"] = depth_rows
    return result


def verify(
    repo_root: Path,
    contract_path: Path,
    candidate_path: Path,
    baseline_rss_path: Path | None = None,
    candidate_rss_path: Path | None = None,
) -> dict[str, Any]:
    contract = _read_json(contract_path)
    candidate = _read_json(candidate_path)
    baseline_path = repo_root / str(_required(contract, "source_result.path"))
    expected_baseline_hash = str(_required(contract, "source_result.sha256"))
    actual_baseline_hash = hashlib.sha256(baseline_path.read_bytes()).hexdigest()
    if actual_baseline_hash != expected_baseline_hash:
        raise ValueError(
            "baseline semantics hash mismatch: "
            f"{actual_baseline_hash} != {expected_baseline_hash}"
        )
    baseline = _read_json(baseline_path)

    baseline_matches = _required(baseline, "matches")
    candidate_matches = _required(candidate, "matches")
    if not isinstance(baseline_matches, list) or not isinstance(candidate_matches, list):
        raise ValueError("matches must be arrays")
    exact_match_semantics = (
        len(baseline_matches) == len(candidate_matches)
        and all(
            _match_semantics(base) == _match_semantics(current)
            for base, current in zip(baseline_matches, candidate_matches, strict=True)
        )
    )

    baseline_counts = _required(baseline, "performance_profile.counts")
    candidate_counts = _required(candidate, "performance_profile.counts")
    required_counts = (
        "actions",
        "choices",
        "decisions",
        "matches",
        "ai_planner_nodes",
        "ai_root_action_count",
        "ai_simulated_action_score_calls",
        "ai_turn_plan_cache_hits",
        "ai_turn_plan_cache_misses",
        "ai_no_progress_actions_blocked",
    )
    exact_work = all(
        baseline_counts.get(key) == candidate_counts.get(key)
        for key in required_counts
    )

    nodes = int(_required(candidate, "performance_profile.counts.ai_planner_nodes"))
    planner_ms = float(
        _required(candidate, "performance_profile.segments_ms.ai_turn_planner_ms")
    )
    if nodes <= 0:
        raise ValueError("candidate planner node count must be positive")
    node_ms = planner_ms / nodes
    match_wall_ms = sum(float(_required(match, "elapsed_ms")) for match in candidate_matches)

    maximum_node_ms = float(_required(contract, "acceptance.maximum_planner_ms_per_node"))
    maximum_wall_ms = float(_required(contract, "acceptance.maximum_match_wall_ms"))
    baseline_node_ms = float(_required(contract, "observed.planner_ms_per_node"))
    baseline_wall_ms = float(_required(contract, "observed.match_wall_ms"))
    node_gate = node_ms <= maximum_node_ms
    wall_gate = match_wall_ms <= maximum_wall_ms
    rss_gate: bool | str = "not_recorded"
    peak_rss_ratio: float | None = None
    if candidate_rss_path is not None and baseline_rss_path is None:
        baseline_rss_path = repo_root / str(_required(
            contract, "rss_source.path"))
    if baseline_rss_path is not None or candidate_rss_path is not None:
        if baseline_rss_path is None or candidate_rss_path is None:
            raise ValueError("both baseline and candidate RSS artifacts are required")
        baseline_rss = _read_json(baseline_rss_path)
        candidate_rss = _read_json(candidate_rss_path)
        baseline_peak = int(_required(baseline_rss, "peak_rss_bytes"))
        candidate_peak = int(_required(candidate_rss, "peak_rss_bytes"))
        if baseline_peak <= 0 or candidate_peak <= 0:
            raise ValueError("RSS artifacts must contain positive peak_rss_bytes")
        peak_rss_ratio = candidate_peak / baseline_peak
        rss_gate = peak_rss_ratio <= float(_required(
            contract, "acceptance.maximum_peak_rss_ratio"))
    passed = exact_match_semantics and exact_work and node_gate and wall_gate \
        and rss_gate is not False
    return {
        "schema": "ptcg_native_gameplay_profile_gate/1",
        "passed": passed,
        "exact_match_semantics": exact_match_semantics,
        "exact_search_work": exact_work,
        "planner_nodes": nodes,
        "planner_ms": planner_ms,
        "planner_ms_per_node": node_ms,
        "planner_ms_per_node_limit": maximum_node_ms,
        "node_cost_reduction": 1.0 - node_ms / baseline_node_ms,
        "match_wall_ms": match_wall_ms,
        "match_wall_ms_limit": maximum_wall_ms,
        "match_wall_reduction": 1.0 - match_wall_ms / baseline_wall_ms,
        "rss_gate": rss_gate,
        "peak_rss_ratio": peak_rss_ratio,
    }


def verify_median(
    repo_root: Path,
    contract_path: Path,
    candidate_paths: list[Path],
    baseline_rss_path: Path | None = None,
    candidate_rss_path: Path | None = None,
) -> dict[str, Any]:
    if len(candidate_paths) < 3 or len(candidate_paths) % 2 == 0:
        raise ValueError("median gate requires an odd number of at least 3 runs")
    runs = [
        verify(
            repo_root,
            contract_path,
            candidate_path,
            baseline_rss_path if index == 0 else None,
            candidate_rss_path if index == 0 else None,
        )
        for index, candidate_path in enumerate(candidate_paths)
    ]
    node_values = [float(row["planner_ms_per_node"]) for row in runs]
    wall_values = [float(row["match_wall_ms"]) for row in runs]
    median_node_ms = float(statistics.median(node_values))
    median_wall_ms = float(statistics.median(wall_values))
    node_limit = float(runs[0]["planner_ms_per_node_limit"])
    wall_limit = float(runs[0]["match_wall_ms_limit"])
    contract = _read_json(contract_path)
    baseline_node_ms = float(_required(
        contract, "observed.planner_ms_per_node"))
    baseline_wall_ms = float(_required(contract, "observed.match_wall_ms"))
    rss_gate = runs[0]["rss_gate"]
    exact_match_semantics = all(
        bool(row["exact_match_semantics"]) for row in runs)
    exact_search_work = all(bool(row["exact_search_work"]) for row in runs)
    planner_nodes = {int(row["planner_nodes"]) for row in runs}
    stable_nodes = len(planner_nodes) == 1
    passed = exact_match_semantics and exact_search_work and stable_nodes \
        and median_node_ms <= node_limit and median_wall_ms <= wall_limit \
        and rss_gate is not False
    return {
        "schema": "ptcg_native_gameplay_profile_median_gate/1",
        "passed": passed,
        "run_count": len(runs),
        "exact_match_semantics": exact_match_semantics,
        "exact_search_work": exact_search_work,
        "stable_planner_nodes": stable_nodes,
        "planner_nodes": next(iter(planner_nodes)) if stable_nodes else None,
        "median_planner_ms_per_node": median_node_ms,
        "planner_ms_per_node_limit": node_limit,
        "median_node_cost_reduction": 1.0 - median_node_ms / baseline_node_ms,
        "median_match_wall_ms": median_wall_ms,
        "match_wall_ms_limit": wall_limit,
        "median_match_wall_reduction": 1.0 - median_wall_ms / baseline_wall_ms,
        "rss_gate": rss_gate,
        "peak_rss_ratio": runs[0]["peak_rss_ratio"],
        "runs": runs,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("candidate", type=Path, nargs="+")
    parser.add_argument(
        "--contract",
        type=Path,
        default=Path("contracts/native_gameplay_cpp_baseline_20260826.json"),
    )
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--baseline-rss", type=Path)
    parser.add_argument("--candidate-rss", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        repo_root = args.repo_root.resolve()
        contract_path = (repo_root / args.contract).resolve() \
            if not args.contract.is_absolute() else args.contract.resolve()
        candidate_paths = [
            (repo_root / candidate).resolve()
            if not candidate.is_absolute() else candidate.resolve()
            for candidate in args.candidate
        ]
        baseline_rss_path = (repo_root / args.baseline_rss).resolve() \
            if args.baseline_rss is not None \
            and not args.baseline_rss.is_absolute() \
            else args.baseline_rss.resolve() \
            if args.baseline_rss is not None else None
        candidate_rss_path = (repo_root / args.candidate_rss).resolve() \
            if args.candidate_rss is not None \
            and not args.candidate_rss.is_absolute() \
            else args.candidate_rss.resolve() \
            if args.candidate_rss is not None else None
        result = verify(
            repo_root,
            contract_path,
            candidate_paths[0],
            baseline_rss_path,
            candidate_rss_path,
        ) if len(candidate_paths) == 1 else verify_median(
            repo_root,
            contract_path,
            candidate_paths,
            baseline_rss_path,
            candidate_rss_path,
        )
    except (OSError, ValueError, TypeError) as error:
        print(json.dumps({"passed": False, "error": str(error)}, ensure_ascii=False))
        return 2
    rendered = json.dumps(result, ensure_ascii=False, sort_keys=True)
    if args.output is not None:
        output_path = (repo_root / args.output).resolve() \
            if not args.output.is_absolute() else args.output.resolve()
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    return 0 if bool(result["passed"]) else 1


if __name__ == "__main__":
    sys.exit(main())
