"""Historical opponent pool for true self-play in RL training.

Keeps a small number of previous model snapshots so the current model can
play against its own past versions, breaking the ceiling effect of always
facing a fixed-strength ChallengeAI opponent.
"""
from __future__ import annotations

import os
from typing import Any


class OpponentPool:
    """Lightweight registry of historical model snapshots for self-play."""

    def __init__(self, max_snapshots: int = 3):
        self._snapshots: list[dict[str, Any]] = []
        self._max = max(1, int(max_snapshots))

    def add(self, model_state: dict[str, Any], model_config: dict[str, Any]) -> None:
        """Add a snapshot.  Oldest is evicted when the pool is full."""
        entry = {
            "model_state": {k: v.detach().cpu().clone() for k, v in model_state.items()},
            "model_config": dict(model_config),
        }
        self._snapshots.append(entry)
        if len(self._snapshots) > self._max:
            self._snapshots = self._snapshots[-self._max:]

    def sample(self) -> tuple[dict[str, Any], dict[str, Any]] | None:
        """Return a random historical snapshot, or None if the pool is empty."""
        import random

        if not self._snapshots:
            return None
        entry = random.choice(self._snapshots)
        return entry["model_state"], entry["model_config"]

    def __len__(self) -> int:
        return len(self._snapshots)

    def clear(self) -> None:
        self._snapshots.clear()


def _opponent_pool_path(deck_key: str) -> str:
    return os.path.join("data", "ai_models", f"pool_{deck_key}.pt")


def save_opponent_pool(pool: OpponentPool, deck_key: str) -> None:
    """Persist opponent pool snapshots to disk."""
    import torch

    path = _opponent_pool_path(deck_key)
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    snapshots = [
        {"model_state": s["model_state"], "model_config": s["model_config"]}
        for s in pool._snapshots
    ]
    torch.save({"snapshots": snapshots}, path)


def load_opponent_pool(deck_key: str, max_snapshots: int = 3) -> OpponentPool:
    """Load opponent pool from disk, or return an empty pool."""
    from engine.ai.dl.model import safe_torch_load

    pool = OpponentPool(max_snapshots=max_snapshots)
    path = _opponent_pool_path(deck_key)
    if not os.path.exists(path):
        return pool
    try:
        data = safe_torch_load(path, map_location="cpu")
        for entry in data.get("snapshots", []):
            pool.add(entry["model_state"], entry["model_config"])
    except Exception:
        pass
    return pool
