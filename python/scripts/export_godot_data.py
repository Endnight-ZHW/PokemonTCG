"""Export the Python-authoritative card data into deterministic Godot assets."""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

PYTHON_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = PYTHON_ROOT.parent
if str(PYTHON_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ROOT))

from card_data.effects import CARD_EFFECT_DEFINITIONS
from card_data.authoring_dsl import (
    card_specs_from_mappings,
    compile_card_ir_v3,
    discover_effect_sources,
)
from card_data.consistency import (
    assert_card_rules_consistent,
)
from data.card_models import Card
from data.card_registry import CardRegistry
from data.ai_card_vocab import (
    CARD_VOCAB_VERSION,
    card_vocab_index,
    card_vocab_sha256,
    card_vocab_size,
    load_card_vocab,
    validate_release_card_vocab,
)
from data.ai_strategy_definitions import build_ai_strategy_catalog
from data.deck_definitions import (
    ALL_CARD_IDS,
    COLORLESS_DECK,
    DARKNESS_DECK,
    DRAGON_DECK,
    FIGHTING_DECK,
    FIRE_DECK,
    GRASS_DECK,
    LIGHTNING_DECK,
    PSYCHIC_DECK_NATU,
    STEEL_DECK,
    WATER_DECK,
)
from engine.action_codec import serialize_entity_ref, serialize_game_action
from engine.actions import (
    ACTION_SCHEMA_VERSION,
    RULES_SCHEMA_VERSION,
    CardRef,
    ChoiceOption,
    ChoiceView,
    GameAction,
    PokemonRef,
)
from engine.ai.observation import Observation
from engine.ai.dl.encoder import ENCODER_SCHEMA_VERSION, ActionStateEncoder
from engine.commands.ir import (
    compile_effect_to_spec,
    compile_effects_to_payload,
)
from engine.commands.ir import OP_BY_EFFECT_TYPE, SUPPORTED_EFFECT_TYPES
from engine.commands.descriptors import (
    VM_COMMAND_DESCRIPTORS,
    descriptor_export_payload,
)
from engine.commands.vm_contract import (
    VM_IR_VERSION,
    iter_command_specs,
    validate_command_spec,
)
from engine.enums import PlayerAction
from engine.random_source import RNG_SCHEMA_VERSION, PortableRandomSourceV1

DEFAULT_OUTPUT = REPO_ROOT / "godot"
RELEASE_MANIFEST_PATH = REPO_ROOT / "release_manifest.json"
CARD_ASSET_EXTS = {".webp", ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff"}

DECKS = {
    "fire": {
        "name": "烈焰猴",
        "energy_type": "Fire",
        "cards": FIRE_DECK,
    },
    "water": {
        "name": "甲贺忍蛙ex",
        "energy_type": "Water",
        "cards": WATER_DECK,
    },
    "psychic": {
        "name": "天然鸟",
        "energy_type": "Psychic",
        "cards": PSYCHIC_DECK_NATU,
    },
    "lightning": {
        "name": "皮卡丘ex",
        "energy_type": "Lightning",
        "cards": LIGHTNING_DECK,
    },
    "fighting": {
        "name": "路卡利欧",
        "energy_type": "Fighting",
        "cards": FIGHTING_DECK,
    },
    "colorless": {
        "name": "一家鼠ex",
        "energy_type": "Colorless",
        "cards": COLORLESS_DECK,
    },
    "dragon": {
        "name": "七夕青鸟ex",
        "energy_type": "Dragon",
        "cards": DRAGON_DECK,
    },
    "grass": {
        "name": "土台龟",
        "energy_type": "Grass",
        "cards": GRASS_DECK,
    },
    "steel": {
        "name": "苍响·藏玛然特",
        "energy_type": "Metal",
        "cards": STEEL_DECK,
    },
    "darkness": {
        "name": "獒教父ex",
        "energy_type": "Darkness",
        "cards": DARKNESS_DECK,
    },
}


def _release_manifest() -> dict[str, Any]:
    payload = json.loads(RELEASE_MANIFEST_PATH.read_text(encoding="utf-8"))
    release_decks = payload.get("release_decks")
    if not isinstance(release_decks, list) or not all(
        isinstance(key, str) and key for key in release_decks
    ):
        raise RuntimeError("release_manifest.json has an invalid release_decks list")
    if len(release_decks) != len(set(release_decks)):
        raise RuntimeError("release_manifest.json contains duplicate release deck keys")
    model_count = int(payload.get("model_count") or 0)
    if model_count not in {0, 1}:
        raise RuntimeError(
            "release_manifest.json model_count must be 0 or 1"
        )
    if set(release_decks) != set(DECKS):
        raise RuntimeError("release_manifest.json release_decks do not match Python deck data")
    return payload

def _json_value(value: Any) -> Any:
    if dataclasses.is_dataclass(value):
        return {
            field.name: _json_value(getattr(value, field.name))
            for field in dataclasses.fields(value)
        }
    if isinstance(value, dict):
        return {str(key): _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    if isinstance(value, set):
        return sorted(_json_value(item) for item in value)
    return value


def _write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _load_image_mapping() -> dict[str, str]:
    mapping_path = PYTHON_ROOT / "data" / "card_image_mapping.json"
    mapping = _parse_image_mapping(mapping_path.read_text(encoding="utf-8"))
    return _validate_image_mapping(mapping)


def _parse_image_mapping(text: str) -> dict[str, str]:
    shape = json.loads(text)
    if not isinstance(shape, dict):
        raise ValueError("Card image mapping must be a JSON object")
    pairs = json.loads(text, object_pairs_hook=lambda rows: rows)
    duplicate_ids: set[str] = set()
    mapping: dict[str, str] = {}
    for key, value in pairs:
        card_id = str(key)
        if card_id in mapping:
            duplicate_ids.add(card_id)
        mapping[card_id] = value
    if duplicate_ids:
        raise ValueError(
            "Duplicate card image mapping IDs: " + ", ".join(sorted(duplicate_ids))
        )
    return mapping


def _validate_image_mapping(
    mapping: dict[str, str],
    *,
    python_root: Path = PYTHON_ROOT,
    card_ids: list[str] | tuple[str, ...] = ALL_CARD_IDS,
) -> dict[str, str]:
    release_ids = list(card_ids)
    if len(release_ids) != len(set(release_ids)):
        raise ValueError("Release deck data contains duplicate card IDs")
    missing = sorted(set(release_ids) - set(mapping))
    if missing:
        raise ValueError("Missing card image mappings: " + ", ".join(missing))
    images_root = (python_root / "data" / "images").resolve()
    normalized: dict[str, str] = {}
    for card_id in sorted(set(release_ids)):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", card_id):
            raise ValueError(f"Unsafe card ID for export target: {card_id!r}")
        source_value = mapping.get(card_id)
        if not isinstance(source_value, str) or not source_value.strip():
            raise ValueError(f"Invalid card image mapping for {card_id}")
        relative = Path(source_value.replace("\\", "/"))
        source = (python_root / relative).resolve()
        try:
            source.relative_to(images_root)
        except ValueError:
            raise ValueError(
                f"Card image source escapes data/images for {card_id}: {source_value}"
            ) from None
        if not source.is_file():
            raise FileNotFoundError(f"Missing card image source for {card_id}: {source}")
        if source.suffix.lower() not in CARD_ASSET_EXTS:
            raise ValueError(f"Unsupported card image extension for {card_id}: {source.suffix}")
        normalized[card_id] = source.relative_to(python_root.resolve()).as_posix()
    return normalized


def _image_paths(mapping: dict[str, str]) -> dict[str, str]:
    exported: dict[str, str] = {}
    for card_id in sorted(set(ALL_CARD_IDS)):
        source_value = mapping.get(card_id)
        if not source_value:
            continue
        source = PYTHON_ROOT / Path(source_value.replace("\\", "/"))
        if not source.is_file():
            continue
        target = Path(f"{card_id}{source.suffix.lower()}")
        exported[card_id] = f"res://assets/cards/{target.name}"
    return exported


def _image_hashes(mapping: dict[str, str]) -> dict[str, str]:
    release_ids = set(ALL_CARD_IDS)
    return {
        card_id: _sha256(PYTHON_ROOT / Path(source_value))
        for card_id, source_value in sorted(mapping.items())
        if card_id in release_ids
    }


def _export_images(output: Path, mapping: dict[str, str]) -> dict[str, str]:
    target_root = output / "assets" / "cards"
    target_root.mkdir(parents=True, exist_ok=True)
    exported = _image_paths(mapping)
    for card_id, target_path in exported.items():
        source_value = mapping[card_id]
        source = PYTHON_ROOT / Path(source_value.replace("\\", "/"))
        target = target_root / Path(target_path).name
        shutil.copy2(source, target)
        if _sha256(source) != _sha256(target):
            raise OSError(f"Card image copy checksum mismatch: {card_id}")

    card_back = PYTHON_ROOT / "data" / "images" / "卡背.webp"
    if not card_back.is_file():
        raise FileNotFoundError(f"Missing card back image source: {card_back}")
    target_card_back = target_root / "card_back.webp"
    shutil.copy2(card_back, target_card_back)
    if _sha256(card_back) != _sha256(target_card_back):
        raise OSError("Card back image copy checksum mismatch")
    _remove_obsolete_card_assets(
        target_root,
        {Path(path).name for path in exported.values()} | {"card_back.webp"},
    )
    return exported


def _exported_image_errors(output: Path, mapping: dict[str, str]) -> list[str]:
    """Return stale/missing generated card assets without mutating the output."""
    target_root = output / "assets" / "cards"
    exported = _image_paths(mapping)
    expected_names = {Path(path).name for path in exported.values()}
    errors: list[str] = []
    for card_id, target_path in exported.items():
        source = PYTHON_ROOT / Path(mapping[card_id].replace("\\", "/"))
        target = target_root / Path(target_path).name
        if not target.is_file():
            errors.append(f"missing:{target.name}")
        elif _sha256(source) != _sha256(target):
            errors.append(f"hash:{target.name}")

    card_back = PYTHON_ROOT / "data" / "images" / "卡背.webp"
    target_card_back = target_root / "card_back.webp"
    expected_names.add(target_card_back.name)
    if not card_back.is_file():
        errors.append("source:card_back.webp")
    elif not target_card_back.is_file():
        errors.append("missing:card_back.webp")
    elif _sha256(card_back) != _sha256(target_card_back):
        errors.append("hash:card_back.webp")

    if target_root.is_dir():
        actual_names = {
            path.name
            for path in target_root.iterdir()
            if path.is_file() and path.suffix.lower() in CARD_ASSET_EXTS
        }
        errors.extend(f"obsolete:{name}" for name in sorted(actual_names - expected_names))
        expected_imports = {f"{name}.import" for name in expected_names}
        actual_imports = {
            path.name
            for path in target_root.iterdir()
            if path.is_file()
            and path.suffix.lower() == ".import"
            and Path(path.name[:-len(".import")]).suffix.lower() in CARD_ASSET_EXTS
        }
        errors.extend(
            f"obsolete:{name}" for name in sorted(actual_imports - expected_imports)
        )
    return errors


def _remove_obsolete_card_assets(target_root: Path, expected_names: set[str]) -> None:
    """Remove generated card assets that are no longer referenced by exported data."""
    if not target_root.is_dir():
        return
    expected_imports = {f"{name}.import" for name in expected_names}
    for path in target_root.iterdir():
        if not path.is_file():
            continue
        if path.suffix.lower() == ".import":
            source_name = path.name[:-len(".import")]
            source_ext = Path(source_name).suffix.lower()
            if source_ext in CARD_ASSET_EXTS and path.name not in expected_imports:
                path.unlink()
            continue
        if path.suffix.lower() in CARD_ASSET_EXTS and path.name not in expected_names:
            path.unlink()


def _card_payload(image_paths: dict[str, str]) -> dict[str, dict[str, Any]]:
    release_ids = sorted(set(ALL_CARD_IDS))
    CardRegistry.initialize(release_ids)
    encoder = ActionStateEncoder()
    cards: dict[str, dict[str, Any]] = {}
    for card_id in release_ids:
        card = CardRegistry.get(card_id)
        if card is None:
            raise ValueError(f"Release card is missing from CardRegistry: {card_id}")
        payload = _json_value(card)
        _add_compiled_effects(payload)
        payload.update(
            {
                "ai_card_index": card_vocab_index(card_id),
                "ai_semantic_features": encoder._card_semantic_features(card),
                "image_path": image_paths.get(card_id, ""),
                "prize_value": card.prize_value,
                "provides_energy": card.provides_energy,
            }
        )
        cards[card_id] = payload
    return cards


def _add_compiled_effects(payload: dict[str, Any]) -> None:
    for attack in payload.get("attacks", []):
        attack["compiled_effects"] = compile_effects_to_payload(
            attack.get("effects", [])
        )
    for ability in payload.get("abilities", []):
        ability["compiled_effects"] = compile_effects_to_payload(
            ability.get("effects", [])
        )
    payload["compiled_trainer_effects"] = compile_effects_to_payload(
        payload.get("trainer_effects", [])
    )
    for descriptor in payload.get("energy_effects", []):
        if not isinstance(descriptor, dict) or descriptor.get("kind") != "trigger":
            continue
        effect = descriptor.get("effect") or {}
        if (
            descriptor.get("hook") == "ON_PRIZE_REVEALED"
            and isinstance(effect, dict)
            and effect.get("op") == "attach_to_benched_pokemon"
        ):
            descriptor["compiled_commands"] = [{
                "op": "attach_energy",
                "args": {"amount": 1, "from_zone": "prizes", "to": "any"},
                "branches": {},
            }]


def _deck_payload() -> dict[str, dict[str, Any]]:
    payload: dict[str, dict[str, Any]] = {}
    for key, definition in DECKS.items():
        rows = [
            {"card_id": card_id, "count": int(count)}
            for card_id, count in definition["cards"]
        ]
        payload[key] = {
            "key": key,
            "name": definition["name"],
            "energy_type": definition["energy_type"],
            "card_count": sum(row["count"] for row in rows),
            "cards": rows,
        }
    return payload


def _portable_rng_sequence(seed: int, count: int) -> list[int]:
    state = seed & 0xFFFFFFFF
    if state == 0:
        state = 0x6D2B79F5
    values: list[int] = []
    for _ in range(count):
        state ^= (state << 13) & 0xFFFFFFFF
        state ^= state >> 17
        state ^= (state << 5) & 0xFFFFFFFF
        state &= 0xFFFFFFFF
        values.append(state)
    return values


def _effect_types(value: Any) -> set[str]:
    found: set[str] = set()
    if isinstance(value, dict):
        effect_type = value.get("effect_type")
        if isinstance(effect_type, str) and effect_type:
            found.add(effect_type)
        for item in value.values():
            found.update(_effect_types(item))
    elif isinstance(value, (list, tuple)):
        for item in value:
            found.update(_effect_types(item))
    elif dataclasses.is_dataclass(value):
        found.update(_effect_types(_json_value(value)))
    return found


def _effect_examples(value: Any, found: dict[str, dict[str, Any]] | None = None):
    if found is None:
        found = {}
    if isinstance(value, dict):
        effect_type = value.get("effect_type")
        if isinstance(effect_type, str) and effect_type and effect_type not in found:
            found[effect_type] = _json_value(value)
        for item in value.values():
            _effect_examples(item, found)
    elif isinstance(value, (list, tuple)):
        for item in value:
            _effect_examples(item, found)
    elif dataclasses.is_dataclass(value):
        _effect_examples(_json_value(value), found)
    return found


def _golden_contract(cards: dict[str, Any], decks: dict[str, Any]) -> dict[str, Any]:
    release_schemas = _release_manifest()["schemas"]
    effect_types = sorted(_effect_types(CARD_EFFECT_DEFINITIONS))
    effect_examples = {
        key: value
        for key, value in sorted(
            _effect_examples(CARD_EFFECT_DEFINITIONS).items()
        )
    }
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
            "encoder_version": ENCODER_SCHEMA_VERSION,
            "rng_version": RNG_SCHEMA_VERSION,
        },
        "counts": {
            "cards": len(cards),
            "decks": len(decks),
            "effects": len(effect_types),
        },
        "effect_types": effect_types,
        "effect_examples": effect_examples,
        "compiled_effect_examples": {
            key: compile_effect_to_spec(value).to_dict()
            for key, value in effect_examples.items()
        },
        "deck_sizes": {key: deck["card_count"] for key, deck in decks.items()},
        "ai_card_index_samples": {
            card_id: cards[card_id]["ai_card_index"]
            for card_id in (
                "svi-chim",
                "sv2-grex",
                "sv1-ener-2",
                "sv1-153",
                "svg2-tort",
            )
        },
        "card_vocab": {
            "format_version": CARD_VOCAB_VERSION,
            "size": card_vocab_size(),
            "sha256": card_vocab_sha256(),
        },
        "portable_rng": {
            "schema_version": RNG_SCHEMA_VERSION,
            "algorithm": "xorshift32",
            "seed": 20260620,
            "uint32": _portable_rng_sequence(20260620, 8),
        },
    }


def _public_ref_payload(ref: Any) -> dict[str, Any] | None:
    """Project a Python entity ref to Protocol 6's strict tagged union."""
    payload = serialize_entity_ref(ref)
    if payload is None:
        return None
    fields_by_kind = {
        "card": ("kind", "player", "zone", "index", "card_id"),
        "pokemon": ("kind", "player", "slot", "card_id"),
        "slot": ("kind", "player", "slot"),
        "attachment": (
            "kind",
            "player",
            "slot",
            "attachment_type",
            "index",
            "card_id",
        ),
    }
    fields = fields_by_kind.get(str(payload.get("kind", "")))
    if fields is None:
        raise ValueError("reference has an unsupported public kind")
    return {field: payload[field] for field in fields}


def _action_payload(action: GameAction) -> dict[str, Any]:
    return serialize_game_action(action)


def _ai_encoder_fixture() -> dict[str, Any]:
    observation = Observation(
        perspective=1,
        turn_number=7,
        phase="MAIN",
        active_player=1,
        winner=None,
        own_hand=("sv1-ener-3", "sv2-cand", "sv2-39"),
        own_discard=("sv1-152", "sv1-ener-3"),
        own_deck_count=34,
        own_prize_count=4,
        opponent_hand_count=5,
        opponent_discard=("sv1-ener-2", "svi-chim"),
        opponent_deck_count=31,
        opponent_prize_count=3,
        board=(
            (0, "active", "svi-ente", 4, ("sv1-ener-2",), ("BURNED",), ""),
            (0, "bench_0", "svi-chim", 0, (), (), ""),
            (0, "bench_1", "", 0, (), (), ""),
            (0, "bench_2", "", 0, (), (), ""),
            (0, "bench_3", "", 0, (), (), ""),
            (0, "bench_4", "", 0, (), (), ""),
            (1, "active", "sv2-grex", 6, ("sv1-ener-3", "sv1-ener-3"), (), ""),
            (1, "bench_0", "sv2-staryu", 0, ("sv1-ener-3",), (), ""),
            (1, "bench_1", "", 0, (), (), ""),
            (1, "bench_2", "", 0, (), (), ""),
            (1, "bench_3", "", 0, (), (), ""),
            (1, "bench_4", "", 0, (), (), ""),
        ),
        stadium_id="sv1-176",
        public_deck_keys=("fire", "water"),
        apply_type_matchups=False,
    )
    actions = (
        GameAction(
            kind=PlayerAction.ATTACH_ENERGY,
            actor=1,
            source=CardRef(1, "hand", 0, "sv1-ener-3"),
            target=PokemonRef(1, "active", "sv2-grex"),
            base_revision=0,
        ),
        GameAction(
            kind=PlayerAction.DECLARE_ATTACK,
            payload={"attack_index": 1},
            actor=1,
            source=PokemonRef(1, "active", "sv2-grex"),
            base_revision=0,
        ),
        GameAction(kind=PlayerAction.END_TURN, actor=1, base_revision=0),
    )
    choice = ChoiceView(
        request_id="choice:fixture",
        base_revision=0,
        request_type="select_bench",
        player=1,
        prompt="fixture",
        options=(
            ChoiceOption(
                "pokemon:1:bench_0:sv2-staryu",
                "海星星",
                PokemonRef(1, "bench_0", "sv2-staryu"),
            ),
            ChoiceOption(
                "card:hand:1:sv2-cand",
                "小菘",
                CardRef(1, "hand", 1, "sv2-cand"),
            ),
        ),
    )
    encoder = ActionStateEncoder()
    encoded_state = encoder.encode_observation(observation, "water")
    encoded_actions = [
        encoder.encode_game_action(observation, action) for action in actions
    ]
    encoded_choices = [
        encoder.encode_choice_option(observation, choice.request_type, option, index)
        for index, option in enumerate(choice.options)
    ]
    return {
        "fixture_version": 2,
        "deck_key": "water",
        "observation": _json_value(observation),
        "actions": [_action_payload(action) for action in actions],
        "choice": {
            "schema_version": 2,
            "request_id": choice.request_id,
            "base_revision": 7,
            "request_type": choice.request_type,
            "player": choice.player,
            "prompt": choice.prompt,
            "options": [
                {
                    "option_id": option.option_id,
                    "label": option.label,
                    "ref": _public_ref_payload(option.ref),
                }
                for option in choice.options
            ],
            "min_select": choice.min_select,
            "max_select": choice.max_select,
            "allow_duplicates": choice.allow_duplicates,
            "can_cancel": choice.can_cancel,
            "presentation": {},
        },
        "expected": {
            "state_numeric": encoded_state.numeric,
            "state_cards": encoded_state.card_ids,
            "actions": [
                {"numeric": item.numeric, "card_id": item.card_id}
                for item in encoded_actions
            ],
            "choices": [
                {"numeric": item.numeric, "card_id": item.card_id}
                for item in encoded_choices
            ],
        },
    }


_RUNTIME_ONLY_VM_OPS = {
    "deal_damage_per_discard_psychic": "compatibility_formula_op",
    "deal_damage_per_energy": "compatibility_formula_op",
    "deal_damage_per_evolved": "compatibility_formula_op",
    "deal_damage_per_hand_size": "compatibility_formula_op",
    "deal_damage_per_self_damage": "compatibility_formula_op",
    "deal_damage_per_self_energy": "compatibility_formula_op",
    "deal_damage_per_self_energy_type": "compatibility_formula_op",
    "deal_damage_plus_bench": "compatibility_formula_op",
    "deal_damage_with_self_penalty": "compatibility_formula_op",
    "set_attack_damage_formula": "compatibility_formula_op",
    "trigger_draw_cards": "trigger_op",
    "trigger_move_basic_energy": "trigger_op",
    "trigger_place_damage_counters": "trigger_op",
    "trigger_switch_with_active": "trigger_op",
}


_TRACE_SEMANTICS: dict[str, dict[str, list[str]]] = {
    "basic_attach_attack": {
        "effect_types": ["energy_discard"],
        "vm_ops": ["discard_energy"],
        "features": ["basic_placement", "manual_energy_attachment", "base_attack"],
    },
    "double_turbo_retreat": {
        "effect_types": [],
        "vm_ops": [],
        "features": [
            "special_energy_retreat",
            "retreat",
            "pending_choice",
            "retreat_payment",
        ],
    },
    "evolution_preserves_attachments": {
        "effect_types": [],
        "vm_ops": [],
        "features": ["evolution"],
    },
    "pending_attack_choice_continuation": {
        "effect_types": ["energy_attach"],
        "vm_ops": ["attach_energy"],
        "features": ["pending_choice", "continuation_selected"],
    },
    "pending_attack_choice_cancel": {
        "effect_types": ["energy_attach"],
        "vm_ops": ["attach_energy"],
        "features": ["pending_choice", "continuation_cancelled", "deck_shuffle"],
    },
    "supporter_draw": {
        "effect_types": ["draw"],
        "vm_ops": ["draw_cards"],
        "features": ["supporter"],
    },
    "tool_attachment": {
        "effect_types": [],
        "vm_ops": [],
        "features": ["tool_attachment"],
    },
    "ability_damage_draw": {
        "effect_types": ["damage_counter_self", "draw"],
        "vm_ops": ["place_damage_counters", "draw_cards"],
        "features": ["ability"],
    },
    "activatable_stadium": {
        "effect_types": [],
        "vm_ops": ["draw_cards"],
        "features": ["synthetic_stadium_fixture", "stadium_activation"],
    },
    "end_turn": {
        "effect_types": [],
        "vm_ops": [],
        "features": ["end_turn", "next_turn_draw"],
    },
    "confused_attack_tails": {
        "effect_types": [],
        "vm_ops": [],
        "features": ["portable_coin_flip", "confused_attack_failure", "attack_turn_finish"],
    },
    "ko_then_promote": {
        "effect_types": ["energy_discard"],
        "vm_ops": ["discard_energy"],
        "features": ["knockout", "prize", "promotion", "attack_turn_finish"],
    },
    "heal_supporter": {
        "effect_types": ["heal"],
        "vm_ops": ["heal_damage"],
        "features": ["supporter", "direct_heal"],
    },
    "shuffle_draw_supporter": {
        "effect_types": ["shuffle_draw"],
        "vm_ops": ["shuffle_then_draw_cards"],
        "features": ["supporter", "portable_deck_shuffle", "draw_after_shuffle"],
    },
    "heal_all_ability": {
        "effect_types": ["heal_all"],
        "vm_ops": ["heal_all"],
        "features": ["ability", "multi_pokemon_heal"],
    },
    "damage_then_self_heal_attack": {
        "effect_types": ["damage_and_self_heal"],
        "vm_ops": ["deal_damage_then_heal"],
        "features": ["attack_effect_damage", "self_heal", "attack_turn_finish"],
    },
    "formula_damage_attack": {
        "effect_types": ["attack_damage_formula"],
        "vm_ops": ["deal_damage"],
        "features": ["formula_ast", "self_damage_counter_formula", "attack_turn_finish"],
    },
    "prevent_damage_and_lock_attack": {
        "effect_types": ["prevent_damage", "self_attack_lock"],
        "vm_ops": ["prevent_damage", "apply_self_attack_lock"],
        "features": ["damage_prevention_marker", "self_attack_lock_marker"],
    },
    "conditional_status_attack": {
        "effect_types": ["conditional_status"],
        "vm_ops": ["conditional_status"],
        "features": ["ko_by_attack_condition", "status_application"],
    },
    "conditional_damage_heal_attack": {
        "effect_types": ["conditional_damage_heal"],
        "vm_ops": ["conditional_damage_then_heal"],
        "features": ["healed_this_turn_condition", "conditional_damage"],
    },
    "prevent_effects_attack": {
        "effect_types": ["prevent_effects"],
        "vm_ops": ["prevent_effects"],
        "features": ["effect_prevention_marker", "attack_turn_finish"],
    },
    "search_energy_attack": {
        "effect_types": ["search"],
        "vm_ops": ["search_cards"],
        "features": ["pending_choice", "deck_search", "deck_shuffle"],
    },
    "potion_heal_choice": {
        "effect_types": ["potion_heal"],
        "vm_ops": ["choose_heal_damage"],
        "features": ["pending_choice", "bench_target", "item_heal"],
    },
}


def _rules_coverage(
    golden_actions: dict[str, Any],
    vm_semantic_golden: dict[str, Any],
) -> dict[str, Any]:
    """Build a strict mapping inventory without overstating semantic coverage."""
    release_effects = set(_effect_types(CARD_EFFECT_DEFINITIONS))
    registered_effects = set(SUPPORTED_EFFECT_TYPES)
    effect_examples = _effect_examples(CARD_EFFECT_DEFINITIONS)
    effect_to_op = dict(OP_BY_EFFECT_TYPE)
    effect_to_op.update({
        effect_type: compile_effect_to_spec(example).op
        for effect_type, example in effect_examples.items()
    })
    registered_ops = set(VM_COMMAND_DESCRIPTORS)
    descriptor_payload = descriptor_export_payload(VM_IR_VERSION)
    descriptor_ops = set(descriptor_payload["descriptors"])
    produced_ops = set(effect_to_op.values())
    runtime_only_ops = registered_ops - produced_ops
    cases = dict(golden_actions.get("cases", {}))
    vm_cases = dict(vm_semantic_golden.get("cases", {}))
    vm_executed_ops = set(vm_semantic_golden.get("executed_ops", []))

    if descriptor_ops != registered_ops:
        raise RuntimeError(
            "VM descriptors and Python handlers must be 1:1; "
            f"missing_handlers={sorted(descriptor_ops - registered_ops)} "
            f"missing_descriptors={sorted(registered_ops - descriptor_ops)}"
        )

    if release_effects - registered_effects:
        raise RuntimeError(
            f"Release effects missing registrations: {sorted(release_effects - registered_effects)}"
        )
    if set(effect_to_op) != registered_effects:
        raise RuntimeError("Every registered effect must have exactly one VM op mapping")
    if produced_ops - registered_ops:
        raise RuntimeError(
            f"Effect mappings target unregistered VM ops: {sorted(produced_ops - registered_ops)}"
        )
    if runtime_only_ops != set(_RUNTIME_ONLY_VM_OPS):
        raise RuntimeError(
            "Every registered VM op not produced by an effect mapping must have an "
            f"explicit classification; missing={sorted(runtime_only_ops - set(_RUNTIME_ONLY_VM_OPS))} "
            f"stale={sorted(set(_RUNTIME_ONLY_VM_OPS) - runtime_only_ops)}"
        )
    if set(_TRACE_SEMANTICS) != set(cases):
        raise RuntimeError(
            f"Trace semantics inventory differs from generated cases: "
            f"missing={sorted(set(cases) - set(_TRACE_SEMANTICS))} "
            f"stale={sorted(set(_TRACE_SEMANTICS) - set(cases))}"
        )
    if (
        int(vm_semantic_golden.get("fixture_version", 0)) != 2
        or vm_executed_ops != registered_ops
        or set(vm_cases) != registered_ops
    ):
        raise RuntimeError(
            "Native VM semantic fixture must execute every registered op; "
            f"missing={sorted(registered_ops - vm_executed_ops)} "
            f"extra={sorted(vm_executed_ops - registered_ops)}"
        )
    for op, row in vm_cases.items():
        if (
            str(row.get("descriptor", {}).get("op", "")) != op
            or str(row.get("command_spec", {}).get("op", "")) != op
            or not bool(row.get("expected", {}).get("success", False))
        ):
            raise RuntimeError(
                f"VM semantic case is not a successful direct execution: {op}"
            )

    action_to_cases: dict[str, list[str]] = {action.name: [] for action in PlayerAction}
    for case_name, row in cases.items():
        for action in row.get("actions", []):
            action_name = str(action.get("action", ""))
            if action_name in action_to_cases and case_name not in action_to_cases[action_name]:
                action_to_cases[action_name].append(case_name)
    untraced_actions = [name for name, mapped in action_to_cases.items() if not mapped]
    if untraced_actions:
        raise RuntimeError(f"Public PlayerAction values lack a trace: {untraced_actions}")

    vm_op_mappings: dict[str, dict[str, Any]] = {}
    for op in sorted(registered_ops):
        effect_sources = sorted(
            effect_type
            for effect_type, mapped_op in effect_to_op.items()
            if mapped_op == op
        )
        vm_op_mappings[op] = {
            "effect_types": effect_sources,
            "classification": (
                "effect_compiler" if effect_sources else _RUNTIME_ONLY_VM_OPS[op]
            ),
        }

    semantic_effects = sorted({
        effect_type
        for row in _TRACE_SEMANTICS.values()
        for effect_type in row["effect_types"]
    })
    public_semantic_ops = sorted({
        op for row in _TRACE_SEMANTICS.values() for op in row["vm_ops"]
    })
    semantic_ops = sorted(set(public_semantic_ops) | vm_executed_ops)
    if not set(semantic_effects).issubset(release_effects):
        raise RuntimeError("Semantic trace effect labels must be release effect types")
    if not set(semantic_ops).issubset(registered_ops):
        raise RuntimeError("Semantic trace VM op labels must be registered VM ops")

    step_count = sum(len(row.get("trace", [])) for row in cases.values())
    return {
        "coverage_version": 3,
        "mapping_inventory": {
            "release_effect_types": sorted(release_effects),
            "registered_effect_types": sorted(registered_effects),
            "non_release_registered_effect_types": sorted(
                registered_effects - release_effects
            ),
            "effect_to_vm_op": {
                key: effect_to_op[key] for key in sorted(effect_to_op)
            },
            "registered_vm_ops": sorted(registered_ops),
            "vm_op_mappings": vm_op_mappings,
            "public_player_actions": sorted(action_to_cases),
            "action_to_trace_cases": action_to_cases,
        },
        "vm_descriptor_contract": {
            "descriptor_schema_version": descriptor_payload[
                "descriptor_schema_version"
            ],
            "descriptor_digest": descriptor_payload["descriptor_digest"],
            "descriptor_ops": sorted(descriptor_ops),
            "handler_ops": sorted(registered_ops),
            "preflight_ops": sorted(
                op for op, descriptor in descriptor_payload["descriptors"].items()
                if str(descriptor.get("preflight_evaluator", ""))
            ),
            "golden_ops": sorted(vm_cases),
            "executed_ops": sorted(vm_executed_ops),
        },
        "semantic_trace_inventory": {
            "case_count": len(cases),
            "transaction_step_count": step_count,
            "native_vm_case_count": len(vm_cases),
            "case_semantics": _TRACE_SEMANTICS,
            "native_vm_fixture": "vm_native_golden.json",
            "public_trace_vm_ops_executed": public_semantic_ops,
            "release_effect_types_executed": semantic_effects,
            "registered_vm_ops_executed": semantic_ops,
            "release_effect_types_not_executed": sorted(
                release_effects - set(semantic_effects)
            ),
            "registered_vm_ops_not_executed": sorted(
                registered_ops - set(semantic_ops)
            ),
            "known_cross_runtime_semantic_gaps": list(
                vm_semantic_golden.get(
                    "known_cross_runtime_semantic_gaps", []
                )
            ),
            "explicitly_not_claimed": [
                "all_release_effect_semantics",
            ],
        },
        "counts": {
            "release_effect_types": len(release_effects),
            "registered_effect_types": len(registered_effects),
            "mapped_registered_effect_types": len(effect_to_op),
            "registered_vm_ops": len(registered_ops),
            "mapped_registered_vm_ops": len(vm_op_mappings),
            "public_player_actions": len(action_to_cases),
            "traced_public_player_actions": sum(bool(rows) for rows in action_to_cases.values()),
            "semantic_release_effect_types": len(semantic_effects),
            "semantic_registered_vm_ops": len(semantic_ops),
        },
    }


def _frozen_rules_fixture(name: str) -> dict[str, Any]:
    path = REPO_ROOT / "godot" / "tests" / "fixtures" / name
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError(f"Frozen rules fixture is invalid: {path}")
    return payload


def export(output: Path, *, copy_images: bool = True) -> dict[str, Any]:
    # Unknown release IDs are a schema change, never an implicit export-time
    # mutation.  Assign them first via update_ai_card_vocab.py.
    validate_release_card_vocab(tuple(ALL_CARD_IDS))
    image_mapping = _load_image_mapping()
    image_paths = (
        _export_images(output, image_mapping)
        if copy_images
        else _image_paths(image_mapping)
    )
    image_hashes = _image_hashes(image_mapping)
    cards = _card_payload(image_paths)
    decks = _deck_payload()
    descriptor_payload = descriptor_export_payload(VM_IR_VERSION)
    descriptor_ops = set(descriptor_payload["descriptors"])

    for spec_index, spec in enumerate(iter_command_specs(cards)):
        errors = validate_command_spec(
            spec,
            supported_ops=descriptor_ops,
            descriptors=VM_COMMAND_DESCRIPTORS,
            allow_internal=False,
            path=f"$.cards.command_specs[{spec_index}]",
        )
        if errors:
            raise RuntimeError(
                "Compiled release card VM contract is invalid: "
                + "; ".join(errors)
            )

    # Fail the authoritative export before writing derived assets when any
    # printed rules segment lacks a runtime binding or either runtime exposes a
    # VM operation the other side cannot execute.
    card_rules_matrix = assert_card_rules_consistent(
        peer_supported_ops=descriptor_ops,
    )
    source_index = discover_effect_sources(PYTHON_ROOT / "card_data" / "effects")
    if source_index.duplicate_card_ids:
        raise RuntimeError(
            "Duplicate card effect source IDs: "
            + ", ".join(source_index.duplicate_card_ids)
        )
    typed_specs = card_specs_from_mappings(
        CARD_EFFECT_DEFINITIONS,
        source_index=source_index,
    )
    card_ir = compile_card_ir_v3(typed_specs, all_card_ids=ALL_CARD_IDS)
    if card_ir["source_mapped_effect_count"] != card_ir["effect_count"]:
        raise RuntimeError("Card IR source-map coverage is incomplete")

    data_root = output / "data"
    _write_json(data_root / "cards.json", cards)
    _write_json(data_root / "card_ir_v3.json", card_ir)
    _write_json(data_root / "decks.json", decks)
    _write_json(data_root / "ai_strategies.json", build_ai_strategy_catalog(DECKS))
    _write_json(data_root / "card_images.json", image_paths)
    _write_json(data_root / "card_image_hashes.json", image_hashes)
    _write_json(data_root / "ai_card_vocab.json", load_card_vocab())
    _write_json(data_root / "release_manifest.json", _release_manifest())
    _write_json(data_root / "vm_command_descriptors.json", descriptor_payload)
    golden = _golden_contract(cards, decks)
    _write_json(output / "tests" / "fixtures" / "data_contract.json", golden)
    _write_json(
        output / "tests" / "fixtures" / "ai_encoder_golden.json",
        _ai_encoder_fixture(),
    )
    # Rule fixtures are language-neutral frozen inputs now.  C++ owns their
    # execution tests; the Python authoring export copies them without running
    # a second rules implementation.
    golden_actions = _frozen_rules_fixture("rules_golden.json")
    _write_json(
        output / "tests" / "fixtures" / "rules_golden.json",
        golden_actions,
    )
    vm_semantic_golden = _frozen_rules_fixture("vm_native_golden.json")
    _write_json(
        output / "tests" / "fixtures" / "vm_native_golden.json",
        vm_semantic_golden,
    )
    _write_json(
        output / "tests" / "fixtures" / "rules_coverage.json",
        _rules_coverage(golden_actions, vm_semantic_golden),
    )
    _write_json(
        output / "tests" / "fixtures" / "card_rules_matrix.json",
        card_rules_matrix,
    )
    return golden


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--skip-images", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        output = args.output.resolve()
        with tempfile.TemporaryDirectory() as temporary:
            generated = Path(temporary)
            export(generated, copy_images=False)
            relative_paths = [
                Path("data/cards.json"),
                Path("data/card_ir_v3.json"),
                Path("data/decks.json"),
                Path("data/ai_strategies.json"),
                Path("data/card_images.json"),
                Path("data/card_image_hashes.json"),
                Path("data/ai_card_vocab.json"),
                Path("data/release_manifest.json"),
                Path("data/vm_command_descriptors.json"),
                Path("tests/fixtures/data_contract.json"),
                Path("tests/fixtures/ai_encoder_golden.json"),
                Path("tests/fixtures/rules_golden.json"),
                Path("tests/fixtures/vm_native_golden.json"),
                Path("tests/fixtures/rules_coverage.json"),
                Path("tests/fixtures/card_rules_matrix.json"),
            ]
            stale = [
                str(path)
                for path in relative_paths
                if not (output / path).is_file()
                or (output / path).read_bytes() != (generated / path).read_bytes()
            ]
            if stale:
                raise SystemExit(
                    "Godot generated data is stale: "
                    + ", ".join(stale)
                    + ". Run python/scripts/export_godot_data.py."
                )
            image_errors = _exported_image_errors(output, _load_image_mapping())
            if image_errors:
                raise SystemExit(
                    "Godot card images are stale: "
                    + ", ".join(image_errors)
                    + ". Run python/scripts/export_godot_data.py."
                )
        print("Godot generated data is current.")
        return
    result = export(args.output.resolve(), copy_images=not args.skip_images)
    print(
        f"Exported {result['counts']['cards']} cards, "
        f"{result['counts']['decks']} decks and "
        f"{result['counts']['effects']} effect types."
    )


if __name__ == "__main__":
    main()
