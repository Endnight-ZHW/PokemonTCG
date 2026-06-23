"""Event bus for abilities, tools, and stadiums."""
from dataclasses import dataclass, field
from typing import Callable, Optional
from utils.logger import get_logger

logger = get_logger(__name__)
from engine.enums import EventType


@dataclass
class EventListener:
    """A registered listener for game events."""
    callback: Callable  # fn(state, event, event_data) -> list
    source: str         # "ability:Infernal Reign", "tool:Rocky Helmet"
    owner_player: int   # Which player owns this
    priority: int = 0
    active: bool = True


class EventBus:
    """Central event dispatcher for ability/tool/stadium triggers."""

    def __init__(self):
        self._listeners: dict[EventType, list[EventListener]] = {
            e: [] for e in EventType
        }

    def register(self, event: EventType, callback: Callable,
                 source: str, owner_player: int, priority: int = 0):
        """Register an event listener."""
        listener = EventListener(
            callback=callback,
            source=source,
            owner_player=owner_player,
            priority=priority,
        )
        self._listeners[event].append(listener)
        # Sort by priority (higher priority = runs first)
        self._listeners[event].sort(key=lambda l: -l.priority)

    def unregister(self, event: EventType, source: str):
        """Remove all listeners from a given source for a given event."""
        self._listeners[event] = [
            l for l in self._listeners[event]
            if l.source != source
        ]

    def unregister_all_for_source(self, source: str):
        """Remove all listeners with the given source from all events."""
        for event in self._listeners:
            self._listeners[event] = [
                l for l in self._listeners[event]
                if l.source != source
            ]

    def unregister_all_for_player(self, player_idx: int):
        """Remove all listeners owned by a specific player."""
        for event in self._listeners:
            self._listeners[event] = [
                l for l in self._listeners[event]
                if l.owner_player != player_idx
            ]

    def emit(self, event: EventType, **event_data) -> list:
        """Fire an event to all registered listeners.
        Active player's listeners fire first."""
        results = []
        for listener in self._listeners.get(event, []):
            if listener.active:
                try:
                    result = listener.callback(event_data)
                    if result:
                        results.append(result)
                except Exception as e:
                    logger.error("EventBus error [%s]: %s", listener.source, e)
        return results

    def clear(self):
        """Remove all listeners."""
        for event in self._listeners:
            self._listeners[event].clear()
