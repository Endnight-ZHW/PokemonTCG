"""Immutable, backend-independent experiments and checked game evidence.

The protocol is the source of truth for membership and weighting. A result never
gets to declare its own block size, seat closure, eligibility or agent identity.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, field
from typing import Any, Mapping

from .evaluation_fairness import canonical_hash, SEAT_FIRST_PLAYER_CLOSURES

PROTOCOL_SCHEMA = "ptcg.ai_evaluation.protocol/1"
REPORT_SCHEMA = "ptcg.ai_evaluation.report/1"
EVIDENCE_SCHEMA = "ptcg.ai_evaluation.game/1"
COMPARISON_ROLES = {"ac": ("candidate", "champion"),
                    "ah": ("candidate", "anchor"), "ch": ("champion", "anchor")}
FORMAL_MODES = {"promotion", "regression"}


def _integer(value: Any, name: str, minimum: int, maximum: int) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"evaluation_invalid_{name}")
    return value


@dataclass(frozen=True, slots=True)
class EvaluationTask:
    task_id: str
    comparison: str
    replicate: int
    candidate_deck: str
    baseline_deck: str
    game_seed: int
    candidate_seat: int
    first_player: int
    max_decisions: int
    block_id: str
    block_size: int
    block_kind: str
    closure: int

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @property
    def pair(self) -> tuple[str, str]:
        return tuple(sorted((self.candidate_deck, self.baseline_deck)))

    def conditions(self) -> dict[str, Any]:
        return {key: getattr(self, key) for key in (
            "candidate_deck", "baseline_deck", "game_seed", "candidate_seat",
            "first_player", "max_decisions")}


@dataclass(frozen=True)
class EvaluationProtocol:
    # JSON strings, rather than mutable dictionaries, keep nested inputs frozen.
    backend: str
    mode: str
    decks: tuple[str, ...]
    participants_json: str
    context_json: str
    seed: int = 17
    cohort: str = ""
    maximum_replicates: int = 100
    minimum_replicates: int = 5
    max_decisions: int = 1024
    family_alpha: float = 0.05
    maximum_candidates: int = 1
    candidate_index: int = 0
    anchor_margin: float = 0.02
    deck_margin: float = 0.05
    _rounds: tuple[tuple[EvaluationTask, ...], ...] = field(init=False, repr=False)
    fingerprint: str = field(init=False)

    def __post_init__(self) -> None:
        if self.backend not in {"challenge", "deep_v3"}:
            raise ValueError("evaluation_backend_invalid")
        if self.mode not in {"promotion", "regression", "screen", "calibration"}:
            raise ValueError("evaluation_mode_invalid")
        if not self.decks or tuple(sorted(set(self.decks))) != self.decks:
            raise ValueError("evaluation_decks_must_be_sorted_unique")
        _integer(self.seed, "seed", 0, 0xFFFFFFFF)
        _integer(self.maximum_replicates, "maximum_replicates", 1, 100)
        _integer(self.minimum_replicates, "minimum_replicates", 1, self.maximum_replicates)
        _integer(self.max_decisions, "max_decisions", 1, 4096)
        _integer(self.maximum_candidates, "maximum_candidates", 1, 1_000_000)
        _integer(self.candidate_index, "candidate_index", 0, self.maximum_candidates - 1)
        if not 0 < self.family_alpha <= 0.05:
            raise ValueError("evaluation_alpha_invalid")
        if self.mode in FORMAL_MODES and self.minimum_replicates < 5:
            raise ValueError("evaluation_formal_requires_five_rounds")
        if not 0 <= self.anchor_margin < 1 or not 0 <= self.deck_margin < 1:
            raise ValueError("evaluation_margin_invalid")
        for role in ("candidate", "champion", "anchor"):
            participant = self.participants.get(role, {})
            content_hash = participant.get("content_hash", "")
            if len(content_hash) != 64 or any(c not in "0123456789abcdef" for c in content_hash):
                raise ValueError(f"evaluation_participant_hash_invalid:{role}")
        context = self.context
        if self.mode == "calibration" and self.participants["candidate"] != self.participants["champion"]:
            raise ValueError("evaluation_calibration_requires_identical_participants")
        if context.get("time_budget_ms", 0) != 0:
            raise ValueError("evaluation_requires_fixed_work")
        if not context.get("rules_hash") or not context.get("decks_hash"):
            raise ValueError("evaluation_content_identity_missing")
        if self.mode in FORMAL_MODES:
            # Import here to keep the statistics/protocol modules usable without
            # Torch, NumPy, or a compiled research binding.
            from .v3_contract import RELEASE_DECKS
            if set(self.decks) != set(RELEASE_DECKS):
                raise ValueError("evaluation_formal_requires_release_decks")
        rounds = []
        used_seeds: set[int] = set()
        namespace = "confirm" if self.mode in FORMAL_MODES else "development"
        for replicate in range(self.maximum_replicates):
            tasks = []
            for pair_index, pair in enumerate(self.pairs):
                salt = 0
                while True:
                    seed = int(canonical_hash([
                        "ptcg.ai_evaluation.seed/1", namespace, self.seed,
                        self.cohort, self.candidate_index, pair, replicate, salt,
                    ])[:8], 16)
                    if seed and seed not in used_seeds:
                        used_seeds.add(seed)
                        break
                    salt += 1
                block = f"r{replicate:03d}:p{pair_index:03d}:s{seed}"
                directions = (pair,) if pair[0] == pair[1] else (pair, pair[::-1])
                for direction, (left, right) in enumerate(directions):
                    for closure, (seat, first) in enumerate(SEAT_FIRST_PLAYER_CLOSURES):
                        tasks.append(EvaluationTask(
                            f"r{replicate:03d}:p{pair_index:03d}:d{direction}:c{closure}",
                            "ac", replicate, left, right, seed, seat, first,
                            self.max_decisions, block, len(directions) * 4,
                            "mirror" if left == right else "cross_deck", closure,
                        ))
            rounds.append(tuple(tasks))
        object.__setattr__(self, "_rounds", tuple(rounds))
        object.__setattr__(self, "fingerprint", canonical_hash(self.to_dict()))

    @classmethod
    def create(cls, *, participants: Mapping[str, Any], context: Mapping[str, Any],
               decks: tuple[str, ...] | list[str], **kwargs: Any) -> EvaluationProtocol:
        return cls(decks=tuple(sorted(decks)),
                   participants_json=json.dumps(participants, sort_keys=True, allow_nan=False),
                   context_json=json.dumps(context, sort_keys=True, allow_nan=False), **kwargs)

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> EvaluationProtocol:
        raw = dict(value)
        if raw.pop("schema", None) != PROTOCOL_SCHEMA:
            raise ValueError("evaluation_protocol_schema_mismatch")
        schedule_hash = raw.pop("schedule_hash")
        protocol = cls.create(**raw)
        if protocol.to_dict()["schedule_hash"] != schedule_hash:
            raise ValueError("evaluation_schedule_hash_mismatch")
        return protocol

    @property
    def participants(self) -> dict[str, Any]:
        return json.loads(self.participants_json)

    @property
    def context(self) -> dict[str, Any]:
        return json.loads(self.context_json)

    @property
    def pairs(self) -> tuple[tuple[str, str], ...]:
        return tuple((a, b) for i, a in enumerate(self.decks) for b in self.decks[i:])

    @property
    def comparisons(self) -> tuple[str, ...]:
        paired_screen = self.mode == "screen" and self.context.get("paired_anchor_screen", False)
        return ("ac", "ah", "ch") if self.mode == "promotion" or paired_screen else ("ac",)

    @property
    def games_per_round(self) -> int:
        return 4 * len(self.decks) ** 2

    @property
    def alpha(self) -> float:
        return self.family_alpha / self.maximum_candidates

    def tasks(self, comparison: str, replicate: int) -> tuple[EvaluationTask, ...]:
        if comparison not in self.comparisons or not 0 <= replicate < self.maximum_replicates:
            raise ValueError("evaluation_round_not_in_protocol")
        return tuple(EvaluationTask(**{
            **task.to_dict(), "task_id": f"{comparison}:{task.task_id}",
            "comparison": comparison,
        }) for task in self._rounds[replicate])

    def to_dict(self) -> dict[str, Any]:
        digest = hashlib.sha256()
        for tasks in self._rounds:
            for task in tasks:
                digest.update((canonical_hash(task.to_dict()) + "\n").encode("ascii"))
        return {
            "schema": PROTOCOL_SCHEMA, "backend": self.backend, "mode": self.mode,
            "decks": list(self.decks), "participants": self.participants,
            "context": self.context, "seed": self.seed, "cohort": self.cohort,
            "maximum_replicates": self.maximum_replicates,
            "minimum_replicates": self.minimum_replicates,
            "max_decisions": self.max_decisions, "family_alpha": self.family_alpha,
            "maximum_candidates": self.maximum_candidates, "candidate_index": self.candidate_index,
            "anchor_margin": self.anchor_margin, "deck_margin": self.deck_margin,
            "schedule_hash": digest.hexdigest(),
        }

    def round_cache_key(self, comparison: str, replicate: int) -> str:
        roles = COMPARISON_ROLES[comparison]
        return canonical_hash({
            "schema": "ptcg.ai_evaluation.round_cache/1", "backend": self.backend,
            "participants": [self.participants[role] for role in roles],
            "context": self.context,
            "conditions": [task.conditions() for task in self.tasks(comparison, replicate)],
        })


FAULT_COUNTERS = ("invalid_actions", "illegal_choices", "controller_failures", "rule_exceptions")


def evidence_semantics(row: Mapping[str, Any]) -> dict[str, Any]:
    return {key: row.get(key) for key in (
        "schema", "protocol_fingerprint", "task_id", "comparison", "replicate",
        "candidate_deck", "baseline_deck", "game_seed", "candidate_seat",
        "first_player", "max_decisions", "block_id", "block_size", "block_kind",
        "closure", "winner_seat", "candidate_score_x2", "success", "terminal",
        "truncated", "strength_eligible", "failure_kind", "error",
        "final_state_hash", "decisions", "turns", *FAULT_COUNTERS,
    )}


@dataclass(frozen=True)
class GameEvidence:
    row: dict[str, Any]

    @classmethod
    def from_result(cls, protocol: EvaluationProtocol, task: EvaluationTask,
                    result: Mapping[str, Any]) -> GameEvidence:
        raw = dict(result)
        for key, expected in {"task_id": task.task_id, **task.conditions()}.items():
            actual = raw.get(key)
            if actual is None or type(actual) is not type(expected) or actual != expected:
                raise ValueError(f"evaluation_result_condition_mismatch:{task.task_id}:{key}")
        for key in ("success", "terminal", "truncated"):
            if type(raw.get(key)) is not bool:
                raise ValueError(f"evaluation_result_boolean_missing:{key}")
        winner = raw.get("winner_seat")
        _integer(winner, "winner", -1, 1)
        error = str(raw.get("error", ""))
        counters = {key: _integer(raw.get(key, 0), key, 0, 2**31 - 1) for key in FAULT_COUNTERS}
        success, terminal, truncated = (raw[key] for key in ("success", "terminal", "truncated"))
        failure = ""
        if truncated or "decision_cap" in error:
            failure = "truncated"
        elif "timeout" in error or raw.get("persistent_timeout"):
            failure = "timeout"
        elif "cancel" in error:
            failure = "cancelled"
        elif counters["rule_exceptions"] or "create_failed" in error or raw.get("failure_kind") == "infrastructure":
            failure = "infrastructure"
        elif not success or not terminal or error or any(counters.values()):
            failure = "agent_error" if (error or any(counters.values())) else "infrastructure"
        eligible = not failure and success and terminal and not truncated
        score = (1 if winner == -1 else 2 if winner == task.candidate_seat else 0) if eligible else None
        if eligible and "candidate_score_x2" in raw and raw["candidate_score_x2"] != score:
            raise ValueError("evaluation_result_score_mismatch")
        row = {
            **raw, **task.to_dict(), **counters, "schema": EVIDENCE_SCHEMA,
            "protocol_fingerprint": protocol.fingerprint, "winner_seat": winner,
            "candidate_score_x2": score, "strength_eligible": eligible,
            "failure_kind": failure, "error": error,
            "final_state_hash": str(raw["final_state_hash"]),
            "decisions": int(raw.get("decisions", 0)), "turns": int(raw.get("turns", 0)),
        }
        row["evidence_hash"] = canonical_hash(evidence_semantics(row))
        return cls(row)

    @classmethod
    def verify(cls, protocol: EvaluationProtocol, task: EvaluationTask,
               row: Mapping[str, Any]) -> GameEvidence:
        if row.get("schema") != EVIDENCE_SCHEMA or row.get("protocol_fingerprint") != protocol.fingerprint:
            raise ValueError("evaluation_evidence_protocol_mismatch")
        if row.get("evidence_hash") != canonical_hash(evidence_semantics(row)):
            raise ValueError("evaluation_evidence_hash_mismatch")
        checked = cls.from_result(protocol, task, row)
        if evidence_semantics(checked.row) != evidence_semantics(row):
            raise ValueError("evaluation_evidence_semantics_mismatch")
        return checked
