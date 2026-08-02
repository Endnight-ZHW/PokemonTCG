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

from card_data.effects import CARD_EFFECTS
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
    ChoiceRequest,
    ChoiceResponse,
    GameAction,
    PokemonRef,
)
from engine.ai.observation import Observation
from engine.ai.dl.encoder import (
    ACTION_NUMERIC_SIZE,
    CARD_BUCKET_COUNT,
    ENCODER_SCHEMA_VERSION,
    STATE_CARD_SLOTS,
    STATE_NUMERIC_SIZE,
    ActionStateEncoder,
    card_bucket,
)
from engine.ai.planner import PLANNER_SCHEMA_VERSION
from engine.commands.dsl_compiler import (
    DEFAULT_COMMAND_REGISTRY,
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
from engine.enums import PlayerAction, StatusType, TurnPhase
from engine.game_engine import GameEngine
from engine.game_state import GameState
from engine.player_state import PokemonInPlay
from engine.random_source import RNG_SCHEMA_VERSION, PortableRandomSourceV1
from engine.snapshot import canonical_state_payload

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
    if model_count not in {0, 1, len(release_decks)}:
        raise RuntimeError(
            "release_manifest.json model_count is not a valid universal or legacy count"
        )
    if set(release_decks) != set(DECKS):
        raise RuntimeError("release_manifest.json release_decks do not match Python deck data")
    return payload

DEEP_AI_MODEL_DECK_KEYS = tuple(_release_manifest()["release_decks"])


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
                "card_bucket": card_bucket(card_id),
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


def _model_manifest() -> dict[str, Any]:
    model_root = PYTHON_ROOT / "data" / "ai_models"
    models: dict[str, Any] = {}
    for deck_key in DEEP_AI_MODEL_DECK_KEYS:
        checkpoint = model_root / f"{deck_key}.pt"
        sidecar = model_root / f"{deck_key}.json"
        metadata: dict[str, Any] = {}
        if sidecar.is_file():
            raw = json.loads(sidecar.read_text(encoding="utf-8"))
            metadata = dict(raw.get("metadata") or {})
        schema_current = (
            int(metadata.get("rules_version") or 0) == RULES_SCHEMA_VERSION
            and int(metadata.get("action_version") or 0) == ACTION_SCHEMA_VERSION
            and int(metadata.get("encoder_version") or 0) == ENCODER_SCHEMA_VERSION
            and int(metadata.get("planner_version") or 0) == PLANNER_SCHEMA_VERSION
        )
        models[deck_key] = {
            "deck_key": deck_key,
            "source_checkpoint": f"python/data/ai_models/{deck_key}.pt",
            "onnx_path": f"res://data/ai_models/{deck_key}.onnx",
            "checkpoint_exists": checkpoint.is_file(),
            "checkpoint_size": checkpoint.stat().st_size if checkpoint.is_file() else 0,
            "checkpoint_sha256": _sha256(checkpoint) if checkpoint.is_file() else "",
            "accepted": bool(metadata.get("accepted")) and schema_current,
            "verified": bool(metadata.get("verified")) and schema_current,
            "rules_version": int(metadata.get("rules_version") or 0),
            "action_version": int(metadata.get("action_version") or 0),
            "encoder_version": int(metadata.get("encoder_version") or 0),
            "planner_version": int(metadata.get("planner_version") or 0),
        }
    return {
        "format_version": 1,
        "inference_format": "onnx-fp32",
        "search_simulations": 64,
        "state_numeric_size": STATE_NUMERIC_SIZE,
        "state_card_slots": STATE_CARD_SLOTS,
        "action_numeric_size": ACTION_NUMERIC_SIZE,
        "card_bucket_count": CARD_BUCKET_COUNT,
        "card_identity_mode": "vocab_v1",
        "card_vocab_version": CARD_VOCAB_VERSION,
        "card_vocab_size": card_vocab_size(),
        "card_vocab_sha256": card_vocab_sha256(),
        "models": models,
    }


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
    effect_types = sorted(_effect_types(CARD_EFFECTS))
    effect_examples = {
        key: value for key, value in sorted(_effect_examples(CARD_EFFECTS).items())
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
            "planner_version": PLANNER_SCHEMA_VERSION,
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
        "card_bucket_samples": {
            card_id: cards[card_id]["card_bucket"]
            for card_id in (
                "svi-chim",
                "sv2-grex",
                "sv1-ener-2",
                "sv1-153",
                "svg2-tort",
            )
        },
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


def _ref_payload(ref: Any) -> dict[str, Any] | None:
    return serialize_entity_ref(ref)


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
            PlayerAction.ATTACH_ENERGY,
            {"hand_idx": 0, "target_slot": "active"},
            False,
            1,
            CardRef(1, "hand", 0, "sv1-ener-3"),
            PokemonRef(1, "active", "sv2-grex"),
        ),
        GameAction(
            PlayerAction.DECLARE_ATTACK,
            {"attack_idx": 1},
            True,
            1,
            PokemonRef(1, "active", "sv2-grex"),
        ),
        GameAction(PlayerAction.END_TURN, {}, True, 1),
    )
    choice = ChoiceRequest(
        "choice:fixture",
        "select_bench",
        1,
        "fixture",
        (
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


def _godot_pokemon_payload(snapshot: dict[str, Any] | None) -> dict[str, Any] | None:
    if snapshot is None:
        return None
    payload = {
        "card_id": str(snapshot.get("card_id", "")),
        "damage_counters": int(snapshot.get("damage_counters", 0)),
        "energy_card_ids": list(snapshot.get("energy_card_ids", [])),
        "attached_tool_id": str(snapshot.get("attached_tool_id") or ""),
        "status_conditions": sorted(snapshot.get("status_conditions", [])),
        "evolution_stack_ids": list(snapshot.get("evolution_stack_ids", [])),
        "can_evolve_this_turn": bool(snapshot.get("can_evolve_this_turn", True)),
        "placed_this_turn": bool(snapshot.get("placed_this_turn", True)),
        "used_abilities": sorted(snapshot.get("used_abilities", [])),
        "healed_this_turn": bool(snapshot.get("healed_this_turn", False)),
        "paralyzed_since_turn": int(snapshot.get("paralyzed_since_turn", 0)),
    }
    # Python snapshots retain serializable MAX_HP registrations separately,
    # while PokemonState stores all persistent registrations in ``modifiers``.
    # Adapt the only snapshot-backed modifier family to the Godot shape.  Like
    # PokemonState.to_dict(), omit the key when no persistent modifier exists.
    modifiers = [
        _json_value(value)
        for value in snapshot.get("modifiers", [])
        if isinstance(value, dict)
    ]
    for value in snapshot.get("max_hp_modifiers", []):
        if not isinstance(value, dict):
            continue
        modifier_kind = str(
            value.get("modifier_kind", value.get("effect_type", ""))
        )
        if not modifier_kind:
            continue
        if (
            modifier_kind == "conditional_hp_boost"
            and any(
                isinstance(row, dict)
                and (row.get("operation") or {}).get("kind") == "hp_delta"
                for row in modifiers
            )
        ):
            continue
        params = dict(value.get("params", {}))
        for key in ("energy_type", "threshold", "amount"):
            if key in value and key not in params:
                params[key] = value[key]
        modifiers.append({
            "source": str(value.get("source", modifier_kind)),
            "source_player": int(value.get("source_player", -1)),
            "source_slot": str(value.get("source_slot", "")),
            "source_card_id": str(
                value.get("source_card_id", snapshot.get("card_id", ""))
            ),
            "modifier_kind": modifier_kind,
            "params": _json_value(params),
        })
    if modifiers:
        payload["modifiers"] = modifiers
    return payload


def _godot_knockout_fact_payload(fact: Any) -> dict[str, Any] | None:
    """Translate one Python TurnFactBook fact to GameState's fact contract."""
    if not isinstance(fact, dict):
        return None
    defeated_player = int(fact.get("defeated_player", fact.get("owner", -1)))
    source_kind = str(fact.get("source_kind", fact.get("cause", "rule")))
    source_player_value = fact.get("source_player", -1)
    source_player = (
        int(source_player_value) if source_player_value in (0, 1) else -1
    )
    if source_kind == "attack_damage":
        cause_kind = "damage"
    elif source_kind == "direct_knockout":
        source_kind = "attack_effect"
        cause_kind = "direct_knockout"
    elif source_kind in {"damage_counter", "damage_counters"}:
        cause_kind = "damage_counters"
    elif source_kind == "special_condition":
        cause_kind = "special_condition"
    else:
        cause_kind = "effect"
    return {
        "defeated_player": defeated_player,
        "slot": str(fact.get("slot", "")),
        "card_id": str(fact.get("card_id", "")),
        "source_player": source_player,
        "source_kind": source_kind,
        "cause_kind": str(fact.get("cause_kind", cause_kind)),
        "cause_detail": _json_value(
            fact.get("cause_detail", fact.get("cause_details", ""))
        ),
        "turn": int(fact.get("turn", fact.get("turn_number", 0))),
    }


def _godot_turn_fact_book_payload(snapshot: Any) -> dict[str, Any]:
    """Return the two-window TurnFactBook shape used by Godot rules v4."""
    source = snapshot if isinstance(snapshot, dict) else {}

    def window(primary: str, fallback: str) -> dict[str, Any]:
        value = source.get(primary, source.get(fallback, {}))
        row = value if isinstance(value, dict) else {}
        facts = [
            mapped
            for fact in row.get("knockouts", [])
            if (mapped := _godot_knockout_fact_payload(fact)) is not None
        ]
        # Godot's authoritative fact book stores immutable KO facts in these
        # windows. Python's window metadata is intentionally not copied: the
        # Godot turn boundary owns window rotation and does not serialize it.
        return {"knockouts": facts}

    return {
        "current_turn": window("current_turn", "current"),
        "previous_turn": window("previous_turn", "previous"),
    }


def _godot_mulligan_bonus_max(snapshot: dict[str, Any]) -> int:
    """Collapse Python's per-player maxima to Godot's single net maximum."""
    value = snapshot.get("mulligan_bonus_max", (0, 0))
    if isinstance(value, (list, tuple)):
        return max((int(item) for item in value), default=0)
    return int(value or 0)


def _godot_player_payload(snapshot: dict[str, Any]) -> dict[str, Any]:
    return {
        "name": str(snapshot.get("name", "")),
        "deck": list(snapshot.get("deck_ids", [])),
        "hand": list(snapshot.get("hand_ids", [])),
        "discard": list(snapshot.get("discard_ids", [])),
        "prizes": list(snapshot.get("prize_ids", [])),
        "active": _godot_pokemon_payload(snapshot.get("active")),
        "bench": [
            _godot_pokemon_payload(pokemon)
            for pokemon in snapshot.get("bench", [])
        ],
        "supporter_played_this_turn": bool(snapshot.get("supporter_played", False)),
        "energy_attached_this_turn": bool(snapshot.get("energy_attached", False)),
        "retreated_this_turn": bool(snapshot.get("retreated", False)),
        "stadium_played_this_turn": bool(snapshot.get("stadium_played", False)),
        "stadium_used_this_turn": bool(snapshot.get("stadium_used", False)),
        "healed_this_turn": bool(snapshot.get("healed", False)),
        "vstar_power_used": bool(snapshot.get("vstar_used", False)),
        "was_ko_by_attack": bool(snapshot.get("was_ko_by_attack", False)),
    }


def _state_payload(state: GameState) -> dict[str, Any]:
    snapshot = canonical_state_payload(state)
    apply_type_matchups = bool(snapshot.get("apply_type_matchups", False))
    rules_options = dict(snapshot.get("rules_options", {}))
    rules_options["apply_type_matchups"] = apply_type_matchups
    return {
        "players": [
            _godot_player_payload(snapshot["p1"]),
            _godot_player_payload(snapshot["p2"]),
        ],
        "active_player_idx": int(snapshot["active_player_idx"]),
        "phase": str(snapshot["phase"]),
        "turn_number": int(snapshot["turn_number"]),
        "first_player_idx": int(snapshot["first_player_idx"]),
        "stadium_card_id": str(snapshot.get("stadium_card_id") or ""),
        "stadium_owner_idx": int(snapshot.get("stadium_owner_idx", -1)),
        "winner": -1 if snapshot.get("winner") is None else int(snapshot["winner"]),
        "result_status": str(snapshot.get("result_status", "ONGOING")),
        "result_reason": str(snapshot.get("result_reason", "")),
        "result_conditions": _json_value(
            snapshot.get("result_conditions", [[], []])
        ),
        "revision": int(snapshot.get("revision", 0)),
        "choice_sequence": int(snapshot.get("choice_sequence", 0)),
        "public_deck_keys": [
            str(value or "")
            for value in snapshot.get("public_deck_keys", ("", ""))
        ],
        "apply_type_matchups": apply_type_matchups,
        "rules_profile_id": str(
            snapshot.get("rules_profile_id", "CN_MAINLAND_3_1_0")
        ),
        "rules_options": _json_value(rules_options),
        "action_log": [],
        "mulligan_count": list(snapshot.get("mulligan_count", (0, 0))),
        "extra_draws": list(snapshot.get("extra_draws", (0, 0))),
        "setup_ready": [
            bool(value)
            for value in snapshot.get("setup_initial_done", (False, False))
        ],
        "setup_stage": str(snapshot.get("setup_stage", "TURN_ORDER")),
        "setup_actor_idx": int(snapshot.get("setup_actor_idx", -1)),
        "opening_coin_winner_idx": int(
            snapshot.get("opening_coin_winner_idx", -1)
        ),
        "mulligan_bonus_max": _godot_mulligan_bonus_max(snapshot),
        # This is an authoritative full-state fixture. These setup-only card
        # identities must never be reused in a player-view/network payload.
        "setup_bonus_card_ids": [
            list(row)
            for row in snapshot.get("setup_bonus_card_ids", ([], []))
        ],
        "pending_promotions": list(snapshot.get("pending_promotions", [])),
        "processed_action_ids": [],
        "resolution_stack": _json_value(snapshot.get("resolution_stack", {})),
        "turn_fact_book": _godot_turn_fact_book_payload(
            snapshot.get("turn_fact_book", {})
        ),
    }


def _state_summary(state: GameState) -> dict[str, Any]:
    payload = _state_payload(state)
    payload.pop("action_log", None)
    payload.pop("resolution_stack", None)
    payload.pop("setup_ready", None)
    payload.pop("processed_action_ids", None)
    return payload


_PENDING_KIND_ALIASES = {
    "search_deck": "search_move",
    "select_heal_target": "select_heal_target",
}

_CONTINUATION_KIND_ALIASES = {
    "search_cards": "search_move",
    "choose_heal_damage": "heal_target",
}


def _canonical_continuation_kind(value: Any) -> str:
    kind = str(value or "")
    return _CONTINUATION_KIND_ALIASES.get(kind, kind)


def _canonical_pending_option(option: dict[str, Any]) -> dict[str, Any]:
    ref = option.get("ref")
    if isinstance(ref, dict) and ref.get("kind"):
        kind = str(ref.get("kind", ""))
        result = {
            "kind": kind,
            "player": int(ref.get("player", -1)),
            "card_id": str(ref.get("card_id", "")),
        }
        if kind == "card":
            result["zone"] = str(ref.get("zone", ""))
            result["index"] = int(ref.get("index", -1))
        else:
            result["slot"] = str(ref.get("slot", ""))
        if kind == "attachment":
            result["attachment_type"] = str(ref.get("attachment_type", ""))
            result["index"] = int(ref.get("index", -1))
        stable_option_id = str(option.get("option_id", ""))
        if (
            stable_option_id.startswith("energy:")
            or stable_option_id.startswith("rare_candy:")
        ):
            result["option_id"] = stable_option_id
        return result

    value = option.get("value")
    if isinstance(value, dict):
        result = {
            "kind": "value",
            "card_id": str(value.get("card_id", "")),
            "slot": str(value.get("slot", "")),
        }
        return result
    return {"kind": "id", "option_id": str(option.get("option_id", ""))}


def _canonical_pending_request(request: dict[str, Any]) -> dict[str, Any]:
    metadata = request.get("metadata", {})
    continuation = metadata.get("continuation", {})
    continuation_kind = _canonical_continuation_kind(
        continuation.get("kind", "") if isinstance(continuation, dict) else ""
    )
    request_type = str(request.get("request_type", ""))
    if continuation_kind == "search_move":
        request_type = "search_move"
    elif continuation_kind == "heal_target":
        request_type = "select_heal_target"
    else:
        request_type = _PENDING_KIND_ALIASES.get(request_type, request_type)
    canonical_metadata: dict[str, Any] = {
        "continuation_kind": continuation_kind,
    }
    if metadata.get("finish_attack_actor") is not None:
        canonical_metadata["finish_attack_actor"] = int(
            metadata.get("finish_attack_actor")
        )
    return {
        "request_type": request_type,
        "player": int(request.get("player", -1)),
        "min_select": int(request.get("min_select", 0)),
        "max_select": int(request.get("max_select", 0)),
        "allow_duplicates": bool(request.get("allow_duplicates", False)),
        "can_cancel": bool(request.get("can_cancel", False)),
        "options": [
            _canonical_pending_option(option)
            for option in request.get("options", [])
            if isinstance(option, dict)
        ],
        "metadata": canonical_metadata,
    }


def _pending_trace(state: GameState) -> dict[str, Any]:
    stack = _json_value(getattr(state, "resolution_stack", {}) or {})
    request = stack.get("pending_request") or {}
    if not request:
        return {}
    result = _canonical_pending_request(request)
    result.update({
        "frame_kinds": [
            str(frame.get("kind", "")) for frame in stack.get("frames", [])
        ],
        "continuation_operations": [
            _canonical_continuation_kind(frame.get("operation", ""))
            for frame in stack.get("frames", [])
            if frame.get("kind") == "continuation"
        ],
    })
    return result


def _pokemon_energy_count(player: dict[str, Any]) -> int:
    pokemon = [player.get("active")] + list(player.get("bench", []))
    return sum(
        len(row.get("energy_card_ids", []))
        for row in pokemon
        if isinstance(row, dict)
    )


def _active_damage(player: dict[str, Any]) -> int:
    active = player.get("active")
    return int(active.get("damage_counters", 0)) if isinstance(active, dict) else 0


def _pokemon_by_slot(player: dict[str, Any]) -> dict[str, dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}
    active = player.get("active")
    if isinstance(active, dict):
        rows["active"] = active
    for index, pokemon in enumerate(player.get("bench", [])):
        if isinstance(pokemon, dict):
            rows[f"bench_{index}"] = pokemon
    return rows


def _healed_target_count(before: dict[str, Any], after: dict[str, Any]) -> int:
    before_rows = _pokemon_by_slot(before)
    after_rows = _pokemon_by_slot(after)
    return sum(
        int(after_rows[slot].get("damage_counters", 0))
        < int(before_row.get("damage_counters", 0))
        for slot, before_row in before_rows.items()
        if slot in after_rows
        and before_row.get("card_id") == after_rows[slot].get("card_id")
    )


def _new_status_count(before: dict[str, Any], after: dict[str, Any]) -> int:
    before_rows = _pokemon_by_slot(before)
    after_rows = _pokemon_by_slot(after)
    return sum(
        len(set(after_rows[slot].get("status_conditions", [])))
        - len(set(before_row.get("status_conditions", [])))
        for slot, before_row in before_rows.items()
        if slot in after_rows
        and before_row.get("card_id") == after_rows[slot].get("card_id")
    )


def _turn_transition_event_types(
    before: dict[str, Any],
    after: dict[str, Any],
) -> list[str]:
    if int(before.get("turn_number", 0)) == int(after.get("turn_number", 0)):
        return []
    events = ["turn_end", "checkup"]
    incoming = int(after.get("active_player_idx", 0))
    before_player = before["players"][incoming]
    after_player = after["players"][incoming]
    events.append("turn_start")
    if (
        len(after_player.get("deck", [])) < len(before_player.get("deck", []))
        and len(after_player.get("hand", [])) > len(before_player.get("hand", []))
    ):
        events.append("cards_drawn")
    return events


def _canonical_attack_presentation_order(events: list[str]) -> list[str]:
    """Keep rule settlement order separate from the attack presentation order."""
    declarations = [event for event in events if event == "attack_declared"]
    pre_hit = [event for event in events if event == "coin_flip"]
    hit_types = {
        "confusion_failed",
        "damage_counters_placed",
        "damage_dealt",
        "damage_prevented",
    }
    hit = [event for event in events if event in hit_types]
    knockouts = [event for event in events if event == "pokemon_ko"]
    leave_play = [event for event in events if event == "card_moved"]
    prizes = [event for event in events if event == "prize_taken"]
    reserved = {
        "attack_declared",
        "coin_flip",
        "pokemon_ko",
        "card_moved",
        "prize_taken",
        *hit_types,
    }
    post_hit: list[str] = []
    flow: list[str] = []
    reached_flow = False
    for event in events:
        if event in {"turn_end", "game_over"}:
            reached_flow = True
        if reached_flow:
            flow.append(event)
        elif event not in reserved:
            post_hit.append(event)
    # Ordinary attack effects resolve after the primary hit but before KO is
    # settled.  KO itself is a visible lifecycle: declaration, leave play,
    # then prize collection.
    return declarations + pre_hit + hit + post_hit + knockouts + leave_play + prizes + flow


def _canonical_transaction_event_types(
    before: dict[str, Any],
    state: GameState,
    operation: dict[str, Any],
) -> list[str]:
    """Normalize observable Python state transitions to the shared event vocabulary.

    Python's debug runtime still has a sparse UI event stream. Differential traces
    therefore derive this contract from the authoritative before/after state and
    operation, while retaining the raw StepResult event list separately.
    """
    after = _state_payload(state)
    before_players = before["players"]
    after_players = after["players"]
    actor = int(operation.get("actor", before.get("active_player_idx", 0)))
    kind = str(operation.get("kind", "action"))
    action_name = str(operation.get("action", ""))
    events: list[str] = []

    if kind == "choice":
        request_type = str(operation.get("request_type", ""))
        if request_type == "select_retreat_payment":
            if (
                _pokemon_energy_count(after_players[actor])
                < _pokemon_energy_count(before_players[actor])
            ):
                events.append("cards_discarded")
            before_active = before_players[actor].get("active")
            after_active = after_players[actor].get("active")
            if (
                isinstance(before_active, dict)
                and isinstance(after_active, dict)
                and before_active.get("card_id") != after_active.get("card_id")
            ):
                events.append("retreat")
        if request_type == "search_deck" and any(
            len(after_players[player_index].get("deck", []))
            < len(before_players[player_index].get("deck", []))
            for player_index in (0, 1)
        ):
            events.extend(["cards_selected", "deck_shuffled"])
        if any(
            _pokemon_energy_count(after_players[index])
            > _pokemon_energy_count(before_players[index])
            for index in (0, 1)
        ):
            events.append("energy_attached")
        if request_type == "distribute_energy":
            events.append("deck_shuffled")
        opponent = 1 - actor
        if (
            _active_damage(after_players[opponent])
            > _active_damage(before_players[opponent])
            or (
                before_players[opponent].get("active") is not None
                and after_players[opponent].get("active") is None
            )
        ):
            events.append("damage_dealt")
        for _index in range(sum(
            _healed_target_count(before_players[player_index], after_players[player_index])
            for player_index in (0, 1)
        )):
            events.append("healed")
        for _index in range(sum(
            _new_status_count(before_players[player_index], after_players[player_index])
            for player_index in (0, 1)
        )):
            events.append("status_applied")
    elif action_name == "PLAY_BASIC":
        events.append("pokemon_played")
    elif action_name == "EVOLVE":
        events.append("pokemon_evolved")
    elif action_name == "ATTACH_ENERGY":
        events.append("energy_attached")
    elif action_name == "RETREAT":
        before_active = before_players[actor].get("active")
        after_active = after_players[actor].get("active")
        if (
            isinstance(before_active, dict)
            and isinstance(after_active, dict)
            and before_active.get("card_id") != after_active.get("card_id")
        ):
            if (
                _pokemon_energy_count(after_players[actor])
                < _pokemon_energy_count(before_players[actor])
            ):
                events.append("cards_discarded")
            events.append("retreat")
    elif action_name == "PROMOTE":
        events.append("promoted")
    elif action_name == "PLAY_TRAINER":
        hand_idx = int(operation.get("params", {}).get("hand_idx", -1))
        before_hand = before_players[actor].get("hand", [])
        card_id = before_hand[hand_idx] if 0 <= hand_idx < len(before_hand) else ""
        card = CardRegistry.get(card_id)
        if card is not None and card.is_trainer_tool:
            events.append("tool_attached")
        elif card is not None and card.is_trainer_stadium:
            events.append("stadium_changed")
        else:
            events.append("trainer_played")
        compiled_ops = {
            str(effect.get("op", ""))
            for effect in getattr(card, "compiled_trainer_effects", [])
            if isinstance(effect, dict)
        } if card is not None else set()
        if "shuffle_then_draw_cards" in compiled_ops:
            events.append("card_moved")
            events.append("deck_shuffled")
    elif action_name == "DECLARE_ATTACK":
        events.append("attack_declared")
        before_active = before_players[actor].get("active") or {}
        after_active = after_players[actor].get("active") or {}
        confused_failure = (
            "CONFUSED" in before_active.get("status_conditions", [])
            and int(after_active.get("damage_counters", 0))
            > int(before_active.get("damage_counters", 0))
        )
        if confused_failure:
            events.extend(["coin_flip", "confusion_failed"])
        else:
            for _index in range(sum(
                _healed_target_count(
                    before_players[player_index], after_players[player_index]
                )
                for player_index in (0, 1)
            )):
                events.append("healed")
            for _index in range(sum(
                _new_status_count(
                    before_players[player_index], after_players[player_index]
                )
                for player_index in (0, 1)
            )):
                events.append("status_applied")
            opponent = 1 - actor
            if (
                _active_damage(after_players[opponent])
                > _active_damage(before_players[opponent])
                or (
                    before_players[opponent].get("active") is not None
                    and after_players[opponent].get("active") is None
                )
            ):
                events.append("damage_dealt")
            if (
                _pokemon_energy_count(after_players[actor])
                < _pokemon_energy_count(before_players[actor])
                and len(after_players[actor].get("discard", []))
                > len(before_players[actor].get("discard", []))
            ):
                events.append("cards_discarded")

    if kind == "action" and action_name not in {"DECLARE_ATTACK"}:
        for _index in range(sum(
            _healed_target_count(before_players[player_index], after_players[player_index])
            for player_index in (0, 1)
        )):
            events.append("healed")
        for _index in range(sum(
            _new_status_count(before_players[player_index], after_players[player_index])
            for player_index in (0, 1)
        )):
            events.append("status_applied")
        damage_increased = any(
            _active_damage(after_players[player_index])
            > _active_damage(before_players[player_index])
            for player_index in (0, 1)
        )
        if damage_increased:
            events.append("damage_dealt")

    for player_index in (0, 1):
        if len(after_players[player_index].get("prizes", [])) < len(
            before_players[player_index].get("prizes", [])
        ):
            events.append("prize_taken")
    for player_index in (0, 1):
        if (
            before_players[player_index].get("active") is not None
            and after_players[player_index].get("active") is None
            and len(after_players[player_index].get("discard", []))
            > len(before_players[player_index].get("discard", []))
        ):
            events.extend(["pokemon_ko", "card_moved"])

    if int(before.get("turn_number", 0)) == int(after.get("turn_number", 0)):
        for player_index in (0, 1):
            if (
                len(after_players[player_index].get("deck", []))
                < len(before_players[player_index].get("deck", []))
                and len(after_players[player_index].get("hand", []))
                > len(before_players[player_index].get("hand", []))
            ):
                events.append("cards_drawn")
                break
    events.extend(_turn_transition_event_types(before, after))
    before_winner = int(before.get("winner", -1))
    after_winner = int(after.get("winner", -1))
    if before_winner not in (0, 1) and after_winner in (0, 1):
        # Terminal settlement is observable only after the complete KO/prize
        # batch. The attack presentation normalizer keeps it after prizes.
        events.append("game_over")
    if (
        action_name == "DECLARE_ATTACK"
        or (kind == "choice" and bool(operation.get("finish_attack", False)))
    ):
        return _canonical_attack_presentation_order(events)
    return events


def _trace_step(
    state: GameState,
    rng: PortableRandomSourceV1,
    result,
    *,
    kind: str,
    index: int,
    before: dict[str, Any],
    operation: dict[str, Any],
) -> dict[str, Any]:
    """Capture the cross-runtime contract after one public API transaction."""
    return {
        "kind": kind,
        "index": index,
        "expected": _state_summary(state),
        "pending": _pending_trace(state),
        "event_types": _canonical_transaction_event_types(before, state, operation),
        "python_step_event_types": [
            str(event.get("event_type", "")) for event in result.events
        ],
        "rng_state": rng.get_state(),
    }


def _resolve_action_name(action_name: str) -> PlayerAction | str:
    return PlayerAction.__members__.get(action_name, action_name)


def _run_golden_actions(
    engine: GameEngine,
    state: GameState,
    actions: list[dict[str, Any]],
    *,
    portable_seed: int,
) -> tuple[list[dict[str, Any]], PortableRandomSourceV1]:
    rng = PortableRandomSourceV1(portable_seed)
    trace: list[dict[str, Any]] = []
    for index, row in enumerate(actions):
        before = _state_payload(state)
        result = engine.apply_action(
            state,
            GameAction(
                _resolve_action_name(str(row["action"])),
                dict(row.get("params", {})),
                actor=int(row.get("actor", -1)),
            ),
            rng,
            auto_resolve=False,
        )
        if not result.success:
            raise RuntimeError(f"Golden action failed: {row}: {result.message}")
        trace.append(_trace_step(
            state,
            rng,
            result,
            kind="action",
            index=index,
            before=before,
            operation={"kind": "action", **row},
        ))
    return trace, rng


def _base_golden_state() -> GameState:
    psychic = CardRegistry.get("sv1-ener-5")
    state = GameState()
    state.phase = TurnPhase.MAIN
    state.turn_number = 2
    state.first_player_idx = 1
    state.active_player_idx = 0
    state.p1.active = PokemonInPlay(CardRegistry.get("sv1-104"), placed_this_turn=False)
    state.p2.active = PokemonInPlay(CardRegistry.get("sv1-104"), placed_this_turn=False)
    state.p1.deck = [psychic] * 4
    state.p2.deck = [psychic] * 4
    state.p1.prizes = [psychic] * 6
    state.p2.prizes = [psychic] * 6
    return state


_VM_SEMANTIC_RUNTIME_SPECS: dict[str, dict[str, Any]] = {
    # These operations are intentionally registered for runtime compatibility
    # even though release effect compilation lowers the corresponding printed
    # effect to a generic formula node.  Keep one real direct-VM specimen for
    # every such descriptor so registry coverage cannot be confused with
    # execution coverage.
    "deal_damage_per_discard_psychic": {
        "base": 80,
        "per_card": 10,
    },
    "deal_damage_per_energy": {
        "base": 0,
        "per_energy": 30,
        "count_from": "opponent_active",
        "target": "opponent_active",
    },
    "deal_damage_per_evolved": {"per_evolved": 50},
    "deal_damage_per_hand_size": {"per": 20},
    "deal_damage_per_self_damage": {"base": 60, "per_counter": 10},
    "deal_damage_per_self_energy": {
        "base": 60,
        "per_energy": 20,
        "energy_filter": "fire",
    },
    "deal_damage_per_self_energy_type": {
        "base": 60,
        "per_energy": 20,
        "energy_type": "Grass",
    },
    "deal_damage_plus_bench": {
        "base": 10,
        "per_bench": 20,
        "count_own_bench": True,
    },
    "deal_damage_with_self_penalty": {"base": 200, "per_counter": 20},
    "set_attack_damage_formula": {
        "base": 100,
        "condition_bonus": {
            "condition": "own_bench_damaged",
            "bonus": 120,
            "consume": False,
        },
    },
    "trigger_draw_cards": {
        "player": 0,
        "amount": 1,
        "source": "vm-golden",
    },
    "trigger_place_damage_counters": {
        "player": 1,
        "slot": "active",
        "count": 2,
        "source": "vm-golden",
        "target_ref": {
            "kind": "pokemon",
            "player": 1,
            "slot": "active",
            "card_id": "sv1-104",
        },
    },
    "trigger_move_basic_energy": {
        "from_player": 0,
        "from_slot": "active",
        "to_player": 0,
        "to_slot": "bench_0",
        "source": "vm-golden",
        "select_source": False,
        "optional": False,
    },
    "trigger_switch_with_active": {
        "player": 0,
        "bench_idx": 0,
        "source": "vm-golden",
        "slot": "bench_0",
    },
}

_VM_SEMANTIC_MODIFIER_KINDS = {
    "register_aura_damage_boost": "aura_damage_boost",
    "register_aura_damage_reduction": "aura_damage_reduction",
    "register_conditional_hp_boost": "conditional_hp_boost",
    "register_conditional_zero_retreat": "conditional_zero_retreat",
    "register_reactive_thorns": "reactive_thorns",
    "register_tool_exp_share": "tool_exp_share",
    "register_tool_modifier": "tool",
}

_VM_SEMANTIC_PARITY_ALLOWLIST: dict[str, dict[str, str]] = {
    "attach_energy_from_discard": {
        "pending": (
            "Python publishes one source-target distribution request while "
            "Godot first selects concrete discard attachments and then targets; "
            "both are authoritative, bounded continuations but their first "
            "pending envelopes are intentionally different until the shared "
            "multi-round choice manifest replaces the legacy Python shape."
        ),
    },
}

_VM_SEMANTIC_CHOICE_TOPOLOGY_GAPS = frozenset({
    "attach_energy_from_discard",
})

_VM_SEMANTIC_CHOICE_EVENT_TYPES: dict[tuple[str, int], list[str]] = {
    ("choose_damage_target", 0): ["damage_dealt"],
    ("choose_heal_damage", 0): ["healed"],
    ("conditional", 0): ["cards_discarded"],
    ("conditional", 1): ["cards_selected", "deck_shuffled"],
    ("conditional_search", 0): ["cards_selected", "deck_shuffled"],
    ("discard_cards", 0): ["cards_discarded"],
    ("discard_energy", 0): ["cards_discarded"],
    ("draw_and_attach_energy", 0): ["energy_attached", "energy_attached"],
    ("evolve_skip_stage", 0): ["pokemon_evolved"],
    # The coin continuation only updates the suspended attack's accumulated
    # damage.  ``damage_dealt`` is emitted by the later attack-damage barrier.
    ("flip_coin_repeat_damage", 0): ["coin_flip"],
    ("flip_coin_then_ko", 0): [
        "coin_flip",
        "direct_knockout_applied",
        "pokemon_ko",
        "card_moved",
    ],
    ("flip_coin_then_ko", 1): ["prize_taken"],
    ("hand_to_bottom_draw_until", 0): ["cards_selected"],
    ("hand_to_bottom_then_draw", 0): ["cards_selected", "cards_drawn"],
    ("look_top_attach_energy", 0): ["cards_selected"],
    ("look_top_attach_energy", 1): [
        "energy_attached",
        "energy_attached",
        "energy_attached",
        "deck_shuffled",
    ],
    ("look_top_deck", 0): ["cards_selected", "deck_shuffled"],
    ("place_counters_then_self_discard", 0): [
        "damage_counters_placed",
        "cards_discarded",
    ],
    ("recover_clara", 0): ["cards_selected"],
    ("relocate_energy", 1): ["energy_attached"],
    ("search_any_and_switch", 0): ["cards_selected", "deck_shuffled"],
    ("search_any_and_switch", 2): ["switched"],
    ("search_cards", 0): ["card_moved", "card_moved", "deck_shuffled"],
    ("search_item_and_tool", 0): ["cards_selected", "deck_shuffled"],
    ("shuffle_from_discard_to_deck", 0): ["card_moved", "deck_shuffled"],
    ("switch_pokemon", 0): ["switched"],
    ("zinnia_resolve", 0): ["cards_discarded", "cards_drawn"],
}


def _vm_semantic_command_specs() -> dict[str, dict[str, Any]]:
    """Return one JSON-safe, executable command spec per native VM op."""
    specs: dict[str, dict[str, Any]] = {}
    examples = _effect_examples(CARD_EFFECTS)
    for effect_type in sorted(examples):
        spec = compile_effect_to_spec(examples[effect_type])
        specs.setdefault(spec.op, spec.to_dict())
    for op, args in _VM_SEMANTIC_RUNTIME_SPECS.items():
        specs[op] = {
            "op": op,
            "args": _json_value(args),
            "branches": {},
        }
    registered = set(DEFAULT_COMMAND_REGISTRY.supported_ops)
    if set(specs) != registered:
        raise RuntimeError(
            "VM semantic specs must cover every registered op exactly once; "
            f"missing={sorted(registered - set(specs))} "
            f"extra={sorted(set(specs) - registered)}"
        )
    return {op: specs[op] for op in sorted(specs)}


def _vm_semantic_state(variant: str = "rich") -> GameState:
    """Build a deterministic board that exercises direct VM primitives.

    The fixture deliberately contains damaged/evolved Pokemon, basic energy,
    tools, and searchable cards in every relevant zone.  Two small variants
    satisfy printed preconditions which are mutually exclusive with the rich
    hand: Rare Candy and Emergency Surfacing.
    """
    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 1
    state.active_player_idx = 0
    state.p1.active.damage_counters = 2
    state.p2.active.damage_counters = 2
    state.p1.active.energy_cards = [
        CardRegistry.get("sv1-ener-2"),
        CardRegistry.get("sv1-ener-5"),
        CardRegistry.get("sv1-ener-6"),
    ]
    state.p2.active.energy_cards = [
        CardRegistry.get("sv1-ener-2"),
        CardRegistry.get("sv1-ener-5"),
    ]
    state.p1.active.attached_tool = CardRegistry.get("sv1-201")
    state.p2.active.attached_tool = CardRegistry.get("sv1-202")
    state.p1.bench[0] = PokemonInPlay(
        CardRegistry.get("sv2-38"),
        damage_counters=1,
        energy_cards=[CardRegistry.get("sv1-ener-5")],
        placed_this_turn=False,
    )
    state.p1.bench[1] = PokemonInPlay(
        CardRegistry.get("sv1-106"),
        damage_counters=1,
        energy_cards=[CardRegistry.get("sv1-ener-6")],
        evolution_stack=[CardRegistry.get("sv1-104")],
        placed_this_turn=False,
    )
    state.p2.bench[0] = PokemonInPlay(
        CardRegistry.get("sv2-38"),
        damage_counters=1,
        energy_cards=[CardRegistry.get("sv1-ener-3")],
        placed_this_turn=False,
    )
    state.p2.bench[1] = PokemonInPlay(
        CardRegistry.get("sv1-106"),
        damage_counters=1,
        energy_cards=[CardRegistry.get("sv1-ener-5")],
        evolution_stack=[CardRegistry.get("sv1-104")],
        placed_this_turn=False,
    )

    hand_ids = [
        "sv1-104",
        "sv1-106",
        "sv1-150",
        "sv1-151",
        "sv1-201",
        "sv1-ener-5",
        "sv1-ener-6",
    ]
    # The end of a Python deck is its top.  Keep the top window deliberately
    # diverse so draw/mill/look-top operations all perform observable work.
    deck_ids = [
        "sv1-104",
        "sv1-106",
        "sv1-150",
        "sv1-151",
        "sv1-201",
        "sv1-ener-6",
        "svf-scyt",
        "sv2-38",
        "sv1-ener-3",
        "sv1-ener-1",
        "sv1-ener-1",
    ]
    state.p1.hand = [CardRegistry.get(card_id) for card_id in hand_ids]
    state.p2.hand = [
        CardRegistry.get(card_id)
        for card_id in [
            "sv1-150",
            "sv1-151",
            "sv1-201",
            "sv1-ener-5",
            "sv2-38",
            "sv1-104",
        ]
    ]
    state.p1.deck = [CardRegistry.get(card_id) for card_id in deck_ids * 2]
    state.p2.deck = [CardRegistry.get(card_id) for card_id in reversed(deck_ids * 2)]
    state.p1.discard = [
        CardRegistry.get(card_id)
        for card_id in [
            "sv1-ener-1",
            "sv1-ener-5",
            "sv1-ener-6",
            "sv1-104",
            "svg2-empo",
            "sv1-201",
        ]
    ]
    state.p2.discard = [
        CardRegistry.get("sv1-ener-5"),
        CardRegistry.get("sv1-104"),
        CardRegistry.get("sv1-202"),
    ]
    state.p1.prizes = [CardRegistry.get("sv1-ener-5")] * 6
    state.p2.prizes = [CardRegistry.get("sv1-ener-5")] * 6
    state.p1.was_ko_by_attack = True
    state.p1.was_ko_last_turn = True

    if variant == "rare_candy":
        state.p1.hand.append(CardRegistry.get("sv2-grex"))
    elif variant == "empty_hand":
        state.p1.hand = []
    elif variant != "rich":
        raise ValueError(f"Unknown VM semantic state variant: {variant}")
    return state


def _vm_state_projection(state: GameState) -> dict[str, Any]:
    """Canonical state projection, excluding runtime-specific hook storage."""
    payload = _state_summary(state)
    for player in payload.get("players", []):
        rows = [player.get("active"), *player.get("bench", [])]
        for pokemon in rows:
            if isinstance(pokemon, dict):
                # Python retains callback-backed hooks in EventBus while Godot
                # serializes the equivalent descriptor on PokemonState.  A
                # separate modifier probe below compares their semantics.
                pokemon.pop("modifiers", None)
    return payload


def _vm_pending_projection(state: GameState, op: str) -> dict[str, Any]:
    pending = _pending_trace(state)
    if not pending:
        return {}
    metadata = pending.get("metadata", {})
    continuation_kind = str(metadata.get("continuation_kind", ""))
    continuation_kind = {
        "choose_damage_target": "damage_target",
        "discard_hand_cards": "discard_cards",
        "flip_coin_branch": "coin",
        "coin_energy_discard": "coin",
        "coin_special": "coin",
        "hand_to_bottom_draw_until": "houb",
        "hand_to_bottom_then_draw": "hand_bottom_draw",
        "look_top_deck": "look_top",
        "place_counters_then_self_discard": "place_counters_self_discard",
        "recover_clara": "clara",
        "recover_from_discard_to_deck": "shuffle_from_discard",
        "search_any_and_switch": "search_any_switch",
        "search_item_and_tool": "arven",
        "switch_bench": "switch",
        "zinnia_resolve": "zinnia",
    }.get(continuation_kind, continuation_kind)
    request_type = str(pending.get("request_type", ""))
    request_type = {
        "damage_target": "damage_target",
        "discard_cards": "discard_cards",
        "houb": "houb",
        "hand_bottom_draw": "hand_bottom_draw",
        "look_top_attach_energy": "look_top_attach_energy",
        "look_top": "look_top",
        "place_counters_self_discard": "place_counters_self_discard",
        "clara": "clara",
        "search_any_switch": "search_any_switch",
        "arven": "arven",
        "shuffle_from_discard": "shuffle_from_discard",
        "switch": "select_opponent_bench",
        "zinnia": "zinnia",
    }.get(continuation_kind, request_type)
    options = list(pending.get("options", []))
    allow_duplicates = bool(pending.get("allow_duplicates", False))
    if continuation_kind == "look_top_attach_target":
        request_type = "select_energy_target"
    elif continuation_kind == "energy_relocate_distribution":
        continuation_kind = "energy_relocate_target"
        request_type = "select_energy_target"
        allow_duplicates = False
    if op == "draw_and_attach_energy":
        continuation_kind = "draw_attach_distribution"
    return {
        "request_type": request_type,
        "player": int(pending.get("player", -1)),
        "min_select": int(pending.get("min_select", 0)),
        "max_select": int(pending.get("max_select", 0)),
        "allow_duplicates": allow_duplicates,
        "can_cancel": bool(pending.get("can_cancel", False)),
        "options": options,
        "continuation_kind": continuation_kind,
    }


def _vm_context_projection(context: dict[str, Any]) -> dict[str, Any]:
    attack = context.get("attack_damage", {})
    if not isinstance(attack, dict):
        attack = {}
    if not attack:
        attack = context
    result: dict[str, Any] = {}
    for key in (
        "base_damage",
        "ignore_weakness",
        "ignore_resistance",
        "ignore_defender_damage_effects",
        "attack_failed",
    ):
        if key in attack:
            value = _json_value(attack[key])
            if key.startswith("ignore_") and value is False:
                continue
            result[key] = value
    return result


def _vm_modifier_probe(
    state: GameState,
    op: str,
    args: dict[str, Any],
) -> dict[str, Any]:
    modifier_kind = _VM_SEMANTIC_MODIFIER_KINDS.get(op, "")
    if not modifier_kind:
        return {}
    # Reactive thorns and Exp. Share are authoritative trigger descriptors,
    # not continuous modifiers.  Keep the golden probe explicit so the two
    # registries cannot silently collapse back into one another.
    if modifier_kind in {"reactive_thorns", "tool_exp_share"}:
        return {"registered": False}
    pokemon = state.p1.active
    registered = False
    if modifier_kind == "conditional_hp_boost":
        registered = any(
            row.get("modifier_kind") == modifier_kind
            for row in pokemon.max_hp_modifiers
        )
    else:
        listeners = [
            listener
            for rows in state.event_bus._listeners.values()
            for listener in rows
            if listener.active
        ]
        registered = bool(listeners)
    if not registered:
        raise RuntimeError(f"VM modifier op did not register a hook: {op}")
    return {
        "registered": True,
        "modifier_kind": modifier_kind,
        "player": 0,
        "slot": "active",
        "card_id": str(pokemon.card.api_id),
        "params": _json_value(args),
    }


def _vm_semantic_event_types(
    before: dict[str, Any],
    after: dict[str, Any],
    op: str,
) -> list[str]:
    """Derive the same public event vocabulary used by Godot VM handlers."""
    events: list[str] = []
    before_players = before.get("players", [])
    after_players = after.get("players", [])
    for player_idx in range(min(len(before_players), len(after_players))):
        before_rows = _pokemon_by_slot(before_players[player_idx])
        after_rows = _pokemon_by_slot(after_players[player_idx])
        for slot, before_pokemon in before_rows.items():
            after_pokemon = after_rows.get(slot)
            if not isinstance(after_pokemon, dict):
                continue
            if before_pokemon.get("card_id") != after_pokemon.get("card_id"):
                continue
            before_damage = int(before_pokemon.get("damage_counters", 0))
            after_damage = int(after_pokemon.get("damage_counters", 0))
            if after_damage > before_damage:
                events.append(
                    "damage_counters_placed"
                    if op in {
                        "place_damage_counters",
                        "trigger_place_damage_counters",
                    }
                    else "damage_dealt"
                )
            elif after_damage < before_damage:
                events.append("healed")
            new_statuses = set(after_pokemon.get("status_conditions", [])) - set(
                before_pokemon.get("status_conditions", [])
            )
            events.extend("status_applied" for _status in sorted(new_statuses))
    if op in {"draw_cards", "trigger_draw_cards"}:
        if any(
            len(after_players[index].get("hand", []))
            > len(before_players[index].get("hand", []))
            for index in range(min(len(before_players), len(after_players)))
        ):
            events.append("cards_drawn")
    if op == "attach_energy":
        before_energy = _pokemon_energy_count(before_players[0])
        after_energy = _pokemon_energy_count(after_players[0])
        events.extend("energy_attached" for _index in range(
            max(0, after_energy - before_energy)
        ))
        if after_energy > before_energy:
            events.append("deck_shuffled")
    if op in {"draw_and_attach_energy", "discard_then_revive"}:
        if len(after_players[0].get("hand", [])) > len(
            before_players[0].get("hand", [])
        ):
            events.append("cards_drawn")
    if op == "deal_damage_then_heal":
        events.sort(key=lambda event: 0 if event == "damage_dealt" else 1)
    if op in {"discard_energy_then_damage", "discard_hand_then_damage"}:
        events.insert(0, "cards_discarded")
    if op == "discard_then_draw_cards":
        events = ["cards_discarded", "cards_drawn"]
    if op == "discard_then_revive":
        events.insert(0, "card_moved")
    if op == "judge":
        events = [
            "card_moved",
            "deck_shuffled",
            "cards_drawn",
            "card_moved",
            "deck_shuffled",
            "cards_drawn",
        ]
    if op == "mill_then_damage":
        events = ["cards_revealed", "deck_shuffled", *events]
    if op == "return_to_hand":
        events.append("card_moved")
    if op == "shuffle_then_draw_cards":
        events = ["card_moved", "deck_shuffled", "cards_drawn"]
    if op == "trigger_move_basic_energy":
        events.append("energy_attached")
    if op == "trigger_switch_with_active":
        events.append("switched")
    return events


def _vm_semantic_choice_response(request: ChoiceRequest) -> ChoiceResponse:
    """Return a deterministic, non-cancelling response without consuming RNG."""
    if request.request_type == "coin_flip":
        return ChoiceResponse(request.request_id, ())
    if request.request_type == "distribute_energy" and request.options:
        count = max(request.min_select, request.max_select)
        max_per_target = int(request.metadata.get("max_per_target", 99) or 99)
        selected_ids: list[str] = []
        seen_energy: set[int] = set()
        per_target: dict[str, int] = {}
        for option in request.options:
            value = option.value if isinstance(option.value, dict) else {}
            energy_index = int(value.get("energy_index", len(seen_energy)))
            slot = str(value.get("slot", "") or "")
            if (
                energy_index in seen_energy
                or per_target.get(slot, 0) >= max_per_target
            ):
                continue
            selected_ids.append(option.option_id)
            seen_energy.add(energy_index)
            per_target[slot] = per_target.get(slot, 0) + 1
            if len(selected_ids) >= count:
                break
        return ChoiceResponse(request.request_id, tuple(selected_ids))
    count = min(
        len(request.options),
        max(request.min_select, min(request.max_select, len(request.options))),
    )
    return ChoiceResponse(
        request.request_id,
        tuple(option.option_id for option in request.options[:count]),
    )


def _vm_semantic_choice_event_types(
    op: str,
    choice_index: int,
    emitted_events: tuple[dict[str, Any], ...],
) -> list[str]:
    """Canonicalize legacy Python continuation events to the public VM set."""
    explicit = _VM_SEMANTIC_CHOICE_EVENT_TYPES.get((op, choice_index))
    if explicit is not None:
        return list(explicit)
    return [str(event.get("event_type", "")) for event in emitted_events]


def _vm_semantic_golden_fixture() -> dict[str, Any]:
    """Execute every native Python VM command and export its replay oracle."""
    from engine.choice_manager import VMChoiceManager
    from engine.commands.attack_frames import (
        begin_attack_damage_context,
        begin_attack_resolution_context,
    )
    from engine.commands.dsl_compiler import compile_command_spec
    from engine.commands.resolution_stack import ResolutionStack
    from engine.transaction_manager import VMTransactionManager

    specs = _vm_semantic_command_specs()
    descriptor_payload = descriptor_export_payload(VM_IR_VERSION)
    cases: dict[str, Any] = {}
    choice_manager = VMChoiceManager()
    transaction_manager = VMTransactionManager()
    game_engine = GameEngine(
        transaction_manager=transaction_manager,
        choice_manager=choice_manager,
    )
    for index, (op, spec) in enumerate(specs.items()):
        variant = (
            "rare_candy" if op == "evolve_skip_stage"
            else "empty_hand" if op == "discard_then_revive"
            else "rich"
        )
        state = _vm_semantic_state(variant)
        initial_state = _state_payload(state)
        before = _vm_state_projection(state)
        seed = 1701 + index
        rng = PortableRandomSourceV1(seed)
        state.random_source = rng
        state.p1.random_source = rng
        state.p2.random_source = rng
        stack = ResolutionStack(state)
        allowed_contexts: set[str] | None = None
        for nested_spec in iter_command_specs(spec):
            nested_op = str(nested_spec.get("op", "") or "")
            nested_contexts = set(
                descriptor_payload["descriptors"][nested_op]["allowed_contexts"]
            )
            allowed_contexts = (
                nested_contexts
                if allowed_contexts is None
                else allowed_contexts & nested_contexts
            )
        allowed_contexts = allowed_contexts or set()
        # Execute each golden in a context that its frozen descriptor actually
        # permits.  Treating every non-attack command as an ability used to
        # make trainer-only commands pass Python generation but fail closed in
        # the Godot interpreter.
        if "attack" in allowed_contexts and "ability" not in allowed_contexts:
            context_mode = "attack"
        elif "ability" in allowed_contexts:
            context_mode = "ability"
        elif "trainer" in allowed_contexts:
            context_mode = "trainer"
        elif "trigger" in allowed_contexts:
            context_mode = "trigger"
        elif "test" in allowed_contexts:
            context_mode = "test"
        else:
            raise RuntimeError(f"VM semantic case has no executable context: {op}")
        if context_mode == "attack":
            begin_attack_damage_context(
                state,
                stack,
                {
                    "active": True,
                    "player_idx": 0,
                    "base_damage": 30,
                },
            )
            begin_attack_resolution_context(stack, 0)
        elif context_mode in {"ability", "trainer"}:
            stack.context["effect_source_kind"] = context_mode
        stack.push(compile_command_spec(spec))
        result = stack.resolve_all(0, "active")
        if not result.success:
            raise RuntimeError(
                f"VM semantic command failed instead of executing: {op}: "
                f"{' '.join(result.log_messages)}"
            )
        if result.pending_choice is not None:
            request = game_engine.choice_request(state, result.pending_choice)
        else:
            request = None
        after = _vm_state_projection(state)
        context_projection = _vm_context_projection(stack.context)
        if result.attack_failed:
            context_projection["attack_failed"] = True
        primary_expected = {
            "success": True,
            "error_code": "",
            "revision": int(state.revision),
            "rng_state": int(rng.get_state()),
            "event_types": _vm_semantic_event_types(before, after, op),
            "pending": _vm_pending_projection(state, op),
            "state": after,
            "context": context_projection,
            "modifier": _vm_modifier_probe(
                state,
                op,
                dict(spec.get("args", {})),
            ),
        }
        choice_trace: list[dict[str, Any]] = []
        # The sole allowlisted first-envelope mismatch cannot share a response
        # manifest yet: Python combines source+target in one request while
        # Godot intentionally uses two bounded requests.  Every other pending
        # native op is resumed to completion below, including two/three-round
        # continuations, using the same deterministic maximal-first policy.
        if request is not None and op not in _VM_SEMANTIC_CHOICE_TOPOLOGY_GAPS:
            for choice_index in range(64):
                if request is None:
                    break
                pending_before = _vm_pending_projection(state, op)
                request_payload = transaction_manager.choice_request_to_dict(request)
                response = _vm_semantic_choice_response(request)
                known_ids = {
                    str(option.option_id) for option in request.options
                }
                unknown_ids = set(response.option_ids) - known_ids
                if unknown_ids:
                    raise RuntimeError(
                        f"VM semantic choice policy selected an unknown option: "
                        f"{op}[{choice_index}]: {sorted(unknown_ids)}"
                    )
                serialized_option_by_id = {
                    str(option.get("option_id", "")): option
                    for option in request_payload.get("options", [])
                }
                selected_options = [
                    _canonical_pending_option(
                        serialized_option_by_id[str(option_id)]
                    )
                    for option_id in response.option_ids
                ]
                choice_result = game_engine.apply_choice(state, response, rng)
                if not choice_result.success:
                    raise RuntimeError(
                        f"VM semantic choice failed instead of executing: "
                        f"{op}[{choice_index}]: {choice_result.error_code}: "
                        f"{choice_result.message}"
                    )
                request = game_engine.pending_choice_request(state)
                choice_after = _vm_state_projection(state)
                choice_context = _vm_context_projection(stack.context)
                if stack.attack_failed:
                    choice_context["attack_failed"] = True
                choice_trace.append({
                    "request": pending_before,
                    "response": {
                        "selected_options": selected_options,
                        "cancelled": False,
                    },
                    "expected": {
                        "success": True,
                        "error_code": "",
                        "revision": int(state.revision),
                        "rng_state": int(rng.get_state()),
                        "event_types": _vm_semantic_choice_event_types(
                            op,
                            choice_index,
                            choice_result.events,
                        ),
                        "pending": _vm_pending_projection(state, op),
                        "state": choice_after,
                        "context": choice_context,
                        "modifier": _vm_modifier_probe(
                            state,
                            op,
                            dict(spec.get("args", {})),
                        ),
                    },
                })
            if request is not None:
                raise RuntimeError(
                    f"VM semantic choice chain exceeded 64 rounds: {op}"
                )
        cases[op] = {
            "descriptor": descriptor_payload["descriptors"][op],
            "command_spec": spec,
            "actor": 0,
            "source_slot": "active",
            "context_mode": context_mode,
            "portable_seed": seed,
            "initial_state": initial_state,
            "expected": primary_expected,
            "parity_allowlist": dict(
                _VM_SEMANTIC_PARITY_ALLOWLIST.get(op, {})
            ),
            "choice_trace": choice_trace,
        }
    registered = sorted(DEFAULT_COMMAND_REGISTRY.supported_ops)
    executed = sorted(cases)
    if executed != registered:
        raise RuntimeError("Generated VM semantic cases differ from registry")
    return {
        "fixture_version": 2,
        "vm_ir_version": VM_IR_VERSION,
        "rng_algorithm": "xorshift32-v1",
        "contract": {
            "name": "native-vm-semantic-parity-v2",
            "fields": [
                "success",
                "error_code",
                "revision",
                "rng_state",
                "event_types",
                "pending",
                "state",
                "context",
                "modifier",
            ],
            "choice_fields": [
                "success",
                "error_code",
                "revision",
                "rng_state",
                "event_types",
                "pending",
                "state",
                "context",
                "modifier",
            ],
            "choice_policy": "deterministic-maximal-first-v1",
            "execution": (
                "compile_command_spec+ResolutionStack+deterministic-choice-loop"
            ),
        },
        "registered_ops": registered,
        "executed_ops": executed,
        "known_cross_runtime_semantic_gaps": [
            {
                "op": op,
                "field": field,
                "reason": reason,
            }
            for op, fields in sorted(_VM_SEMANTIC_PARITY_ALLOWLIST.items())
            for field, reason in sorted(fields.items())
        ],
        "cases": cases,
        "counts": {
            "registered_ops": len(registered),
            "executed_ops": len(executed),
            "successful_ops": sum(
                bool(row["expected"]["success"]) for row in cases.values()
            ),
            "pending_ops": sum(
                bool(row["expected"]["pending"]) for row in cases.values()
            ),
            "continued_ops": sum(
                bool(row["choice_trace"]) for row in cases.values()
            ),
            "choice_rounds": sum(
                len(row["choice_trace"]) for row in cases.values()
            ),
        },
    }


def _pending_choice_case(
    engine: GameEngine,
    state: GameState,
    actions: list[dict[str, Any]],
    *,
    selected_option_ids: tuple[str, ...] = (),
    cancel_choice: bool = False,
    followup_actions: tuple[dict[str, Any], ...] = (),
    portable_seed: int = 700,
) -> dict[str, Any]:
    """Execute one public-action sequence followed by exactly one choice.

    This keeps pending-choice fixtures on the same public APIs used by clients:
    both the paused transaction and the resumed transaction are captured, and
    the response is validated against the authoritative request before export.
    """
    rng = PortableRandomSourceV1(portable_seed)
    initial = _state_payload(state)
    trace: list[dict[str, Any]] = []
    step = None
    for action_index, action_row in enumerate(actions):
        before_action = _state_payload(state)
        step = engine.apply_action(
            state,
            GameAction(
                _resolve_action_name(str(action_row["action"])),
                dict(action_row.get("params", {})),
                actor=int(action_row.get("actor", -1)),
            ),
            rng,
            auto_resolve=False,
        )
        if not step.success:
            raise RuntimeError(
                f"Golden pending action failed: {action_row}: {step.message}"
            )
        trace.append(_trace_step(
            state,
            rng,
            step,
            kind="action",
            index=action_index,
            before=before_action,
            operation={"kind": "action", **action_row},
        ))
        if step.pending_choice is not None and action_index != len(actions) - 1:
            raise RuntimeError("Only the final action may pause in a golden choice case")

    if step is None:
        raise RuntimeError("Golden pending choice case requires at least one action")
    if not step.success or step.pending_choice is None:
        raise RuntimeError(f"Golden pending attack did not pause: {step.message}")
    pending_summary = _state_summary(state)
    pending_stack = _json_value(state.resolution_stack)
    pending_request = pending_stack.get("pending_request") or {}
    if cancel_choice:
        response = ChoiceResponse(step.pending_choice.request_id, (), cancelled=True)
    else:
        authoritative_ids = {
            option.option_id for option in step.pending_choice.options
        }
        unknown_ids = set(selected_option_ids) - authoritative_ids
        if unknown_ids:
            raise RuntimeError(
                f"Golden choice selected unknown options: {sorted(unknown_ids)}"
            )
        response = ChoiceResponse(
            step.pending_choice.request_id,
            selected_option_ids,
        )
    selected_option_semantics = [
        _canonical_pending_option(option)
        for option in pending_request.get("options", [])
        if option.get("option_id") in response.option_ids
    ]
    before_choice = _state_payload(state)
    result = engine.apply_choice(state, response, rng)
    if not result.success:
        raise RuntimeError(f"Golden pending attack choice failed: {result.message}")
    trace.append(_trace_step(
        state,
        rng,
        result,
        kind="choice",
        index=0,
        before=before_choice,
        operation={
            "kind": "choice",
            "actor": step.pending_choice.player,
            "request_type": step.pending_choice.request_type,
            "finish_attack": (
                pending_request.get("metadata", {}).get("finish_attack_actor")
                is not None
            ),
        },
    ))
    for followup_index, action_row in enumerate(followup_actions):
        before_action = _state_payload(state)
        followup_result = engine.apply_action(
            state,
            GameAction(
                _resolve_action_name(str(action_row["action"])),
                dict(action_row.get("params", {})),
                actor=int(action_row.get("actor", -1)),
            ),
            rng,
            auto_resolve=False,
        )
        if not followup_result.success:
            raise RuntimeError(
                f"Golden follow-up action failed: {action_row}: "
                f"{followup_result.message}"
            )
        if followup_result.pending_choice is not None:
            raise RuntimeError(
                f"Golden follow-up action unexpectedly paused: {action_row}"
            )
        trace.append(_trace_step(
            state,
            rng,
            followup_result,
            kind="action",
            index=len(actions) + followup_index,
            before=before_action,
            operation={"kind": "action", **action_row},
        ))
    return {
        "portable_seed": portable_seed,
        "initial_state": initial,
        "actions": actions,
        "pending_after_action": {
            "expected": pending_summary,
            "request": _canonical_pending_request(pending_request),
            "stack": {
                "frame_kinds": [
                    frame.get("kind", "")
                    for frame in pending_stack.get("frames", [])
                ],
                "continuation_operations": [
                    _canonical_continuation_kind(frame.get("operation", ""))
                    for frame in pending_stack.get("frames", [])
                    if frame.get("kind") == "continuation"
                ],
                "continuation_data_kinds": [
                    _canonical_continuation_kind(
                        (frame.get("data") or {}).get("kind", "")
                    )
                    for frame in pending_stack.get("frames", [])
                    if frame.get("kind") == "continuation"
                ],
                "pending_request_type": _canonical_pending_request(
                    pending_request
                ).get("request_type", ""),
            },
        },
        "choice_response": {
            "request_id": response.request_id,
            "option_ids": list(response.option_ids),
            "selected_options": selected_option_semantics,
            "cancelled": response.cancelled,
        },
        "followup_actions": list(followup_actions),
        "trace": trace,
        "expected": _state_summary(state),
        "expected_rng_state": rng.get_state(),
    }


def _cobalion_attack_choice_case(
    engine: GameEngine,
    *,
    cancel_choice: bool,
) -> dict[str, Any]:
    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.active = PokemonInPlay(CardRegistry.get("svm-cobalion"), placed_this_turn=False)
    state.p1.active.energy_cards = [
        CardRegistry.get("sv1-ener-8"),
        CardRegistry.get("sv1-ener-8"),
    ]
    state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svm-zacian"), placed_this_turn=False)
    state.p1.bench[1] = PokemonInPlay(CardRegistry.get("svm-zamazenta"), placed_this_turn=False)
    state.p1.deck = [CardRegistry.get("sv1-ener-8"), CardRegistry.get("sv1-ener-8")]
    return _pending_choice_case(
        engine,
        state,
        [{
            "action": "DECLARE_ATTACK",
            "params": {"attack_idx": 0},
            "actor": 0,
        }],
        selected_option_ids=(
            "energy:0:sv1-ener-8->pokemon:0:bench_1:svm-zamazenta",
        ),
        cancel_choice=cancel_choice,
    )


def _golden_action_cases() -> dict[str, Any]:
    cases: dict[str, Any] = {}
    engine = GameEngine()

    def add_case(
        name: str,
        state: GameState,
        actions: list[dict[str, Any]],
        *,
        portable_seed: int = 700,
    ) -> None:
        initial = _state_payload(state)
        trace, rng = _run_golden_actions(
            engine,
            state,
            actions,
            portable_seed=portable_seed,
        )
        cases[name] = {
            "portable_seed": portable_seed,
            "initial_state": initial,
            "actions": actions,
            "trace": trace,
            "expected": _state_summary(state),
            "expected_rng_state": rng.get_state(),
        }

    state = _base_golden_state()
    state.p1.hand = [CardRegistry.get("svi-chim"), CardRegistry.get("sv1-ener-5")]
    actions = [
        {"action": "PLAY_BASIC", "params": {"hand_idx": 0, "target": "bench_0"}, "actor": 0},
        {"action": "ATTACH_ENERGY", "params": {"hand_idx": 0, "target_slot": "active"}, "actor": 0},
        {"action": "DECLARE_ATTACK", "params": {"attack_idx": 0}, "actor": 0},
    ]
    add_case("basic_attach_attack", state, actions)

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.active.energy_cards = [CardRegistry.get("svi-dtur")]
    state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svi-chim"), placed_this_turn=False)
    actions = [{
        "action": "RETREAT",
        "params": {"bench_idx": 0},
        "actor": 0,
    }]
    cases["double_turbo_retreat"] = _pending_choice_case(
        engine,
        state,
        actions,
        selected_option_ids=("retreat:energy:0",),
    )

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.active = PokemonInPlay(CardRegistry.get("svf-rio"), placed_this_turn=False)
    state.p1.hand = [CardRegistry.get("svf-luca")]
    actions = [{
        "action": "EVOLVE",
        "params": {"hand_idx": 0, "slot": "active"},
        "actor": 0,
    }]
    add_case("evolution_preserves_attachments", state, actions)

    cases["pending_attack_choice_continuation"] = _cobalion_attack_choice_case(
        engine,
        cancel_choice=False,
    )
    cases["pending_attack_choice_cancel"] = _cobalion_attack_choice_case(
        engine,
        cancel_choice=True,
    )

    state = _base_golden_state()
    state.p1.hand = [CardRegistry.get("sv1-180")]
    add_case("supporter_draw", state, [{
        "action": "PLAY_TRAINER",
        "params": {"hand_idx": 0},
        "actor": 0,
    }])

    state = _base_golden_state()
    state.p1.hand = [CardRegistry.get("svl-vitb")]
    add_case("tool_attachment", state, [{
        "action": "PLAY_TRAINER",
        "params": {"hand_idx": 0, "target_slot": "active"},
        "actor": 0,
    }])

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.active = PokemonInPlay(
        CardRegistry.get("svd-dodrio"), placed_this_turn=False
    )
    add_case("ability_damage_draw", state, [{
        "action": "USE_ABILITY",
        "params": {"slot": "active", "ability_name": "暴走抽取"},
        "actor": 0,
    }])

    fixture_stadium = Card(
        api_id="fixture-activatable-stadium",
        name="Fixture Activatable Stadium",
        supertype="Trainer",
        subtypes=["Stadium"],
        compiled_trainer_effects=[{
            "op": "draw_cards",
            "args": {"amount": 1, "stadium_type": "activatable"},
            "branches": {},
        }],
    )
    state = _base_golden_state()
    state.stadium_card = fixture_stadium
    add_case("activatable_stadium", state, [{
        "action": "USE_STADIUM",
        "params": {},
        "actor": 0,
    }])

    state = _base_golden_state()
    add_case("end_turn", state, [{
        "action": "END_TURN",
        "params": {},
        "actor": 0,
    }])

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"), placed_this_turn=False)
    state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-2")]
    state.p1.active.status_conditions.add(StatusType.CONFUSED)
    add_case("confused_attack_tails", state, [{
        "action": "DECLARE_ATTACK",
        "params": {"attack_idx": 0},
        "actor": 0,
    }], portable_seed=700)

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.active = PokemonInPlay(CardRegistry.get("svi-chim"), placed_this_turn=False)
    state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-2")]
    state.p2.active.damage_counters = 4
    state.p2.bench[0] = PokemonInPlay(
        CardRegistry.get("sv1-104"), placed_this_turn=False
    )
    cases["ko_then_promote"] = _pending_choice_case(
        engine,
        state,
        [{"action": "DECLARE_ATTACK", "params": {"attack_idx": 0}, "actor": 0}],
        selected_option_ids=("prize:0",),
        followup_actions=({
            "action": "PROMOTE",
            "params": {"bench_idx": 0},
            "actor": 1,
        },),
    )

    state = _base_golden_state()
    state.p1.active.damage_counters = 6
    state.p1.hand = [CardRegistry.get("svg-chef")]
    add_case("heal_supporter", state, [{
        "action": "PLAY_TRAINER",
        "params": {"hand_idx": 0},
        "actor": 0,
    }])

    state = _base_golden_state()
    state.p1.hand = [
        CardRegistry.get("sv2-young"),
        CardRegistry.get("svi-chim"),
        CardRegistry.get("sv1-ener-2"),
    ]
    state.p1.deck = [
        CardRegistry.get("sv1-ener-1"),
        CardRegistry.get("sv1-ener-2"),
        CardRegistry.get("sv1-ener-3"),
        CardRegistry.get("sv1-ener-4"),
        CardRegistry.get("sv1-ener-5"),
        CardRegistry.get("sv1-ener-6"),
    ]
    add_case("shuffle_draw_supporter", state, [{
        "action": "PLAY_TRAINER",
        "params": {"hand_idx": 0},
        "actor": 0,
    }], portable_seed=1337)

    state = _base_golden_state()
    state.p1.active = PokemonInPlay(
        CardRegistry.get("svg-alt"), damage_counters=3, placed_this_turn=False
    )
    state.p1.bench[0] = PokemonInPlay(
        CardRegistry.get("svi-chim"), damage_counters=2, placed_this_turn=False
    )
    add_case("heal_all_ability", state, [{
        "action": "USE_ABILITY",
        "params": {"slot": "active", "ability_name": "哼唱治愈"},
        "actor": 0,
    }])

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.active = PokemonInPlay(
        CardRegistry.get("svg2-shro"), damage_counters=2, placed_this_turn=False
    )
    state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-1")]
    state.p2.active = PokemonInPlay(CardRegistry.get("sv2-grex"), placed_this_turn=False)
    add_case("damage_then_self_heal_attack", state, [{
        "action": "DECLARE_ATTACK",
        "params": {"attack_idx": 0},
        "actor": 0,
    }])

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.active = PokemonInPlay(
        CardRegistry.get("svd-dodrio"), damage_counters=1, placed_this_turn=False
    )
    state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-5")]
    state.p2.active = PokemonInPlay(CardRegistry.get("sv2-grex"), placed_this_turn=False)
    add_case("formula_damage_attack", state, [{
        "action": "DECLARE_ATTACK",
        "params": {"attack_idx": 0},
        "actor": 0,
    }])

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.active = PokemonInPlay(CardRegistry.get("svf-terr"), placed_this_turn=False)
    state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-6")] * 3
    state.p2.active = PokemonInPlay(CardRegistry.get("sv2-grex"), placed_this_turn=False)
    add_case("prevent_damage_and_lock_attack", state, [{
        "action": "DECLARE_ATTACK",
        "params": {"attack_idx": 0},
        "actor": 0,
    }])

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.was_ko_by_attack = True
    state.p1.active = PokemonInPlay(CardRegistry.get("sv1-49"), placed_this_turn=False)
    state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-3")] * 3
    state.p2.active = PokemonInPlay(CardRegistry.get("sv2-grex"), placed_this_turn=False)
    add_case("conditional_status_attack", state, [{
        "action": "DECLARE_ATTACK",
        "params": {"attack_idx": 0},
        "actor": 0,
    }])

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.healed_this_turn = True
    state.p1.active = PokemonInPlay(CardRegistry.get("svg-milt"), placed_this_turn=False)
    state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-5")] * 2
    state.p2.active = PokemonInPlay(CardRegistry.get("sv2-grex"), placed_this_turn=False)
    add_case("conditional_damage_heal_attack", state, [{
        "action": "DECLARE_ATTACK",
        "params": {"attack_idx": 0},
        "actor": 0,
    }])

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.active = PokemonInPlay(CardRegistry.get("svg-alt"), placed_this_turn=False)
    state.p1.active.energy_cards = [
        CardRegistry.get("sv1-ener-3"),
        CardRegistry.get("sv1-ener-8"),
    ]
    state.p2.active = PokemonInPlay(CardRegistry.get("sv2-grex"), placed_this_turn=False)
    add_case("prevent_effects_attack", state, [{
        "action": "DECLARE_ATTACK",
        "params": {"attack_idx": 0},
        "actor": 0,
    }])

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.active = PokemonInPlay(CardRegistry.get("sv1-114"), placed_this_turn=False)
    state.p1.active.energy_cards = [CardRegistry.get("sv1-ener-5")]
    state.p1.deck = [
        CardRegistry.get("sv1-ener-5"),
        CardRegistry.get("sv1-ener-4"),
        CardRegistry.get("svi-chim"),
        CardRegistry.get("sv1-ener-2"),
    ]
    cases["search_energy_attack"] = _pending_choice_case(
        engine,
        state,
        [{"action": "DECLARE_ATTACK", "params": {"attack_idx": 0}, "actor": 0}],
        selected_option_ids=(
            "card:0:deck:0:sv1-ener-5",
            "card:0:deck:1:sv1-ener-4",
        ),
        portable_seed=2027,
    )

    state = _base_golden_state()
    state.p1.active.damage_counters = 2
    state.p1.bench[0] = PokemonInPlay(
        CardRegistry.get("svi-chim"), damage_counters=1, placed_this_turn=False
    )
    state.p1.hand = [CardRegistry.get("svf-potion")]
    cases["potion_heal_choice"] = _pending_choice_case(
        engine,
        state,
        [{"action": "PLAY_TRAINER", "params": {"hand_idx": 0}, "actor": 0}],
        selected_option_ids=("pokemon:0:bench_0:svi-chim",),
    )

    return {
        "fixture_version": 3,
        "rng_schema_version": RNG_SCHEMA_VERSION,
        "rng_algorithm": "xorshift32-v1",
        "event_contract": {
            "name": "canonical-state-transition-events-v1",
            "python_expected_source": "before_after_state_and_operation",
            "python_raw_step_events_retained_as": "python_step_event_types",
            "godot_actual_source": "StepResult.events",
        },
        "pending_contract": {
            "name": "canonical-pending-semantics-v1",
            "compares": [
                "request_family",
                "selection_bounds",
                "entity_references",
                "continuation_family",
            ],
            "ignores": ["runtime_specific_request_id", "runtime_specific_option_id"],
        },
        "test_cards": {
            fixture_stadium.api_id: {
                "api_id": fixture_stadium.api_id,
                "name": fixture_stadium.name,
                "supertype": fixture_stadium.supertype,
                "subtypes": fixture_stadium.subtypes,
                "trainer_effects": [],
                "compiled_trainer_effects": fixture_stadium.compiled_trainer_effects,
            },
        },
        "cases": cases,
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
    release_effects = set(_effect_types(CARD_EFFECTS))
    registered_effects = set(SUPPORTED_EFFECT_TYPES)
    effect_examples = _effect_examples(CARD_EFFECTS)
    effect_to_op = dict(OP_BY_EFFECT_TYPE)
    effect_to_op.update({
        effect_type: compile_effect_to_spec(example).op
        for effect_type, example in effect_examples.items()
    })
    registered_ops = set(DEFAULT_COMMAND_REGISTRY.supported_ops)
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

    data_root = output / "data"
    _write_json(data_root / "cards.json", cards)
    _write_json(data_root / "effects.json", _json_value(CARD_EFFECTS))
    _write_json(data_root / "decks.json", decks)
    _write_json(data_root / "ai_strategies.json", build_ai_strategy_catalog(DECKS))
    _write_json(data_root / "card_images.json", image_paths)
    _write_json(data_root / "card_image_hashes.json", image_hashes)
    _write_json(
        data_root / "card_buckets.json",
        {card_id: cards[card_id]["card_bucket"] for card_id in sorted(cards)},
    )
    _write_json(data_root / "ai_card_vocab.json", load_card_vocab())
    _write_json(data_root / "ai_models.json", _model_manifest())
    _write_json(data_root / "release_manifest.json", _release_manifest())
    _write_json(data_root / "vm_command_descriptors.json", descriptor_payload)
    golden = _golden_contract(cards, decks)
    _write_json(output / "tests" / "fixtures" / "data_contract.json", golden)
    _write_json(
        output / "tests" / "fixtures" / "ai_encoder_golden.json",
        _ai_encoder_fixture(),
    )
    golden_actions = _golden_action_cases()
    _write_json(
        output / "tests" / "fixtures" / "rules_golden.json",
        golden_actions,
    )
    vm_semantic_golden = _vm_semantic_golden_fixture()
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
                Path("data/effects.json"),
                Path("data/decks.json"),
                Path("data/ai_strategies.json"),
                Path("data/card_images.json"),
                Path("data/card_image_hashes.json"),
                Path("data/card_buckets.json"),
                Path("data/ai_card_vocab.json"),
                Path("data/ai_models.json"),
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
