"""Read compiled VM payloads for AI feature extraction."""
from __future__ import annotations

from typing import Any


def runtime_effects(owner: Any, compiled_attr: str) -> list:
    return list(getattr(owner, compiled_attr, None) or [])


def ability_runtime_effects(ability: Any) -> list:
    return runtime_effects(ability, "compiled_effects")


def attack_runtime_effects(attack: Any) -> list:
    return runtime_effects(attack, "compiled_effects")


def trainer_runtime_effects(card: Any) -> list:
    return runtime_effects(card, "compiled_trainer_effects")
