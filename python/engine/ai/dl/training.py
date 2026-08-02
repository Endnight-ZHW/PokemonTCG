"""Public training API for the sole supported Deep AI pipeline."""
from __future__ import annotations

from .alphazero_v2 import (
    AlphaZeroV2Config,
    AlphaZeroV2Trainer,
    evaluate_model,
    generate_bootstrap_cache,
    load_bootstrap_cache,
    load_bootstrap_splits,
    train_model,
)
from .replay_v2 import AlphaZeroSample, ReplayStoreV2


def run_deep_training(config: AlphaZeroV2Config):
    if not isinstance(config, AlphaZeroV2Config):
        raise TypeError(
            "Deep AI only supports AlphaZeroV2Config; "
            "legacy trainer configurations were removed"
        )
    return AlphaZeroV2Trainer(config).run()


__all__ = [
    "AlphaZeroSample",
    "AlphaZeroV2Config",
    "AlphaZeroV2Trainer",
    "ReplayStoreV2",
    "evaluate_model",
    "generate_bootstrap_cache",
    "load_bootstrap_cache",
    "load_bootstrap_splits",
    "run_deep_training",
    "train_model",
]
