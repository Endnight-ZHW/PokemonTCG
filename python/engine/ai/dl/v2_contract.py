"""Frozen public contract for the information-set AlphaZero v2 stack.

The v2 stack deliberately lives beside the read-only v6/v11 implementation
until a universal model is promoted.  Training, ONNX export, the native
simulation bridge, and the Godot runtime all consume the constants in this
module (or the generated JSON representation of them).
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any


ENCODER_SCHEMA_VERSION = 7
CHECKPOINT_VERSION = 12
DEEP_PLANNER_VERSION = 2
RUNTIME_MANIFEST_FORMAT_VERSION = 3
MODEL_VARIANT = "universal_infoset_transformer_v2"
TRAINER_ID = "infoset_alphazero_v2"
NATIVE_ABI_VERSION = 1

STATE_GLOBAL_SIZE = 128
ENTITY_SLOTS = 128
ENTITY_NUMERIC_SIZE = 16
ENTITY_TYPE_FIELDS = 4
CANDIDATE_NUMERIC_SIZE = 32
CANDIDATE_REF_FIELDS = 4
WDL_SIZE = 3

MODEL_DIM = 128
MODEL_LAYERS = 4
MODEL_HEADS = 8
MODEL_FFN_DIM = 512

DEFAULT_C_PUCT = 1.4
DEFAULT_TRAINING_SIMULATIONS = 128
DEFAULT_DIRICHLET_EPSILON = 0.25
DEFAULT_REPLAY_CAPACITY = 1_000_000

RELEASE_DECKS = (
    "fire",
    "water",
    "psychic",
    "lightning",
    "fighting",
    "colorless",
    "dragon",
    "grass",
    "steel",
    "darkness",
)

ONNX_INPUT_NAMES = (
    "state_global",
    "entity_numeric",
    "entity_card_ids",
    "entity_type_ids",
    "candidate_numeric",
    "candidate_card_ids",
    "candidate_type_ids",
    "candidate_refs",
    "candidate_mask",
    "actor_deck_id",
    "opponent_deck_id",
)
ONNX_OUTPUT_NAMES = ("policy_logits", "wdl_logits")


@dataclass(frozen=True)
class RuntimeSearchBudget:
    min_simulations: int
    target_simulations: int
    max_simulations: int
    leaf_batch_size: int
    watchdog_seconds: float = 2.0
    stop_margin_seconds: float = 0.05

    def validate(self) -> None:
        if not (
            0 < self.min_simulations
            <= self.target_simulations
            <= self.max_simulations
        ):
            raise ValueError("invalid_runtime_simulation_budget")
        if self.leaf_batch_size <= 0:
            raise ValueError("invalid_runtime_leaf_batch_size")
        if not 0.0 < self.stop_margin_seconds < self.watchdog_seconds:
            raise ValueError("invalid_runtime_watchdog_margin")


WINDOWS_SEARCH_BUDGET = RuntimeSearchBudget(32, 128, 256, 8)
ANDROID_SEARCH_BUDGET = RuntimeSearchBudget(16, 64, 128, 4)


def visit_temperature(turn_number: int) -> float:
    """Return the frozen self-play visit temperature schedule."""
    turn = int(turn_number)
    if turn <= 6:
        return 1.0
    if turn <= 12:
        return 0.5
    return 0.1


def dirichlet_alpha(legal_count: int) -> float:
    """Scale root noise to branching factor while keeping stable bounds."""
    return max(0.03, min(0.30, 10.0 / max(1, int(legal_count))))


def deck_index(deck_key: str | None) -> int:
    try:
        return RELEASE_DECKS.index(str(deck_key))
    except ValueError:
        return 0


def contract_dict() -> dict[str, Any]:
    """Return the canonical JSON-serializable v2 contract."""
    return {
        "encoder_version": ENCODER_SCHEMA_VERSION,
        "checkpoint_version": CHECKPOINT_VERSION,
        "deep_planner_version": DEEP_PLANNER_VERSION,
        "runtime_manifest_format": RUNTIME_MANIFEST_FORMAT_VERSION,
        "model_variant": MODEL_VARIANT,
        "trainer": TRAINER_ID,
        "native_abi_version": NATIVE_ABI_VERSION,
        "inputs": {
            "state_global": ["float32", STATE_GLOBAL_SIZE],
            "entity_numeric": ["float32", ENTITY_SLOTS, ENTITY_NUMERIC_SIZE],
            "entity_card_ids": ["int64", ENTITY_SLOTS],
            "entity_type_ids": [
                "int64",
                ENTITY_SLOTS,
                ENTITY_TYPE_FIELDS,
            ],
            "candidate_numeric": ["float32", "A", CANDIDATE_NUMERIC_SIZE],
            "candidate_card_ids": ["int64", "A"],
            "candidate_type_ids": ["int64", "A"],
            "candidate_refs": ["int64", "A", CANDIDATE_REF_FIELDS],
            "candidate_mask": ["bool", "A"],
            "actor_deck_id": ["int64"],
            "opponent_deck_id": ["int64"],
        },
        "outputs": {
            "policy_logits": ["float32", "A"],
            "wdl_logits": ["float32", WDL_SIZE],
        },
        "model": {
            "dimension": MODEL_DIM,
            "layers": MODEL_LAYERS,
            "heads": MODEL_HEADS,
            "ffn_dimension": MODEL_FFN_DIM,
        },
        "training_search": {
            "simulations": DEFAULT_TRAINING_SIMULATIONS,
            "c_puct": DEFAULT_C_PUCT,
            "dirichlet_epsilon": DEFAULT_DIRICHLET_EPSILON,
        },
        "runtime_search": {
            "windows": asdict(WINDOWS_SEARCH_BUDGET),
            "android": asdict(ANDROID_SEARCH_BUDGET),
        },
        "release_decks": list(RELEASE_DECKS),
    }


for _budget in (WINDOWS_SEARCH_BUDGET, ANDROID_SEARCH_BUDGET):
    _budget.validate()
