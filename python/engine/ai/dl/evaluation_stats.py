"""Pure aggregation for Deep AI and Challenge evaluation game rows."""
from __future__ import annotations

from typing import Any, Iterable, Sequence

from engine.ai.dl.release_gate import point_rate


def empty_evaluation_stats(games: int) -> dict[str, Any]:
    return {
        "wins": 0,
        "losses": 0,
        "draws": 0,
        "point_rate": 0.0,
        "game_points": [],
        "avg_score": 0.0,
        "games": max(0, int(games)),
        "actions": 0,
        "invalid_actions": 0,
        "no_target_actions": 0,
        "rule_exceptions": 0,
        "decision_timeouts": 0,
        "decision_seconds": 0.0,
        "max_step_exhaustions": 0,
        "invalid_action_rate": 0.0,
        "no_target_action_rate": 0.0,
        "rule_exception_rate": 0.0,
        "decision_timeout_rate": 0.0,
        "average_decision_seconds": 0.0,
        "max_step_exhaustion_rate": 0.0,
        "seat_win_rates": {"0": 0.0, "1": 0.0},
        "seat_win_rate_gap": 0.0,
    }


def summarize_evaluation_rows(
    rows: Iterable[Sequence[Any]],
    games: int,
) -> dict[str, Any]:
    """Aggregate the stable `(winner, score, ..., diagnostics)` row contract."""
    stats = empty_evaluation_stats(games)
    if games <= 0:
        return stats

    score_total = 0.0
    seat_wins = {0: 0, 1: 0}
    seat_games = {0: 0, 1: 0}
    for row in rows:
        winner = row[0]
        score = float(row[1])
        diagnostics = row[4] if len(row) > 4 and isinstance(row[4], dict) else {}
        stats["game_points"].append(_result_point(winner))
        seat = int(diagnostics.get("seat", 0))
        seat_games[seat] = seat_games.get(seat, 0) + 1
        score_total += score
        if winner == 0:
            stats["wins"] += 1
            seat_wins[seat] = seat_wins.get(seat, 0) + 1
        elif winner == 1:
            stats["losses"] += 1
        else:
            stats["draws"] += 1
        stats["actions"] += int(diagnostics.get("actions", 0))
        stats["invalid_actions"] += int(diagnostics.get("invalid_actions", 0))
        stats["no_target_actions"] += int(diagnostics.get("no_target_actions", 0))
        stats["rule_exceptions"] += int(diagnostics.get("rule_exceptions", 0))
        stats["decision_timeouts"] += int(diagnostics.get("decision_timeouts", 0))
        stats["decision_seconds"] += float(diagnostics.get("decision_seconds", 0.0))
        stats["max_step_exhaustions"] += int(
            diagnostics.get("max_step_exhaustions", 0)
        )

    stats["avg_score"] = round(score_total / max(1, games), 3)
    stats["point_rate"] = round(point_rate(stats), 6)
    action_count = max(1, int(stats["actions"]))
    stats["invalid_action_rate"] = round(
        float(stats["invalid_actions"]) / action_count, 6
    )
    stats["no_target_action_rate"] = round(
        float(stats["no_target_actions"]) / action_count, 6
    )
    stats["rule_exception_rate"] = round(
        float(stats["rule_exceptions"]) / action_count, 6
    )
    stats["decision_timeout_rate"] = round(
        float(stats["decision_timeouts"]) / action_count, 6
    )
    stats["average_decision_seconds"] = round(
        float(stats["decision_seconds"]) / action_count, 6
    )
    stats["max_step_exhaustion_rate"] = round(
        float(stats["max_step_exhaustions"]) / max(1, games), 6
    )
    stats["seat_win_rates"] = {
        str(seat): round(
            seat_wins.get(seat, 0) / max(1, seat_games.get(seat, 0)), 6
        )
        for seat in (0, 1)
    }
    stats["seat_win_rate_gap"] = round(
        abs(stats["seat_win_rates"]["0"] - stats["seat_win_rates"]["1"]), 6
    )
    return stats


def _result_point(winner: int | None) -> float:
    if winner == 0:
        return 1.0
    if winner == 1:
        return 0.0
    return 0.5
