"""Modifier Based Framework facade over the existing EventBus."""
from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from engine.enums import EventType


MODIFY_DAMAGE = "MODIFY_DAMAGE"
AFTER_DAMAGE = "AFTER_DAMAGE"
CAN_RETREAT = "CAN_RETREAT"
MAX_HP = "MAX_HP"
POKEMON_KO = "POKEMON_KO"
ON_ATTACH = "ON_ATTACH"

HOOK_TO_EVENT = {
    MODIFY_DAMAGE: EventType.DAMAGE_ABOUT_TO_BE_DEALT,
    AFTER_DAMAGE: EventType.DAMAGE_DEALT,
    CAN_RETREAT: EventType.CAN_RETREAT,
    POKEMON_KO: EventType.POKEMON_KO,
}


@dataclass(frozen=True)
class ModifierHook:
    hook: str
    source: str
    owner_player: int
    priority: int = 0


class ModifierManager:
    """Stable MBF entrypoint while existing listeners migrate incrementally."""

    def __init__(self, event_bus) -> None:
        self.event_bus = event_bus
        self._local_hooks: dict[str, list[tuple[int, int, ModifierHook, Callable]]] = {
            MAX_HP: [],
            ON_ATTACH: [],
        }
        self._sequence = 0

    def register(
        self,
        hook: str,
        callback: Callable,
        *,
        source: str,
        owner_player: int,
        priority: int = 0,
    ) -> None:
        event = HOOK_TO_EVENT.get(hook)
        if event is not None:
            self.event_bus.register(
                event,
                callback,
                source=source,
                owner_player=owner_player,
                priority=priority,
            )
            return
        if hook not in self._local_hooks:
            raise ValueError(f"Unknown modifier hook: {hook}")
        self._sequence += 1
        self._local_hooks[hook].append((
            -int(priority),
            self._sequence,
            ModifierHook(hook, source, owner_player, priority),
            callback,
        ))
        self._local_hooks[hook].sort(key=lambda row: (row[0], row[1]))

    def emit(self, hook: str, **data) -> list:
        event = HOOK_TO_EVENT.get(hook)
        if event is not None:
            return self.event_bus.emit(event, **data)
        if hook not in self._local_hooks:
            raise ValueError(f"Unknown modifier hook: {hook}")
        results = []
        for _priority, _sequence, _meta, callback in self._local_hooks[hook]:
            result = callback(data)
            if result:
                results.append(result)
        return results

    def clear(self) -> None:
        self.event_bus.clear()
        for hooks in self._local_hooks.values():
            hooks.clear()
