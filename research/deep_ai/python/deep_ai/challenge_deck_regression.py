"""Paired deck regression with the opponent controller held fixed.

A(D)-B(O) versus B(D)-A(O) changes both controllers. That relative contrast
can conceal a regression in D when A improves on O. Compare A(D)-B(O) with
B(D)-B(O) on identical decks, rules seeds, seats and first-player settings.
"""
from __future__ import annotations

from collections import Counter, defaultdict
import hashlib
import random
from typing import Any, Mapping, Sequence

from .evaluation_fairness import percentile


def fixed_opponent_deck_effects(
    treatment: Sequence[Mapping[str, Any]], control: Sequence[Mapping[str, Any]],
    *, seed: int, samples: int = 10000, alpha: float = 0.05,
) -> dict[str, dict[str, Any]]:
    def index(rows):
        result = {}
        counts = Counter(str(row["block_id"]) for row in rows)
        for row in rows:
            if (not row.get("success") or not row.get("terminal")
                    or not row.get("strength_eligible") or row.get("truncated")
                    or row.get("persistent_timeout") or any(row.get(key, 0) for key in (
                        "invalid_actions", "illegal_choices", "controller_failures", "rule_exceptions"))):
                raise ValueError("fixed_opponent_requires_reliable_complete_games")
            if counts[str(row["block_id"])] != int(row["block_size"]):
                raise ValueError("fixed_opponent_requires_complete_blocks")
            key = (str(row["candidate_deck"]), str(row["baseline_deck"]),
                   int(row["game_seed"]), int(row["candidate_seat"]),
                   int(row["first_player"]), int(row.get("max_decisions", 0)))
            if key in result:
                raise ValueError("fixed_opponent_duplicate_game_conditions")
            result[key] = row
        return result

    treated, controls = index(treatment), index(control)
    if not treated or treated.keys() != controls.keys():
        raise ValueError("fixed_opponent_game_conditions_do_not_match")
    groups = defaultdict(lambda: defaultdict(list))
    for key, row in sorted(treated.items()):
        other = controls[key]
        if row["block_id"] != other["block_id"]:
            raise ValueError("fixed_opponent_blocks_do_not_match")
        groups[str(row["candidate_deck"])][str(row["block_id"])].append(
            (float(row["candidate_score_x2"]) / 2, float(other["candidate_score_x2"]) / 2))
    effects = {}
    for deck, blocks in sorted(groups.items()):
        rows = [(len(values), sum(a for a, _ in values), sum(b for _, b in values))
                for _, values in sorted(blocks.items())]
        count = sum(n for n, _, _ in rows)
        candidate = sum(a for _, a, _ in rows) / count
        baseline = sum(b for _, _, b in rows) / count
        rng = random.Random(seed ^ int.from_bytes(hashlib.sha256(deck.encode()).digest()[:8], "big"))
        distribution = []
        for _ in range(samples):
            picked = [rows[rng.randrange(len(rows))] for _ in rows]
            distribution.append(sum(a - b for _, a, b in picked) / sum(n for n, _, _ in picked))
        effects[deck] = {"games": count, "paired_blocks": len(rows),
            "candidate_score_rate": candidate, "baseline_score_rate": baseline,
            "score_delta": candidate - baseline,
            "score_delta_ci": [percentile(distribution, alpha / 2), percentile(distribution, 1 - alpha / 2)],
            "confidence_level": 1 - alpha, "opponent_controller": "frozen_baseline"}
    return effects
