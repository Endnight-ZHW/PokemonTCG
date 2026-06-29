"""Runtime effect payload selection.

Compiled VM payloads are authoritative when present. Raw effect metadata stays
available for display, audits, and migration fallback.
"""
from __future__ import annotations

from typing import Any


MISSING_COMPILED_OP = "__missing_compiled_effect__"


def runtime_effects(owner: Any, legacy_attr: str, compiled_attr: str) -> list:
    compiled = getattr(owner, compiled_attr, None)
    if compiled:
        return list(compiled)
    return list(getattr(owner, legacy_attr, []) or [])


def strict_runtime_effects(
    owner: Any,
    legacy_attr: str,
    compiled_attr: str,
    source: str,
) -> list:
    compiled = getattr(owner, compiled_attr, None)
    if compiled:
        return list(compiled)
    raw = getattr(owner, legacy_attr, None)
    if raw:
        return [missing_compiled_effect(source)]
    return []


def missing_compiled_effect(source: str) -> dict[str, Any]:
    return {
        "op": MISSING_COMPILED_OP,
        "args": {"source": source},
        "branches": {},
    }


def _owner_source(owner: Any, prefix: str) -> str:
    identifier = (
        getattr(owner, "api_id", "")
        or getattr(owner, "name", "")
        or getattr(owner, "trainer_type", "")
        or "unknown"
    )
    return f"{prefix}:{identifier}"


def ability_runtime_effects(ability: Any) -> list:
    return runtime_effects(ability, "effects", "compiled_effects")


def attack_runtime_effects(attack: Any) -> list:
    return runtime_effects(attack, "effects", "compiled_effects")


def trainer_runtime_effects(card: Any) -> list:
    return runtime_effects(card, "trainer_effects", "compiled_trainer_effects")


def strict_ability_runtime_effects(ability: Any) -> list:
    return strict_runtime_effects(
        ability,
        "effects",
        "compiled_effects",
        _owner_source(ability, "ability"),
    )


def strict_attack_runtime_effects(attack: Any) -> list:
    return strict_runtime_effects(
        attack,
        "effects",
        "compiled_effects",
        _owner_source(attack, "attack"),
    )


def strict_trainer_runtime_effects(card: Any) -> list:
    return strict_runtime_effects(
        card,
        "trainer_effects",
        "compiled_trainer_effects",
        _owner_source(card, "trainer"),
    )
