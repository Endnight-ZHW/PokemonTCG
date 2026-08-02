"""Stable AlphaZero v2 training/runtime contract and seed derivation."""
from __future__ import annotations

import hashlib
from typing import Any

from .v2_contract import (
    CHECKPOINT_VERSION,
    DEEP_PLANNER_VERSION,
    DEFAULT_C_PUCT,
    DEFAULT_TRAINING_SIMULATIONS,
    MODEL_VARIANT,
    RELEASE_DECKS,
    TRAINER_ID,
    contract_dict,
)


DEEP_PLANNER_ID = "infoset_puct_v2"
DEEP_PLANNER_SCHEMA_VERSION = DEEP_PLANNER_VERSION
DEEP_PLANNER_CONSTANTS: dict[str, Any] = {
    "c_puct": DEFAULT_C_PUCT,
    "training_simulations": DEFAULT_TRAINING_SIMULATIONS,
    "challenge_prior_weight": 0.0,
    "full_turn_rollout": False,
    "leaf_evaluator": "neural_wdl",
    "value_head_mode": "search_backup",
}

TRAINING_EVENT_SCHEMA = "alphazero_v2_event_v1"
RUN_FORMAT_VERSION = 2
CHECKPOINT_FORMAT_VERSION = CHECKPOINT_VERSION
EVIDENCE_FORMAT_VERSION = 2
AI_SEED_FALLBACK = 0x6D2B79F5


def _seed(domain: str, *parts: Any) -> int:
    wire = "|".join(
        (domain, DEEP_PLANNER_ID, *(str(part) for part in parts))
    ).encode("utf-8")
    return (
        int.from_bytes(hashlib.sha256(wire).digest()[:8], "big")
        & 0xFFFFFFFF
    ) or AI_SEED_FALLBACK


def derive_deep_decision_seed(
    match_seed: int,
    revision: int,
    actor: int,
    ordinal: int,
) -> int:
    return _seed(
        "deep-decision-v2",
        int(match_seed),
        int(revision),
        int(actor),
        int(ordinal),
    )


def derive_training_decision_seed(
    task_seed: int,
    revision: int,
    actor: int,
    decision_ordinal: int,
    purpose: str,
) -> int:
    return _seed(
        "deep-training-v2",
        int(task_seed),
        int(revision),
        int(actor),
        int(decision_ordinal),
        str(purpose),
    )


def deep_planner_manifest(evidence_sha256: str = "") -> dict[str, Any]:
    result = {
        "planner_id": DEEP_PLANNER_ID,
        "schema_version": DEEP_PLANNER_SCHEMA_VERSION,
        **DEEP_PLANNER_CONSTANTS,
        "evidence_sha256": str(evidence_sha256).lower(),
    }
    return result


__all__ = [
    "CHECKPOINT_FORMAT_VERSION",
    "DEEP_PLANNER_CONSTANTS",
    "DEEP_PLANNER_ID",
    "DEEP_PLANNER_SCHEMA_VERSION",
    "EVIDENCE_FORMAT_VERSION",
    "MODEL_VARIANT",
    "RELEASE_DECKS",
    "RUN_FORMAT_VERSION",
    "TRAINER_ID",
    "TRAINING_EVENT_SCHEMA",
    "contract_dict",
    "deep_planner_manifest",
    "derive_deep_decision_seed",
    "derive_training_decision_seed",
]
