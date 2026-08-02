"""Structured, privacy-safe encoder for AlphaZero v2."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable, Sequence

import numpy as np

from data.ai_card_vocab import card_vocab_size
from engine.actions import ChoiceOption, GameAction
from engine.ai.dl.encoder import (
    ACTION_TYPES,
    CHOICE_TYPE_ALIASES,
    CHOICE_TYPES,
    STATE_TOKEN_OWNERS,
    STATE_TOKEN_TYPES,
    TARGET_SLOTS,
    ActionStateEncoder,
)
from engine.ai.observation import Observation
from engine.enums import TurnPhase

from .v2_contract import (
    CANDIDATE_NUMERIC_SIZE,
    CANDIDATE_REF_FIELDS,
    ENCODER_SCHEMA_VERSION,
    ENTITY_NUMERIC_SIZE,
    ENTITY_SLOTS,
    ENTITY_TYPE_FIELDS,
    RELEASE_DECKS,
    STATE_GLOBAL_SIZE,
    deck_index,
)


ZONE_IDS = {
    "": 0,
    "active": 1,
    "bench": 2,
    "hand": 3,
    "discard": 4,
    "stadium": 5,
    "energy": 6,
    "tool": 7,
    "deck": 8,
    "prizes": 9,
    "field": 10,
}

SLOT_IDS = {"": 0, "active": 1}
SLOT_IDS.update({f"bench_{index}": index + 2 for index in range(5)})

ACTION_TYPE_IDS = {
    name: index + 1
    for index, name in enumerate((*ACTION_TYPES, *CHOICE_TYPES))
}


@dataclass(frozen=True)
class EncodedInformationSet:
    state_global: np.ndarray
    entity_numeric: np.ndarray
    entity_card_ids: np.ndarray
    entity_type_ids: np.ndarray
    actor_deck_id: np.int64
    opponent_deck_id: np.int64

    def validate(self) -> None:
        _require(self.state_global, np.float32, (STATE_GLOBAL_SIZE,))
        _require(
            self.entity_numeric,
            np.float32,
            (ENTITY_SLOTS, ENTITY_NUMERIC_SIZE),
        )
        _require(self.entity_card_ids, np.int64, (ENTITY_SLOTS,))
        _require(
            self.entity_type_ids,
            np.int64,
            (ENTITY_SLOTS, ENTITY_TYPE_FIELDS),
        )
        if np.any(self.entity_card_ids < 0):
            raise ValueError("negative_entity_card_id")
        if np.any(self.entity_card_ids >= card_vocab_size()):
            raise ValueError("entity_card_id_out_of_range")


@dataclass(frozen=True)
class EncodedCandidates:
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
        _require(
            self.numeric,
            np.float32,
            (count, CANDIDATE_NUMERIC_SIZE),
        )
        _require(self.card_ids, np.int64, (count,))
        _require(self.type_ids, np.int64, (count,))
        _require(self.refs, np.int64, (count, CANDIDATE_REF_FIELDS))
        _require(self.mask, np.bool_, (count,))
        if not bool(self.mask.any()):
            raise ValueError("candidate_mask_empty")


@dataclass(frozen=True)
class EncodedDecision:
    information_set: EncodedInformationSet
    candidates: EncodedCandidates

    def validate(self) -> None:
        self.information_set.validate()
        self.candidates.validate()


def _require(array: np.ndarray, dtype: Any, shape: tuple[int, ...]) -> None:
    if not isinstance(array, np.ndarray):
        raise TypeError("encoder_output_not_ndarray")
    if array.dtype != dtype:
        raise TypeError(f"encoder_dtype:{array.dtype}!={dtype}")
    if array.shape != shape:
        raise ValueError(f"encoder_shape:{array.shape}!={shape}")
    if not array.flags.c_contiguous:
        raise ValueError("encoder_output_not_contiguous")
    if np.issubdtype(array.dtype, np.floating) and not np.isfinite(array).all():
        raise ValueError("encoder_non_finite")


def _card_index(card_id: str) -> int:
    from data.ai_card_vocab import card_vocab_index

    return int(card_vocab_index(card_id or ""))


def _normalized(value: float, scale: float) -> float:
    return max(-1.0, min(1.0, float(value) / max(1e-6, scale)))


def _phase_index(name: str) -> int:
    names = [phase.name for phase in TurnPhase]
    try:
        return names.index(str(name))
    except ValueError:
        return -1


def _deck_key(
    observation: Observation,
    player: int,
    fallback: str | None,
) -> str | None:
    keys = tuple(observation.public_deck_keys or ())
    if 0 <= player < len(keys) and keys[player]:
        return str(keys[player])
    return fallback


def _reference_mapping(value: Any) -> dict[str, Any]:
    if value is None:
        return {}
    if hasattr(value, "to_dict"):
        return dict(value.to_dict())
    if isinstance(value, dict):
        return dict(value)
    player = getattr(value, "player", None)
    if type(player) is not int:
        return {}
    result: dict[str, Any] = {"player": player}
    zone = getattr(value, "zone", None)
    slot = getattr(value, "slot", None)
    index = getattr(value, "index", None)
    card_id = getattr(value, "card_id", None)
    attachment_type = getattr(value, "attachment_type", None)
    if isinstance(zone, str):
        result.update({"kind": "card", "zone": zone})
    elif isinstance(attachment_type, str):
        result.update({
            "kind": "attachment",
            "attachment_type": attachment_type,
        })
    elif isinstance(slot, str) and isinstance(card_id, str):
        result["kind"] = "pokemon"
    elif isinstance(slot, str):
        result["kind"] = "slot"
    else:
        return {}
    if isinstance(slot, str):
        result["slot"] = slot
    if type(index) is int:
        result["index"] = index
    if isinstance(card_id, str):
        result["card_id"] = card_id
    return result


class InformationSetEncoderV7:
    """Encode only an actor's observation; full hidden state is never accepted."""

    schema_version = ENCODER_SCHEMA_VERSION
    state_global_size = STATE_GLOBAL_SIZE
    entity_slots = ENTITY_SLOTS
    entity_numeric_size = ENTITY_NUMERIC_SIZE
    candidate_numeric_size = CANDIDATE_NUMERIC_SIZE

    def __init__(self) -> None:
        self._candidate_encoder = ActionStateEncoder()

    def encode_information_set(
        self,
        observation: Observation,
        actor_deck_key: str | None = None,
    ) -> EncodedInformationSet:
        if not isinstance(observation, Observation):
            raise TypeError("v2_encoder_requires_observation")

        global_values = np.zeros(STATE_GLOBAL_SIZE, dtype=np.float32)
        phase = _phase_index(observation.phase)
        if phase >= 0 and phase < 16:
            global_values[phase] = 1.0
        cursor = 16
        scalar_values = (
            observation.active_player == observation.perspective,
            _normalized(observation.turn_number, 30.0),
            observation.apply_type_matchups,
            observation.winner == observation.perspective,
            observation.winner == 1 - observation.perspective,
            _normalized(len(observation.own_hand), 20.0),
            _normalized(len(observation.own_discard), 60.0),
            _normalized(observation.own_deck_count, 60.0),
            _normalized(observation.own_prize_count, 6.0),
            _normalized(observation.opponent_hand_count, 20.0),
            _normalized(len(observation.opponent_discard), 60.0),
            _normalized(observation.opponent_deck_count, 60.0),
            _normalized(observation.opponent_prize_count, 6.0),
        )
        global_values[cursor:cursor + len(scalar_values)] = scalar_values
        cursor += len(scalar_values)

        own_key = _deck_key(
            observation,
            observation.perspective,
            actor_deck_key,
        )
        opponent_key = _deck_key(
            observation,
            1 - observation.perspective,
            None,
        )
        global_values[cursor + deck_index(own_key)] = 1.0
        cursor += len(RELEASE_DECKS)
        global_values[cursor + deck_index(opponent_key)] = 1.0

        entity_numeric = np.zeros(
            (ENTITY_SLOTS, ENTITY_NUMERIC_SIZE),
            dtype=np.float32,
        )
        entity_card_ids = np.zeros(ENTITY_SLOTS, dtype=np.int64)
        entity_type_ids = np.zeros(
            (ENTITY_SLOTS, ENTITY_TYPE_FIELDS),
            dtype=np.int64,
        )
        self._encode_entities(
            observation,
            entity_numeric,
            entity_card_ids,
            entity_type_ids,
        )
        result = EncodedInformationSet(
            state_global=np.ascontiguousarray(global_values),
            entity_numeric=np.ascontiguousarray(entity_numeric),
            entity_card_ids=np.ascontiguousarray(entity_card_ids),
            entity_type_ids=np.ascontiguousarray(entity_type_ids),
            actor_deck_id=np.int64(deck_index(own_key)),
            opponent_deck_id=np.int64(deck_index(opponent_key)),
        )
        result.validate()
        return result

    def _encode_entities(
        self,
        observation: Observation,
        numeric: np.ndarray,
        card_ids: np.ndarray,
        type_ids: np.ndarray,
    ) -> None:
        board = {
            (int(row[0]), str(row[1])): row
            for row in observation.board
        }
        entity_index = 0
        for player in (
            observation.perspective,
            1 - observation.perspective,
        ):
            for slot in TARGET_SLOTS:
                row = board.get(
                    (player, slot),
                    (player, slot, "", 0, (), (), ""),
                )
                _, _, card_id, damage, energies, statuses, tool_id = row
                owner = 1 if player == observation.perspective else 2
                base = entity_index
                self._set_entity(
                    base,
                    card_id,
                    token_type=1,
                    owner=owner,
                    zone="active" if slot == "active" else "bench",
                    slot=slot,
                    values=(
                        bool(card_id),
                        slot == "active",
                        _normalized(damage, 30.0),
                        _normalized(len(energies), 6.0),
                        _normalized(len(statuses), 5.0),
                        bool(tool_id),
                    ),
                    numeric=numeric,
                    card_ids=card_ids,
                    type_ids=type_ids,
                )
                for offset in range(4):
                    energy_id = energies[offset] if offset < len(energies) else ""
                    self._set_entity(
                        base + 1 + offset,
                        energy_id,
                        token_type=2,
                        owner=owner,
                        zone="energy",
                        slot=slot,
                        values=(
                            bool(energy_id),
                            _normalized(offset + 1, 4.0),
                            _normalized(base + 1, ENTITY_SLOTS),
                        ),
                        numeric=numeric,
                        card_ids=card_ids,
                        type_ids=type_ids,
                    )
                self._set_entity(
                    base + 5,
                    tool_id,
                    token_type=3,
                    owner=owner,
                    zone="tool",
                    slot=slot,
                    values=(
                        bool(tool_id),
                        _normalized(base + 1, ENTITY_SLOTS),
                    ),
                    numeric=numeric,
                    card_ids=card_ids,
                    type_ids=type_ids,
                )
                entity_index += 6

        entity_index = self._encode_zone(
            observation.own_hand[:16],
            entity_index,
            16,
            token_type=4,
            owner=1,
            zone="hand",
            numeric=numeric,
            card_ids=card_ids,
            type_ids=type_ids,
        )
        entity_index = self._encode_zone(
            observation.own_discard[-12:],
            entity_index,
            12,
            token_type=5,
            owner=1,
            zone="discard",
            numeric=numeric,
            card_ids=card_ids,
            type_ids=type_ids,
        )
        entity_index = self._encode_zone(
            observation.opponent_discard[-12:],
            entity_index,
            12,
            token_type=6,
            owner=2,
            zone="discard",
            numeric=numeric,
            card_ids=card_ids,
            type_ids=type_ids,
        )
        self._set_entity(
            entity_index,
            observation.stadium_id,
            token_type=7,
            owner=0,
            zone="stadium",
            slot="",
            values=(bool(observation.stadium_id),),
            numeric=numeric,
            card_ids=card_ids,
            type_ids=type_ids,
        )

    def _encode_zone(
        self,
        values: Sequence[str],
        start: int,
        width: int,
        *,
        token_type: int,
        owner: int,
        zone: str,
        numeric: np.ndarray,
        card_ids: np.ndarray,
        type_ids: np.ndarray,
    ) -> int:
        for offset in range(width):
            card_id = values[offset] if offset < len(values) else ""
            self._set_entity(
                start + offset,
                card_id,
                token_type=token_type,
                owner=owner,
                zone=zone,
                slot="",
                values=(
                    bool(card_id),
                    _normalized(offset + 1, width),
                ),
                numeric=numeric,
                card_ids=card_ids,
                type_ids=type_ids,
            )
        return start + width

    @staticmethod
    def _set_entity(
        index: int,
        card_id: str,
        *,
        token_type: int,
        owner: int,
        zone: str,
        slot: str,
        values: Iterable[float],
        numeric: np.ndarray,
        card_ids: np.ndarray,
        type_ids: np.ndarray,
    ) -> None:
        if not 0 <= index < ENTITY_SLOTS:
            raise ValueError("entity_layout_overflow")
        card_ids[index] = _card_index(str(card_id or ""))
        type_ids[index] = (
            int(token_type),
            int(owner),
            ZONE_IDS.get(zone, 0),
            SLOT_IDS.get(slot, 0),
        )
        row = list(float(value) for value in values)
        numeric[index, : min(len(row), ENTITY_NUMERIC_SIZE)] = row[
            :ENTITY_NUMERIC_SIZE
        ]

    def encode_actions(
        self,
        observation: Observation,
        actions: Sequence[GameAction],
    ) -> EncodedCandidates:
        if not actions:
            raise ValueError("candidate_set_empty")
        rows = [
            self._candidate_encoder.encode_game_action(observation, action)
            for action in actions
        ]
        type_names = [
            action.action.name
            if hasattr(action.action, "name")
            else str(action.action)
            for action in actions
        ]
        return self._candidate_arrays(rows, type_names, actions)

    def encode_choices(
        self,
        observation: Observation,
        request_type: str,
        options: Sequence[ChoiceOption],
    ) -> EncodedCandidates:
        if not options:
            raise ValueError("candidate_set_empty")
        rows = [
            self._candidate_encoder.encode_choice_option(
                observation,
                request_type,
                option,
                index,
            )
            for index, option in enumerate(options)
        ]
        normalized = CHOICE_TYPE_ALIASES.get(request_type, request_type)
        return self._candidate_arrays(
            rows,
            [normalized] * len(rows),
            options,
        )

    def _candidate_arrays(
        self,
        encoded_rows: Sequence[Any],
        type_names: Sequence[str],
        sources: Sequence[Any],
    ) -> EncodedCandidates:
        count = len(encoded_rows)
        numeric = np.zeros(
            (count, CANDIDATE_NUMERIC_SIZE),
            dtype=np.float32,
        )
        card_ids = np.zeros(count, dtype=np.int64)
        type_ids = np.zeros(count, dtype=np.int64)
        refs = np.zeros((count, CANDIDATE_REF_FIELDS), dtype=np.int64)
        for index, (row, type_name, source) in enumerate(
            zip(encoded_rows, type_names, sources, strict=True)
        ):
            legacy = np.asarray(row.numeric, dtype=np.float32)
            numeric[index, : min(len(legacy), CANDIDATE_NUMERIC_SIZE)] = (
                legacy[:CANDIDATE_NUMERIC_SIZE]
            )
            card_ids[index] = int(row.card_id)
            type_ids[index] = ACTION_TYPE_IDS.get(str(type_name), 0)
            refs[index] = self._candidate_ref(source)
        result = EncodedCandidates(
            numeric=np.ascontiguousarray(numeric),
            card_ids=np.ascontiguousarray(card_ids),
            type_ids=np.ascontiguousarray(type_ids),
            refs=np.ascontiguousarray(refs),
            mask=np.ones(count, dtype=np.bool_),
        )
        result.validate()
        return result

    @staticmethod
    def _candidate_ref(source: Any) -> np.ndarray:
        row: dict[str, Any] = {}
        for name in ("target", "source"):
            value = getattr(source, name, None)
            if value is None:
                continue
            row = _reference_mapping(value)
            if row:
                break
        if not row and isinstance(source, ChoiceOption):
            row = _reference_mapping(source.ref)
            if not row:
                row = _reference_mapping(source.value)
        owner = int(row.get("player", -1))
        return np.asarray(
            (
                owner + 2 if owner in (-1, 0, 1) else 0,
                ZONE_IDS.get(str(row.get("zone", "")), 0),
                SLOT_IDS.get(str(row.get("slot", "")), 0),
                max(0, int(row.get("index", -1)) + 1),
            ),
            dtype=np.int64,
        )
    def encode_decision(
        self,
        observation: Observation,
        candidates: Sequence[GameAction],
        actor_deck_key: str | None = None,
    ) -> EncodedDecision:
        result = EncodedDecision(
            self.encode_information_set(observation, actor_deck_key),
            self.encode_actions(observation, candidates),
        )
        result.validate()
        return result


def assert_hidden_information_invariant(
    left: Observation,
    right: Observation,
    *,
    actor_deck_key: str | None = None,
) -> None:
    """Fail if observation-equivalent worlds produce different v2 inputs."""
    if left.information_key != right.information_key:
        raise ValueError("observations_are_not_information_equivalent")
    encoder = InformationSetEncoderV7()
    lhs = encoder.encode_information_set(left, actor_deck_key)
    rhs = encoder.encode_information_set(right, actor_deck_key)
    for name in (
        "state_global",
        "entity_numeric",
        "entity_card_ids",
        "entity_type_ids",
    ):
        if not np.array_equal(getattr(lhs, name), getattr(rhs, name)):
            raise AssertionError(f"hidden_information_leak:{name}")
