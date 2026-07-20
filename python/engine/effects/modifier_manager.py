"""Modifier Based Framework facade over the existing EventBus."""
from __future__ import annotations

from collections.abc import Callable
from copy import deepcopy
from dataclasses import dataclass
from types import MappingProxyType

from engine.enums import EventType


MODIFY_DAMAGE = "MODIFY_DAMAGE"
AFTER_DAMAGE = "AFTER_DAMAGE"
CAN_RETREAT = "CAN_RETREAT"
MAX_HP = "MAX_HP"
POKEMON_KO = "POKEMON_KO"
ON_ATTACH = "ON_ATTACH"

MODIFIER_DESCRIPTOR_FIELDS = frozenset({
    "hook", "layer", "priority", "controller", "source_ref", "scope",
    "duration", "stacking", "conflict_policy", "condition", "operation",
})
MODIFIER_OPERATION_DEFINITIONS = MappingProxyType({
    "damage_delta": (MODIFY_DAMAGE, frozenset({"attacker_adjust", "defender_adjust"}), frozenset({"kind", "amount"})),
    "prevent_damage": (MODIFY_DAMAGE, frozenset({"prevent"}), frozenset({"kind"})),
    "hp_delta": (MAX_HP, frozenset({"add"}), frozenset({"kind", "amount"})),
    "retreat_delta": (CAN_RETREAT, frozenset({"add"}), frozenset({"kind", "amount"})),
    "retreat_set": (CAN_RETREAT, frozenset({"set"}), frozenset({"kind", "value"})),
    "attack_lock": ("CAN_ATTACK", frozenset({"permission"}), frozenset({"kind", "attack_name"})),
    "attack_gate_coin": ("CAN_ATTACK", frozenset({"gate"}), frozenset({"kind", "reason"})),
    "prevent_effects": ("PREVENT_EFFECTS", frozenset({"prevent"}), frozenset({"kind"})),
})


class ModifierDescriptorRegistry:
    """Frozen cross-runtime contract for serializable continuous modifiers."""

    definitions = MODIFIER_OPERATION_DEFINITIONS

    @classmethod
    def validate(cls, descriptor: dict) -> str:
        if not isinstance(descriptor, dict) or set(descriptor) != MODIFIER_DESCRIPTOR_FIELDS:
            return "modifier descriptor has missing or extra fields"
        operation = descriptor.get("operation")
        if not isinstance(operation, dict):
            return "modifier operation must be a dictionary"
        definition = cls.definitions.get(str(operation.get("kind", "")))
        if definition is None:
            return "unknown modifier operation"
        hook, layers, operation_fields = definition
        if descriptor.get("hook") != hook or descriptor.get("layer") not in layers:
            return "modifier operation does not match hook/layer"
        if set(operation) != operation_fields:
            return "modifier operation has missing or extra fields"
        if type(descriptor.get("priority")) is not int:
            return "modifier priority must be an integer"
        if descriptor.get("controller") not in (0, 1):
            return "modifier controller is invalid"
        source_ref = descriptor.get("source_ref")
        if not isinstance(source_ref, dict) or source_ref.get("kind") not in {"pokemon", "attachment"}:
            return "modifier source reference is invalid"
        if not isinstance(descriptor.get("condition"), dict):
            return "modifier condition must be a dictionary"
        return ""


def build_modifier_descriptor(
    *, hook: str, layer: str, controller: int, source_ref: dict,
    scope: str, duration: str, condition: dict, operation: dict,
    priority: int = 0, stacking: str = "replace_same_source",
    conflict_policy: str = "commutative",
) -> dict:
    descriptor = {
        "hook": hook,
        "layer": layer,
        "priority": int(priority),
        "controller": int(controller),
        "source_ref": deepcopy(source_ref),
        "scope": str(scope),
        "duration": str(duration),
        "stacking": str(stacking),
        "conflict_policy": str(conflict_policy),
        "condition": deepcopy(condition),
        "operation": deepcopy(operation),
    }
    error = ModifierDescriptorRegistry.validate(descriptor)
    if error:
        raise ValueError(error)
    return descriptor


def register_serialized_modifier(pokemon, descriptor: dict) -> None:
    error = ModifierDescriptorRegistry.validate(descriptor)
    if error:
        raise ValueError(error)
    rows = list(getattr(pokemon, "modifiers", ()) or ())
    operation = descriptor["operation"]
    operation_kind = operation["kind"]
    source_ref = descriptor["source_ref"]
    stacking = descriptor["stacking"]
    if stacking in {"replace_same_source", "unique"}:
        rows = [
            row for row in rows
            if not (
                row.get("operation", {}).get("kind") == operation_kind
                and (stacking == "unique" or row.get("source_ref") == source_ref)
            )
        ]
    elif stacking == "maximum":
        matching = [
            row for row in rows
            if row.get("operation", {}).get("kind") == operation_kind
        ]
        candidate = abs(int(operation.get("amount", 0)))
        if matching and max(abs(int(row["operation"].get("amount", 0))) for row in matching) >= candidate:
            return
        rows = [row for row in rows if row not in matching]
    rows.append(deepcopy(descriptor))
    pokemon.modifiers = rows

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
