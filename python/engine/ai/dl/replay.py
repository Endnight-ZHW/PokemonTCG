"""Per-deck replay buffer for deep-learning AI training."""
from __future__ import annotations

import random
from collections import deque
from typing import TYPE_CHECKING, Iterator

if TYPE_CHECKING:
    from engine.ai.dl.training import TrainingExample


class ReplayBuffer:
    """Fixed-capacity replay buffer that stores TrainingExample instances.

    Each deck maintains its own buffer so that examples from different
    strategies are not mixed.
    """

    def __init__(self, capacity: int = 50000, seed: int = 17):
        self._buffer: deque = deque(maxlen=max(1, int(capacity)))
        self._rng = random.Random(seed)

    @property
    def size(self) -> int:
        return len(self._buffer)

    @property
    def capacity(self) -> int:
        return self._buffer.maxlen or 0

    def add(self, example) -> None:
        self._buffer.append(example)

    def extend(self, examples) -> None:
        for ex in examples:
            self._buffer.append(ex)

    def sample(self, batch_size: int):
        if len(self._buffer) <= batch_size:
            return list(self._buffer)
        return self._rng.sample(list(self._buffer), batch_size)

    def clear(self) -> None:
        self._buffer.clear()

    def __len__(self) -> int:
        return len(self._buffer)

    def __iter__(self) -> Iterator:
        return iter(self._buffer)
