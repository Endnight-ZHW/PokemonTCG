"""Injectable randomness for live games, deterministic tests, and search."""
from __future__ import annotations

import random
from contextlib import contextmanager
from typing import Iterable, MutableSequence, TypeVar

T = TypeVar("T")


# Version of the authoritative RNG consumption contract.  The xorshift32
# bitstream remains algorithm v1; v2 moves coin outcomes into rule execution
# before the display acknowledgement is published.
RNG_SCHEMA_VERSION = 2


class RandomSource:
    """Legacy MT19937 source used by existing Python training checkpoints."""

    algorithm = "python_mt19937"
    algorithm_version = 1

    def __init__(self, seed: int | None = None):
        self._random = random.Random(seed)
        # The authoritative core consumes xorshift32.  Retain a separate,
        # serializable native stream while Python-side policy sampling keeps
        # its historical MT19937 behavior.
        native_seed = (
            int(seed)
            if seed is not None
            else self._random.getrandbits(32)
        ) & 0xFFFFFFFF
        self._ptcg_native_state = native_seed or 0x6D2B79F5

    def get_native_state(self) -> int:
        return int(self._ptcg_native_state) & 0xFFFFFFFF

    def set_native_state(self, state: int) -> None:
        value = int(state) & 0xFFFFFFFF
        self._ptcg_native_state = value or 0x6D2B79F5

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
    _STATE_TAG = "scripted_random_v1"

    def __init__(self, coin_results: Iterable[bool] = (), seed: int = 0):
        super().__init__(seed)
        self._coin_results = list(coin_results)

    def coin(self) -> bool:
        if self._coin_results:
            return bool(self._coin_results.pop(0))
        return super().coin()

    def getstate(self):
        """Include the scripted cursor in transaction snapshots.

        Older code only captured the backing MT state, which meant a failed
        action permanently consumed scripted coin results even after rollback.
        """
        return (
            self._STATE_TAG,
            super().getstate(),
            tuple(self._coin_results),
        )

    def setstate(self, state) -> None:
        if (
            isinstance(state, (tuple, list))
            and len(state) == 3
            and state[0] == self._STATE_TAG
        ):
            super().setstate(state[1])
            self._coin_results = [bool(value) for value in state[2]]
            return
        # Backward compatibility with checkpoints created before the scripted
        # queue became part of the RNG state.
        super().setstate(state)

    @contextmanager
    def bind_global(self):
        """Bind only the backing MT state while retaining scripted coins."""
        global_state = random.getstate()
        random.setstate(super().getstate())
        try:
            yield self
        finally:
            super().setstate(random.getstate())
            random.setstate(global_state)


class PortableRandomSourceV1(RandomSource):
    """Godot-compatible xorshift32 source for cross-runtime rule fixtures."""

    algorithm = "xorshift32"
    algorithm_version = 1
    _MASK = 0xFFFFFFFF
    _UINT32_RANGE = 4294967296.0
    _FALLBACK_SEED = 0x6D2B79F5

    def __init__(self, seed: int = 0):
        # Do not initialize ``random.Random``: portable state is exactly one
        # uint32 and must match godot/core/random_source.gd bit-for-bit.
        self._state = int(seed) & self._MASK
        if self._state == 0:
            self._state = self._FALLBACK_SEED

    def next_u32(self) -> int:
        state = self._state
        state ^= (state << 13) & self._MASK
        state ^= state >> 17
        state ^= (state << 5) & self._MASK
        self._state = state & self._MASK
        return self._state

    def random(self) -> float:
        return self.next_u32() / self._UINT32_RANGE

    def coin(self) -> bool:
        return (self.next_u32() & 1) == 0

    def choice(self, values: Iterable[T]) -> T:
        sequence = tuple(values)
        if not sequence:
            raise IndexError("cannot choose from an empty sequence")
        return sequence[self.next_u32() % len(sequence)]

    def shuffle(self, values: MutableSequence[T]) -> None:
        for index in range(len(values) - 1, 0, -1):
            selected = self.next_u32() % (index + 1)
            values[index], values[selected] = values[selected], values[index]

    def getstate(self) -> int:
        return self._state

    def setstate(self, state) -> None:
        self._state = int(state) & self._MASK
        if self._state == 0:
            self._state = self._FALLBACK_SEED

    # Godot naming aliases make fixture generators easier to share.
    def get_state(self) -> int:
        return self.getstate()

    def set_state(self, state) -> None:
        self.setstate(state)

    def get_native_state(self) -> int:
        return self.get_state()

    def set_native_state(self, state: int) -> None:
        self.set_state(state)

    @contextmanager
    def bind_global(self):
        raise RuntimeError(
            "PortableRandomSourceV1 cannot be bound to Python's global MT19937 RNG"
        )
        yield self


class SamplingRandomSource(RandomSource):
    """Named search-time source; behavior is deterministic for a given seed."""
