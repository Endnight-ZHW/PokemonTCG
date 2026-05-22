"""Structured game events for UI observation and modifier hooks."""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any


@dataclass
class GameEvent:
    """A single game event emitted during resolution.

    event_type examples:
        'damage_dealt', 'pokemon_ko', 'card_drawn', 'card_discarded',
        'pokemon_placed', 'pokemon_evolved', 'energy_attached',
        'status_applied', 'healed', 'retreated', 'attack_declared'
    """
    event_type: str
    data: dict[str, Any] = field(default_factory=dict)


class GameEventStream:
    """Ring buffer of game events consumed by the UI each frame.

    The resolution engine pushes events as commands execute. The UI
    drains events each tick and schedules corresponding animations.
    """
    def __init__(self, capacity: int = 256):
        self._events: list[GameEvent] = []
        self._capacity = capacity

    def push(self, event: GameEvent):
        if len(self._events) >= self._capacity:
            self._events.pop(0)
        self._events.append(event)

    def drain(self) -> list[GameEvent]:
        events = self._events[:]
        self._events.clear()
        return events

    def __len__(self) -> int:
        return len(self._events)
