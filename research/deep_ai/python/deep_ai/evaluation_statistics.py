"""Incremental, time-uniform inference over complete, predeclared matrix rounds.

Howard et al., arXiv:1810.08240v9, Theorems 1 and 4, equations (8), (23).
Both tails receive alpha/2. No iid assumption across matchup strata is made.
The independent sampling unit is the entire same-seed four/eight-game block.
"""
from __future__ import annotations

import math
from collections import defaultdict
from typing import Any, Mapping

from .evaluation_protocol import EvaluationProtocol, GameEvidence, REPORT_SCHEMA
from .evaluation_fairness import canonical_hash, record, standard_breakdowns


def stitched_boundary(variance: float, alpha: float) -> float:
    if not math.isfinite(variance) or variance < 0 or not 0 < alpha < 1:
        raise ValueError("evaluation_confidence_parameters_invalid")
    v = max(variance, 1.0)
    epoch = math.log2(v)
    ell = math.log((epoch + 1.0) * (epoch + 2.0) / (alpha / 2.0))
    k1 = (2.0**0.25 + 2.0**-0.25) / math.sqrt(2.0)
    k2 = (math.sqrt(2.0) + 1.0) / 2.0
    return math.sqrt(k1 * k1 * v * ell + k2 * k2 * ell * ell) + k2 * ell


class BoundedMeanCS:
    """Weighted stratum means with predictable, stratum-local forecasts.

For H strata, z=.5+(w_h/w_max)*(x-.5). At a complete matrix
boundary, theta=.5+H*w_max*(mean(z)-.5). Difference observations are
first mapped from [-1,1] to [0,1]. Only complete rounds may be added.
"""

    def __init__(self, weights: Mapping[Any, float], *, alpha: float, difference: bool = False):
        if not weights or not math.isclose(sum(weights.values()), 1.0):
            raise ValueError("evaluation_weights_not_normalized")
        if any(not math.isfinite(w) or w <= 0 for w in weights.values()):
            raise ValueError("evaluation_weight_invalid")
        self.weights = dict(weights)
        self.alpha = alpha
        self.difference = difference
        self.maximum_weight = max(weights.values())
        self.scale = len(weights) * self.maximum_weight * (2 if difference else 1)
        self.offset = 0.0 if difference else 0.5
        self.sums = dict.fromkeys(weights, 0.0)
        self.rounds = 0
        self.n = 0
        self.total = 0.0
        self.variance = 0.0
        self.lower = -1.0 if difference else 0.0
        self.upper = 1.0

    def add_round(self, values: Mapping[Any, float]) -> None:
        if set(values) != set(self.weights):
            raise ValueError("evaluation_incomplete_statistical_round")
        for key in self.weights:
            x = float(values[key])
            if not math.isfinite(x) or not (-1 if self.difference else 0) <= x <= 1:
                raise ValueError("evaluation_observation_out_of_range")
            if self.difference:
                x = (x + 1.0) / 2.0
            z = 0.5 + self.weights[key] / self.maximum_weight * (x - 0.5)
            forecast = (0.5 + self.sums[key]) / (1 + self.rounds)
            self.variance += (z - forecast) ** 2
            self.sums[key] += z
            self.total += z
            self.n += 1
        self.rounds += 1
        point = self.offset + self.scale * (self.total / self.n - 0.5)
        radius = self.scale * stitched_boundary(self.variance, self.alpha) / self.n
        # The estimand is constant at full matrix boundaries, so intersections
        # of the confidence sequence remain valid and decisions are monotone.
        self.lower = max(self.lower, point - radius)
        self.upper = min(self.upper, point + radius)

    def snapshot(self) -> dict[str, Any]:
        point = self.offset + self.scale * (self.total / self.n - 0.5) if self.n else None
        return {
            "method": "stratified_empirical_bernstein_confidence_sequence",
            "alpha": self.alpha, "confidence_level": 1 - self.alpha,
            "time_uniform": True, "blocks": self.n, "complete_rounds": self.rounds,
            "estimate": point, "interval": [self.lower, self.upper] if self.n else [None, None],
            "prediction_squared_error": self.variance,
            "boundary": {"eta": 2, "m": 1, "h": "(k+1)*(k+2)"},
        }


class EvaluationAccumulator:
    def __init__(self, protocol: EvaluationProtocol):
        self.protocol = protocol
        weights = {pair: (1 if pair[0] == pair[1] else 2) / len(protocol.decks)**2
                   for pair in protocol.pairs}
        self.primary = BoundedMeanCS(weights, alpha=protocol.alpha * 0.5)
        self.anchor = BoundedMeanCS(weights, alpha=protocol.alpha * 0.25, difference=True)
        self.decks = {deck: BoundedMeanCS(
            dict.fromkeys(protocol.decks, 1 / len(protocol.decks)),
            alpha=protocol.alpha * 0.25 / len(protocol.decks), difference=True,
        ) for deck in protocol.decks}
        self.rows: dict[str, dict[str, Any]] = {}
        self.round_rows: dict[tuple[str, int], dict[str, dict[str, Any]]] = defaultdict(dict)
        self.faults: list[dict[str, Any]] = []
        self.eligible_primary: list[dict[str, Any]] = []
        self.completed: dict[str, int] = dict.fromkeys(protocol.comparisons, 0)

    def add(self, evidence: GameEvidence) -> None:
        row = evidence.row
        identifier = row["task_id"]
        if identifier in self.rows:
            raise ValueError("evaluation_duplicate_evidence")
        self.rows[identifier] = row
        self.round_rows[(row["comparison"], row["replicate"])][identifier] = row
        if not row["strength_eligible"]:
            self.faults.append(row)

    def advance(self) -> None:
        for comparison in self.protocol.comparisons:
            while self.completed[comparison] < self.protocol.maximum_replicates:
                rep = self.completed[comparison]
                rows = self._complete_round(comparison, rep)
                if rows is None:
                    break
                self.completed[comparison] += 1
                if comparison == "ac":
                    self.primary.add_round(self._block_means(rows))
                    self.eligible_primary.extend(rows)
        while self.anchor.rounds < min(self.completed.get("ah", 0), self.completed.get("ch", 0)):
            rep = self.anchor.rounds
            treated = self._complete_round("ah", rep)
            control = self._complete_round("ch", rep)
            assert treated is not None and control is not None
            # Conditions, not result ordering or opaque task IDs, match controls.
            def key(row: Mapping[str, Any]) -> tuple:
                return tuple(row[k] for k in ("candidate_deck", "baseline_deck", "game_seed",
                                             "candidate_seat", "first_player", "max_decisions"))
            controls = {key(row): row for row in control}
            diffs = []
            for row in treated:
                other = controls[key(row)]
                diffs.append({**row, "difference": (row["candidate_score_x2"] - other["candidate_score_x2"]) / 2})
            self.anchor.add_round(self._block_means(diffs, "difference"))
            for deck, statistic in self.decks.items():
                groups: dict[str, list[float]] = defaultdict(list)
                for row in diffs:
                    if row["candidate_deck"] == deck:
                        groups[row["baseline_deck"]].append(row["difference"])
                statistic.add_round({opponent: sum(values) / len(values) for opponent, values in groups.items()})

    def _complete_round(self, comparison: str, rep: int) -> list[dict[str, Any]] | None:
        observed = self.round_rows.get((comparison, rep), {})
        if len(observed) != self.protocol.games_per_round:
            return None
        tasks = self.protocol.tasks(comparison, rep)
        if set(observed) != {task.task_id for task in tasks}:
            raise ValueError("evaluation_round_membership_mismatch")
        rows = [observed[task.task_id] for task in tasks]
        return rows if all(row["strength_eligible"] for row in rows) else None

    @staticmethod
    def _block_means(rows: list[dict[str, Any]], field: str = "candidate_score_x2") -> dict[tuple, float]:
        grouped: dict[tuple, list[float]] = defaultdict(list)
        for row in rows:
            grouped[tuple(sorted((row["candidate_deck"], row["baseline_deck"])))].append(
                row[field] / 2 if field == "candidate_score_x2" else row[field])
        return {key: sum(values) / len(values) for key, values in grouped.items()}

    def report(self, *, final: bool = False) -> dict[str, Any]:
        self.advance()
        p = self.protocol
        primary = self.primary.snapshot()
        anchor = self.anchor.snapshot()
        sufficient = self.primary.rounds >= p.minimum_replicates
        strength = "not_evaluated" if p.mode in {"screen", "calibration"} else "inconclusive"
        if sufficient and p.mode in {"promotion", "regression"}:
            if self.primary.lower > 0.5:
                strength = "improved"
            elif self.primary.upper < 0.5:
                strength = "regressed"
        per_deck = {}
        for deck, statistic in self.decks.items():
            value = statistic.snapshot()
            value["status"] = ("confirmed_regression" if statistic.n and statistic.upper < -p.deck_margin
                               else "noninferior" if statistic.n and statistic.lower > -p.deck_margin
                               else "inconclusive")
            per_deck[deck] = value
        reasons: list[str] = []
        if self.faults:
            status = "infrastructure_fail" if any(r["failure_kind"] in {"infrastructure", "cancelled"} for r in self.faults) else "fail"
            reasons = sorted({r["failure_kind"] for r in self.faults})
            strength = "not_evaluated"
        elif p.mode in {"screen", "calibration"}:
            status = "pass" if self.completed["ac"] == p.maximum_replicates else "continue"
            reasons = ["diagnostic_only"]
            if p.mode == "calibration" and self.primary.n and not self.primary.lower <= 0.5 <= self.primary.upper:
                status, reasons = "fail", ["self_play_outside_confidence_sequence"]
        elif p.mode == "regression":
            status = ("pass" if sufficient and self.primary.lower > 0.48
                      else "fail" if sufficient and self.primary.upper < 0.48 else "continue")
            reasons = ["noninferiority_established" if status == "pass" else "primary_evidence_insufficient"]
        else:
            severe = [deck for deck, value in per_deck.items() if value["status"] == "confirmed_regression"]
            anchor_ready = self.anchor.rounds >= p.minimum_replicates
            if sufficient and self.primary.upper < 0.5:
                status, reasons = "fail", ["overall_regression"]
            elif anchor_ready and (self.anchor.upper < -p.anchor_margin or severe):
                status, reasons = "fail", (["anchor_regression"] if self.anchor.upper < -p.anchor_margin else []) + [f"deck_regression:{deck}" for deck in severe]
            elif strength == "improved" and anchor_ready and self.anchor.lower > -p.anchor_margin:
                status, reasons = "pass", ["overall_improvement_and_anchor_protection"]
            else:
                status = "continue"
                reasons = ["primary_evidence_insufficient" if strength != "improved" else "anchor_evidence_insufficient"]
        if final and status == "continue":
            status = "inconclusive"
            reasons.append("budget_exhausted_or_incomplete_evidence")
        reliable = not self.faults
        result = {
            "schema": REPORT_SCHEMA, "protocol_fingerprint": p.fingerprint,
            "backend": p.backend, "mode": p.mode, "gate_status": status,
            "references": p.participants, "comparison_context_hash": canonical_hash(p.context),
            "promotion_passed": p.mode == "promotion" and status == "pass",
            "strength": {"status": strength, **primary},
            "anchor": {**anchor, "noninferiority_margin": p.anchor_margin,
                       "candidate_record": record(self._reliable_rows("ah")),
                       "champion_record": record(self._reliable_rows("ch"))},
            "per_deck": per_deck, "stop_reasons": reasons,
            "completed_rounds": dict(self.completed),
            "games": len(self.rows), "strength_games": len(self.eligible_primary),
            "record": record(self.eligible_primary),
            "breakdowns": standard_breakdowns(self.eligible_primary),
            "reliability": {"passed": reliable, "failed_games": len(self.faults),
                            "failure_task_ids": [r["task_id"] for r in self.faults]},
            "integrity": {"structural_errors": sum(r["failure_kind"] == "agent_error" for r in self.faults),
                          "truncated_games": sum(r["failure_kind"] == "truncated" for r in self.faults),
                          "persistent_timeout_games": sum(r["failure_kind"] == "timeout" for r in self.faults),
                          "failed_games": len(self.faults)},
            "error_budget": {"family_alpha": p.family_alpha, "candidate_alpha": p.alpha,
                             "maximum_candidates": p.maximum_candidates, "candidate_index": p.candidate_index,
                             "primary": p.alpha * 0.5, "anchor": p.alpha * 0.25,
                             "per_deck": p.alpha * 0.25 / len(p.decks)},
            "performance_advisory": {"gating": False},
        }
        return result

    def _reliable_rows(self, comparison: str) -> list[dict[str, Any]]:
        return [row for row in self.rows.values() if row["comparison"] == comparison
                and row["replicate"] < self.completed.get(comparison, 0)]
