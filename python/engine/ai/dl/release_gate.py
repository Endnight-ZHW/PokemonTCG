"""Shared release-gate metrics for Deep AI checkpoints.

Training, runtime loading, and offline validation must make the same release
decision.  Keep the pure metric calculations here so those three entry points
cannot silently drift apart.
"""
from __future__ import annotations

from typing import Any


DEFAULT_MIN_ACCEPTED_EVAL_GAMES = 600
DEFAULT_MIN_ACCEPTED_POINT_RATE = 0.50
# A 600-game paired slice is noisy enough that an exact zero floor encourages
# seed shopping.  Treat at most six game-points (1%) as practical
# non-inferiority; this remains much stricter than the broader deep-practical
# evaluation gate.
DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE = -0.01
DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE = 0.05
_EPSILON = 1e-12


def point_rate(result: dict[str, Any] | None) -> float:
    """Return win + half-draw points per game."""
    if not result:
        return 0.0
    games = max(1, int(result.get("games") or 0))
    wins = float(result.get("wins", 0) or 0.0)
    draws = float(result.get("draws", 0) or 0.0)
    return (wins + draws * 0.5) / games


def paired_delta_point_rate(
    candidate: dict[str, Any] | None,
    baseline: dict[str, Any] | None,
) -> float | None:
    """Return the mean per-game candidate minus baseline point delta."""
    if not candidate or not baseline:
        return None
    candidate_points = candidate.get("game_points")
    baseline_points = baseline.get("game_points")
    if not isinstance(candidate_points, list) or not isinstance(baseline_points, list):
        return None
    candidate_games = int(candidate.get("games") or 0)
    baseline_games = int(baseline.get("games") or 0)
    if (
        candidate_games <= 0
        or candidate_games != baseline_games
        or len(candidate_points) != candidate_games
        or len(baseline_points) != baseline_games
    ):
        return None
    try:
        return sum(
            float(candidate_points[index]) - float(baseline_points[index])
            for index in range(candidate_games)
        ) / candidate_games
    except (TypeError, ValueError):
        return None


def release_delta_point_rate(
    candidate: dict[str, Any] | None,
    baseline: dict[str, Any] | None,
) -> float | None:
    """Prefer paired evidence, falling back to aggregate point-rate delta."""
    if not baseline or int(baseline.get("games") or 0) <= 0:
        return None
    paired_delta = paired_delta_point_rate(candidate, baseline)
    if paired_delta is not None:
        return paired_delta
    return point_rate(candidate) - point_rate(baseline)


def max_step_exhaustion_rate(result: dict[str, Any] | None) -> float:
    if not result:
        return 0.0
    if "max_step_exhaustion_rate" in result:
        return float(result.get("max_step_exhaustion_rate", 0.0) or 0.0)
    games = max(1, int(result.get("games") or 0))
    return float(result.get("max_step_exhaustions", 0.0) or 0.0) / games


def allowed_max_step_exhaustion_rate(
    absolute_limit: float,
    paired_baseline: dict[str, Any] | None = None,
) -> float:
    """Return the release ceiling for max-step exhaustion.

    The absolute limit remains authoritative when there is no paired baseline.
    When the paired Challenge policy itself exceeds that limit, a candidate is
    allowed to match or improve the baseline instead of being rejected for a
    deck-specific long-game profile it did not cause.
    """
    limit = max(0.0, min(1.0, float(absolute_limit)))
    if paired_baseline and int(paired_baseline.get("games") or 0) > 0:
        limit = max(limit, max_step_exhaustion_rate(paired_baseline))
    return limit


def has_strength_and_reliability_floor(
    candidate: dict[str, Any] | None,
    *,
    min_point_rate: float,
    paired_baseline: dict[str, Any] | None = None,
    min_delta_point_rate: float = DEFAULT_MIN_ACCEPTED_DELTA_POINT_RATE,
    max_step_exhaustion_rate_limit: float = DEFAULT_MAX_ACCEPTED_STEP_EXHAUSTION_RATE,
) -> bool:
    """Apply the shared strength and long-game release floors."""
    if not candidate or int(candidate.get("games") or 0) <= 0:
        return False
    if paired_baseline and int(paired_baseline.get("games") or 0) > 0:
        delta = release_delta_point_rate(candidate, paired_baseline)
        if delta is None or delta + _EPSILON < float(min_delta_point_rate):
            return False
    elif point_rate(candidate) + _EPSILON < float(min_point_rate):
        return False

    exhaustion_limit = allowed_max_step_exhaustion_rate(
        max_step_exhaustion_rate_limit,
        paired_baseline,
    )
    return max_step_exhaustion_rate(candidate) <= exhaustion_limit + _EPSILON
