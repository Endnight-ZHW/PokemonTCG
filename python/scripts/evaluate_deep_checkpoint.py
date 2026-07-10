"""Evaluate a Deep AI checkpoint with raw policy or neural-MCTS action selection."""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import sys
import time
from typing import Any

PYTHON_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, PYTHON_ROOT)

from engine.ai.dl.model import load_checkpoint, torch
from engine.ai.dl.encoder import ACTION_TYPES
from engine.ai.dl.training import (
    _collect_bootstrap_examples_parallel,
    _forward_batch,
    _model_game_tasks,
    _opponent_for,
    _restore_rng,
    _run_model_game_tasks,
    _ensure_cards_loaded,
    _setup_match,
    terminal_training_score,
)
from engine.turn_manager import TurnManager
from engine.enums import TurnPhase


def _encoded_action_type(encoded_action) -> str:
    numeric = list(getattr(encoded_action, "numeric", []) or [])
    width = len(ACTION_TYPES)
    if len(numeric) < width:
        return "UNKNOWN"
    best_idx = max(range(width), key=lambda idx: float(numeric[idx]))
    if float(numeric[best_idx]) <= 0.0:
        return "UNKNOWN"
    return str(ACTION_TYPES[best_idx])


def _top_counts(values: dict[str, int], limit: int = 12) -> dict[str, int]:
    return dict(sorted(values.items(), key=lambda item: (-item[1], item[0]))[:limit])


def _aggregate(rows: list[tuple[Any, float, list, list, dict[str, Any]]], games: int) -> dict[str, Any]:
    stats: dict[str, Any] = {
        "games": max(0, int(games)),
        "wins": 0,
        "losses": 0,
        "draws": 0,
        "actions": 0,
        "invalid_actions": 0,
        "no_target_actions": 0,
        "rule_exceptions": 0,
        "decision_timeouts": 0,
        "max_step_exhaustions": 0,
        "avg_score": 0.0,
    }
    score_total = 0.0
    for row in rows:
        winner, score = row[0], row[1]
        diagnostics = row[4] if len(row) > 4 and isinstance(row[4], dict) else {}
        score_total += float(score)
        if winner == 0:
            stats["wins"] += 1
        elif winner == 1:
            stats["losses"] += 1
        else:
            stats["draws"] += 1
        for key in (
            "actions",
            "invalid_actions",
            "no_target_actions",
            "rule_exceptions",
            "decision_timeouts",
            "max_step_exhaustions",
        ):
            stats[key] += int(diagnostics.get(key, 0) or 0)
    action_count = max(1, int(stats["actions"]))
    game_count = max(1, int(stats["games"]))
    stats["point_rate"] = (float(stats["wins"]) + float(stats["draws"]) * 0.5) / game_count
    stats["avg_score"] = score_total / game_count
    stats["invalid_action_rate"] = float(stats["invalid_actions"]) / action_count
    stats["no_target_action_rate"] = float(stats["no_target_actions"]) / action_count
    stats["rule_exception_rate"] = float(stats["rule_exceptions"]) / action_count
    stats["decision_timeout_rate"] = float(stats["decision_timeouts"]) / action_count
    stats["max_step_exhaustion_rate"] = float(stats["max_step_exhaustions"]) / game_count
    return stats


def _play_teacher_game(deck_key: str, seed: int, *, max_steps: int, teacher_search_preset: str) -> tuple[int | None, float, list, list, dict[str, Any]]:
    _ensure_cards_loaded()
    opponent_key = _opponent_for(deck_key, seed)
    seat = seed % 2
    state, _tm, ais, target_player_idx, rng_state = _setup_match(
        deck_key,
        opponent_key,
        seed,
        seat,
        teacher_search_preset,
    )
    diagnostics: dict[str, Any] = {
        "actions": 0,
        "invalid_actions": 0,
        "no_target_actions": 0,
        "rule_exceptions": 0,
        "decision_timeouts": 0,
        "decision_seconds": 0.0,
        "max_step_exhaustions": 0,
        "seat": seat,
    }
    try:
        for _ in range(max_steps):
            if state.winner is not None or state.phase == TurnPhase.GAME_OVER:
                break
            if state.pending_promotion_player >= 0:
                ais[state.pending_promotion_player]._auto_promote_for_sim(state)
                continue
            if state.phase == TurnPhase.DRAW:
                TurnManager(state).advance_phase()
                continue
            if state.phase not in (TurnPhase.SETUP, TurnPhase.MAIN, TurnPhase.ATTACK):
                TurnManager(state).advance_phase()
                continue
            player_idx = state.active_player_idx if state.phase != TurnPhase.SETUP else target_player_idx
            ai = ais[player_idx]
            action = ai.choose_action(state, player_idx)
            if player_idx == target_player_idx:
                diagnostics["actions"] += 1
            try:
                result = ai._apply_action_for_sim(state, player_idx, action)
            except Exception:
                result = None
                if player_idx == target_player_idx:
                    diagnostics["rule_exceptions"] += 1
            invalid = result is None or not result.success
            if invalid and player_idx == target_player_idx:
                diagnostics["invalid_actions"] += 1
            if invalid:
                break
        if state.winner is not None:
            logical_winner = 0 if state.winner == target_player_idx else 1
            score = terminal_training_score(state, target_player_idx)
        else:
            diagnostics["max_step_exhaustions"] = 1
            logical_winner = None
            score = terminal_training_score(state, target_player_idx)
        return logical_winner, score, [], [], diagnostics
    finally:
        _restore_rng(rng_state)


def _policy_agreement(
    model,
    deck_key: str,
    *,
    games: int,
    seed: int,
    workers: int,
    device: str,
    max_steps: int,
    teacher_search_preset: str,
) -> dict[str, Any]:
    if games <= 0:
        return {}
    examples = _collect_bootstrap_examples_parallel(
        deck_key,
        games,
        seed,
        max_steps=max_steps,
        workers=max(1, workers),
        teacher_search_preset=teacher_search_preset,
    )
    valid = 0
    top1 = 0
    top3 = 0
    rank_total = 0.0
    nll_total = 0.0
    action_total = 0
    max_actions = 0
    target_type_counts: dict[str, int] = {}
    predicted_type_counts: dict[str, int] = {}
    confusion_counts: dict[str, int] = {}
    correct_by_target_type: dict[str, int] = {}
    batch_size = 256
    model.eval()
    for start in range(0, len(examples), batch_size):
        batch = examples[start:start + batch_size]
        if not batch:
            continue
        with torch.no_grad():
            logits, _value, _mask = _forward_batch(model, batch, device)
            log_probs = torch.log_softmax(logits.float(), dim=-1)
            for row_idx, ex in enumerate(batch):
                action_count = len(ex.actions)
                target = int(ex.target_index)
                if action_count <= 0 or target < 0 or target >= action_count:
                    continue
                row = logits[row_idx, :action_count].detach().cpu()
                ranked = torch.argsort(row, descending=True).tolist()
                rank = ranked.index(target) + 1
                predicted = int(ranked[0])
                target_type = _encoded_action_type(ex.actions[target])
                predicted_type = _encoded_action_type(ex.actions[predicted])
                valid += 1
                top1 += int(rank == 1)
                top3 += int(rank <= 3)
                rank_total += float(rank)
                nll_total += -float(log_probs[row_idx, target].detach().cpu())
                action_total += action_count
                max_actions = max(max_actions, action_count)
                target_type_counts[target_type] = target_type_counts.get(target_type, 0) + 1
                predicted_type_counts[predicted_type] = predicted_type_counts.get(predicted_type, 0) + 1
                if rank == 1:
                    correct_by_target_type[target_type] = correct_by_target_type.get(target_type, 0) + 1
                if target_type != predicted_type:
                    key = f"{target_type}->{predicted_type}"
                    confusion_counts[key] = confusion_counts.get(key, 0) + 1
    top1_by_target_type = {
        key: correct_by_target_type.get(key, 0) / max(1, count)
        for key, count in sorted(target_type_counts.items())
    }
    return {
        "agreement_games": games,
        "agreement_examples": len(examples),
        "agreement_valid_examples": valid,
        "policy_top1": top1 / max(1, valid),
        "policy_top3": top3 / max(1, valid),
        "policy_avg_rank": rank_total / max(1, valid),
        "policy_nll": nll_total / max(1, valid),
        "policy_avg_actions": action_total / max(1, valid),
        "policy_max_actions": max_actions,
        "target_action_counts": _top_counts(target_type_counts),
        "predicted_action_counts": _top_counts(predicted_type_counts),
        "action_type_confusions": _top_counts(confusion_counts),
        "policy_top1_by_target_type": top1_by_target_type,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", default="")
    parser.add_argument("--deck", required=True)
    parser.add_argument("--games", type=int, default=100)
    parser.add_argument("--seed", type=int, default=1900017)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--max-steps", type=int, default=120)
    parser.add_argument("--teacher-search-preset", default="hybrid")
    parser.add_argument("--use-mcts", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--mcts-simulations", type=int, default=64)
    parser.add_argument("--mcts-chance-nodes", action=argparse.BooleanOptionalAction, default=False)
    parser.add_argument("--teacher-only", action="store_true")
    parser.add_argument("--agreement-games", type=int, default=0,
                        help="Also measure top-k agreement with fresh teacher-labeled states.")
    args = parser.parse_args()
    if not args.teacher_only and not args.checkpoint:
        parser.error("--checkpoint is required unless --teacher-only is set")

    started = time.perf_counter()
    _ensure_cards_loaded()
    games = max(0, int(args.games))
    seeds = [int(args.seed) + idx * 97 for idx in range(games)]
    payload: dict[str, Any] = {}
    if args.teacher_only:
        worker_count = max(1, int(args.workers))
        if worker_count <= 1:
            rows = [
                _play_teacher_game(
                    args.deck,
                    seed,
                    max_steps=max(20, int(args.max_steps)),
                    teacher_search_preset=args.teacher_search_preset,
                )
                for seed in seeds
            ]
        else:
            rows = []
            with concurrent.futures.ProcessPoolExecutor(max_workers=worker_count) as pool:
                futures = [
                    pool.submit(
                        _play_teacher_game,
                        args.deck,
                        seed,
                        max_steps=max(20, int(args.max_steps)),
                        teacher_search_preset=args.teacher_search_preset,
                    )
                    for seed in seeds
                ]
                for future in concurrent.futures.as_completed(futures):
                    rows.append(future.result())
    else:
        model, payload = load_checkpoint(args.checkpoint, args.device)
        tasks = _model_game_tasks(
            model,
            args.deck,
            seeds,
            max_steps=max(20, int(args.max_steps)),
            record=False,
            teacher_search_preset=args.teacher_search_preset,
            temperature=0.0,
            teacher_label_model_states=False,
            phase_tag="eval_probe",
            use_mcts=bool(args.use_mcts),
            mcts_simulations=max(1, int(args.mcts_simulations)),
            mcts_chance_nodes=bool(args.mcts_chance_nodes),
        )
        rows = _run_model_game_tasks(tasks, max(1, int(args.workers))) if tasks else []
    stats = _aggregate(rows, games)
    if not args.teacher_only and int(args.agreement_games) > 0:
        stats.update(_policy_agreement(
            model,
            args.deck,
            games=max(0, int(args.agreement_games)),
            seed=int(args.seed) + 10_000_000,
            workers=max(1, int(args.workers)),
            device=args.device,
            max_steps=max(20, int(args.max_steps)),
            teacher_search_preset=args.teacher_search_preset,
        ))
    stats.update({
        "checkpoint": args.checkpoint,
        "deck": args.deck,
        "teacher_only": bool(args.teacher_only),
        "use_mcts": bool(args.use_mcts),
        "mcts_simulations": max(1, int(args.mcts_simulations)),
        "checkpoint_version": int(payload.get("version") or 0),
        "encoder_version": int((payload.get("schema") or {}).get("encoder_version") or 0),
        "elapsed_seconds": round(time.perf_counter() - started, 3),
    })
    print(json.dumps(stats, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    os.chdir(os.path.abspath(os.path.join(PYTHON_ROOT, "..")))
    raise SystemExit(main())
