"""Injectable randomness for live games, deterministic tests, and search."""
from __future__ import annotations

import random
from contextlib import contextmanager
from typing import Iterable, MutableSequence, TypeVar

T = TypeVar("T")


class RandomSource:
    def __init__(self, seed: int | None = None):
        self._random = random.Random(seed)

    def random(self) -> float:
        return self._random.random()

    def choice(self, values: Iterable[T]) -> T:
        sequence = tuple(values)
        if not sequence:
            raise IndexError("cannot choose from an empty sequence")
        return self._random.choice(sequence)

    def shuffle(self, values: MutableSequence[T]) -> None:
        self._random.shuffle(values)

    def coin(self) -> bool:
        return self.random() < 0.5

    def getstate(self):
        return self._random.getstate()

    def setstate(self, state) -> None:
        self._random.setstate(state)

    @contextmanager
    def bind_global(self):
        """Temporarily route legacy ``random`` module calls through this source."""
        global_state = random.getstate()
        random.setstate(self.getstate())
        try:
            yield self
        finally:
            self.setstate(random.getstate())
            random.setstate(global_state)

    @contextmanager
    def bind_state(self, state):
        """Bind this source to one state without touching process-global RNG."""
        previous_state_source = getattr(state, "random_source", None)
        players = [state.get_player(0), state.get_player(1)]
        previous_player_sources = [
            getattr(player, "random_source", None)
            for player in players
        ]
        state.random_source = self
        for player in players:
            player.random_source = self
        try:
            yield self
        finally:
            state.random_source = previous_state_source
            for player, previous in zip(players, previous_player_sources):
                player.random_source = previous


class ScriptedRandomSource(RandomSource):
    def __init__(self, coin_results: Iterable[bool] = (), seed: int = 0):
        super().__init__(seed)
        self._coin_results = list(coin_results)

    def coin(self) -> bool:
        if self._coin_results:
            return bool(self._coin_results.pop(0))
        return super().coin()


class SamplingRandomSource(RandomSource):
    """Named search-time source; behavior is deterministic for a given seed."""
