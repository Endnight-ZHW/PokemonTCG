"""Low-priority, fixed-seed strength probes for a live hybrid training run.

The monitor is deliberately a sidecar.  It only reads atomically committed
checkpoints and never touches trainer RNG, replay order, optimizer state, or
the training event stream.  Results are a small-sample trend indicator; the
authoritative release decision remains the fixed 2800-game Godot gate.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import math
import os
import re
import statistics
import sys
import time
from pathlib import Path
from typing import Any

# Keep the observer CPU-only even when the training process owns CUDA.
os.environ["CUDA_VISIBLE_DEVICES"] = ""

PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from engine.ai.dl.model import create_model, torch
from engine.ai.dl.run_store import (
    atomic_write_json,
    process_is_alive,
    read_json,
    resolve_within,
    sha256_file,
    update_run,
    utc_now,
    validate_run_id,
)
from engine.ai.dl.training import (
    evaluate_challenge_baseline,
    evaluate_model,
)


PROBE_SCHEMA = "hybrid_strength_probe_v1"
TERMINAL_STATUSES = frozenset(
    {"completed", "failed", "cancelled", "promoted"}
)
_STAGE_BATCH = re.compile(r"^(teacher|dagger)_([a-z0-9]+)_(\d+)$")
_GENERATION_COMPLETE = re.compile(r"^generation_(\d+)_complete$")
_T_CRITICAL_95 = {
    1: 12.706,
    2: 4.303,
    3: 3.182,
    4: 2.776,
    5: 2.571,
    6: 2.447,
    7: 2.365,
    8: 2.306,
    9: 2.262,
    10: 2.228,
    11: 2.201,
    12: 2.179,
    13: 2.160,
    14: 2.145,
    15: 2.131,
    16: 2.120,
    17: 2.110,
    18: 2.101,
    19: 2.093,
    20: 2.086,
    21: 2.080,
    22: 2.074,
    23: 2.069,
    24: 2.064,
    25: 2.060,
    26: 2.056,
    27: 2.052,
    28: 2.048,
    29: 2.045,
    30: 2.042,
}


def paired_probe_stats(
    candidate: dict[str, Any],
    baseline: dict[str, Any],
) -> dict[str, Any]:
    candidate_points = [
        float(value) for value in candidate.get("game_points") or []
    ]
    baseline_points = [
        float(value) for value in baseline.get("game_points") or []
    ]
    if (
        not candidate_points
        or len(candidate_points) != len(baseline_points)
    ):
        raise ValueError("paired probe game points are incomplete")
    differences = [
        candidate_points[index] - baseline_points[index]
        for index in range(len(candidate_points))
    ]
    count = len(differences)
    mean = statistics.fmean(differences)
    if count > 1:
        standard_error = statistics.stdev(differences) / math.sqrt(count)
        critical = _T_CRITICAL_95.get(count - 1, 1.96)
        margin = critical * standard_error
    else:
        margin = 1.0
    return {
        "games": count,
        "candidate_point_rate": round(
            statistics.fmean(candidate_points), 6
        ),
        "challenge_point_rate": round(
            statistics.fmean(baseline_points), 6
        ),
        "point_delta": round(mean, 6),
        "ci95": [
            round(max(-1.0, mean - margin), 6),
            round(min(1.0, mean + margin), 6),
        ],
        "paired_differences": differences,
    }


def choose_probe_targets(
    *,
    batch_id: str,
    payload: dict[str, Any],
    history: list[dict[str, Any]],
    decks: list[str],
    every_games: int,
    terminal: bool = False,
) -> list[tuple[str, str, int, int]]:
    """Return `(deck, stage, completed, total)` probe targets."""

    if terminal:
        already = {
            str(row.get("deck", ""))
            for row in history
            if str(row.get("checkpoint_batch", "")) == batch_id
        }
        return [
            (deck, str(payload.get("stage", "completed")), 0, 0)
            for deck in decks
            if deck not in already
        ]

    stage_match = _STAGE_BATCH.fullmatch(batch_id)
    if stage_match:
        stage, deck, completed_text = stage_match.groups()
        if deck not in decks:
            return []
        completed = int(completed_text)
        total = int(
            dict(payload.get("counters") or {})
            .get(f"{stage}_games", {})
            .get(deck, completed)
        )
        previous = [
            int(row.get("completed", 0))
            for row in history
            if row.get("deck") == deck and row.get("stage") == stage
        ]
        if not previous or (
            completed // max(1, every_games)
            > max(previous) // max(1, every_games)
        ):
            return [(deck, stage, completed, max(completed, total))]
        return []

    generation = _GENERATION_COMPLETE.fullmatch(batch_id)
    if generation:
        stage = f"population_generation_{generation.group(1)}"
        already = {
            str(row.get("deck", ""))
            for row in history
            if str(row.get("checkpoint_batch", "")) == batch_id
        }
        return [
            (deck, stage, int(generation.group(1)), int(generation.group(1)))
            for deck in decks
            if deck not in already
        ]
    return []


def _below_normal_priority() -> None:
    if os.name != "nt":
        try:
            os.nice(5)
        except OSError:
            pass
        return
    try:
        process = ctypes.windll.kernel32.GetCurrentProcess()
        ctypes.windll.kernel32.SetPriorityClass(process, 0x00004000)
    except (AttributeError, OSError):
        pass


def _new_state(
    run_id: str,
    *,
    games: int,
    workers: int,
    max_steps: int,
    seed_base: int,
    every_games: int,
) -> dict[str, Any]:
    return {
        "schema": PROBE_SCHEMA,
        "run_id": run_id,
        "status": "waiting",
        "updated_at": utc_now(),
        "config": {
            "baseline": "challenge_fast",
            "policy": "raw_policy",
            "games_per_probe": int(games),
            "workers": int(workers),
            "max_steps": int(max_steps),
            "seed_base": int(seed_base),
            "probe_every_games": int(every_games),
            "paired": True,
            "authoritative": False,
        },
        "history": [],
        "latest_by_deck": {},
        "last_error": "",
    }


def _load_state(
    history_path: Path,
    run_id: str,
    **config: int,
) -> dict[str, Any]:
    if history_path.is_file():
        value = read_json(history_path)
        expected = _new_state(run_id, **config)
        if (
            value.get("schema") == PROBE_SCHEMA
            and value.get("run_id") == run_id
            and value.get("config") == expected.get("config")
        ):
            return value
    return _new_state(run_id, **config)


def _publish(
    run_dir: Path,
    history_path: Path,
    state: dict[str, Any],
) -> None:
    state["updated_at"] = utc_now()
    state["latest_by_deck"] = {
        deck: next(
            (
                row
                for row in reversed(state.get("history") or [])
                if row.get("deck") == deck
            ),
            None,
        )
        for deck in sorted(
            {
                str(row.get("deck", ""))
                for row in state.get("history") or []
                if row.get("deck")
            }
        )
    }
    atomic_write_json(history_path, state)
    # run.json is a summary/index.  The canonical probe history remains the
    # separate atomic sidecar above; trainer updates preserve unknown fields.
    update_run(run_dir, strength_probe=state)


def _baseline_config_key(
    *,
    games: int,
    max_steps: int,
    seed_base: int,
) -> dict[str, Any]:
    return {
        "games": int(games),
        "max_steps": int(max_steps),
        "seed_base": int(seed_base),
        "teacher_search_preset": "fast",
    }


def _load_baselines(
    path: Path,
    *,
    games: int,
    max_steps: int,
    seed_base: int,
) -> dict[str, Any]:
    config = _baseline_config_key(
        games=games,
        max_steps=max_steps,
        seed_base=seed_base,
    )
    if path.is_file():
        value = read_json(path)
        if value.get("config") == config:
            return value
    return {
        "schema": "hybrid_strength_baselines_v1",
        "config": config,
        "decks": {},
    }


def _deck_seed(seed_base: int, decks: list[str], deck: str) -> int:
    return int(seed_base) + decks.index(deck) * 100_003


def _evaluate_target(
    *,
    checkpoint_path: Path,
    checkpoint_sha: str,
    checkpoint_batch: str,
    payload: dict[str, Any],
    deck: str,
    stage: str,
    completed: int,
    total: int,
    decks: list[str],
    games: int,
    workers: int,
    max_steps: int,
    seed_base: int,
    baselines: dict[str, Any],
    baseline_path: Path,
    details_dir: Path,
) -> dict[str, Any]:
    if torch is None:
        raise RuntimeError("PyTorch is required for strength probes")
    model_states = dict(payload.get("models") or {})
    if deck not in model_states:
        raise RuntimeError(f"checkpoint has no model for {deck}")
    model = create_model(choice_head_enabled=True)
    model.load_state_dict(model_states[deck])
    model.to("cpu")
    model.eval()
    seed = _deck_seed(seed_base, decks, deck)

    baseline_rows = dict(baselines.get("decks") or {})
    baseline = baseline_rows.get(deck)
    if not isinstance(baseline, dict):
        baseline = evaluate_challenge_baseline(
            deck,
            seed,
            games,
            max_steps=max_steps,
            workers=workers,
            teacher_search_preset="fast",
        )
        baseline_rows[deck] = baseline
        baselines["decks"] = baseline_rows
        atomic_write_json(baseline_path, baselines)

    started = time.perf_counter()
    candidate = evaluate_model(
        model,
        deck,
        seed,
        games,
        device="cpu",
        max_steps=max_steps,
        workers=workers,
        teacher_search_preset="fast",
        use_mcts=False,
    )
    duration = time.perf_counter() - started
    paired = paired_probe_stats(candidate, baseline)
    detail = {
        "schema": PROBE_SCHEMA,
        "checkpoint_batch": checkpoint_batch,
        "checkpoint_sha256": checkpoint_sha,
        "checkpoint_path": checkpoint_path.name,
        "deck": deck,
        "stage": stage,
        "completed": int(completed),
        "total": int(total),
        "seed": seed,
        "candidate": candidate,
        "challenge": baseline,
        "paired": paired,
        "duration_seconds": round(duration, 3),
        "created_at": utc_now(),
    }
    details_dir.mkdir(parents=True, exist_ok=True)
    detail_path = details_dir / f"{checkpoint_sha[:12]}-{deck}.json"
    atomic_write_json(detail_path, detail)
    return {
        "index": 0,
        "checkpoint_batch": checkpoint_batch,
        "checkpoint_sha256": checkpoint_sha,
        "deck": deck,
        "stage": stage,
        "completed": int(completed),
        "total": int(total),
        "games": int(paired["games"]),
        "candidate_point_rate": paired["candidate_point_rate"],
        "challenge_point_rate": paired["challenge_point_rate"],
        "point_delta": paired["point_delta"],
        "ci95": paired["ci95"],
        "wins": int(candidate.get("wins", 0)),
        "losses": int(candidate.get("losses", 0)),
        "draws": int(candidate.get("draws", 0)),
        "invalid_actions": int(candidate.get("invalid_actions", 0)),
        "rule_exceptions": int(candidate.get("rule_exceptions", 0)),
        "max_step_exhaustions": int(
            candidate.get("max_step_exhaustions", 0)
        ),
        "duration_seconds": round(duration, 3),
        "detail_path": str(
            detail_path.relative_to(checkpoint_path.parents[1]).as_posix()
        ),
        "created_at": detail["created_at"],
    }


def _acquire_monitor_lock(lock_path: Path) -> bool:
    if lock_path.is_file():
        try:
            owner = read_json(lock_path)
            if process_is_alive(int(owner.get("pid", 0) or 0)):
                return False
        except (OSError, ValueError, json.JSONDecodeError):
            pass
        lock_path.unlink(missing_ok=True)
    try:
        descriptor = os.open(
            lock_path,
            os.O_CREAT | os.O_EXCL | os.O_WRONLY,
        )
    except FileExistsError:
        return False
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump({"pid": os.getpid(), "started_at": utc_now()}, handle)
        handle.flush()
        os.fsync(handle.fileno())
    return True


def monitor(
    *,
    run_dir: Path,
    games: int,
    workers: int,
    max_steps: int,
    seed_base: int,
    every_games: int,
    interval_seconds: float,
    once: bool,
) -> int:
    run_dir = run_dir.resolve()
    run = read_json(run_dir / "run.json")
    run_id = validate_run_id(str(run.get("run_id", "")))
    decks = [str(deck) for deck in dict(run.get("config") or {}).get("decks", [])]
    if not decks:
        raise RuntimeError("run configuration has no decks")
    evaluation_dir = run_dir / "evaluation"
    evaluation_dir.mkdir(exist_ok=True)
    logs_dir = run_dir / "logs"
    logs_dir.mkdir(exist_ok=True)
    lock_path = logs_dir / "strength_probe.lock.json"
    if not _acquire_monitor_lock(lock_path):
        print("A strength monitor is already attached.", flush=True)
        return 2

    history_path = evaluation_dir / "strength_history.json"
    baseline_path = evaluation_dir / "strength_baselines.json"
    details_dir = evaluation_dir / "strength_details"
    state = _load_state(
        history_path,
        run_id,
        games=games,
        workers=workers,
        max_steps=max_steps,
        seed_base=seed_base,
        every_games=every_games,
    )
    baselines = _load_baselines(
        baseline_path,
        games=games,
        max_steps=max_steps,
        seed_base=seed_base,
    )
    last_failed_checkpoint = ""
    _publish(run_dir, history_path, state)
    try:
        while True:
            run = read_json(run_dir / "run.json")
            run_status = str(run.get("status", ""))
            terminal = run_status in TERMINAL_STATUSES
            latest_path = run_dir / "checkpoints" / "latest.json"
            if not latest_path.is_file():
                if terminal or once:
                    break
                time.sleep(interval_seconds)
                continue
            latest = read_json(latest_path)
            checkpoint_sha = str(latest.get("sha256", "")).lower()
            checkpoint_batch = str(latest.get("batch_id", ""))
            checkpoint_path = resolve_within(
                run_dir / "checkpoints",
                str(latest.get("path", "")),
            )
            if (
                not checkpoint_path.is_file()
                or sha256_file(checkpoint_path) != checkpoint_sha
            ):
                if once:
                    raise RuntimeError("latest checkpoint hash mismatch")
                time.sleep(interval_seconds)
                continue
            if checkpoint_sha == last_failed_checkpoint:
                if terminal or once:
                    break
                time.sleep(interval_seconds)
                continue
            try:
                payload = torch.load(
                    checkpoint_path,
                    map_location="cpu",
                    weights_only=False,
                )
                if not isinstance(payload, dict):
                    raise RuntimeError("checkpoint payload is invalid")
                targets = choose_probe_targets(
                    batch_id=checkpoint_batch,
                    payload=payload,
                    history=list(state.get("history") or []),
                    decks=decks,
                    every_games=every_games,
                    terminal=run_status == "completed",
                )
                run_config = dict(run.get("config") or {})
                targets = [
                    (
                        deck,
                        stage,
                        completed,
                        int(
                            run_config.get(
                                f"{stage}_games",
                                total,
                            )
                            if stage in {"teacher", "dagger"}
                            else total
                        ),
                    )
                    for deck, stage, completed, total in targets
                ]
                if not targets:
                    if terminal or once:
                        break
                    time.sleep(interval_seconds)
                    continue

                state["status"] = "evaluating"
                state["current"] = {
                    "checkpoint_batch": checkpoint_batch,
                    "checkpoint_sha256": checkpoint_sha,
                    "decks": [target[0] for target in targets],
                }
                state["last_error"] = ""
                _publish(run_dir, history_path, state)
                for deck, stage, completed, total in targets:
                    row = _evaluate_target(
                        checkpoint_path=checkpoint_path,
                        checkpoint_sha=checkpoint_sha,
                        checkpoint_batch=checkpoint_batch,
                        payload=payload,
                        deck=deck,
                        stage=stage,
                        completed=completed,
                        total=total,
                        decks=decks,
                        games=games,
                        workers=workers,
                        max_steps=max_steps,
                        seed_base=seed_base,
                        baselines=baselines,
                        baseline_path=baseline_path,
                        details_dir=details_dir,
                    )
                    history = list(state.get("history") or [])
                    row["index"] = len(history) + 1
                    first = next(
                        (
                            item
                            for item in history
                            if item.get("deck") == deck
                        ),
                        None,
                    )
                    row["change_from_first"] = round(
                        float(row["point_delta"])
                        - float(
                            (first or row).get("point_delta", 0.0)
                        ),
                        6,
                    )
                    history.append(row)
                    state["history"] = history[-250:]
                    _publish(run_dir, history_path, state)
                    print(
                        f"PROBE {checkpoint_batch} {deck} "
                        f"delta={float(row['point_delta']):+.4f} "
                        f"ci95={row['ci95']}",
                        flush=True,
                    )
                state["status"] = "idle"
                state["current"] = {}
                _publish(run_dir, history_path, state)
                last_failed_checkpoint = ""
            except Exception as exc:
                last_failed_checkpoint = checkpoint_sha
                state["status"] = "error"
                state["current"] = {}
                state["last_error"] = f"{type(exc).__name__}: {exc}"
                _publish(run_dir, history_path, state)
                print(f"STRENGTH_PROBE_ERROR {state['last_error']}", flush=True)
                if once:
                    raise
            if once:
                break
            time.sleep(interval_seconds)
        state["status"] = "stopped" if terminal else "waiting"
        state["current"] = {}
        _publish(run_dir, history_path, state)
        return 0
    finally:
        try:
            owner = read_json(lock_path)
            if int(owner.get("pid", 0) or 0) == os.getpid():
                lock_path.unlink(missing_ok=True)
        except (OSError, ValueError, json.JSONDecodeError):
            pass


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Observe committed hybrid checkpoints with low-priority, "
            "fixed-seed Challenge probes."
        )
    )
    parser.add_argument("--run-id", required=True)
    parser.add_argument(
        "--runs-root",
        default=str(REPO_ROOT / "build" / "ai_training" / "runs"),
    )
    parser.add_argument("--games", type=int, default=12)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--max-steps", type=int, default=160)
    parser.add_argument("--seed-base", type=int, default=8_800_017)
    parser.add_argument("--every-games", type=int, default=100)
    parser.add_argument("--interval-seconds", type=float, default=10.0)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    if args.games < 2 or args.games > 64:
        parser.error("--games must be between 2 and 64")
    if args.workers < 1 or args.workers > 4:
        parser.error("--workers must be between 1 and 4")
    if args.max_steps < 40 or args.max_steps > 320:
        parser.error("--max-steps must be between 40 and 320")
    if args.every_games < 20:
        parser.error("--every-games must be at least 20")
    if args.interval_seconds < 2:
        parser.error("--interval-seconds must be at least 2")
    validate_run_id(args.run_id)
    runs_root = Path(args.runs_root).resolve()
    run_dir = (runs_root / args.run_id).resolve()
    try:
        run_dir.relative_to(runs_root)
    except ValueError as exc:
        raise SystemExit("run id resolves outside runs root") from exc
    _below_normal_priority()
    if torch is not None:
        torch.set_num_threads(1)
    return monitor(
        run_dir=run_dir,
        games=args.games,
        workers=args.workers,
        max_steps=args.max_steps,
        seed_base=args.seed_base,
        every_games=args.every_games,
        interval_seconds=args.interval_seconds,
        once=args.once,
    )


if __name__ == "__main__":
    raise SystemExit(main())
