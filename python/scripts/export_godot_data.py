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
from data.card_registry import CardRegistry
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
from engine.commands.dsl_compiler import compile_effect_to_spec, compile_effects_to_payload
from engine.commands.vm_contract import VM_IR_VERSION
from engine.enums import PlayerAction, TurnPhase
from engine.game_engine import GameEngine
from engine.game_state import GameState
from engine.player_state import PokemonInPlay
from engine.random_source import PortableRandomSourceV1

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
    if int(payload.get("model_count") or 0) != len(release_decks):
        raise RuntimeError("release_manifest.json model_count does not match release_decks")
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
    pairs = json.loads(text, object_pairs_hook=lambda rows: rows)
    if not isinstance(pairs, list):
        raise ValueError("Card image mapping must be a JSON object")
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
    if card_back.is_file():
        shutil.copy2(card_back, target_root / "card_back.webp")
    _remove_obsolete_card_assets(
        target_root,
        {Path(path).name for path in exported.values()} | {"card_back.webp"},
    )
    return exported


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
            "godot_rules_version": 3,
            "godot_action_version": 3,
            "protocol_version": 3,
            "encoder_version": ENCODER_SCHEMA_VERSION,
            "planner_version": PLANNER_SCHEMA_VERSION,
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
        "portable_rng": {
            "algorithm": "xorshift32",
            "seed": 20260620,
            "uint32": _portable_rng_sequence(20260620, 8),
        },
    }


def _ref_payload(ref: Any) -> dict[str, Any] | None:
    if isinstance(ref, CardRef):
        return {
            "kind": "card",
            "player": ref.player,
            "zone": ref.zone,
            "slot": "",
            "index": ref.index,
            "attachment_type": "",
            "card_id": ref.card_id,
        }
    if isinstance(ref, PokemonRef):
        return {
            "kind": "pokemon",
            "player": ref.player,
            "zone": "",
            "slot": ref.slot,
            "index": -1,
            "attachment_type": "",
            "card_id": ref.card_id,
        }
    return None


def _action_payload(action: GameAction) -> dict[str, Any]:
    return {
        "action": action.action.name if isinstance(action.action, PlayerAction) else str(action.action),
        "params": _json_value(action.params),
        "terminal": action.terminal,
        "actor": action.actor if action.actor is not None else -1,
        "source": _ref_payload(action.source),
        "target": _ref_payload(action.target),
        "action_id": action.action_id,
    }


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
        "fixture_version": 1,
        "deck_key": "water",
        "observation": _json_value(observation),
        "actions": [_action_payload(action) for action in actions],
        "choice": {
            "request_id": choice.request_id,
            "request_type": choice.request_type,
            "player": choice.player,
            "prompt": choice.prompt,
            "options": [
                {
                    "option_id": option.option_id,
                    "label": option.label,
                    "ref": _ref_payload(option.ref),
                    "value": {},
                }
                for option in choice.options
            ],
            "min_select": choice.min_select,
            "max_select": choice.max_select,
            "allow_duplicates": choice.allow_duplicates,
            "can_cancel": choice.can_cancel,
            "metadata": {},
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


def _pokemon_payload(pokemon) -> dict[str, Any] | None:
    if pokemon is None:
        return None
    return {
        "card_id": pokemon.card.api_id,
        "damage_counters": pokemon.damage_counters,
        "energy_card_ids": [card.api_id for card in pokemon.energy_cards],
        "attached_tool_id": pokemon.attached_tool.api_id if pokemon.attached_tool else "",
        "status_conditions": sorted(status.name for status in pokemon.status_conditions),
        "evolution_stack_ids": [card.api_id for card in pokemon.evolution_stack],
        "can_evolve_this_turn": pokemon.can_evolve_this_turn,
        "placed_this_turn": pokemon.placed_this_turn,
        "used_abilities": sorted(pokemon.used_abilities),
        "damage_prevented_next_turn": pokemon.damage_prevented_next_turn,
        "all_prevented_next_turn": pokemon.all_prevented_next_turn,
        "outgoing_damage_reduction_next_turn": pokemon.outgoing_damage_reduction_next_turn,
        "attack_locked": pokemon.attack_locked,
        "attack_locked_names": dict(pokemon.attack_locked_names),
        "dazzled": pokemon.dazzled,
        "paralyzed_since_turn": pokemon.paralyzed_since_turn,
    }


def _player_payload(player) -> dict[str, Any]:
    return {
        "name": player.name,
        "deck": [card.api_id for card in player.deck],
        "hand": [card.api_id for card in player.hand],
        "discard": [card.api_id for card in player.discard],
        "prizes": [card.api_id for card in player.prizes],
        "active": _pokemon_payload(player.active),
        "bench": [_pokemon_payload(pokemon) for pokemon in player.bench],
        "supporter_played_this_turn": player.supporter_played_this_turn,
        "energy_attached_this_turn": player.energy_attached_this_turn,
        "retreated_this_turn": player.retreated_this_turn,
        "stadium_played_this_turn": player.stadium_played_this_turn,
        "stadium_used_this_turn": player.stadium_used_this_turn,
        "healed_this_turn": player.healed_this_turn,
        "vstar_power_used": player.vstar_power_used,
        "was_ko_by_attack": player.was_ko_by_attack,
    }


def _state_payload(state: GameState) -> dict[str, Any]:
    stadium = getattr(state, "stadium_card", None)
    return {
        "players": [_player_payload(state.p1), _player_payload(state.p2)],
        "active_player_idx": state.active_player_idx,
        "phase": state.phase.name,
        "turn_number": state.turn_number,
        "first_player_idx": state.first_player_idx,
        "stadium_card_id": stadium.api_id if stadium else "",
        "winner": -1 if state.winner is None else state.winner,
        "revision": int(getattr(state, "revision", 0)),
        "choice_sequence": int(getattr(state, "choice_sequence", 0)),
        "public_deck_keys": [
            str(value or "")
            for value in getattr(state, "public_deck_keys", ("", ""))
        ],
        "apply_type_matchups": bool(getattr(state, "apply_type_matchups", False)),
        "action_log": [],
        "mulligan_count": list(getattr(state, "mulligan_count", (0, 0))),
        "extra_draws": list(getattr(state, "extra_draws", (0, 0))),
        "setup_ready": [False, False],
        "pending_promotions": list(getattr(state, "pending_promotions", [])),
        "processed_action_ids": [],
        "resolution_stack": _json_value(
            getattr(
                state,
                "resolution_stack",
                {
                    "frames": [],
                    "pending_request": None,
                    "sequence": 0,
                    "context": {},
                },
            )
        ),
    }


def _state_summary(state: GameState) -> dict[str, Any]:
    payload = _state_payload(state)
    payload.pop("action_log", None)
    payload.pop("resolution_stack", None)
    payload.pop("setup_ready", None)
    payload.pop("processed_action_ids", None)
    return payload


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


def _cobalion_attack_choice_case(
    engine: GameEngine,
    *,
    cancel_choice: bool,
) -> dict[str, Any]:
    portable_seed = 700
    rng = PortableRandomSourceV1(portable_seed)
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
    initial = _state_payload(state)
    actions = [{
        "action": "DECLARE_ATTACK",
        "params": {"attack_idx": 0},
        "actor": 0,
    }]
    step = engine.apply_action(
        state,
        GameAction(PlayerAction.DECLARE_ATTACK, actions[0]["params"], actor=0),
        rng,
        auto_resolve=False,
    )
    if not step.success or step.pending_choice is None:
        raise RuntimeError(f"Golden pending attack did not pause: {step.message}")
    pending_summary = _state_summary(state)
    pending_stack = _json_value(state.resolution_stack)
    pending_request = pending_stack.get("pending_request") or {}
    if cancel_choice:
        response = ChoiceResponse(step.pending_choice.request_id, (), cancelled=True)
    else:
        bench_1 = next(
            option
            for option in step.pending_choice.options
            if isinstance(option.value, dict) and option.value.get("slot") == "bench_1"
        )
        response = ChoiceResponse(step.pending_choice.request_id, (bench_1.option_id,))
    result = engine.apply_choice(
        state,
        step.pending_choice,
        response,
        rng,
    )
    if not result.success:
        raise RuntimeError(f"Golden pending attack choice failed: {result.message}")
    return {
        "portable_seed": portable_seed,
        "initial_state": initial,
        "actions": actions,
        "pending_after_action": {
            "expected": pending_summary,
            "request": {
                "request_id": pending_request.get("request_id", ""),
                "request_type": pending_request.get("request_type", ""),
                "player": pending_request.get("player", 0),
                "min_select": pending_request.get("min_select", 0),
                "max_select": pending_request.get("max_select", 0),
                "allow_duplicates": pending_request.get("allow_duplicates", False),
                "can_cancel": pending_request.get("can_cancel", False),
                "option_ids": [
                    option.get("option_id", "")
                    for option in pending_request.get("options", [])
                ],
                "metadata": {
                    "finish_attack_actor": pending_request.get("metadata", {}).get(
                        "finish_attack_actor"
                    ),
                    "continuation_kind": pending_request.get("metadata", {})
                    .get("continuation", {})
                    .get("kind", ""),
                },
            },
            "stack": {
                "frame_kinds": [
                    frame.get("kind", "")
                    for frame in pending_stack.get("frames", [])
                ],
                "continuation_operations": [
                    frame.get("operation", "")
                    for frame in pending_stack.get("frames", [])
                    if frame.get("kind") == "continuation"
                ],
                "continuation_data_kinds": [
                    (frame.get("data") or {}).get("kind", "")
                    for frame in pending_stack.get("frames", [])
                    if frame.get("kind") == "continuation"
                ],
                "pending_request_type": pending_request.get("request_type", ""),
            },
        },
        "choice_response": {
            "request_id": response.request_id,
            "option_ids": list(response.option_ids),
            "cancelled": response.cancelled,
        },
        "expected": _state_summary(state),
        "expected_rng_state": rng.get_state(),
    }


def _golden_action_cases() -> dict[str, Any]:
    cases: dict[str, Any] = {}
    engine = GameEngine()

    state = _base_golden_state()
    state.p1.hand = [CardRegistry.get("svi-chim"), CardRegistry.get("sv1-ener-5")]
    initial = _state_payload(state)
    actions = [
        {"action": "PLAY_BASIC", "params": {"hand_idx": 0, "target": "bench_0"}, "actor": 0},
        {"action": "ATTACH_ENERGY", "params": {"hand_idx": 0, "target_slot": "active"}, "actor": 0},
        {"action": "DECLARE_ATTACK", "params": {"attack_idx": 0}, "actor": 0},
    ]
    portable_seed = 700
    rng = PortableRandomSourceV1(portable_seed)
    for row in actions:
        result = engine.apply_action(
            state,
            GameAction(PlayerAction[row["action"]], row["params"], actor=row["actor"]),
            rng,
            auto_resolve=True,
        )
        if not result.success:
            raise RuntimeError(f"Golden action failed: {row}: {result.message}")
    cases["basic_attach_attack"] = {
        "portable_seed": portable_seed,
        "initial_state": initial,
        "actions": actions,
        "expected": _state_summary(state),
        "expected_rng_state": rng.get_state(),
    }

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.active.energy_cards = [CardRegistry.get("svi-dtur")]
    state.p1.bench[0] = PokemonInPlay(CardRegistry.get("svi-chim"), placed_this_turn=False)
    initial = _state_payload(state)
    actions = [{
        "action": "RETREAT",
        "params": {"bench_idx": 0, "energy_indices": [0]},
        "actor": 0,
    }]
    portable_seed = 700
    rng = PortableRandomSourceV1(portable_seed)
    result = engine.apply_action(
        state,
        GameAction(PlayerAction.RETREAT, actions[0]["params"], actor=0),
        rng,
    )
    if not result.success:
        raise RuntimeError(f"Golden retreat failed: {result.message}")
    cases["double_turbo_retreat"] = {
        "portable_seed": portable_seed,
        "initial_state": initial,
        "actions": actions,
        "expected": _state_summary(state),
        "expected_rng_state": rng.get_state(),
    }

    state = _base_golden_state()
    state.turn_number = 3
    state.first_player_idx = 0
    state.p1.active = PokemonInPlay(CardRegistry.get("svf-rio"), placed_this_turn=False)
    state.p1.hand = [CardRegistry.get("svf-luca")]
    initial = _state_payload(state)
    actions = [{
        "action": "EVOLVE",
        "params": {"hand_idx": 0, "slot": "active"},
        "actor": 0,
    }]
    portable_seed = 700
    rng = PortableRandomSourceV1(portable_seed)
    result = engine.apply_action(
        state,
        GameAction(PlayerAction.EVOLVE, actions[0]["params"], actor=0),
        rng,
    )
    if not result.success:
        raise RuntimeError(f"Golden evolution failed: {result.message}")
    cases["evolution_preserves_attachments"] = {
        "portable_seed": portable_seed,
        "initial_state": initial,
        "actions": actions,
        "expected": _state_summary(state),
        "expected_rng_state": rng.get_state(),
    }

    cases["pending_attack_choice_continuation"] = _cobalion_attack_choice_case(
        engine,
        cancel_choice=False,
    )
    cases["pending_attack_choice_cancel"] = _cobalion_attack_choice_case(
        engine,
        cancel_choice=True,
    )
    return {"fixture_version": 2, "rng_algorithm": "xorshift32-v1", "cases": cases}


def export(output: Path, *, copy_images: bool = True) -> dict[str, Any]:
    image_mapping = _load_image_mapping()
    image_paths = (
        _export_images(output, image_mapping)
        if copy_images
        else _image_paths(image_mapping)
    )
    image_hashes = _image_hashes(image_mapping)
    cards = _card_payload(image_paths)
    decks = _deck_payload()

    data_root = output / "data"
    _write_json(data_root / "cards.json", cards)
    _write_json(data_root / "effects.json", _json_value(CARD_EFFECTS))
    _write_json(data_root / "decks.json", decks)
    _write_json(data_root / "card_images.json", image_paths)
    _write_json(data_root / "card_image_hashes.json", image_hashes)
    _write_json(
        data_root / "card_buckets.json",
        {card_id: cards[card_id]["card_bucket"] for card_id in sorted(cards)},
    )
    _write_json(data_root / "ai_models.json", _model_manifest())
    _write_json(data_root / "release_manifest.json", _release_manifest())
    golden = _golden_contract(cards, decks)
    _write_json(output / "tests" / "fixtures" / "data_contract.json", golden)
    _write_json(
        output / "tests" / "fixtures" / "ai_encoder_golden.json",
        _ai_encoder_fixture(),
    )
    _write_json(
        output / "tests" / "fixtures" / "rules_golden.json",
        _golden_action_cases(),
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
                Path("data/card_images.json"),
                Path("data/card_image_hashes.json"),
                Path("data/card_buckets.json"),
                Path("data/ai_models.json"),
                Path("data/release_manifest.json"),
                Path("tests/fixtures/data_contract.json"),
                Path("tests/fixtures/rules_golden.json"),
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
