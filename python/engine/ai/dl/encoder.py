"""Feature encoders for the optional deep-learning AI.

The model scores legal candidate actions rather than predicting a fixed action
ID.  Encoder v6 uses an append-only card vocabulary and a fixed, perspective-
relative token layout so slot meaning never shifts with attachment counts.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from data.ai_card_vocab import (
    CARD_PAD_INDEX,
    CARD_VOCAB_VERSION,
    card_vocab_index,
    card_vocab_sha256,
)
from data.card_registry import CardRegistry
from engine.actions import (
    AttachmentRef,
    CardRef,
    ChoiceOption,
    GameAction,
    PokemonRef,
    SlotRef,
)
from engine.ai.effect_features import (
    effect_feature_names,
    iter_effects_recursive,
)
from engine.ai.observation import Observation
from engine.enums import PlayerAction, TurnPhase
from engine.effects.runtime_effects import (
    ability_runtime_effects,
    attack_runtime_effects,
    trainer_runtime_effects,
)


CARD_IDENTITY_MODE = "vocab_v1"
CARD_VOCAB_SHA256 = card_vocab_sha256()
STATE_NUMERIC_SIZE = 960  # +32 for tactical situation features (v8)
STATE_CARD_SLOTS = 128
ACTION_NUMERIC_SIZE = 178  # +16 for action feasibility/context features (v8)
CARD_SEMANTIC_SIZE = 53
ENCODER_SCHEMA_VERSION = 6

BOARD_POKEMON_SLOTS = 12
TOKENS_PER_POKEMON = 6
BOARD_CARD_TOKEN_COUNT = BOARD_POKEMON_SLOTS * TOKENS_PER_POKEMON
OWN_HAND_TOKEN_START = 72
OWN_HAND_TOKEN_COUNT = 16
OWN_DISCARD_TOKEN_START = 88
DISCARD_TOKEN_COUNT = 12
OPPONENT_DISCARD_TOKEN_START = 100
STADIUM_TOKEN_INDEX = 112
RESERVED_TOKEN_START = 113

TOKEN_TYPE_PADDING = 0
TOKEN_TYPE_POKEMON = 1
TOKEN_TYPE_ENERGY = 2
TOKEN_TYPE_TOOL = 3
TOKEN_TYPE_HAND = 4
TOKEN_TYPE_OWN_DISCARD = 5
TOKEN_TYPE_OPPONENT_DISCARD = 6
TOKEN_TYPE_STADIUM = 7
TOKEN_TYPE_COUNT = 8

TOKEN_OWNER_OWN = 0
TOKEN_OWNER_OPPONENT = 1
TOKEN_OWNER_NEUTRAL = 2
TOKEN_OWNER_COUNT = 3

ACTION_TYPES = [
    PlayerAction.PLAY_BASIC.name,
    PlayerAction.EVOLVE.name,
    PlayerAction.ATTACH_ENERGY.name,
    PlayerAction.PLAY_TRAINER.name,
    PlayerAction.USE_ABILITY.name,
    PlayerAction.USE_STADIUM.name,
    PlayerAction.RETREAT.name,
    PlayerAction.DECLARE_ATTACK.name,
    "PROMOTE",
    "SETUP_DONE",
    PlayerAction.END_TURN.name,
]

CHOICE_TYPES = [
    "select_card",
    "select_pokemon",
    "select_attachment",
    "distribute_energy",
    "confirm",
    "select_prize",
    "setup",
    "coin_flip",
    "order",
]
CHOICE_TYPE_ALIASES = {
    "arven": "select_card",
    "clara": "select_card",
    "discard_cards": "select_card",
    "discard_then_draw": "select_card",
    "evolve_skip_stage": "select_card",
    "hand_bottom_draw": "select_card",
    "houb": "select_card",
    "look_top": "select_card",
    "look_top_attach_energy": "select_card",
    "resolve_empty": "select_card",
    "search": "select_card",
    "search_any_switch": "select_card",
    "search_deck": "select_card",
    "search_move": "select_card",
    "select": "select_card",
    "select_card": "select_card",
    "select_hand_to_discard": "select_card",
    "shuffle_from_discard": "select_card",
    "zinnia": "select_card",
    "bench_damage_target": "select_pokemon",
    "damage_target": "select_pokemon",
    "place_counters_self_discard": "select_pokemon",
    "select_bench": "select_pokemon",
    "select_bench_targets": "select_pokemon",
    "select_energy_source": "select_pokemon",
    "select_energy_target": "select_pokemon",
    "select_heal_target": "select_pokemon",
    "select_opponent_bench": "select_pokemon",
    "select_own_bench_energy": "select_pokemon",
    "select_prize_energy_target": "select_pokemon",
    "select_attachment": "select_attachment",
    "select_retreat_payment": "select_attachment",
    "distribute_energy": "distribute_energy",
    "confirm": "confirm",
    "confirm_trigger": "confirm",
    "select_prize": "select_prize",
    "choose_mulligan_draw_count": "setup",
    "choose_turn_order": "setup",
    "coin_flip": "coin_flip",
    "choose_trigger_order": "order",
}

TARGET_SLOTS = ["active", "bench_0", "bench_1", "bench_2", "bench_3", "bench_4"]
REF_KINDS = ["card", "pokemon", "slot", "attachment"]
REF_ZONES = ["hand", "deck", "discard", "prizes", "active", "bench", "field", "stadium"]
ATTACHMENT_TYPES = ["energy", "tool"]
TERMINAL_ACTIONS = frozenset({"DECLARE_ATTACK", "SETUP_DONE", "END_TURN"})

ENERGY_TYPES = [
    "Grass",
    "Fire",
    "Water",
    "Lightning",
    "Psychic",
    "Fighting",
    "Darkness",
    "Metal",
    "Dragon",
    "Colorless",
    "Rainbow",
]

EFFECT_TYPES = [
    "draw",
    "search",
    "discard",
    "energy",
    "attach",
    "heal",
    "coin",
    "switch",
    "damage",
    "prevent",
    "lock",
    "evolve",
]

def _state_token_layout() -> tuple[tuple[int, ...], tuple[int, ...]]:
    token_types: list[int] = []
    token_owners: list[int] = []
    for owner in (TOKEN_OWNER_OWN, TOKEN_OWNER_OPPONENT):
        for _slot in TARGET_SLOTS:
            token_types.extend([
                TOKEN_TYPE_POKEMON,
                TOKEN_TYPE_ENERGY,
                TOKEN_TYPE_ENERGY,
                TOKEN_TYPE_ENERGY,
                TOKEN_TYPE_ENERGY,
                TOKEN_TYPE_TOOL,
            ])
            token_owners.extend([owner] * TOKENS_PER_POKEMON)
    token_types.extend([TOKEN_TYPE_HAND] * OWN_HAND_TOKEN_COUNT)
    token_owners.extend([TOKEN_OWNER_OWN] * OWN_HAND_TOKEN_COUNT)
    token_types.extend([TOKEN_TYPE_OWN_DISCARD] * DISCARD_TOKEN_COUNT)
    token_owners.extend([TOKEN_OWNER_OWN] * DISCARD_TOKEN_COUNT)
    token_types.extend([TOKEN_TYPE_OPPONENT_DISCARD] * DISCARD_TOKEN_COUNT)
    token_owners.extend([TOKEN_OWNER_OPPONENT] * DISCARD_TOKEN_COUNT)
    token_types.append(TOKEN_TYPE_STADIUM)
    token_owners.append(TOKEN_OWNER_NEUTRAL)
    reserved = STATE_CARD_SLOTS - len(token_types)
    token_types.extend([TOKEN_TYPE_PADDING] * reserved)
    token_owners.extend([TOKEN_OWNER_NEUTRAL] * reserved)
    if len(token_types) != STATE_CARD_SLOTS:
        raise RuntimeError("Deep AI state token layout width mismatch")
    return tuple(token_types), tuple(token_owners)


STATE_TOKEN_TYPES, STATE_TOKEN_OWNERS = _state_token_layout()


@dataclass(frozen=True)
class EncodedState:
    numeric: list[float]
    card_ids: list[int]


@dataclass(frozen=True)
class EncodedAction:
    numeric: list[float]
    card_id: int


def _pad(values: list[float], size: int) -> list[float]:
    if len(values) > size:
        raise ValueError(
            f"encoder_numeric_overflow:{len(values)}>{size}"
        )
    if len(values) == size:
        return values
    return values + [0.0] * (size - len(values))


def _pad_ids(values: list[int], size: int) -> list[int]:
    if len(values) > size:
        raise ValueError(
            f"encoder_card_slot_overflow:{len(values)}>{size}"
        )
    if len(values) == size:
        return values
    return values + [0] * (size - len(values))


def card_index(card_or_id: Any) -> int:
    """Collision-free append-only identity used by encoder v6."""
    return card_vocab_index(card_or_id)


def _bool(value: Any) -> float:
    return 1.0 if value else 0.0


def _one_hot(index: int, size: int) -> list[float]:
    values = [0.0] * size
    if 0 <= index < size:
        values[index] = 1.0
    return values


def _choice_type_one_hot(request_type: str) -> list[float]:
    encoded_type = CHOICE_TYPE_ALIASES.get(str(request_type), str(request_type))
    if encoded_type not in CHOICE_TYPES:
        raise ValueError(f"unknown_choice_type:{request_type}")
    return _one_hot(CHOICE_TYPES.index(encoded_type), len(CHOICE_TYPES))


def _norm(value: float, divisor: float) -> float:
    if divisor <= 0:
        return 0.0
    return max(-4.0, min(4.0, float(value) / divisor))


def _card_id(card: Any) -> str:
    return str(getattr(card, "api_id", "") or "")


def _ref_dict(ref: Any) -> dict[str, Any]:
    if ref is None:
        return {}
    if isinstance(ref, dict):
        return dict(ref)
    if isinstance(ref, CardRef):
        return {
            "kind": "card", "player": ref.player, "zone": ref.zone,
            "slot": "", "index": ref.index, "attachment_type": "",
            "card_id": ref.card_id,
        }
    if isinstance(ref, PokemonRef):
        return {
            "kind": "pokemon", "player": ref.player, "zone": "",
            "slot": ref.slot, "index": -1, "attachment_type": "",
            "card_id": ref.card_id,
        }
    if isinstance(ref, SlotRef):
        return {
            "kind": "slot", "player": ref.player, "zone": "",
            "slot": ref.slot, "index": -1, "attachment_type": "",
            "card_id": "",
        }
    if isinstance(ref, AttachmentRef):
        return {
            "kind": "attachment", "player": ref.player, "zone": "",
            "slot": ref.slot, "index": ref.index,
            "attachment_type": ref.attachment_type, "card_id": ref.card_id,
        }
    return {}


_CHOICE_REF_FIELDS = {
    "card": frozenset({"kind", "player", "zone", "index", "card_id"}),
    "pokemon": frozenset({"kind", "player", "slot", "card_id"}),
    "slot": frozenset({"kind", "player", "slot"}),
    "attachment": frozenset({
        "kind", "player", "slot", "attachment_type", "index", "card_id",
    }),
}


def _valid_choice_slot(value: Any) -> bool:
    if value == "active":
        return True
    if not isinstance(value, str) or not value.startswith("bench_"):
        return False
    suffix = value.removeprefix("bench_")
    return suffix.isdigit() and 0 <= int(suffix) < 5


def _choice_ref(option: ChoiceOption, _request_player: int) -> dict[str, Any]:
    """Return only a validated ChoiceView-v2 tagged-union reference.

    Choice option values belong to the authoritative continuation and are never
    an identity fallback for the public encoder.
    """
    ref = option.ref
    if isinstance(ref, CardRef):
        payload = {
            "kind": "card",
            "player": ref.player,
            "zone": ref.zone,
            "index": ref.index,
            "card_id": ref.card_id,
        }
    elif isinstance(ref, PokemonRef):
        payload = {
            "kind": "pokemon",
            "player": ref.player,
            "slot": ref.slot,
            "card_id": ref.card_id,
        }
    elif isinstance(ref, SlotRef):
        payload = {"kind": "slot", "player": ref.player, "slot": ref.slot}
    elif isinstance(ref, AttachmentRef):
        payload = {
            "kind": "attachment",
            "player": ref.player,
            "slot": ref.slot,
            "attachment_type": ref.attachment_type,
            "index": ref.index,
            "card_id": ref.card_id,
        }
    elif isinstance(ref, dict):
        payload = dict(ref)
    else:
        return {}

    kind = payload.get("kind")
    expected_fields = _CHOICE_REF_FIELDS.get(kind)
    if expected_fields is None or set(payload) != expected_fields:
        return {}
    if type(payload.get("player")) is not int or payload["player"] not in (0, 1):
        return {}
    if kind == "card":
        if (
            payload.get("zone") not in {"deck", "hand", "discard", "prizes", "stadium"}
            or type(payload.get("index")) is not int
            or payload["index"] < 0
            or not isinstance(payload.get("card_id"), str)
            or not payload["card_id"]
        ):
            return {}
    elif kind == "pokemon":
        if (
            not _valid_choice_slot(payload.get("slot"))
            or not isinstance(payload.get("card_id"), str)
            or not payload["card_id"]
        ):
            return {}
    elif kind == "slot":
        if not _valid_choice_slot(payload.get("slot")):
            return {}
    elif (
        not _valid_choice_slot(payload.get("slot"))
        or payload.get("attachment_type") not in {"energy", "tool"}
        or type(payload.get("index")) is not int
        or payload["index"] < 0
        or not isinstance(payload.get("card_id"), str)
        or not payload["card_id"]
    ):
        return {}
    return payload


def _card_id_from_option_id(option_id: str) -> str:
    parts = str(option_id).split(":")
    if len(parts) < 2:
        return ""
    candidate = parts[-1]
    return candidate if CardRegistry.get(candidate) is not None else ""


def _decision_seed(domain: str, value: str) -> int:
    """Match Godot ``AIDecisionSeed.derive(0, 0, 0, domain, value)``."""
    result = 2166136261

    def mix_byte(current: int, byte: int) -> int:
        return ((current ^ byte) * 16777619) & 0xFFFFFFFF

    def mix_int(current: int, number: int) -> int:
        normalized = number & 0xFFFFFFFF
        for shift in (0, 8, 16, 24):
            current = mix_byte(current, (normalized >> shift) & 0xFF)
        return mix_byte(current, 0xFF)

    def mix_string(current: int, text: str) -> int:
        for byte in text.encode("utf-8"):
            current = mix_byte(current, byte)
        return mix_byte(current, 0xFF)

    for number in (0, 0, 0):
        result = mix_int(result, number)
    result = mix_string(result, domain)
    result = mix_string(result, value)
    return result or 0x6D2B79F5


def _stable_string_feature(value: str) -> float:
    return (
        _decision_seed("encoder-option", value) / 4294967296.0
        if value
        else 0.0
    )


def _stable_card_identity(card_id: str) -> float:
    return (
        _decision_seed("encoder-card", card_id) / 4294967296.0
        if card_id
        else 0.0
    )


def _ref_features(ref: Any, perspective: int) -> list[float]:
    row = _ref_dict(ref)
    present = bool(row)
    player = row.get("player", -1)
    kind = str(row.get("kind", "") or "")
    zone = str(row.get("zone", "") or "")
    slot = str(row.get("slot", "") or "")
    attachment_type = str(row.get("attachment_type", "") or "")
    index = row.get("index", -1)
    values = [
        _bool(present),
        _bool(present and player == perspective),
        _bool(present and player in (0, 1) and player != perspective),
        _bool(present and player not in (0, 1)),
    ]
    values.extend(_one_hot(REF_KINDS.index(kind), len(REF_KINDS)) if kind in REF_KINDS else [0.0] * len(REF_KINDS))
    values.extend(_one_hot(REF_ZONES.index(zone), len(REF_ZONES)) if zone in REF_ZONES else [0.0] * len(REF_ZONES))
    values.extend(_one_hot(TARGET_SLOTS.index(slot), len(TARGET_SLOTS)) if slot in TARGET_SLOTS else [0.0] * len(TARGET_SLOTS))
    values.extend(
        _one_hot(ATTACHMENT_TYPES.index(attachment_type), len(ATTACHMENT_TYPES))
        if attachment_type in ATTACHMENT_TYPES
        else [0.0] * len(ATTACHMENT_TYPES)
    )
    values.append(_norm(index + 1 if type(index) is int and present else 0, 64.0))
    values.append(_stable_card_identity(str(row.get("card_id", "") or "")))
    return values


class ActionStateEncoder:
    """Encode public observations and structured candidates into fixed features."""

    state_numeric_size = STATE_NUMERIC_SIZE
    state_card_slots = STATE_CARD_SLOTS
    action_numeric_size = ACTION_NUMERIC_SIZE
    deck_keys: tuple[str, ...] = (
        "fire", "water", "psychic", "lightning", "fighting",
        "colorless", "dragon", "grass", "steel", "darkness",
    )

    @staticmethod
    def _ordered_board(
        observation: Observation,
    ) -> list[tuple[Any, ...]]:
        """Return twelve fixed rows: own active/bench, then opponent."""
        rows = {
            (int(row[0]), str(row[1])): tuple(row)
            for row in observation.board
        }
        ordered: list[tuple[Any, ...]] = []
        for player_idx in (
            observation.perspective,
            1 - observation.perspective,
        ):
            for slot in TARGET_SLOTS:
                ordered.append(
                    rows.get(
                        (player_idx, slot),
                        (player_idx, slot, "", 0, (), (), ""),
                    )
                )
        return ordered

    @staticmethod
    def _fixed_zone_ids(
        card_ids: tuple[str, ...] | list[str],
        width: int,
        *,
        take_last: bool = False,
    ) -> list[int]:
        selected = list(card_ids[-width:] if take_last else card_ids[:width])
        encoded = [card_index(card_id) for card_id in selected]
        return encoded + [CARD_PAD_INDEX] * (width - len(encoded))




    def encode_observation(
        self,
        observation: Observation,
        deck_key: str | None = None,
    ) -> EncodedState:
        self._active_deck_key = deck_key
        numeric: list[float] = []
        phases = [phase.name for phase in TurnPhase]
        numeric.extend(
            _one_hot(phases.index(observation.phase), len(phases))
            if observation.phase in phases else [0.0] * len(phases)
        )
        numeric.extend([
            _bool(observation.active_player == observation.perspective),
            _norm(observation.turn_number, 20.0),
            _bool(observation.apply_type_matchups),
            1.0 if observation.winner == observation.perspective else 0.0,
            1.0 if observation.winner == 1 - observation.perspective else 0.0,
            _norm(len(observation.own_hand), 20.0),
            _norm(len(observation.own_discard), 60.0),
            _norm(observation.own_deck_count, 60.0),
            _norm(observation.own_prize_count, 6.0),
            _norm(observation.opponent_hand_count, 20.0),
            _norm(len(observation.opponent_discard), 60.0),
            _norm(observation.opponent_deck_count, 60.0),
            _norm(observation.opponent_prize_count, 6.0),
        ])
        numeric.extend(self._deck_key_features(deck_key))
        numeric.extend([
            _norm(max(0, len(observation.own_hand) - OWN_HAND_TOKEN_COUNT), 20.0),
            _norm(max(0, len(observation.own_discard) - DISCARD_TOKEN_COUNT), 60.0),
            _norm(
                max(0, len(observation.opponent_discard) - DISCARD_TOKEN_COUNT),
                60.0,
            ),
        ])

        card_ids: list[int] = []
        for (
            player_idx,
            slot,
            card_id,
            damage,
            energy_ids,
            statuses,
            tool_id,
        ) in self._ordered_board(observation):
            card = CardRegistry.get(card_id) if card_id else None
            numeric.extend([
                _bool(bool(card_id)),
                _bool(player_idx == observation.perspective),
                _bool(slot == "active"),
                _norm(damage, 30.0),
                _norm(len(energy_ids), 6.0),
                _norm(len(statuses), 5.0),
                _bool(bool(tool_id)),
            ])
            numeric.extend(self._card_semantic_features(card))
            card_ids.append(card_index(card_id))
            encoded_energy = [
                card_index(energy_id) for energy_id in energy_ids[:4]
            ]
            card_ids.extend(
                encoded_energy
                + [CARD_PAD_INDEX] * (4 - len(encoded_energy))
            )
            card_ids.append(card_index(tool_id))

        card_ids.extend(
            self._fixed_zone_ids(
                observation.own_hand,
                OWN_HAND_TOKEN_COUNT,
            )
        )
        card_ids.extend(
            self._fixed_zone_ids(
                observation.own_discard,
                DISCARD_TOKEN_COUNT,
                take_last=True,
            )
        )
        card_ids.extend(
            self._fixed_zone_ids(
                observation.opponent_discard,
                DISCARD_TOKEN_COUNT,
                take_last=True,
            )
        )
        card_ids.append(card_index(observation.stadium_id))
        if len(card_ids) != RESERVED_TOKEN_START:
            raise RuntimeError(
                f"encoder_v6_card_layout:{len(card_ids)}"
            )
        card_ids.extend(
            [CARD_PAD_INDEX] * (STATE_CARD_SLOTS - len(card_ids))
        )
        return EncodedState(
            numeric=_pad(numeric, STATE_NUMERIC_SIZE),
            card_ids=card_ids,
        )

    def encode_game_action(
        self,
        observation: Observation,
        action: GameAction,
    ) -> EncodedAction:
        action_name = (
            action.action.name
            if isinstance(action.action, PlayerAction)
            else str(action.action)
        )
        if action_name not in ACTION_TYPES:
            raise ValueError(f"unknown_action_type:{action_name}")
        numeric: list[float] = []
        numeric.extend(_one_hot(ACTION_TYPES.index(action_name), len(ACTION_TYPES)))
        numeric.extend([
            _bool(action_name in TERMINAL_ACTIONS),
            _bool(action.actor in (None, observation.perspective)),
        ])

        params = dict(action.params or {})
        source = _ref_dict(action.source)
        target = _ref_dict(action.target)
        slot_name = (
            target.get("slot")
            or params.get("target_slot")
            or params.get("target")
            or params.get("slot")
        )
        numeric.extend(
            _one_hot(TARGET_SLOTS.index(slot_name), len(TARGET_SLOTS))
            if slot_name in TARGET_SLOTS else [0.0] * len(TARGET_SLOTS)
        )
        hand_idx = params.get("hand_idx")
        if hand_idx is None and source.get("zone") == "hand":
            hand_idx = source.get("index")
        attack_idx = params.get("attack_index", params.get("attack_idx"))
        bench_idx = params.get("bench_idx")
        if bench_idx is None and isinstance(slot_name, str) and slot_name.startswith("bench_"):
            suffix = slot_name.removeprefix("bench_")
            bench_idx = int(suffix) if suffix.isdigit() else None
        energy_indices = list(params.get("energy_indices", []) or [])
        if not energy_indices:
            for value in params.get("attachments", params.get("payment", [])) or []:
                attachment = _ref_dict(value)
                if type(attachment.get("index")) is int:
                    energy_indices.append(attachment["index"])
        numeric.extend([
            _norm(hand_idx + 1 if type(hand_idx) is int else 0, 12.0),
            _norm(attack_idx + 1 if type(attack_idx) is int else 0, 4.0),
            _norm(bench_idx + 1 if type(bench_idx) is int else 0, 5.0),
            _norm(len(energy_indices), 6.0),
            _norm(sum(1 for row in observation.board if row[2]), 12.0),
            _norm(sum(1 for row in observation.board if row[0] != observation.perspective and row[2]), 6.0),
        ])

        card_id = str(source.get("card_id", "") or "")
        if not card_id:
            if type(hand_idx) is int and 0 <= hand_idx < len(observation.own_hand):
                card_id = observation.own_hand[hand_idx]
        card = CardRegistry.get(card_id) if card_id else None
        numeric.extend(self._card_semantic_features(card))
        numeric.extend(self._deck_key_features(
            getattr(self, "_active_deck_key", None)
            or observation.public_deck_keys[observation.perspective]
            if observation.perspective < len(observation.public_deck_keys)
            else None
        ))
        numeric.extend(_ref_features(target, observation.perspective))
        numeric.extend(_ref_features(source, observation.perspective))
        for index in range(4):
            numeric.append(
                _norm(energy_indices[index] + 1, 64.0)
                if index < len(energy_indices) and type(energy_indices[index]) is int
                else 0.0
            )
        return EncodedAction(
            numeric=_pad(numeric, ACTION_NUMERIC_SIZE),
            card_id=card_index(card_id),
        )

    def encode_choice_option(
        self,
        observation: Observation,
        request_type: str,
        option: ChoiceOption,
        index: int = 0,
    ) -> EncodedAction:
        numeric: list[float] = []
        numeric.extend(_choice_type_one_hot(request_type))
        ref = _choice_ref(option, observation.perspective)
        kind = str(ref.get("kind", "") or "")
        numeric.extend([
            _norm(index + 1, 64.0),
            _bool(kind == "card"),
            _bool(kind == "pokemon"),
            _bool(kind == "attachment"),
            _bool(ref.get("player", observation.perspective) == observation.perspective),
        ])
        slot = str(ref.get("slot", "") or "")
        numeric.extend(
            _one_hot(TARGET_SLOTS.index(slot), len(TARGET_SLOTS))
            if slot in TARGET_SLOTS else [0.0] * len(TARGET_SLOTS)
        )
        card_id = str(ref.get("card_id", "") or "")
        if not card_id:
            card_id = _card_id_from_option_id(option.option_id)
        card = CardRegistry.get(card_id) if card_id else None
        numeric.extend(self._card_semantic_features(card))
        numeric.extend(_ref_features(ref, observation.perspective))
        numeric.append(_stable_string_feature(option.option_id))
        return EncodedAction(
            numeric=_pad(numeric, ACTION_NUMERIC_SIZE),
            card_id=card_index(card_id),
        )










    def _deck_key_features(self, deck_key: str | None) -> list[float]:
        return _one_hot(self.deck_keys.index(deck_key), len(self.deck_keys)) if deck_key in self.deck_keys else [0.0] * len(self.deck_keys)










    def _card_semantic_features(self, card) -> list[float]:
        """Rich semantic card features capturing what a card actually does.

        Provides explicit card-type, stats, and effect-keyword signals so the
        model can generalise across functionally similar cards.
        Returns CARD_SEMANTIC_SIZE floats (53).
        """
        if card is None:
            return [0.0] * CARD_SEMANTIC_SIZE

        subtypes = getattr(card, "subtypes", []) or []
        attacks = getattr(card, "attacks", []) or []
        energy_types = set(getattr(card, "energy_types", []) or [])
        energy_types.update(getattr(card, "provides_energy", []) or [])
        effect_names = self._card_effect_names(card)

        # --- supertype (3) ---
        supertype_onehot = [
            _bool(getattr(card, "is_pokemon", False)),
            _bool(getattr(card, "is_trainer", False)),
            _bool(getattr(card, "is_energy", False)),
        ]

        # --- stage (5): Basic / Stage1 / Stage2 / Restored / None ---
        stage_onehot = [
            _bool("Basic" in subtypes or getattr(card, "is_basic_pokemon", False)),
            _bool("Stage 1" in subtypes or getattr(card, "is_stage1", False)),
            _bool("Stage 2" in subtypes or getattr(card, "is_stage2", False)),
            _bool("Restored" in subtypes),
            _bool(not any(t in subtypes for t in ("Basic", "Stage 1", "Stage 2", "Restored"))),
        ]

        # --- trainer_type (5): Item / Supporter / Stadium / Tool / None ---
        trainer_type_onehot = [
            _bool(getattr(card, "is_trainer_item", False)),
            _bool(getattr(card, "is_trainer_supporter", False)),
            _bool(getattr(card, "is_trainer_stadium", False)),
            _bool(getattr(card, "is_trainer_tool", False)),
            _bool(not getattr(card, "is_trainer", False)),
        ]

        # --- energy_type multi-hot (12): 11 specific + None ---
        energy_type_flags = [_bool(t in energy_types) for t in ENERGY_TYPES]
        energy_type_flags.append(_bool(not energy_types))

        # --- numerical stats (8) ---
        max_damage = max((self._damage_value(getattr(atk, "damage", 0)) for atk in attacks), default=0)
        min_energy_cost = min((len(getattr(atk, "cost", []) or []) for atk in attacks), default=0) if attacks else 0
        max_energy_cost = max((len(getattr(atk, "cost", []) or []) for atk in attacks), default=0) if attacks else 0
        total_damage = sum(self._damage_value(getattr(atk, "damage", 0)) for atk in attacks)
        cost_efficiency = total_damage / max(1, max_energy_cost) / 100.0
        numerical = [
            min(getattr(card, "hp", 0) / 350.0, 1.0),
            min(getattr(card, "retreat_cost", 0) / 5.0, 1.0),
            min(len(attacks) / 3.0, 1.0),
            min(max_damage / 300.0, 1.0),
            min(max_energy_cost / 5.0, 1.0),
            min(cost_efficiency, 2.0),
            min(getattr(card, "prize_value", 0) / 3.0, 1.0),
            min(min_energy_cost / 5.0, 1.0),
        ]

        # --- flags (8) ---
        has_non_damage_attack = any(
            self._damage_value(getattr(atk, "damage", 0)) == 0 for atk in attacks
        ) if attacks else False
        has_bench_damage = any(
            "bench" in getattr(atk, "text", "").lower() for atk in attacks
        ) if attacks else False
        flags = [
            _bool(getattr(card, "abilities", [])),
            _bool("ex" in subtypes or "V" in subtypes or "GX" in subtypes or "EX" in subtypes),
            _bool(any(t in subtypes for t in ("VMAX", "VSTAR", "V-UNION", "TAG TEAM"))),
            _bool(getattr(card, "is_special_energy", False)),
            _bool(has_non_damage_attack),
            _bool(has_bench_damage),
            _bool(getattr(card, "evolves_from", "") != ""),
            _bool(getattr(card, "evolves_to", [])),
        ]

        # --- effect keywords (12) ---
        effect_flags = [_bool(t in effect_names) for t in EFFECT_TYPES]

        features: list[float] = []
        features.extend(supertype_onehot)
        features.extend(stage_onehot)
        features.extend(trainer_type_onehot)
        features.extend(energy_type_flags)
        features.extend(numerical)
        features.extend(flags)
        features.extend(effect_flags)
        return _pad(features, CARD_SEMANTIC_SIZE)







    def _damage_value(self, value) -> int:
        try:
            return int(value or 0)
        except (TypeError, ValueError):
            digits = "".join(ch for ch in str(value) if ch.isdigit())
            return int(digits) if digits else 0




    def _card_effect_names(self, card) -> set[str]:
        names: list[str] = []
        for attack in getattr(card, "attacks", []) or []:
            for effect in self._iter_effects_recursive(attack_runtime_effects(attack)):
                names.append(self._effect_name(effect))
            names.append(getattr(attack, "text", "") or "")
        for ability in getattr(card, "abilities", []) or []:
            names.append(getattr(ability, "text", "") or "")
            for effect in self._iter_effects_recursive(ability_runtime_effects(ability)):
                names.append(self._effect_name(effect))
        for effect in self._iter_effects_recursive(trainer_runtime_effects(card)):
            names.append(self._effect_name(effect))
        names.extend(getattr(card, "rules", []) or [])
        names.append(getattr(card, "trainer_text", "") or "")
        return self._normalized_effect_tokens(names)



    def _effect_name(self, effect) -> str:
        return " ".join(effect_feature_names(effect))


    def _iter_effects_recursive(self, effects):
        yield from iter_effects_recursive(effects)

    def _normalized_effect_tokens(self, names) -> set[str]:
        joined = " ".join(str(name) for name in names).lower()
        tokens = set()
        for token in EFFECT_TYPES:
            if token in joined:
                tokens.add(token)
        if "attach" in joined:
            tokens.add("energy")
        if "prevent" in joined:
            tokens.add("prevent")
        return tokens
