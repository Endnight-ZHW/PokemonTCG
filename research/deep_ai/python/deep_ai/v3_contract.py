"""Frozen public contract for the Deep AI v3 training/runtime stack."""
from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any


ENCODER_SCHEMA_VERSION = 8
CHECKPOINT_VERSION = 13
DEEP_PLANNER_VERSION = 3
RUNTIME_MANIFEST_FORMAT_VERSION = 4
RUN_FORMAT_VERSION = 3
REPLAY_FORMAT_VERSION = 3
MODEL_VARIANT = "universal_infoset_transformer_v3"
TRAINER_ID = "infoset_alphazero_v3"
PLANNER_ID = "infoset_puct_v3"
NATIVE_RULES_ABI_VERSION = 2

STATE_GLOBAL_SIZE = 192
ENTITY_SLOTS = 160
ENTITY_NUMERIC_SIZE = 24
ENTITY_TYPE_FIELDS = 4
CANDIDATE_NUMERIC_SIZE = 48
CANDIDATE_REF_FIELDS = 8
CARD_SEMANTIC_SIZE = 53
WDL_SIZE = 3

MODEL_DIM = 128
MODEL_LAYERS = 4
MODEL_HEADS = 8
MODEL_FFN_DIM = 512

DEFAULT_C_PUCT = 1.4
DEFAULT_TRAINING_SIMULATIONS = 128
DEFAULT_DIRICHLET_EPSILON = 0.25
DEFAULT_REPLAY_CAPACITY = 500_000
DEFAULT_REPLAY_BYTES = 8 * 1024**3
DEFAULT_REPLAY_SHARD_SAMPLES = 4_096
DEFAULT_TEACHER_FRACTION = 0.20
DEFAULT_CYCLE_SAMPLES = 25_000
DEFAULT_REPLAY_PASSES = 2

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
    "entity_mask",
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


def deck_index(deck_key: str | None) -> int:
    try:
        return RELEASE_DECKS.index(str(deck_key))
    except ValueError:
        return 0


def visit_temperature(turn_number: int) -> float:
    turn = int(turn_number)
    if turn <= 6:
        return 1.0
    if turn <= 12:
        return 0.5
    return 0.1


def dirichlet_alpha(legal_count: int) -> float:
    return max(0.03, min(0.30, 10.0 / max(1, int(legal_count))))


def contract_dict() -> dict[str, Any]:
    return {
        "encoder_version": ENCODER_SCHEMA_VERSION,
        "checkpoint_version": CHECKPOINT_VERSION,
        "deep_planner_version": DEEP_PLANNER_VERSION,
        "runtime_manifest_format": RUNTIME_MANIFEST_FORMAT_VERSION,
        "run_format": RUN_FORMAT_VERSION,
        "replay_format": REPLAY_FORMAT_VERSION,
        "model_variant": MODEL_VARIANT,
        "trainer": TRAINER_ID,
        "planner_id": PLANNER_ID,
        "native_rules_abi_version": NATIVE_RULES_ABI_VERSION,
        "inputs": {
            "state_global": ["float32", STATE_GLOBAL_SIZE],
            "entity_numeric": [
                "float32",
                ENTITY_SLOTS,
                ENTITY_NUMERIC_SIZE,
            ],
            "entity_card_ids": ["int64", ENTITY_SLOTS],
            "entity_type_ids": [
                "int64",
                ENTITY_SLOTS,
                ENTITY_TYPE_FIELDS,
            ],
            "entity_mask": ["bool", ENTITY_SLOTS],
            "candidate_numeric": [
                "float32",
                "A",
                CANDIDATE_NUMERIC_SIZE,
            ],
            "candidate_card_ids": ["int64", "A"],
            "candidate_type_ids": ["int64", "A"],
            "candidate_refs": [
                "int64",
                "A",
                CANDIDATE_REF_FIELDS,
            ],
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
            "card_semantic_size": CARD_SEMANTIC_SIZE,
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
