"""Validate the fixed 280-game Godot gate for a v6 research10 run.

This is intentionally separate from the authoritative ``deep-release`` gate:
passing it records research evidence only and never makes a run promotable.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.production_contract import RELEASE_DECKS  # noqa: E402
from engine.ai.dl.run_store import (  # noqa: E402
    atomic_write_json,
    read_json,
    sha256_file,
    update_run,
    utc_now,
)
from scripts.validate_ai_evaluation import (  # noqa: E402
    _deep_release_runtime_validation,
)


SCHEMA = "deep_ai_v6_research10_gate_v1"
PROTOCOL = "traditional_ai_evaluation_v7"
BOOTSTRAP_ITERATIONS = 10_000
CI_LOWER_FLOOR = -0.05
EXPECTED_GAMES = 280
EXPECTED_MIRROR_UNITS = 50
EXPECTED_CROSS_UNITS = 45


def _quantile(values: list[float], probability: float) -> float:
    rows = sorted(values)
    if not rows:
        return 0.0
    position = (len(rows) - 1) * float(probability)
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return rows[lower]
    fraction = position - lower
    return rows[lower] * (1.0 - fraction) + rows[upper] * fraction


def _point_for(match: dict[str, Any]) -> float:
    winner = str(match.get("winner", "")).upper()
    if winner == "A":
        return 1.0
    if winner == "B":
        return 0.0
    if winner in {"", "DRAW", "NONE", "NULL"}:
        return 0.5
    raise ValueError(f"Unknown evaluation winner label: {winner!r}")


def _unit_key(match: dict[str, Any]) -> tuple[str, str]:
    kind = str(match.get("matchup_kind", "")).lower()
    if kind == "mirror":
        key = str(match.get("pair_key", ""))
    elif kind in {"cross", "cross_role"}:
        key = str(match.get("role_crossover_block_key", ""))
    else:
        raise ValueError(f"Unknown matchup kind: {kind!r}")
    if not key:
        raise ValueError(f"Evaluation match has no paired unit key ({kind})")
    return kind, key


def paired_cluster_stats(
    matches: list[dict[str, Any]],
    *,
    seed: int = 17,
    iterations: int = BOOTSTRAP_ITERATIONS,
) -> dict[str, Any]:
    """Return a stratified cluster bootstrap over paired mirror/cross units."""

    by_kind: dict[str, dict[str, list[float]]] = {
        "mirror": defaultdict(list),
        "cross": defaultdict(list),
    }
    for match in matches:
        kind, key = _unit_key(match)
        normalized = "mirror" if kind == "mirror" else "cross"
        by_kind[normalized][key].append(_point_for(match))

    mirror = list(by_kind["mirror"].values())
    cross = list(by_kind["cross"].values())
    if any(len(unit) != 2 for unit in mirror):
        raise ValueError("Every mirror unit must contain exactly two games")
    if any(len(unit) != 4 for unit in cross):
        raise ValueError("Every cross unit must contain exactly four games")
    all_points = [
        point
        for unit in mirror + cross
        for point in unit
    ]
    if not all_points:
        raise ValueError("Evaluation contains no paired games")

    rng = random.Random(int(seed) + 6_101_803)
    samples: list[float] = []
    for _ in range(max(1, int(iterations))):
        sampled_units = [
            mirror[rng.randrange(len(mirror))]
            for _ in range(len(mirror))
        ] + [
            cross[rng.randrange(len(cross))]
            for _ in range(len(cross))
        ]
        sampled_points = [
            point
            for unit in sampled_units
            for point in unit
        ]
        samples.append(
            2.0 * sum(sampled_points) / len(sampled_points) - 1.0
        )
    point_delta = 2.0 * sum(all_points) / len(all_points) - 1.0
    return {
        "games": len(all_points),
        "mirror_units": len(mirror),
        "cross_units": len(cross),
        "candidate_point_rate": (point_delta + 1.0) / 2.0,
        "point_rate_delta": point_delta,
        "ci95": {
            "lower": _quantile(samples, 0.025),
            "upper": _quantile(samples, 0.975),
            "iterations": max(1, int(iterations)),
            "unit": "paired_cluster_stratified_by_matchup_kind",
        },
    }


def _append(
    errors: list[dict[str, Any]],
    code: str,
    **details: Any,
) -> None:
    errors.append({"code": code, **details})


def _choice_gate(run_dir: Path, run: dict[str, Any]) -> dict[str, Any]:
    generation = int((run.get("config") or {}).get("generations", 0))
    path = run_dir / "evaluation" / f"choice_generation_{generation}.json"
    if not path.is_file():
        return {
            "passed": False,
            "path": str(path),
            "error": "missing_choice_evidence",
        }
    payload = read_json(path)
    decks = dict(payload.get("decks") or {})
    passed = (
        payload.get("schema") == "choice_drift_metrics_v1"
        and int(payload.get("generation", -1)) == generation
        and bool(payload.get("passed"))
        and not list(payload.get("failures") or [])
        and set(decks) == set(RELEASE_DECKS)
        and all(bool((row.get("gate") or {}).get("passed")) for row in decks.values())
    )
    return {
        "passed": passed,
        "path": str(path.relative_to(run_dir).as_posix()),
        "sha256": sha256_file(path),
        "generation": generation,
        "failures": list(payload.get("failures") or []),
    }


def validate(
    payload: dict[str, Any],
    *,
    run_dir: Path | None = None,
) -> dict[str, Any]:
    errors: list[dict[str, Any]] = []
    observed = dict(payload.get("observed") or {})
    config = dict(payload.get("config") or {})
    coverage = dict(payload.get("coverage") or {})

    if (
        int(payload.get("schema_version", -1)) != 7
        or str(payload.get("protocol_id", "")) != PROTOCOL
        or str(payload.get("artifact_kind", "")) != "ai_evaluation_result"
    ):
        _append(errors, "evaluation_contract")
    if (
        set(payload.get("deck_keys") or []) != set(RELEASE_DECKS)
        or len(payload.get("deck_keys") or []) != len(RELEASE_DECKS)
    ):
        _append(errors, "deck_coverage")
    expected_config = {
        "seed": 17,
        "seed_blocks_per_deck": 5,
        "cross_seed_blocks_per_matchup": 1,
        "max_actions": 1200,
    }
    for key, expected in expected_config.items():
        if int(config.get(key, -1)) != expected:
            _append(
                errors,
                f"config_{key}",
                expected=expected,
                actual=config.get(key),
            )
    if str(config.get("matchup_mode", "")).lower() != "balanced":
        _append(
            errors,
            "config_matchup_mode",
            expected="Balanced",
            actual=config.get("matchup_mode"),
        )
    if (
        int(observed.get("games", -1)) != EXPECTED_GAMES
        or int(observed.get("clean_games", -1)) != EXPECTED_GAMES
        or not bool(coverage.get("complete"))
        or int(coverage.get("actual_games", -1)) != EXPECTED_GAMES
    ):
        _append(errors, "coverage_280", observed=observed.get("games"))

    reliability_fields = (
        "invalid_actions",
        "choice_failures",
        "rule_exceptions",
        "max_actions_exhaustions",
        "deep_fallbacks",
        "time_capped_decisions",
    )
    reliability = {
        key: int(observed.get(key, 0) or 0)
        for key in reliability_fields
    }
    for key, value in reliability.items():
        if value:
            _append(errors, f"nonzero_{key}", actual=value)

    deep_runtime = _deep_release_runtime_validation(payload)
    for key in (
        "runtime_contract",
        "decision_accounting",
        "planner_coverage",
        "timeout_free",
    ):
        if not bool(deep_runtime.get(key)):
            _append(
                errors,
                f"deep_{key}",
                runtime=deep_runtime,
            )

    try:
        paired = paired_cluster_stats(
            list(payload.get("matches") or []),
            seed=17,
        )
    except (TypeError, ValueError) as exc:
        paired = {}
        _append(errors, "paired_statistics", message=str(exc))
    if paired:
        if (
            int(paired["games"]) != EXPECTED_GAMES
            or int(paired["mirror_units"]) != EXPECTED_MIRROR_UNITS
            or int(paired["cross_units"]) != EXPECTED_CROSS_UNITS
        ):
            _append(errors, "paired_schedule", paired=paired)
        lower = float((paired.get("ci95") or {}).get("lower", -1.0))
        if lower < CI_LOWER_FLOOR - 1e-12:
            _append(
                errors,
                "paired_ci_below_floor",
                lower=lower,
                floor=CI_LOWER_FLOOR,
            )

    run_contract: dict[str, Any] = {}
    choice: dict[str, Any] = {}
    if run_dir is not None:
        run_dir = run_dir.resolve()
        run = read_json(run_dir / "run.json")
        run_config = dict(run.get("config") or {})
        run_contract = {
            "run_id": run.get("run_id"),
            "preset": run.get("preset"),
            "status": run.get("status"),
            "promotable": bool(run.get("promotable")),
            "model_variant": run_config.get("model_variant"),
        }
        lineage = dict(run.get("stage_lineage") or {})
        ablation_lineage = dict(lineage.get("ablation") or {})
        ablation_path = Path(str(ablation_lineage.get("path", "")))
        ablation_lineage_valid = (
            ablation_path.is_file()
            and str(ablation_lineage.get("model_variant", ""))
            == str(run_config.get("model_variant", ""))
            and str(ablation_lineage.get("sha256", "")).lower()
            == sha256_file(ablation_path)
        )
        run_contract["ablation_lineage"] = {
            **ablation_lineage,
            "valid": ablation_lineage_valid,
        }
        if (
            str(run.get("preset", "")) != "research10"
            or str(run.get("status", "")) != "completed"
            or bool(run.get("promotable"))
            or int(run_config.get("seed", -1)) != 17
            or tuple(run_config.get("decks") or ()) != RELEASE_DECKS
            or int(run_config.get("teacher_games", -1)) != 200
            or int(run_config.get("dagger_games", -1)) != 200
            or int(run_config.get("generations", -1)) != 2
            or int(run_config.get("games_per_matchup", -1)) != 8
            or int(run_config.get("current_generation_games", -1)) != 4
            or int(run_config.get("historical_games", -1)) != 4
            or int(run_config.get("mcts_simulations", -1)) != 64
            or int(run_config.get("rollout_workers", -1)) != 10
            or str(run_config.get("model_variant", ""))
            not in {"v6_pooled", "v6_cross_attention"}
        ):
            _append(errors, "research10_run_contract", run=run_contract)
        if not ablation_lineage_valid:
            _append(errors, "ablation_lineage", run=run_contract)
        choice = _choice_gate(run_dir, run)
        if not bool(choice.get("passed")):
            _append(errors, "choice_drift", choice=choice)

    return {
        "schema": SCHEMA,
        "created_at": utc_now(),
        "valid": not errors,
        "promotable": False,
        "release_manifest_modified": False,
        "thresholds": {
            "games": EXPECTED_GAMES,
            "paired_ci95_lower": CI_LOWER_FLOOR,
            "deep_decision_ms_max": 2000.0,
            "bootstrap_iterations": BOOTSTRAP_ITERATIONS,
        },
        "paired": paired,
        "reliability": reliability,
        "deep_runtime": deep_runtime,
        "choice": choice,
        "run": run_contract,
        "errors": errors,
        "error_codes": [str(row["code"]) for row in errors],
    }


def _record_run_result(
    run_dir: Path,
    output: Path,
    report: dict[str, Any],
) -> None:
    run_dir = run_dir.resolve()
    run = read_json(run_dir / "run.json")
    candidate_path = run_dir / "staging" / "candidate_manifest.json"
    if candidate_path.is_file():
        candidate = read_json(candidate_path)
        candidate["evaluation_status"] = (
            "research10_verified"
            if report["valid"]
            else "research10_rejected"
        )
        candidate["research_evaluation"] = {
            "path": str(output.relative_to(run_dir).as_posix()),
            "sha256": sha256_file(output),
            "valid": bool(report["valid"]),
        }
        candidate["promotable"] = False
        atomic_write_json(candidate_path, candidate)
    candidate_stage = dict(run.get("candidate_stage") or {})
    candidate_stage.update({
        "status": (
            "research10_verified"
            if report["valid"]
            else "research10_rejected"
        ),
        "research_only": True,
        "research_evaluation_path": str(
            output.relative_to(run_dir).as_posix()
        ),
        "research_evaluation_sha256": sha256_file(output),
    })
    if candidate_path.is_file():
        candidate_stage["manifest_sha256"] = sha256_file(candidate_path)
    update_run(run_dir, candidate_stage=candidate_stage)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path)
    args = parser.parse_args()
    payload = json.loads(args.input.read_text(encoding="utf-8-sig"))
    report = validate(payload, run_dir=args.run_dir)
    atomic_write_json(args.output, report)
    if args.run_dir is not None:
        try:
            args.output.resolve().relative_to(args.run_dir.resolve())
        except ValueError as exc:
            raise RuntimeError(
                "Research gate output must stay inside the run directory"
            ) from exc
        _record_run_result(
            args.run_dir.resolve(),
            args.output.resolve(),
            report,
        )
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if report["valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
