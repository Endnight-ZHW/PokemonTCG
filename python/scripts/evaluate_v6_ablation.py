"""Run the fixed 280-game paired v6 pooled/cross-attention ablation.

This research gate never edits the release manifest.  It writes a standalone
winner decision that can be consumed by the later research10/release stages.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
from typing import Any, Iterable


PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.hybrid_population import (  # noqa: E402
    _model_payload_sha256,
    _population_group_worker,
)
from engine.ai.dl.model import load_checkpoint, torch  # noqa: E402
from engine.ai.dl.production_contract import PopulationTask  # noqa: E402
from engine.ai.dl.run_store import atomic_write_json, read_json  # noqa: E402
from engine.ai.dl.training import (  # noqa: E402
    _collect_bootstrap_examples_parallel,
    _forward_batch,
    _model_payload_for_worker,
    _worker_init,
)
from scripts.export_onnx_models import (  # noqa: E402
    _benchmark_one,
    _export_one,
    _verify_one,
)


DECKS = ("steel", "darkness")
MIRROR_BLOCKS_PER_DECK = 50
CROSS_BLOCKS = 20
BOOTSTRAP_ITERATIONS = 10_000


def _stable_seed(*parts: Any) -> int:
    wire = "|".join(str(part) for part in parts).encode("utf-8")
    return (
        int.from_bytes(hashlib.sha256(wire).digest()[:8], "big")
        % 2_147_483_647
    ) or 1


def _task_id(*parts: Any) -> str:
    wire = "|".join(str(part) for part in parts).encode("utf-8")
    return "v6-ablation:" + hashlib.sha256(wire).hexdigest()[:24]


def build_ablation_tasks(
    *,
    seed: int = 17,
    mirror_blocks: int = MIRROR_BLOCKS_PER_DECK,
    cross_blocks: int = CROSS_BLOCKS,
) -> tuple[list[PopulationTask], dict[str, dict[str, Any]]]:
    tasks: list[PopulationTask] = []
    metadata: dict[str, dict[str, Any]] = {}
    matchup_index = 0
    for deck in DECKS:
        for block in range(max(0, int(mirror_blocks))):
            block_id = f"mirror:{deck}:{block:03d}"
            block_seed = _stable_seed("v6-ablation", seed, block_id)
            forced_first = block % 2
            for game in range(2):
                task_id = _task_id(block_id, game)
                task = PopulationTask(
                    task_id=task_id,
                    generation=1,
                    matchup_index=matchup_index,
                    deck_a=deck,
                    deck_b=deck,
                    game_index=game,
                    seed_block=block,
                    seed=block_seed,
                    seat_a=game,
                    forced_first_player=forced_first,
                    opponent_kind="current",
                    history_generation=None,
                    history_side=None,
                )
                tasks.append(task)
                metadata[task_id] = {
                    "block_id": block_id,
                    "kind": "mirror",
                    "cross_deck": deck,
                    "pooled_deck": deck,
                }
            matchup_index += 1

    for block in range(max(0, int(cross_blocks))):
        block_id = f"cross:steel__darkness:{block:03d}"
        block_seed = _stable_seed("v6-ablation", seed, block_id)
        for game in range(4):
            cross_deck, pooled_deck = (
                ("steel", "darkness")
                if game < 2
                else ("darkness", "steel")
            )
            task_id = _task_id(block_id, game)
            task = PopulationTask(
                task_id=task_id,
                generation=1,
                matchup_index=matchup_index,
                deck_a=cross_deck,
                deck_b=pooled_deck,
                game_index=game,
                seed_block=block,
                seed=block_seed,
                seat_a=game % 2,
                forced_first_player=game // 2,
                opponent_kind="current",
                history_generation=None,
                history_side=None,
            )
            tasks.append(task)
            metadata[task_id] = {
                "block_id": block_id,
                "kind": "cross",
                "cross_deck": cross_deck,
                "pooled_deck": pooled_deck,
            }
        matchup_index += 1
    return tasks, metadata


def _load_run_models(
    run_dir: Path,
    expected_variant: str,
) -> dict[str, tuple[Any, dict[str, Any], dict[str, Any], str]]:
    run = read_json(run_dir / "run.json")
    config = dict(run.get("config") or {})
    if (
        str(run.get("preset", "")) != "research2"
        or str(run.get("status", "")) != "completed"
        or bool(run.get("promotable"))
        or int(config.get("seed", -1)) != 17
        or tuple(config.get("decks") or ()) != DECKS
        or int(config.get("teacher_games", -1)) != 200
        or int(config.get("dagger_games", -1)) != 200
        or int(config.get("generations", -1)) != 2
        or int(config.get("games_per_matchup", -1)) != 8
        or int(config.get("current_generation_games", -1)) != 4
        or int(config.get("historical_games", -1)) != 4
        or int(config.get("mcts_simulations", -1)) != 64
        or int(config.get("rollout_workers", -1)) != 4
        or str(config.get("model_variant")) != expected_variant
    ):
        raise RuntimeError(
            f"{run_dir.name} is not an exact {expected_variant} research2 run"
        )
    models = {}
    for deck in DECKS:
        path = run_dir / "models" / f"{deck}.pt"
        model, payload = load_checkpoint(str(path), "cpu")
        config = dict(payload.get("model_config") or {})
        if bool(config.get("candidate_cross_attention")) != (
            expected_variant == "v6_cross_attention"
        ):
            raise RuntimeError(
                f"{run_dir.name}/{deck} model variant mismatch"
            )
        state, worker_config = _model_payload_for_worker(model)
        models[deck] = (
            model,
            state,
            worker_config,
            _model_payload_sha256(state, worker_config),
        )
    return models


def _choice_drift_evidence(run_dir: Path) -> dict[str, Any]:
    run = read_json(run_dir / "run.json")
    generation = int((run.get("config") or {}).get("generations", 0))
    path = run_dir / "evaluation" / f"choice_generation_{generation}.json"
    if not path.is_file():
        return {
            "passed": False,
            "generation": generation,
            "error": "missing_choice_evidence",
        }
    payload = read_json(path)
    deck_rows = dict(payload.get("decks") or {})
    passed = (
        payload.get("schema") == "choice_drift_metrics_v1"
        and int(payload.get("generation", -1)) == generation
        and bool(payload.get("passed"))
        and not list(payload.get("failures") or [])
        and set(deck_rows) == set(DECKS)
        and all(
            bool((row.get("gate") or {}).get("passed"))
            for row in deck_rows.values()
        )
    )
    return {
        "passed": passed,
        "generation": generation,
        "path": str(path.resolve()),
        "failures": list(payload.get("failures") or []),
        "decks": deck_rows,
    }


def _chunk(values: list[Any], count: int) -> list[list[Any]]:
    chunks = [[] for _ in range(max(1, int(count)))]
    for index, value in enumerate(values):
        chunks[index % len(chunks)].append(value)
    return [chunk for chunk in chunks if chunk]


def _requests(
    tasks: Iterable[PopulationTask],
    cross_models: dict[str, tuple[Any, dict, dict, str]],
    pooled_models: dict[str, tuple[Any, dict, dict, str]],
    *,
    workers: int,
) -> list[dict[str, Any]]:
    groups: dict[tuple[str, str], list[PopulationTask]] = {}
    for task in tasks:
        groups.setdefault((task.deck_a, task.deck_b), []).append(task)
    requests: list[dict[str, Any]] = []
    for (cross_deck, pooled_deck), rows in sorted(groups.items()):
        _model_a, state_a, config_a, sha_a = cross_models[cross_deck]
        _model_b, state_b, config_b, sha_b = pooled_models[pooled_deck]
        for chunk in _chunk(rows, workers):
            requests.append({
                "tasks": [task.to_dict() for task in chunk],
                "model_a_state": state_a,
                "model_a_config": config_a,
                "model_a_sha": sha_a,
                "model_b_state": state_b,
                "model_b_config": config_b,
                "model_b_sha": sha_b,
                "max_steps": 160,
                "mcts_simulations": 64,
                "teacher_search_preset": "quality",
                "training_exploration": False,
                "record_trajectories": False,
            })
    return requests


def _quantile(values: list[float], probability: float) -> float:
    rows = sorted(values)
    if not rows:
        return 0.0
    position = (len(rows) - 1) * probability
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return rows[lower]
    fraction = position - lower
    return rows[lower] * (1.0 - fraction) + rows[upper] * fraction


def _cluster_ci(
    block_point_rows: list[list[float]],
    *,
    seed: int,
    iterations: int = BOOTSTRAP_ITERATIONS,
) -> tuple[float, float]:
    if not block_point_rows:
        return 0.0, 0.0
    rng = random.Random(seed)
    count = len(block_point_rows)
    samples = []
    for _ in range(max(1, int(iterations))):
        sampled = [
            block_point_rows[rng.randrange(count)]
            for _ in range(count)
        ]
        points = [point for block in sampled for point in block]
        samples.append(
            2.0 * sum(points) / max(1, len(points)) - 1.0
        )
    return _quantile(samples, 0.025), _quantile(samples, 0.975)


def _action_nll(model: Any, examples: list[Any]) -> tuple[float, int]:
    total = 0.0
    count = 0
    model.eval()
    with torch.no_grad():
        for start in range(0, len(examples), 256):
            batch = examples[start:start + 256]
            logits, _value, _mask = _forward_batch(model, batch, "cpu")
            if logits is None:
                continue
            for index, example in enumerate(batch):
                action_count = len(example.actions)
                target = int(example.target_index)
                if action_count <= 0 or target < 0 or target >= action_count:
                    continue
                log_probs = torch.log_softmax(
                    logits[index, :action_count].float(),
                    dim=0,
                )
                total -= float(log_probs[target].item())
                count += 1
    return total, count


def _heldout_nll(
    cross_models: dict[str, tuple[Any, dict, dict, str]],
    pooled_models: dict[str, tuple[Any, dict, dict, str]],
    *,
    games: int,
    workers: int,
    seed: int,
) -> dict[str, Any]:
    totals = {"v6_cross_attention": [0.0, 0], "v6_pooled": [0.0, 0]}
    by_deck = {}
    for deck_index, deck in enumerate(DECKS):
        examples = _collect_bootstrap_examples_parallel(
            deck,
            games,
            seed + 7_000_019 + deck_index * 1009,
            max_steps=160,
            workers=workers,
            teacher_search_preset="quality",
        )
        cross_total, cross_count = _action_nll(
            cross_models[deck][0],
            examples,
        )
        pooled_total, pooled_count = _action_nll(
            pooled_models[deck][0],
            examples,
        )
        totals["v6_cross_attention"][0] += cross_total
        totals["v6_cross_attention"][1] += cross_count
        totals["v6_pooled"][0] += pooled_total
        totals["v6_pooled"][1] += pooled_count
        by_deck[deck] = {
            "examples": len(examples),
            "cross_nll": cross_total / max(1, cross_count),
            "pooled_nll": pooled_total / max(1, pooled_count),
        }
    cross_nll = totals["v6_cross_attention"][0] / max(
        1,
        totals["v6_cross_attention"][1],
    )
    pooled_nll = totals["v6_pooled"][0] / max(
        1,
        totals["v6_pooled"][1],
    )
    return {
        "by_deck": by_deck,
        "cross_nll": cross_nll,
        "pooled_nll": pooled_nll,
        "cross_relative_improvement": (
            (pooled_nll - cross_nll) / pooled_nll
            if pooled_nll > 0.0
            else 0.0
        ),
    }


def _onnx_gate(
    models: dict[str, tuple[Any, dict, dict, str]],
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for deck, (model, _state, _config, _sha) in models.items():
            checkpoint = root / f"{deck}.pt"
            output = root / f"{deck}.onnx"
            from engine.ai.dl.model import save_checkpoint

            try:
                save_checkpoint(str(checkpoint), model)
                _payload, wrapper = _export_one(checkpoint, output)
                performance = _benchmark_one(output, enforce=False)
                result[deck] = {
                    "passed": bool(performance.get("passed")),
                    "parity_max_abs_error": _verify_one(
                        wrapper,
                        output,
                        tolerance=1e-4,
                    ),
                    "performance": performance,
                }
            except Exception as exc:
                result[deck] = {
                    "passed": False,
                    "error": str(exc),
                }
    return {
        "passed": (
            set(result) == set(models)
            and all(bool(row.get("passed")) for row in result.values())
        ),
        "decks": result,
    }


def _select_winner(
    reliable: dict[str, bool],
    *,
    cross_statistical_gate: bool,
) -> tuple[str | None, str, bool]:
    cross_reliable = bool(reliable.get("v6_cross_attention"))
    pooled_reliable = bool(reliable.get("v6_pooled"))
    cross_win_gate = cross_reliable and bool(cross_statistical_gate)
    if not pooled_reliable and not cross_reliable:
        return None, "stop_both_unreliable", cross_win_gate
    if cross_win_gate:
        return "v6_cross_attention", "cross_gate_passed", cross_win_gate
    if pooled_reliable:
        return (
            "v6_pooled",
            (
                "pooled_cross_unreliable"
                if not cross_reliable
                else "pooled_control_selected"
            ),
            cross_win_gate,
        )
    return None, "stop_no_qualified_variant", cross_win_gate


def evaluate(
    pooled_run: Path,
    cross_run: Path,
    *,
    output: Path,
    seed: int = 17,
    workers: int = 4,
    mirror_blocks: int = MIRROR_BLOCKS_PER_DECK,
    cross_blocks: int = CROSS_BLOCKS,
    heldout_games: int = 20,
) -> dict[str, Any]:
    pooled_models = _load_run_models(pooled_run, "v6_pooled")
    cross_models = _load_run_models(cross_run, "v6_cross_attention")
    choice_drift = {
        "v6_pooled": _choice_drift_evidence(pooled_run),
        "v6_cross_attention": _choice_drift_evidence(cross_run),
    }
    tasks, metadata = build_ablation_tasks(
        seed=seed,
        mirror_blocks=mirror_blocks,
        cross_blocks=cross_blocks,
    )
    requests = _requests(
        tasks,
        cross_models,
        pooled_models,
        workers=workers,
    )
    results_by_task = {}
    with ProcessPoolExecutor(
        max_workers=max(1, int(workers)),
        initializer=_worker_init,
    ) as pool:
        for rows in pool.map(_population_group_worker, requests):
            for result in rows:
                results_by_task[result.task_id] = result

    reliability = {
        "v6_cross_attention": {
            "invalid_actions": 0,
            "illegal_choices": 0,
            "rule_exceptions": 0,
            "decision_timeouts": 0,
            "choice_drift_failures": (
                0 if choice_drift["v6_cross_attention"]["passed"] else 1
            ),
        },
        "v6_pooled": {
            "invalid_actions": 0,
            "illegal_choices": 0,
            "rule_exceptions": 0,
            "decision_timeouts": 0,
            "choice_drift_failures": (
                0 if choice_drift["v6_pooled"]["passed"] else 1
            ),
        },
    }
    block_points: dict[str, list[float]] = {}
    game_rows = []
    for task in tasks:
        result = results_by_task[task.task_id]
        cross_player = 1 if task.seat_a == 1 else 0
        cross_point = (
            0.5
            if result.winner_player is None
            else 1.0 if result.winner_player == cross_player else 0.0
        )
        block_id = metadata[task.task_id]["block_id"]
        block_points.setdefault(block_id, []).append(cross_point)
        for variant, player, deck in (
            ("v6_cross_attention", cross_player, task.deck_a),
            ("v6_pooled", 1 - cross_player, task.deck_b),
        ):
            diagnostics = dict(
                result.diagnostics.get(f"{deck}@p{player}") or {}
            )
            for key in reliability[variant]:
                reliability[variant][key] += int(
                    diagnostics.get(key, 0) or 0
                )
        game_rows.append({
            "task_id": task.task_id,
            "block_id": block_id,
            "cross_point": cross_point,
            "winner_player": result.winner_player,
            "max_step_draw": any(
                int(row.get("max_step_exhaustions", 0)) > 0
                for row in result.diagnostics.values()
            ),
        })
    block_point_rows = list(block_points.values())
    all_points = [
        point
        for points in block_point_rows
        for point in points
    ]
    point_delta = 2.0 * sum(all_points) / max(1, len(all_points)) - 1.0
    ci_lower, ci_upper = _cluster_ci(
        block_point_rows,
        seed=seed + 991,
    )
    nll = _heldout_nll(
        cross_models,
        pooled_models,
        games=heldout_games,
        workers=workers,
        seed=seed,
    )
    performance = {
        "v6_pooled": _onnx_gate(pooled_models),
        "v6_cross_attention": _onnx_gate(cross_models),
    }
    for variant in reliability:
        reliability[variant]["onnx_gate_failures"] = (
            0 if performance[variant]["passed"] else 1
        )
    reliable = {
        variant: all(int(value) == 0 for value in metrics.values())
        for variant, metrics in reliability.items()
    }
    cross_statistical_gate = (
        ci_lower >= -0.02
        and (
            point_delta >= 0.01
            or float(nll["cross_relative_improvement"]) >= 0.03
        )
    )
    # Cross-attention never wins merely because the pooled control failed: it
    # must still satisfy its complete reliability/statistical contract.
    winner, decision, cross_win_gate = _select_winner(
        reliable,
        cross_statistical_gate=cross_statistical_gate,
    )
    report = {
        "schema": "deep_ai_v6_ablation_v1",
        "seed": seed,
        "pooled_run": str(pooled_run.resolve()),
        "cross_run": str(cross_run.resolve()),
        "schedule": {
            "games": len(tasks),
            "blocks": len(block_points),
            "mirror_blocks_per_deck": mirror_blocks,
            "cross_blocks": cross_blocks,
        },
        "paired": {
            "cross_point_rate": (point_delta + 1.0) / 2.0,
            "pooled_point_rate": (1.0 - point_delta) / 2.0,
            "point_rate_delta": point_delta,
            "ci95": [ci_lower, ci_upper],
            "bootstrap_iterations": BOOTSTRAP_ITERATIONS,
        },
        "heldout_action": nll,
        "choice_drift": choice_drift,
        "reliability": reliability,
        "performance": performance,
        "cross_statistical_gate": cross_statistical_gate,
        "cross_win_gate": cross_win_gate,
        "winner": winner,
        "decision": decision,
        "promotable": False,
        "release_manifest_modified": False,
        "games": game_rows,
    }
    atomic_write_json(output, report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pooled-run", type=Path, required=True)
    parser.add_argument("--cross-run", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--mirror-blocks", type=int, default=50)
    parser.add_argument("--cross-blocks", type=int, default=20)
    parser.add_argument("--heldout-games", type=int, default=20)
    args = parser.parse_args()
    report = evaluate(
        args.pooled_run,
        args.cross_run,
        output=args.output,
        seed=args.seed,
        workers=args.workers,
        mirror_blocks=args.mirror_blocks,
        cross_blocks=args.cross_blocks,
        heldout_games=args.heldout_games,
    )
    print(json.dumps({
        "winner": report["winner"],
        "decision": report["decision"],
        "point_rate_delta": report["paired"]["point_rate_delta"],
        "ci95": report["paired"]["ci95"],
    }, ensure_ascii=False, sort_keys=True))
    return 0 if report["winner"] else 2


if __name__ == "__main__":
    os.chdir(PYTHON_ROOT)
    raise SystemExit(main())
