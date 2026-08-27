from __future__ import annotations

import dataclasses
import json
from pathlib import Path
from typing import Any

from engine.actions import ACTION_SCHEMA_VERSION, RULES_SCHEMA_VERSION
from engine.commands.ir import compile_effect_to_spec
from engine.commands.vm_contract import VM_IR_VERSION
from engine.random_source import RNG_SCHEMA_VERSION

from .card_data import json_value


def load_release_manifest(path: Path, deck_keys: set[str]) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    release_decks = payload.get("release_decks")
    if not isinstance(release_decks, list) or not all(
        isinstance(key, str) and key for key in release_decks
    ):
        raise RuntimeError("release_manifest.json has an invalid release_decks list")
    if len(release_decks) != len(set(release_decks)):
        raise RuntimeError("release_manifest.json contains duplicate release deck keys")
    if set(release_decks) != deck_keys:
        raise RuntimeError("release_manifest.json release_decks do not match deck data")
    return payload


def effect_types(value: Any) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        effect_type = value.get("effect_type")
        if isinstance(effect_type, str) and effect_type:
            found.add(effect_type)
        for item in value.values():
            found.update(effect_types(item))
    elif isinstance(value, (list, tuple)):
        for item in value:
            found.update(effect_types(item))
    elif dataclasses.is_dataclass(value):
        found.update(effect_types(json_value(value)))
    return found


def effect_examples(
    value: Any,
    found: dict[str, dict[str, Any]] | None = None,
) -> dict[str, dict[str, Any]]:
    if found is None:
        found = {}
    if isinstance(value, dict):
        effect_type = value.get("effect_type")
        if isinstance(effect_type, str) and effect_type and effect_type not in found:
            found[effect_type] = json_value(value)
        for item in value.values():
            effect_examples(item, found)
    elif isinstance(value, (list, tuple)):
        for item in value:
            effect_examples(item, found)
    elif dataclasses.is_dataclass(value):
        effect_examples(json_value(value), found)
    return found


def _portable_rng_sequence(seed: int, count: int) -> list[int]:
    state = seed & 0xFFFFFFFF or 0x6D2B79F5
    values: list[int] = []
    for _ in range(count):
        state ^= (state << 13) & 0xFFFFFFFF
        state ^= state >> 17
        state ^= (state << 5) & 0xFFFFFFFF
        state &= 0xFFFFFFFF
        values.append(state)
    return values


def build_data_contract(
    cards: dict[str, Any],
    decks: dict[str, Any],
    effect_definitions: dict[str, Any],
    release_manifest: dict[str, Any],
) -> dict[str, Any]:
    release_schemas = release_manifest["schemas"]
    effect_type_names = sorted(effect_types(effect_definitions))
    examples = dict(sorted(effect_examples(effect_definitions).items()))
    return {
        "fixture_version": 2,
        "vm_version": VM_IR_VERSION,
        "vm": {
            "ir_version": VM_IR_VERSION,
            "command_shape": ["op", "args", "branches"],
            "runtime_effect_source": "compiled_effects",
            "legacy_effect_type_args_allowed": False,
        },
        "schema": {
            "python_rules_version": RULES_SCHEMA_VERSION,
            "python_action_version": ACTION_SCHEMA_VERSION,
            "godot_rules_version": int(release_schemas["godot_rules"]),
            "godot_action_version": int(release_schemas["godot_actions"]),
            "protocol_version": int(release_schemas["protocol"]),
            "rng_version": RNG_SCHEMA_VERSION,
        },
        "counts": {
            "cards": len(cards),
            "decks": len(decks),
            "effects": len(effect_type_names),
        },
        "effect_types": effect_type_names,
        "effect_examples": examples,
        "compiled_effect_examples": {
            key: compile_effect_to_spec(value).to_dict()
            for key, value in examples.items()
        },
        "deck_sizes": {key: deck["card_count"] for key, deck in decks.items()},
        "portable_rng": {
            "schema_version": RNG_SCHEMA_VERSION,
            "algorithm": "xorshift32",
            "seed": 20260620,
            "uint32": _portable_rng_sequence(20260620, 8),
        },
    }


def load_frozen_fixture(repo_root: Path, name: str) -> dict[str, Any]:
    path = repo_root / "godot" / "tests" / "fixtures" / name
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError(f"Frozen rules fixture is invalid: {path}")
    return payload
