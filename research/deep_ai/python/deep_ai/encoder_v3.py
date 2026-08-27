"""Lossless-for-valid-decks information-set encoder for Deep AI v3.

The encoder accepts only a native information-set observation. Hidden deck,
prize and opponent-hand identities must already be replaced by native marker
values.  Entity rows are deterministic grouped multisets, so no visible card
is silently dropped when a hand or discard pile grows.
"""
from __future__ import annotations

import json
from collections import Counter
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

import numpy as np

from .card_vocab import card_vocab_index, card_vocab_size

from .v3_contract import (
    CANDIDATE_NUMERIC_SIZE,
    CANDIDATE_REF_FIELDS,
    CARD_SEMANTIC_SIZE,
    ENCODER_SCHEMA_VERSION,
    ENTITY_NUMERIC_SIZE,
    ENTITY_SLOTS,
    ENTITY_TYPE_FIELDS,
    RELEASE_DECKS,
    STATE_GLOBAL_SIZE,
    deck_index,
)


REPO_ROOT = Path(__file__).resolve().parents[4]
HIDDEN_MARKERS = frozenset({"__hidden_card__", "__hidden_prize__", ""})
TARGET_SLOTS = ("active", "bench_0", "bench_1", "bench_2", "bench_3", "bench_4")
PHASES = ("SETUP", "DRAW", "MAIN", "ATTACK", "POKEMON_CHECKUP", "GAME_OVER")
SETUP_STAGES = (
    "TURN_ORDER",
    "INITIAL_PLACEMENT",
    "BONUS_DRAW",
    "BONUS_PLACEMENT",
    "COMPLETE",
)
STATUS_NAMES = ("POISONED", "BURNED", "ASLEEP", "PARALYZED", "CONFUSED")

ZONE_IDS = {
    "": 0,
    "active": 1,
    "bench": 2,
    "hand": 3,
    "discard": 4,
    "stadium": 5,
    "energy": 6,
    "tool": 7,
    "evolution": 8,
}
SLOT_IDS = {"": 0, "active": 1}
SLOT_IDS.update({f"bench_{index}": index + 2 for index in range(5)})

ACTION_TYPES = (
    "PLAY_BASIC",
    "EVOLVE",
    "ATTACH_ENERGY",
    "PLAY_TRAINER",
    "USE_ABILITY",
    "USE_STADIUM",
    "RETREAT",
    "DECLARE_ATTACK",
    "PROMOTE",
    "SETUP_DONE",
    "END_TURN",
)
CHOICE_TYPES = (
    "select_card",
    "select_pokemon",
    "select_attachment",
    "distribute_energy",
    "confirm",
    "select_prize",
    "setup",
    "coin_flip",
    "order",
)
CHOICE_ALIASES = {
    "choose_mulligan_draw_count": "setup",
    "choose_turn_order": "setup",
    "confirm_trigger": "confirm",
    "select_retreat_payment": "select_attachment",
    "choose_trigger_order": "order",
    "select_prize_energy_target": "select_pokemon",
}


def _norm(value: float, scale: float) -> float:
    return float(max(-1.0, min(1.0, float(value) / max(scale, 1e-6))))


def _field(row: Any, key: str, fallback: Any = None) -> Any:
    return row.get(key, fallback) if isinstance(row, Mapping) else fallback


def _player(observation: Mapping[str, Any], index: int) -> Mapping[str, Any]:
    players = observation.get("players")
    if not isinstance(players, Sequence) or len(players) != 2:
        raise ValueError("v3_encoder_invalid_players")
    row = players[index]
    if not isinstance(row, Mapping):
        raise ValueError("v3_encoder_invalid_player")
    return row


def _card_id(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, Mapping):
        return str(value.get("card_id", "") or "")
    return str(getattr(value, "api_id", "") or "")


def _visible_card_id(value: Any) -> str:
    card_id = _card_id(value)
    return "" if card_id in HIDDEN_MARKERS else card_id


def _card_index(card_id: str) -> int:
    return int(card_vocab_index(str(card_id or "")))


def _require_array(
    array: np.ndarray,
    dtype: Any,
    shape: tuple[int, ...],
    name: str,
) -> None:
    if not isinstance(array, np.ndarray):
        raise TypeError(f"{name}_not_ndarray")
    if array.dtype != dtype:
        raise TypeError(f"{name}_dtype:{array.dtype}!={dtype}")
    if array.shape != shape:
        raise ValueError(f"{name}_shape:{array.shape}!={shape}")
    if not array.flags.c_contiguous:
        raise ValueError(f"{name}_not_contiguous")
    if np.issubdtype(array.dtype, np.floating) and not np.isfinite(array).all():
        raise ValueError(f"{name}_non_finite")


@dataclass(frozen=True, slots=True)
class EncodedInformationSetV3:
    state_global: np.ndarray
    entity_numeric: np.ndarray
    entity_card_ids: np.ndarray
    entity_type_ids: np.ndarray
    entity_mask: np.ndarray
    actor_deck_id: np.int64
    opponent_deck_id: np.int64

    def validate(self) -> None:
        _require_array(
            self.state_global,
            np.float32,
            (STATE_GLOBAL_SIZE,),
            "state_global",
        )
        _require_array(
            self.entity_numeric,
            np.float32,
            (ENTITY_SLOTS, ENTITY_NUMERIC_SIZE),
            "entity_numeric",
        )
        _require_array(
            self.entity_card_ids,
            np.int64,
            (ENTITY_SLOTS,),
            "entity_card_ids",
        )
        _require_array(
            self.entity_type_ids,
            np.int64,
            (ENTITY_SLOTS, ENTITY_TYPE_FIELDS),
            "entity_type_ids",
        )
        _require_array(
            self.entity_mask,
            np.bool_,
            (ENTITY_SLOTS,),
            "entity_mask",
        )
        if int(self.entity_mask.sum()) < 12:
            raise ValueError("v3_encoder_board_tokens_missing")
        if np.any(self.entity_card_ids < 0) or np.any(
            self.entity_card_ids >= card_vocab_size()
        ):
            raise ValueError("v3_encoder_card_id_out_of_range")


@dataclass(frozen=True, slots=True)
class EncodedCandidatesV3:
    numeric: np.ndarray
    card_ids: np.ndarray
    type_ids: np.ndarray
    refs: np.ndarray
    mask: np.ndarray

    @property
    def count(self) -> int:
        return int(self.card_ids.shape[0])

    def validate(self) -> None:
        count = self.count
        if count <= 0:
            raise ValueError("candidate_set_empty")
        _require_array(
            self.numeric,
            np.float32,
            (count, CANDIDATE_NUMERIC_SIZE),
            "candidate_numeric",
        )
        _require_array(self.card_ids, np.int64, (count,), "candidate_card_ids")
        _require_array(self.type_ids, np.int64, (count,), "candidate_type_ids")
        _require_array(
            self.refs,
            np.int64,
            (count, CANDIDATE_REF_FIELDS),
            "candidate_refs",
        )
        _require_array(self.mask, np.bool_, (count,), "candidate_mask")
        if not bool(self.mask.all()):
            raise ValueError("unpadded_candidates_must_all_be_valid")


class InformationSetEncoderV8:
    """Encode a native actor observation and its legal candidates."""

    schema_version = ENCODER_SCHEMA_VERSION

    def encode_information_set(
        self,
        observation: Mapping[str, Any],
        request: Mapping[str, Any] | None = None,
    ) -> EncodedInformationSetV3:
        if not isinstance(observation, Mapping):
            raise TypeError("v3_encoder_requires_native_observation")
        perspective = int(observation.get("perspective", -1))
        if perspective not in (0, 1):
            raise ValueError("v3_encoder_invalid_perspective")
        own = _player(observation, perspective)
        opponent = _player(observation, 1 - perspective)
        self._reject_hidden_identity_leaks(own, opponent)

        global_values = np.zeros(STATE_GLOBAL_SIZE, dtype=np.float32)
        phase = str(observation.get("phase", ""))
        if phase in PHASES:
            global_values[PHASES.index(phase)] = 1.0
        global_values[16:31] = np.asarray(
            (
                int(observation.get("active_player_idx", -1)) == perspective,
                int(observation.get("first_player_idx", -1)) == perspective,
                _norm(int(observation.get("turn_number", 0)), 30.0),
                bool(observation.get("apply_type_matchups", False)),
                int(observation.get("winner", -1)) == perspective,
                int(observation.get("winner", -1)) == 1 - perspective,
                _norm(len(list(own.get("hand", ()) or ())), 20.0),
                _norm(len(list(own.get("discard", ()) or ())), 60.0),
                _norm(len(list(own.get("deck", ()) or ())), 60.0),
                _norm(len(list(own.get("prizes", ()) or ())), 6.0),
                _norm(len(list(opponent.get("hand", ()) or ())), 20.0),
                _norm(len(list(opponent.get("discard", ()) or ())), 60.0),
                _norm(len(list(opponent.get("deck", ()) or ())), 60.0),
                _norm(len(list(opponent.get("prizes", ()) or ())), 6.0),
                int(observation.get("revision", 0)) % 2,
            ),
            dtype=np.float32,
        )
        keys = list(observation.get("public_deck_keys", ("", "")) or ("", ""))
        own_key = str(keys[perspective] or "") if len(keys) == 2 else ""
        opponent_key = str(keys[1 - perspective] or "") if len(keys) == 2 else ""
        own_deck_id = deck_index(own_key)
        opponent_deck_id = deck_index(opponent_key)
        global_values[32 + own_deck_id] = 1.0
        global_values[42 + opponent_deck_id] = 1.0

        setup_stage = str(observation.get("setup_stage", ""))
        if setup_stage in SETUP_STAGES:
            global_values[52 + SETUP_STAGES.index(setup_stage)] = 1.0
        cursor = 64
        for player in (own, opponent):
            flags = (
                "supporter_played_this_turn",
                "energy_attached_this_turn",
                "retreated_this_turn",
                "stadium_played_this_turn",
                "stadium_used_this_turn",
                "healed_this_turn",
                "vstar_power_used",
                "was_ko_by_attack",
            )
            for name in flags:
                global_values[cursor] = float(bool(player.get(name, False)))
                cursor += 1
        global_values[80] = _norm(
            len(list(observation.get("pending_promotions", ()) or ())),
            2.0,
        )
        facts = observation.get("turn_fact_book", {})
        if isinstance(facts, Mapping):
            for offset, name in enumerate(("previous_turn", "current_turn")):
                window = facts.get(name, {})
                rows = window.get("knockouts", ()) if isinstance(window, Mapping) else ()
                global_values[81 + offset] = _norm(len(list(rows or ())), 6.0)
        self._encode_request(global_values, request)

        numeric = np.zeros(
            (ENTITY_SLOTS, ENTITY_NUMERIC_SIZE),
            dtype=np.float32,
        )
        card_ids = np.zeros(ENTITY_SLOTS, dtype=np.int64)
        type_ids = np.zeros(
            (ENTITY_SLOTS, ENTITY_TYPE_FIELDS),
            dtype=np.int64,
        )
        mask = np.zeros(ENTITY_SLOTS, dtype=np.bool_)
        next_index = self._encode_board(
            observation,
            perspective,
            numeric,
            card_ids,
            type_ids,
            mask,
        )
        groups = self._visible_groups(observation, perspective)
        if next_index + len(groups) > ENTITY_SLOTS:
            raise ValueError(
                "v3_entity_overflow:"
                f"required={next_index + len(groups)}:limit={ENTITY_SLOTS}"
            )
        for row in groups:
            owner, zone, slot, token_type, card_id, count = row
            mask[next_index] = True
            card_ids[next_index] = _card_index(card_id)
            type_ids[next_index] = (
                token_type,
                owner,
                ZONE_IDS[zone],
                SLOT_IDS.get(slot, 0),
            )
            numeric[next_index, 0] = 1.0
            numeric[next_index, 1] = _norm(count, 60.0)
            numeric[next_index, 2] = _norm(count, 4.0)
            next_index += 1

        result = EncodedInformationSetV3(
            np.ascontiguousarray(global_values),
            np.ascontiguousarray(numeric),
            np.ascontiguousarray(card_ids),
            np.ascontiguousarray(type_ids),
            np.ascontiguousarray(mask),
            np.int64(own_deck_id),
            np.int64(opponent_deck_id),
        )
        result.validate()
        return result

    @staticmethod
    def _reject_hidden_identity_leaks(
        own: Mapping[str, Any],
        opponent: Mapping[str, Any],
    ) -> None:
        for player, zones in ((own, ("deck", "prizes")), (opponent, ("deck", "hand", "prizes"))):
            for zone in zones:
                values = list(player.get(zone, ()) or ())
                if any(_card_id(value) not in HIDDEN_MARKERS for value in values):
                    raise ValueError(f"v3_hidden_identity_exposed:{zone}")

    @staticmethod
    def _encode_request(
        global_values: np.ndarray,
        request: Mapping[str, Any] | None,
    ) -> None:
        if not isinstance(request, Mapping):
            return
        normalized = CHOICE_ALIASES.get(
            str(request.get("request_type", "")),
            str(request.get("request_type", "")),
        )
        if normalized in CHOICE_TYPES:
            global_values[96 + CHOICE_TYPES.index(normalized)] = 1.0
        global_values[112] = _norm(int(request.get("min_select", 0)), 60.0)
        global_values[113] = _norm(int(request.get("max_select", 0)), 60.0)
        global_values[114] = float(bool(request.get("allow_duplicates", False)))
        global_values[115] = float(bool(request.get("can_cancel", False)))
        global_values[116] = _norm(len(list(request.get("options", ()) or ())), 256.0)

    def _encode_board(
        self,
        observation: Mapping[str, Any],
        perspective: int,
        numeric: np.ndarray,
        card_ids: np.ndarray,
        type_ids: np.ndarray,
        mask: np.ndarray,
    ) -> int:
        index = 0
        for player_index in (perspective, 1 - perspective):
            player = _player(observation, player_index)
            bench = list(player.get("bench", ()) or ())
            for slot in TARGET_SLOTS:
                pokemon = (
                    player.get("active")
                    if slot == "active"
                    else bench[int(slot[-1])] if int(slot[-1]) < len(bench) else None
                )
                pokemon = pokemon if isinstance(pokemon, Mapping) else {}
                mask[index] = True
                card_id = _visible_card_id(pokemon)
                card_ids[index] = _card_index(card_id)
                type_ids[index] = (
                    1,
                    1 if player_index == perspective else 2,
                    ZONE_IDS["active" if slot == "active" else "bench"],
                    SLOT_IDS[slot],
                )
                energies = list(pokemon.get("energy_card_ids", ()) or ())
                statuses = {str(value) for value in pokemon.get("status_conditions", ()) or ()}
                values = (
                    bool(card_id),
                    1.0,
                    slot == "active",
                    _norm(int(pokemon.get("damage_counters", 0)), 30.0),
                    _norm(len(energies), 12.0),
                    bool(pokemon.get("attached_tool_id")),
                    *(name in statuses for name in STATUS_NAMES),
                    bool(pokemon.get("can_evolve_this_turn", False)),
                    bool(pokemon.get("placed_this_turn", False)),
                    _norm(len(list(pokemon.get("used_abilities", ()) or ())), 4.0),
                    bool(pokemon.get("damage_prevented", False)),
                    bool(pokemon.get("all_prevented", False)),
                    _norm(int(pokemon.get("outgoing_damage_reduction", 0)), 300.0),
                    bool(pokemon.get("attack_locked", False)),
                    bool(pokemon.get("dazzled", False)),
                    bool(pokemon.get("healed_this_turn", False)),
                    _norm(int(pokemon.get("paralyzed_since_turn", 0)), 30.0),
                    _norm(len(list(pokemon.get("modifiers", ()) or ())), 8.0),
                    _norm(len(list(pokemon.get("max_hp_modifiers", ()) or ())), 8.0),
                )
                numeric[index, : len(values)] = np.asarray(values, dtype=np.float32)
                index += 1
        return index

    @staticmethod
    def _visible_groups(
        observation: Mapping[str, Any],
        perspective: int,
    ) -> list[tuple[int, str, str, int, str, int]]:
        groups: Counter[tuple[int, str, str, int, str]] = Counter()

        def add(owner: int, zone: str, slot: str, token_type: int, values: Iterable[Any]) -> None:
            for value in values:
                card_id = _visible_card_id(value)
                if card_id:
                    groups[(owner, zone, slot, token_type, card_id)] += 1

        for player_index in (perspective, 1 - perspective):
            owner = 1 if player_index == perspective else 2
            player = _player(observation, player_index)
            if player_index == perspective:
                add(owner, "hand", "", 4, player.get("hand", ()) or ())
            add(owner, "discard", "", 5 if owner == 1 else 6, player.get("discard", ()) or ())
            bench = list(player.get("bench", ()) or ())
            for slot in TARGET_SLOTS:
                pokemon = (
                    player.get("active")
                    if slot == "active"
                    else bench[int(slot[-1])] if int(slot[-1]) < len(bench) else None
                )
                if not isinstance(pokemon, Mapping):
                    continue
                add(owner, "energy", slot, 2, pokemon.get("energy_card_ids", ()) or ())
                add(owner, "evolution", slot, 8, pokemon.get("evolution_stack_ids", ()) or ())
                tool = _visible_card_id(pokemon.get("attached_tool_id", ""))
                if tool:
                    groups[(owner, "tool", slot, 3, tool)] += 1
        stadium = _visible_card_id(observation.get("stadium_card_id", ""))
        if stadium:
            groups[(0, "stadium", "", 7, stadium)] += 1
        return [(*key, count) for key, count in sorted(groups.items())]

    def encode_actions(
        self,
        observation: Mapping[str, Any],
        actions: Sequence[Mapping[str, Any]],
    ) -> EncodedCandidatesV3:
        return self._encode_candidates(observation, actions, None)

    def encode_choices(
        self,
        observation: Mapping[str, Any],
        request: Mapping[str, Any],
        candidates: Sequence[Mapping[str, Any]],
    ) -> EncodedCandidatesV3:
        return self._encode_candidates(observation, candidates, request)

    def _encode_candidates(
        self,
        observation: Mapping[str, Any],
        candidates: Sequence[Mapping[str, Any]],
        request: Mapping[str, Any] | None,
    ) -> EncodedCandidatesV3:
        if not candidates:
            raise ValueError("candidate_set_empty")
        count = len(candidates)
        numeric = np.zeros((count, CANDIDATE_NUMERIC_SIZE), dtype=np.float32)
        card_ids = np.zeros(count, dtype=np.int64)
        type_ids = np.zeros(count, dtype=np.int64)
        refs = np.zeros((count, CANDIDATE_REF_FIELDS), dtype=np.int64)
        perspective = int(observation.get("perspective", -1))
        request_type = (
            CHOICE_ALIASES.get(str(request.get("request_type", "")), str(request.get("request_type", "")))
            if isinstance(request, Mapping)
            else ""
        )
        option_by_id = {
            str(row.get("option_id", "")): row
            for row in list(request.get("options", ()) or ())
            if isinstance(row, Mapping)
        } if isinstance(request, Mapping) else {}
        presentation = (
            request.get("presentation", request.get("metadata", {}))
            if isinstance(request, Mapping)
            else {}
        )
        presentation = presentation if isinstance(presentation, Mapping) else {}
        for index, candidate in enumerate(candidates):
            if not isinstance(candidate, Mapping):
                raise TypeError("invalid_v3_candidate")
            choice = isinstance(request, Mapping) or str(candidate.get("kind", "")) == "choice"
            source = candidate.get("source")
            target = candidate.get("target")
            selected = list(candidate.get("selected_options", ()) or ())
            if choice and selected:
                first = option_by_id.get(str(selected[0]), {})
                second = option_by_id.get(str(selected[1]), {}) if len(selected) > 1 else {}
                source = first.get("ref", first)
                target = second.get("ref", second)
                if request_type == "distribute_energy":
                    energy = self._energy_option_identity(str(selected[0]))
                    if energy is not None:
                        target = first.get("ref", first)
                        source = {
                            "kind": "card",
                            "player": int(request.get("player", perspective)),
                            "zone": str(presentation.get("source_zone", "")),
                            "index": energy[0],
                            "card_id": energy[1],
                        }
            source_row = source if isinstance(source, Mapping) else {}
            target_row = target if isinstance(target, Mapping) else {}
            payload = candidate.get("payload", {})
            payload = payload if isinstance(payload, Mapping) else {}
            card_id = _visible_card_id(source_row) or _visible_card_id(target_row)
            card_ids[index] = _card_index(card_id)
            if choice:
                normalized = request_type if request_type in CHOICE_TYPES else "select_card"
                type_ids[index] = len(ACTION_TYPES) + CHOICE_TYPES.index(normalized) + 1
            else:
                kind = str(candidate.get("kind", ""))
                if kind not in ACTION_TYPES:
                    raise ValueError(f"unknown_v3_action_type:{kind}")
                type_ids[index] = ACTION_TYPES.index(kind) + 1
            refs[index, :4] = self._encode_ref(source_row)
            refs[index, 4:] = self._encode_ref(target_row)
            numeric[index, :18] = np.asarray(
                (
                    choice,
                    bool(candidate.get("cancelled", False)),
                    str(candidate.get("kind", "")) in {"DECLARE_ATTACK", "SETUP_DONE", "END_TURN"},
                    int(candidate.get("actor", perspective)) == perspective,
                    _norm(int(payload.get("hand_idx", source_row.get("index", -1))) + 1, 60.0),
                    _norm(int(payload.get("attack_index", payload.get("attack_idx", -1))) + 1, 4.0),
                    _norm(int(payload.get("ability_index", -1)) + 1, 8.0),
                    _norm(len(selected), 60.0),
                    _norm(len(list(payload.get("energy_indices", ()) or ())), 12.0),
                    _norm(int(payload.get("amount", payload.get("count", 0))), 60.0),
                    _norm(index + 1, 256.0),
                    bool(source_row),
                    bool(target_row),
                    int(source_row.get("player", -1)) == perspective,
                    int(target_row.get("player", -1)) == perspective,
                    _norm(int(request.get("min_select", 0)), 60.0) if isinstance(request, Mapping) else 0.0,
                    _norm(int(request.get("max_select", 0)), 60.0) if isinstance(request, Mapping) else 0.0,
                    float(bool(request.get("allow_duplicates", False))) if isinstance(request, Mapping) else 0.0,
                ),
                dtype=np.float32,
            )
        result = EncodedCandidatesV3(
            np.ascontiguousarray(numeric),
            np.ascontiguousarray(card_ids),
            np.ascontiguousarray(type_ids),
            np.ascontiguousarray(refs),
            np.ones(count, dtype=np.bool_),
        )
        result.validate()
        return result

    @staticmethod
    def _energy_option_identity(option_id: str) -> tuple[int, str] | None:
        if not option_id.startswith("energy:"):
            return None
        prefix = len("energy:")
        index_end = option_id.find(":", prefix)
        identity_end = option_id.find("->", index_end + 1)
        if index_end < 0 or identity_end <= index_end + 1:
            return None
        try:
            index = int(option_id[prefix:index_end])
        except ValueError:
            return None
        card_id = option_id[index_end + 1 : identity_end]
        return (index, card_id) if index >= 0 and card_id else None

    @staticmethod
    def _encode_ref(row: Mapping[str, Any]) -> np.ndarray:
        if not row:
            return np.zeros(4, dtype=np.int64)
        owner = int(row.get("player", -1))
        zone = str(row.get("zone", ""))
        slot = str(row.get("slot", ""))
        return np.asarray(
            (
                owner + 2 if owner in (-1, 0, 1) else 0,
                ZONE_IDS.get(zone, 0),
                SLOT_IDS.get(slot, 0),
                max(0, int(row.get("index", -1)) + 1),
            ),
            dtype=np.int64,
        )


@lru_cache(maxsize=1)
def card_semantic_table() -> np.ndarray:
    cards = json.loads(
        (REPO_ROOT / "godot" / "data" / "cards.json").read_text(
            encoding="utf-8"
        )
    )
    result = np.zeros(
        (card_vocab_size(), CARD_SEMANTIC_SIZE),
        dtype=np.float32,
    )
    for card_id, definition in cards.items():
        index = _card_index(str(card_id))
        features = list(definition.get("ai_semantic_features", ()) or ())
        if 0 <= index < result.shape[0]:
            width = min(CARD_SEMANTIC_SIZE, len(features))
            result[index, :width] = np.asarray(features[:width], dtype=np.float32)
    return np.ascontiguousarray(result)
