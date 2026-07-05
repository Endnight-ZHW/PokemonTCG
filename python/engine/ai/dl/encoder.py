"""Feature encoders for the optional deep-learning AI.

The model scores legal candidate actions rather than predicting a fixed action
ID.  This keeps the rules engine authoritative and lets future card/deck
additions work through card metadata plus hashed card identity features.
"""
from __future__ import annotations

import hashlib
import math
from collections import Counter
from dataclasses import dataclass
from typing import Any

from data.deck_definitions import (
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
from data.card_registry import CardRegistry
from engine.actions import (
    AttachmentRef,
    CardRef,
    ChoiceOption,
    GameAction,
    PokemonRef,
)
from engine.ai.effect_features import (
    effect_feature_names,
    effect_params,
    iter_effects_recursive,
)
from engine.ai.observation import Observation
from engine.ai.profiles import get_deck_ai_profile
from engine.enums import PlayerAction, TurnPhase
from engine.effects.runtime_effects import (
    ability_runtime_effects,
    attack_runtime_effects,
    trainer_runtime_effects,
)


CARD_BUCKET_COUNT = 4096
STATE_NUMERIC_SIZE = 960  # +32 for tactical situation features (v8)
STATE_CARD_SLOTS = 96
ACTION_NUMERIC_SIZE = 178  # +16 for action feasibility/context features (v8)
CARD_SEMANTIC_SIZE = 48
ENCODER_SCHEMA_VERSION = 2

ACTION_TYPES = [
    "NOOP",
    "SETUP_DONE",
    "PROMOTE",
    PlayerAction.PLAY_BASIC.name,
    PlayerAction.EVOLVE.name,
    PlayerAction.ATTACH_ENERGY.name,
    PlayerAction.PLAY_TRAINER.name,
    PlayerAction.USE_ABILITY.name,
    PlayerAction.USE_STADIUM.name,
    PlayerAction.RETREAT.name,
    PlayerAction.DECLARE_ATTACK.name,
    PlayerAction.END_TURN.name,
]

CHOICE_TYPES = [
    "search_deck",
    "select_hand_to_discard",
    "select_bench",
    "select_opponent_bench",
    "select_own_bench_energy",
    "select_bench_targets",
    "distribute_energy",
    "confirm",
]
CHOICE_TYPE_ALIASES = {
    "evolve_skip_stage": "search_deck",
}

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

PUBLIC_DECK_SPECS = {
    "fire": FIRE_DECK,
    "water": WATER_DECK,
    "psychic": PSYCHIC_DECK_NATU,
    "lightning": LIGHTNING_DECK,
    "fighting": FIGHTING_DECK,
    "colorless": COLORLESS_DECK,
    "dragon": DRAGON_DECK,
    "grass": GRASS_DECK,
    "steel": STEEL_DECK,
    "darkness": DARKNESS_DECK,
}


@dataclass(frozen=True)
class EncodedState:
    numeric: list[float]
    card_ids: list[int]


@dataclass(frozen=True)
class EncodedAction:
    numeric: list[float]
    card_id: int


def _pad(values: list[float], size: int) -> list[float]:
    if len(values) >= size:
        return values[:size]
    return values + [0.0] * (size - len(values))


def _pad_ids(values: list[int], size: int) -> list[int]:
    if len(values) >= size:
        return values[:size]
    return values + [0] * (size - len(values))


def card_bucket(card_or_id: Any) -> int:
    """Stable bucket ID for card identity embeddings; 0 is reserved for pad."""
    if card_or_id is None:
        return 0
    cid = getattr(card_or_id, "api_id", card_or_id)
    if not cid:
        return 0
    digest = hashlib.blake2b(str(cid).encode("utf-8"), digest_size=4).digest()
    value = int.from_bytes(digest, "big")
    return 1 + value % (CARD_BUCKET_COUNT - 1)


def _bool(value: Any) -> float:
    return 1.0 if value else 0.0


def _one_hot(index: int, size: int) -> list[float]:
    values = [0.0] * size
    if 0 <= index < size:
        values[index] = 1.0
    return values


def _choice_type_one_hot(request_type: str) -> list[float]:
    encoded_type = CHOICE_TYPE_ALIASES.get(str(request_type), str(request_type))
    return (
        _one_hot(CHOICE_TYPES.index(encoded_type), len(CHOICE_TYPES))
        if encoded_type in CHOICE_TYPES else [0.0] * len(CHOICE_TYPES)
    )


def _norm(value: float, divisor: float) -> float:
    if divisor <= 0:
        return 0.0
    return max(-4.0, min(4.0, float(value) / divisor))


def _card_id(card: Any) -> str:
    return str(getattr(card, "api_id", "") or "")


class ActionStateEncoder:
    """Encode public observations and structured candidates into fixed features."""

    state_numeric_size = STATE_NUMERIC_SIZE
    state_card_slots = STATE_CARD_SLOTS
    action_numeric_size = ACTION_NUMERIC_SIZE
    card_bucket_count = CARD_BUCKET_COUNT
    deck_keys: tuple[str, ...] = (
        "fire", "water", "psychic", "lightning", "fighting",
        "colorless", "dragon", "grass", "steel", "darkness",
    )

    def encode_state(self, state, player_idx: int, deck_key: str | None = None) -> EncodedState:
        """Compatibility adapter. New code should pass Observation directly."""
        return self.encode_observation(
            Observation.from_state(state, player_idx),
            deck_key,
        )

    def encode_action(self, state, player_idx: int, action) -> EncodedAction:
        """Compatibility adapter for callers not yet holding an Observation."""
        return self.encode_game_action(
            Observation.from_state(state, player_idx),
            action,
        )

    def encode_choice(
        self,
        state,
        player_idx: int,
        request_type: str,
        candidate: Any,
        index: int = 0,
    ) -> EncodedAction:
        """Compatibility adapter for legacy training examples."""
        option = ChoiceOption(
            option_id=f"legacy:{request_type}:{index}",
            label=str(getattr(candidate, "name", candidate)),
            value=candidate,
        )
        return self.encode_choice_option(
            Observation.from_state(state, player_idx),
            request_type,
            option,
            index,
        )

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

        card_ids: list[int] = []
        for player_idx, slot, card_id, damage, energy_ids, statuses, tool_id in observation.board:
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
            card_ids.append(card_bucket(card_id))
            card_ids.extend(card_bucket(energy_id) for energy_id in energy_ids[:4])
            card_ids.append(card_bucket(tool_id))

        card_ids.extend(card_bucket(card_id) for card_id in observation.own_hand[:16])
        card_ids.extend(card_bucket(card_id) for card_id in observation.own_discard[-12:])
        card_ids.extend(card_bucket(card_id) for card_id in observation.opponent_discard[-12:])
        card_ids.append(card_bucket(observation.stadium_id))
        return EncodedState(
            numeric=_pad(numeric, STATE_NUMERIC_SIZE),
            card_ids=_pad_ids(card_ids, STATE_CARD_SLOTS),
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
        numeric: list[float] = []
        numeric.extend(
            _one_hot(ACTION_TYPES.index(action_name), len(ACTION_TYPES))
            if action_name in ACTION_TYPES else [0.0] * len(ACTION_TYPES)
        )
        numeric.extend([
            _bool(action.terminal),
            _bool(action.actor in (None, observation.perspective)),
        ])

        params = dict(action.params or {})
        slot_name = (
            getattr(action.target, "slot", None)
            or params.get("target_slot")
            or params.get("target")
            or params.get("slot")
        )
        target_slots = ["active", "bench_0", "bench_1", "bench_2", "bench_3", "bench_4"]
        numeric.extend(
            _one_hot(target_slots.index(slot_name), len(target_slots))
            if slot_name in target_slots else [0.0] * len(target_slots)
        )
        numeric.extend([
            _norm(params.get("hand_idx", -1) + 1 if isinstance(params.get("hand_idx"), int) else 0, 12.0),
            _norm(params.get("attack_idx", -1) + 1 if isinstance(params.get("attack_idx"), int) else 0, 4.0),
            _norm(params.get("bench_idx", -1) + 1 if isinstance(params.get("bench_idx"), int) else 0, 5.0),
            _norm(len(params.get("energy_indices", []) or []), 6.0),
            _norm(sum(1 for row in observation.board if row[2]), 12.0),
            _norm(sum(1 for row in observation.board if row[0] != observation.perspective and row[2]), 6.0),
        ])

        card_id = getattr(action.source, "card_id", "")
        if not card_id:
            hand_idx = params.get("hand_idx")
            if isinstance(hand_idx, int) and 0 <= hand_idx < len(observation.own_hand):
                card_id = observation.own_hand[hand_idx]
        card = CardRegistry.get(card_id) if card_id else None
        numeric.extend(self._card_semantic_features(card))
        numeric.extend(self._deck_key_features(
            getattr(self, "_active_deck_key", None)
            or observation.public_deck_keys[observation.perspective]
            if observation.perspective < len(observation.public_deck_keys)
            else None
        ))
        return EncodedAction(
            numeric=_pad(numeric, ACTION_NUMERIC_SIZE),
            card_id=card_bucket(card_id),
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
        ref = option.ref
        numeric.extend([
            _norm(index + 1, 64.0),
            _bool(isinstance(ref, CardRef)),
            _bool(isinstance(ref, PokemonRef)),
            _bool(isinstance(ref, AttachmentRef)),
            _bool(getattr(ref, "player", observation.perspective) == observation.perspective),
        ])
        slot = getattr(ref, "slot", "")
        target_slots = ["active", "bench_0", "bench_1", "bench_2", "bench_3", "bench_4"]
        numeric.extend(
            _one_hot(target_slots.index(slot), len(target_slots))
            if slot in target_slots else [0.0] * len(target_slots)
        )
        card_id = getattr(ref, "card_id", "")
        if not card_id:
            card_id = getattr(option.value, "api_id", "")
        card = CardRegistry.get(card_id) if card_id else None
        numeric.extend(self._card_semantic_features(card))
        return EncodedAction(
            numeric=_pad(numeric, ACTION_NUMERIC_SIZE),
            card_id=card_bucket(card_id),
        )

    def _encode_state_legacy(self, state, player_idx: int, deck_key: str | None = None) -> EncodedState:
        self._active_deck_key = deck_key
        opponent_idx = 1 - player_idx
        player = state.get_player(player_idx)
        opponent = state.get_player(opponent_idx)

        numeric: list[float] = []
        phases = list(TurnPhase)
        numeric.extend(_one_hot(phases.index(state.phase), len(phases)) if state.phase in phases else [0.0] * len(phases))
        numeric.extend([
            _bool(state.active_player_idx == player_idx),
            _bool(state.first_player_idx == player_idx),
            _norm(getattr(state, "turn_number", 0), 20.0),
            _bool(getattr(state, "apply_type_matchups", False)),
            1.0 if state.winner == player_idx else 0.0,
            1.0 if state.winner == opponent_idx else 0.0,
        ])

        numeric.extend(self._player_summary(player, own=True))
        numeric.extend(self._player_summary(opponent, own=False))
        numeric.extend(self._deck_context(state, player_idx, deck_key))
        numeric.extend(self._zone_context(opponent.discard))
        numeric.extend(self._card_semantic_features(getattr(state, "stadium_card", None)))
        numeric.extend(self._deck_key_features(deck_key))
        numeric.extend(self._profile_context(state, player_idx, deck_key))
        numeric.extend(self._board_tactics(state, player_idx))
        numeric.extend(self._situation_features(state, player_idx))
        numeric.extend(self._probability_features(state, player_idx, deck_key))

        for _, pokemon in player.get_all_pokemon():
            numeric.extend(self._pokemon_features(pokemon))
        for _, pokemon in opponent.get_all_pokemon():
            numeric.extend(self._pokemon_features(pokemon))

        card_ids = []
        card_ids.extend(card_bucket(p.card) if p else 0 for _, p in player.get_all_pokemon())
        card_ids.extend(card_bucket(p.card) if p else 0 for _, p in opponent.get_all_pokemon())
        card_ids.extend(card_bucket(getattr(p, "attached_tool", None)) if p else 0 for _, p in player.get_all_pokemon())
        card_ids.extend(card_bucket(getattr(p, "attached_tool", None)) if p else 0 for _, p in opponent.get_all_pokemon())
        card_ids.extend(card_bucket(card) for card in list(player.hand)[:16])
        card_ids.extend(card_bucket(card) for card in list(player.discard)[-12:])
        card_ids.extend(card_bucket(card) for card in list(opponent.discard)[-12:])
        card_ids.append(card_bucket(getattr(state, "stadium_card", None)))

        return EncodedState(
            numeric=_pad(numeric, STATE_NUMERIC_SIZE),
            card_ids=_pad_ids(card_ids, STATE_CARD_SLOTS),
        )

    def _encode_action_legacy(self, state, player_idx: int, action) -> EncodedAction:
        player = state.get_player(player_idx)
        action_name = action.action.name if isinstance(action.action, PlayerAction) else str(action.action)
        numeric: list[float] = []
        numeric.extend(_one_hot(ACTION_TYPES.index(action_name), len(ACTION_TYPES)) if action_name in ACTION_TYPES else [0.0] * len(ACTION_TYPES))
        numeric.append(_bool(getattr(action, "terminal", False)))

        params = getattr(action, "params", {}) or {}
        slot_name = params.get("target_slot") or params.get("target") or params.get("slot")
        target_slots = ["active", "bench_0", "bench_1", "bench_2", "bench_3", "bench_4"]
        numeric.extend(_one_hot(target_slots.index(slot_name), len(target_slots)) if slot_name in target_slots else [0.0] * len(target_slots))
        numeric.extend([
            _norm(params.get("hand_idx", -1) + 1 if isinstance(params.get("hand_idx"), int) else 0, 12.0),
            _norm(params.get("attack_idx", -1) + 1 if isinstance(params.get("attack_idx"), int) else 0, 4.0),
            _norm(params.get("bench_idx", -1) + 1 if isinstance(params.get("bench_idx"), int) else 0, 5.0),
        ])

        card = self._primary_action_card(state, player_idx, action)
        numeric.extend(self._card_semantic_features(card))
        numeric.extend(self._attack_features(state, player_idx, action))
        numeric.extend(self._action_tactical_features(state, player_idx, action, card))

        if action_name == PlayerAction.END_TURN.name:
            numeric.append(-1.0)
        elif action_name == PlayerAction.DECLARE_ATTACK.name:
            numeric.append(1.0)
        else:
            numeric.append(0.0)

        return EncodedAction(
            numeric=_pad(numeric, ACTION_NUMERIC_SIZE),
            card_id=card_bucket(card),
        )

    def _encode_choice_legacy(self, state, player_idx: int, request_type: str, candidate: Any, index: int = 0) -> EncodedAction:
        """Encode one pending ActionRequest candidate for the optional choice head."""
        numeric: list[float] = []
        numeric.extend(_choice_type_one_hot(request_type))
        numeric.extend([
            _norm(index + 1, 64.0),
            _bool(hasattr(candidate, "api_id")),
            _bool(isinstance(candidate, int)),
            _bool(isinstance(candidate, bool)),
        ])
        if isinstance(candidate, int):
            numeric.extend(_one_hot(candidate, 6))
        else:
            numeric.extend([0.0] * 6)
        if isinstance(candidate, bool):
            numeric.extend([1.0, 0.0] if candidate else [0.0, 1.0])
        else:
            numeric.extend([0.0, 0.0])

        card = candidate if hasattr(candidate, "api_id") else None
        numeric.extend(self._card_semantic_features(card))
        return EncodedAction(
            numeric=_pad(numeric, ACTION_NUMERIC_SIZE),
            card_id=card_bucket(card),
        )

    def _primary_action_card(self, state, player_idx: int, action):
        player = state.get_player(player_idx)
        params = getattr(action, "params", {}) or {}
        hand_idx = params.get("hand_idx")
        if isinstance(hand_idx, int) and 0 <= hand_idx < len(player.hand):
            return player.hand[hand_idx]
        if action.action == PlayerAction.DECLARE_ATTACK:
            return player.active.card if player.active else None
        if action.action == PlayerAction.USE_ABILITY:
            pokemon = player.get_pokemon(params.get("slot") or "active")
            return pokemon.card if pokemon else None
        if action.action == PlayerAction.USE_STADIUM:
            return getattr(state, "stadium_card", None)
        return None

    def _player_summary(self, player, own: bool) -> list[float]:
        return [
            _norm(player.hand_count if not own else len(player.hand), 20.0),
            _norm(len(player.deck), 60.0),
            _norm(len(player.discard), 60.0),
            _norm(len(player.prizes), 6.0),
            _norm(6 - len(player.prizes), 6.0),
            _norm(player.bench_count(), 5.0),
            _bool(player.supporter_played_this_turn),
            _bool(player.energy_attached_this_turn),
            _bool(player.retreated_this_turn),
            _bool(player.stadium_played_this_turn),
            _bool(player.stadium_used_this_turn),
            _bool(player.was_ko_by_attack),
        ]

    def _deck_context(self, state, player_idx: int, deck_key: str | None) -> list[float]:
        player = state.get_player(player_idx)
        unknown_cards = self._estimated_unknown_cards(state, player_idx, deck_key)
        values = [
            _norm(len(player.deck), 60.0),
        ]
        values.extend(self._zone_context(unknown_cards))
        values.extend(self._zone_context(player.hand))
        values.extend(self._zone_context(player.discard))
        return values

    def _estimated_unknown_cards(self, state, player_idx: int, deck_key: str | None) -> list[Any]:
        """Estimate own hidden-zone contents from public decklist minus known cards.

        This models ordinary deck tracking: hand, board, discard, and attached
        cards are known; exact current deck and prize identities are not.
        """
        spec = PUBLIC_DECK_SPECS.get(deck_key or "")
        if not spec:
            return []
        remaining = Counter({card_id: count for card_id, count in spec})
        for card in self._known_own_cards(state, player_idx):
            cid = _card_id(card)
            if cid and remaining[cid] > 0:
                remaining[cid] -= 1
        cards = []
        for card_id, count in remaining.items():
            if count <= 0:
                continue
            try:
                card = CardRegistry.get(card_id)
            except Exception:
                card = None
            if card is not None:
                cards.extend([card] * count)
        return cards

    def _known_own_cards(self, state, player_idx: int) -> list[Any]:
        player = state.get_player(player_idx)
        cards = []
        cards.extend(player.hand)
        cards.extend(player.discard)
        for _, pokemon in player.get_all_pokemon():
            if not pokemon:
                continue
            cards.append(pokemon.card)
            cards.extend(getattr(pokemon, "evolution_stack", []) or [])
            cards.extend(getattr(pokemon, "energy_cards", []) or [])
            tool = getattr(pokemon, "attached_tool", None)
            if tool is not None:
                cards.append(tool)
        return cards

    def _zone_context(self, zone) -> list[float]:
        total = max(1, len(zone))
        values = [
            _norm(len(zone), 60.0),
            sum(1 for c in zone if getattr(c, "is_pokemon", False)) / total,
            sum(1 for c in zone if getattr(c, "is_trainer", False)) / total,
            sum(1 for c in zone if getattr(c, "is_energy", False)) / total,
            sum(1 for c in zone if getattr(c, "is_basic_pokemon", False)) / total,
            sum(1 for c in zone if getattr(c, "is_trainer_supporter", False)) / total,
            sum(1 for c in zone if getattr(c, "is_trainer_item", False)) / total,
        ]
        energy_seen = set()
        effect_seen = set()
        for card in zone:
            energy_seen.update(getattr(card, "provides_energy", []) or [])
            energy_seen.update(getattr(card, "energy_types", []) or [])
            effect_seen.update(self._card_effect_names(card))
        values.extend(_bool(t in energy_seen) for t in ENERGY_TYPES)
        values.extend(_bool(t in effect_seen) for t in EFFECT_TYPES)
        return values

    def _deck_key_features(self, deck_key: str | None) -> list[float]:
        return _one_hot(self.deck_keys.index(deck_key), len(self.deck_keys)) if deck_key in self.deck_keys else [0.0] * len(self.deck_keys)

    def _profile_sets(self, deck_key: str | None) -> dict[str, set[str]]:
        profile = get_deck_ai_profile(deck_key)
        return {
            "core": set(profile.core_cards),
            "engine": set(profile.engine_cards),
            "setup": set(profile.setup_active),
            "bench": set(profile.preferred_bench),
            "evolution": set(profile.evolution_cards),
            "trainer": set(profile.trainer_cards),
            "energy": set(profile.energy_types),
        }

    def _profile_card_flags(self, card, deck_key: str | None) -> list[float]:
        if card is None:
            return [0.0] * 8
        profile = self._profile_sets(deck_key)
        cid = _card_id(card)
        provided = set(getattr(card, "provides_energy", []) or [])
        provided.update(getattr(card, "energy_types", []) or [])
        return [
            _bool(cid in profile["core"]),
            _bool(cid in profile["engine"]),
            _bool(cid in profile["setup"]),
            _bool(cid in profile["bench"]),
            _bool(cid in profile["evolution"]),
            _bool(cid in profile["trainer"]),
            _bool(bool(provided & profile["energy"]) or ("Rainbow" in provided and bool(profile["energy"]))),
            _bool(getattr(card, "is_energy", False) and not profile["energy"]),
        ]

    def _profile_zone_context(self, zone, deck_key: str | None) -> list[float]:
        profile = self._profile_sets(deck_key)
        cards = list(zone or [])
        total = max(1, len(cards))
        counts = {
            key: sum(1 for card in cards if _card_id(card) in ids)
            for key, ids in profile.items()
            if key != "energy"
        }
        energy_matches = 0
        for card in cards:
            provided = set(getattr(card, "provides_energy", []) or [])
            provided.update(getattr(card, "energy_types", []) or [])
            if provided & profile["energy"] or ("Rainbow" in provided and profile["energy"]):
                energy_matches += 1
        return [
            _norm(counts.get("core", 0), 4.0),
            _norm(counts.get("engine", 0), 8.0),
            _norm(counts.get("setup", 0), 4.0),
            _norm(counts.get("bench", 0), 6.0),
            _norm(counts.get("evolution", 0), 8.0),
            _norm(counts.get("trainer", 0), 10.0),
            _norm(energy_matches, 16.0),
            counts.get("core", 0) / total,
            counts.get("engine", 0) / total,
            energy_matches / total,
        ]

    def _profile_context(self, state, player_idx: int, deck_key: str | None) -> list[float]:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        unknown_cards = self._estimated_unknown_cards(state, player_idx, deck_key)
        values: list[float] = []
        for zone in (player.hand, unknown_cards, player.discard, opponent.discard):
            values.extend(self._profile_zone_context(zone, deck_key))

        own_cards = [pokemon.card for _, pokemon in player.get_all_pokemon() if pokemon]
        opp_cards = [pokemon.card for _, pokemon in opponent.get_all_pokemon() if pokemon]
        values.extend(self._profile_zone_context(own_cards, deck_key))
        values.extend(self._profile_zone_context(opp_cards, deck_key))

        profile = self._profile_sets(deck_key)
        own_ids = {_card_id(card) for card in own_cards}
        hand_ids = {_card_id(card) for card in player.hand}
        discard_ids = {_card_id(card) for card in player.discard}
        values.extend([
            _bool(profile["core"] & own_ids),
            _bool(profile["core"] & hand_ids),
            _bool(profile["core"] and not (profile["core"] & (own_ids | hand_ids | discard_ids))),
            _norm(len(profile["evolution"] & hand_ids), 4.0),
            _norm(len(profile["trainer"] & hand_ids), 6.0),
        ])
        return values

    def _board_tactics(self, state, player_idx: int) -> list[float]:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        own_active = player.active
        opp_active = opponent.active
        own_best = self._best_attack_damage(own_active)
        opp_best = self._best_attack_damage(opp_active)
        values = [
            _norm(own_best, 340.0),
            _norm(opp_best, 340.0),
            _bool(opp_active and own_best >= opp_active.current_hp),
            _bool(own_active and opp_best >= own_active.current_hp),
            _norm(self._best_missing_energy(own_active), 5.0),
            _norm(self._best_missing_energy(opp_active), 5.0),
            _norm(self._damaged_bench_count(player), 5.0),
            _norm(self._damaged_bench_count(opponent), 5.0),
            _norm(self._low_hp_bench_count(opponent), 5.0),
            _norm(self._bench_ready_count(player), 5.0),
            _norm(self._bench_ready_count(opponent), 5.0),
        ]
        if own_active and opp_active:
            values.extend([
                _norm(own_active.current_hp - opp_active.current_hp, 340.0),
                _norm(getattr(opp_active.card, "prize_value", 0), 3.0),
                _norm(getattr(own_active.card, "prize_value", 0), 3.0),
            ])
        else:
            values.extend([0.0, 0.0, 0.0])
        return values

    def _situation_features(self, state, player_idx: int) -> list[float]:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        own_active = player.active
        opp_active = opponent.active
        own_best = self._best_attack_damage(own_active)
        opp_best = self._best_attack_damage(opp_active)
        own_ready = own_active is not None and self._best_missing_energy(own_active) <= 0
        opp_ready = opp_active is not None and self._best_missing_energy(opp_active) <= 0
        own_damaged = [p for _, p in player.get_all_pokemon() if p and p.current_hp < p.card.hp]
        opp_damaged = [p for _, p in opponent.get_all_pokemon() if p and p.current_hp < p.card.hp]
        own_energy_total = sum(
            len(getattr(p, "energy_cards", []) or [])
            for _, p in player.get_all_pokemon() if p
        )
        opp_energy_total = sum(
            len(getattr(p, "energy_cards", []) or [])
            for _, p in opponent.get_all_pokemon() if p
        )
        hand_discardable_after_trainer = max(0, len(player.hand) - 1)
        active_damage_gap = 0.0
        if own_active and opp_active:
            active_damage_gap = own_active.current_hp - opp_active.current_hp
        values = [
            _bool(player.bench_count() > 0),
            _bool(opponent.bench_count() > 0),
            _bool(player.bench_count() == 0),
            _bool(opponent.bench_count() == 0),
            _norm(player.bench_count(), 5.0),
            _norm(opponent.bench_count(), 5.0),
            _bool(bool(own_damaged)),
            _bool(bool(opp_damaged)),
            _norm(len(own_damaged), 6.0),
            _norm(len(opp_damaged), 6.0),
            _bool(own_active and own_active.current_hp <= max(40, own_active.card.hp * 0.35)),
            _bool(opp_active and opp_active.current_hp <= max(40, opp_active.card.hp * 0.35)),
            _bool(own_ready),
            _bool(opp_ready),
            _bool(own_ready and opp_active and own_best >= opp_active.current_hp),
            _bool(opp_ready and own_active and opp_best >= own_active.current_hp),
            _bool(any(p and self._best_missing_energy(p) <= 0 for p in player.bench)),
            _bool(any(p and self._best_missing_energy(p) <= 0 for p in opponent.bench)),
            _bool(any(p and p.current_hp <= own_best for p in opponent.bench if p)),
            _bool(any(p and opp_best >= p.current_hp for p in player.bench if p)),
            _bool(bool(getattr(opp_active, "energy_cards", []) or [])),
            _bool(opp_energy_total > 0),
            _bool(own_energy_total > 0),
            _norm(own_energy_total, 12.0),
            _norm(opp_energy_total, 12.0),
            _bool(hand_discardable_after_trainer >= 1),
            _bool(hand_discardable_after_trainer >= 2),
            _bool(len(player.deck) <= 4),
            _bool(len(player.deck) <= 8),
            _norm(len(player.deck), 60.0),
            _norm(len(player.hand), 16.0),
            _norm(active_damage_gap, 340.0),
        ]
        return values

    def _probability_features(self, state, player_idx: int, deck_key: str | None) -> list[float]:
        """Probability-aware features for draw/deck estimation.

        Adds ~32 dimensions encoding:
        - Probability of drawing key card types next turn
        - Deck composition ratios for known/unknown cards
        - Prize card probability estimates

        This helps the model distinguish between "good strategy" and "good draw luck",
        and make decisions based on remaining deck composition.
        """
        player = state.get_player(player_idx)
        deck_size = max(1, len(player.deck))
        unknown = self._estimated_unknown_cards(state, player_idx, deck_key)
        unknown_size = max(1, len(unknown))

        values: list[float] = []

        # --- Estimated deck composition ---
        # Deck identities are hidden; use public decklist minus known cards.
        pokemon_in_deck = sum(1 for c in unknown if getattr(c, "is_pokemon", False)) / unknown_size
        trainer_in_deck = sum(1 for c in unknown if getattr(c, "is_trainer", False)) / unknown_size
        energy_in_deck = sum(1 for c in unknown if getattr(c, "is_energy", False)) / unknown_size
        basic_in_deck = sum(1 for c in unknown if getattr(c, "is_basic_pokemon", False)) / unknown_size
        evo_in_deck = sum(1 for c in unknown if getattr(c, "is_stage1", False) or getattr(c, "is_stage2", False)) / unknown_size
        supporter_in_deck = sum(1 for c in unknown if getattr(c, "is_trainer_supporter", False)) / unknown_size
        item_in_deck = sum(1 for c in unknown if getattr(c, "is_trainer_item", False)) / unknown_size
        values.extend([
            pokemon_in_deck,
            trainer_in_deck,
            energy_in_deck,
            basic_in_deck,
            evo_in_deck,
            supporter_in_deck,
            item_in_deck,
            _norm(deck_size, 60.0),
        ])

        # --- Estimated unknown card composition (deck tracking) ---
        # How many of each type are probably still in unknown zones?
        unk_pokemon = sum(1 for c in unknown if getattr(c, "is_pokemon", False)) / unknown_size
        unk_energy = sum(1 for c in unknown if getattr(c, "is_energy", False)) / unknown_size
        unk_trainer = sum(1 for c in unknown if getattr(c, "is_trainer", False)) / unknown_size
        values.extend([
            unk_pokemon,
            unk_energy,
            unk_trainer,
            _norm(unknown_size, 60.0),
        ])

        # --- Profile-card probabilities ---
        # What's the probability of drawing a core/engine/evolution card?
        profile = get_deck_ai_profile(deck_key)
        core_in_unknown = sum(
            1 for c in unknown if str(getattr(c, "api_id", "")) in profile.core_cards
        ) / unknown_size if unknown_size > 0 else 0.0
        engine_in_unknown = sum(
            1 for c in unknown if str(getattr(c, "api_id", "")) in profile.engine_cards
        ) / unknown_size if unknown_size > 0 else 0.0
        evo_in_unknown = sum(
            1 for c in unknown if str(getattr(c, "api_id", "")) in profile.evolution_cards
        ) / unknown_size if unknown_size > 0 else 0.0
        energy_match = profile.energy_types
        energy_match_in_unknown = sum(
            1 for c in unknown
            if getattr(c, "is_energy", False) and (
                set(getattr(c, "provides_energy", []) or []) & energy_match
                or "Rainbow" in (getattr(c, "provides_energy", []) or [])
            )
        ) / unknown_size if unknown_size > 0 else 0.0
        values.extend([
            core_in_unknown,
            engine_in_unknown,
            evo_in_unknown,
            energy_match_in_unknown,
        ])

        # --- Prize card estimation ---
        # Rough probability that a key card is stuck in prizes
        prizes_left = len(player.prizes)
        core_in_unknown_count = sum(
            1 for c in unknown if str(getattr(c, "api_id", "")) in profile.core_cards
        )
        # If we've seen fewer core cards than expected, some may be prized
        total_core = len(profile.core_cards)
        seen_core = sum(
            1 for _, p in player.get_all_pokemon() if p
            and str(getattr(getattr(p, "card", None), "api_id", "")) in profile.core_cards
        )
        seen_core += sum(
            1 for c in player.hand if str(getattr(c, "api_id", "")) in profile.core_cards
        )
        seen_core += sum(
            1 for c in player.discard if str(getattr(c, "api_id", "")) in profile.core_cards
        )
        prob_core_prized = (
            (core_in_unknown_count / unknown_size) * (prizes_left / 6.0)
            if prizes_left > 0 else 0.0
        )

        # Similar for energy
        total_energy_need = 8  # rough estimate
        energy_on_board = sum(
            len(getattr(p, "energy_cards", []) or [])
            for _, p in player.get_all_pokemon() if p
        )
        energy_seen = energy_on_board + sum(
            1 for c in player.hand if getattr(c, "is_energy", False)
        ) + sum(
            1 for c in player.discard if getattr(c, "is_energy", False)
        )
        energy_in_unknown_count = sum(1 for c in unknown if getattr(c, "is_energy", False))
        estimated_energy_drawable = energy_in_unknown_count * (deck_size / unknown_size)
        energy_unaccounted = max(0, total_energy_need * 2 - energy_seen - estimated_energy_drawable)
        prob_energy_prized = energy_unaccounted / max(1, prizes_left) if prizes_left > 0 else 0.0

        values.extend([
            _norm(prizes_left, 6.0),
            prob_core_prized,
            prob_energy_prized,
        ])

        # --- Draw pressure indicators ---
        # How many more turns can we survive with current deck?
        draw_per_turn = 1.0
        turns_left = deck_size / max(1, draw_per_turn)
        values.append(_norm(turns_left, 30.0))

        # Deck diversity: entropy-like measure of deck composition
        type_counts = [
            sum(1 for c in unknown if getattr(c, "is_pokemon", False)),
            sum(1 for c in unknown if getattr(c, "is_trainer", False)),
            sum(1 for c in unknown if getattr(c, "is_energy", False)),
        ]
        total_cards = max(1, sum(type_counts))
        entropy = -sum(
            (c / total_cards) * (math.log(c / total_cards) if c > 0 else 0)
            for c in type_counts
        )
        values.append(min(1.0, entropy / 1.5))

        # Chance of drawing at least 1 energy in next 2 draws
        energy_left = int(round(energy_in_unknown_count * (deck_size / unknown_size)))
        if deck_size >= 2:
            prob_no_energy = 1.0
            remaining = deck_size
            no_energy_count = energy_left
            for _ in range(2):
                if remaining > 0:
                    prob_no_energy *= (remaining - no_energy_count) / remaining
                    remaining -= 1
            values.append(max(0.0, min(1.0, 1.0 - prob_no_energy)))
        else:
            values.append(0.0)

        # Chance of drawing a basic Pokemon in next draw
        basics_left = int(round(
            sum(1 for c in unknown if getattr(c, "is_basic_pokemon", False)) * (deck_size / unknown_size)
        ))
        values.append(_norm(basics_left, deck_size) if deck_size > 0 else 0.0)

        return values

    def _pokemon_features(self, pokemon) -> list[float]:
        if pokemon is None:
            return [0.0] * 44
        card = pokemon.card
        attacks = getattr(card, "attacks", []) or []
        status_count = len(getattr(pokemon, "status_conditions", []) or [])
        available_energy = list(getattr(pokemon, "available_energy", []) or [])
        energy_counts = [_norm(available_energy.count(t), 4.0) for t in ENERGY_TYPES]
        attack_missing = [self._missing_energy_count(pokemon, getattr(atk, "cost", []) or []) for atk in attacks]
        ready_attacks = sum(1 for missing in attack_missing if missing <= 0)
        best_missing = min(attack_missing or [0])
        max_damage = max((self._damage_value(getattr(atk, "damage", 0)) for atk in attacks), default=0)
        has_non_damage = any(self._damage_value(getattr(atk, "damage", 0)) == 0 for atk in attacks) if attacks else False

        features = [
            1.0,
            _norm(pokemon.current_hp, 340.0),
            _norm(getattr(card, "hp", 0), 340.0),
            _norm(getattr(pokemon, "damage_counters", 0) * 10, 340.0),
            _norm(len(getattr(pokemon, "energy_cards", []) or []), 8.0),
            _norm(len(getattr(pokemon, "evolution_stack", []) or []), 3.0),
            _norm(status_count, 5.0),
            _norm(getattr(card, "prize_value", 0), 3.0),
            _bool(getattr(card, "is_basic_pokemon", False)),
            _bool(getattr(card, "is_stage1", False)),
            _bool(getattr(card, "is_stage2", False)),
            _bool("ex" in getattr(card, "subtypes", [])),
            _bool(getattr(pokemon, "attached_tool", None)),
            _bool(getattr(pokemon, "can_evolve_this_turn", False)),
            _bool(getattr(pokemon, "damage_prevented_next_turn", False)),
            _bool(getattr(pokemon, "all_prevented_next_turn", False)),
            _bool(getattr(pokemon, "attack_locked", False)),
            _norm(len(available_energy), 8.0),
            _norm(ready_attacks, 4.0),
            _norm(best_missing, 5.0),
            _norm(max_damage, 340.0),
            _norm(len(attacks), 4.0),
            _bool(getattr(card, "abilities", [])),
            # --- card semantic extras (10 dims) ---
            _norm(getattr(card, "retreat_cost", 0), 5.0),
            _bool("V" in getattr(card, "subtypes", []) or "GX" in getattr(card, "subtypes", [])),
            _bool(any(t in getattr(card, "subtypes", []) for t in ("VMAX", "VSTAR", "TAG TEAM"))),
            _bool(has_non_damage),
            _bool(any("bench" in getattr(atk, "text", "").lower() for atk in attacks)),
            _bool(getattr(card, "evolves_from", "") != ""),
            _bool(getattr(card, "evolves_to", [])),
            _norm(max((len(getattr(atk, "cost", []) or []) for atk in attacks), default=0), 5.0),
            _bool(getattr(card, "is_special_energy", False)),
            _norm(min((len(getattr(atk, "cost", []) or []) for atk in attacks), default=0), 5.0) if attacks else 0.0,
        ]
        features.extend(energy_counts)
        return features

    def _card_features(self, card) -> list[float]:
        if card is None:
            return [0.0] * 40
        energy_types = set(getattr(card, "energy_types", []) or [])
        energy_types.update(getattr(card, "provides_energy", []) or [])
        effect_names = self._card_effect_names(card)
        features = [
            1.0,
            _bool(getattr(card, "is_pokemon", False)),
            _bool(getattr(card, "is_basic_pokemon", False)),
            _bool(getattr(card, "is_stage1", False)),
            _bool(getattr(card, "is_stage2", False)),
            _bool(getattr(card, "is_trainer", False)),
            _bool(getattr(card, "is_trainer_item", False)),
            _bool(getattr(card, "is_trainer_supporter", False)),
            _bool(getattr(card, "is_trainer_stadium", False)),
            _bool(getattr(card, "is_trainer_tool", False)),
            _bool(getattr(card, "is_energy", False)),
            _bool(getattr(card, "is_special_energy", False)),
            _norm(getattr(card, "hp", 0), 340.0),
            _norm(len(getattr(card, "attacks", []) or []), 4.0),
            _norm(getattr(card, "retreat_cost", 0), 5.0),
            _norm(getattr(card, "prize_value", 0), 3.0),
            _bool(energy_types),
        ]
        features.extend(_bool(t in energy_types) for t in ENERGY_TYPES)
        features.extend(_bool(t in effect_names) for t in EFFECT_TYPES)
        return features

    def _card_semantic_features(self, card) -> list[float]:
        """Rich semantic card features capturing what a card actually does.

        Complements the blake2b-hash card_bucket embedding with explicit
        card-type, stats, and effect-keyword signals so the model can
        generalise across functionally similar cards.
        Returns CARD_SEMANTIC_SIZE floats (48).
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
        return features

    def _action_tactical_features(self, state, player_idx: int, action, card) -> list[float]:
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        params = getattr(action, "params", {}) or {}
        target = self._action_target_pokemon(state, player_idx, action)
        target_card = target.card if target else None
        attack_idx = params.get("attack_idx")
        attack_damage = 0
        if action.action == PlayerAction.DECLARE_ATTACK and player.active and isinstance(attack_idx, int):
            attacks = getattr(player.active.card, "attacks", []) or []
            if 0 <= attack_idx < len(attacks):
                attack_damage = self._damage_value(getattr(attacks[attack_idx], "damage", 0))
        best_missing = self._best_missing_energy(target)
        active_missing = self._best_missing_energy(player.active)
        effect_tokens = self._effect_tokens_for_action_card(card)
        discard_cost = self._discard_cost_amount(card)
        draws_or_searches = bool(effect_tokens & {"draw", "search"})
        switches = "switch" in effect_tokens
        heals = "heal" in effect_tokens
        discards_energy = "discard" in effect_tokens and action.action == PlayerAction.PLAY_TRAINER
        low_deck_pressure = len(player.deck) <= 4 or (len(player.deck) <= 8 and draws_or_searches)
        own_has_heal_target = any(p and p.current_hp < p.card.hp for _, p in player.get_all_pokemon())
        opp_has_bench = opponent.bench_count() > 0
        own_has_bench = player.bench_count() > 0
        opp_active_energy = bool(getattr(opponent.active, "energy_cards", []) or []) if opponent.active else False
        values = [
            _bool(target is not None),
            _norm(getattr(target, "current_hp", 0) if target else 0, 340.0),
            _norm(getattr(target_card, "prize_value", 0) if target_card else 0, 3.0),
            _norm(len(getattr(target, "energy_cards", []) or []), 8.0) if target else 0.0,
            _norm(best_missing, 5.0),
            _bool(best_missing <= 1),
            _bool(action.action == PlayerAction.ATTACH_ENERGY and best_missing <= active_missing),
            _bool(action.action == PlayerAction.EVOLVE and target is not None),
            _norm(attack_damage, 340.0),
            _bool(opponent.active and attack_damage >= opponent.active.current_hp),
            _norm(getattr(opponent.active.card, "prize_value", 0) if opponent.active else 0, 3.0),
            _bool(action.action == PlayerAction.RETREAT and target is not None and self._best_attack_damage(target) > self._best_attack_damage(player.active)),
            _bool(getattr(target, 'damage_prevented_next_turn', False) if target else False),
            _bool(getattr(target, 'all_prevented_next_turn', False) if target else False),
            _bool(action.action == PlayerAction.PLAY_TRAINER and "switch" in effect_tokens and opp_has_bench),
            _bool(action.action == PlayerAction.PLAY_TRAINER and switches and not opp_has_bench),
            _bool(action.action in (PlayerAction.RETREAT, PlayerAction.PLAY_TRAINER) and own_has_bench),
            _bool(action.action in (PlayerAction.RETREAT, PlayerAction.PLAY_TRAINER) and not own_has_bench),
            _bool(draws_or_searches and not low_deck_pressure),
            _bool(draws_or_searches and low_deck_pressure),
            _bool(heals and own_has_heal_target),
            _bool(heals and not own_has_heal_target),
            _bool(discards_energy and opp_active_energy),
            _bool(discards_energy and not opp_active_energy),
            _bool(discard_cost > 0 and max(0, len(player.hand) - 1) >= discard_cost),
            _bool(discard_cost > 0 and max(0, len(player.hand) - 1) < discard_cost),
            _bool(action.action == PlayerAction.PLAY_BASIC and player.bench_count() < 5),
            _bool(action.action == PlayerAction.PLAY_BASIC and player.bench_count() >= 5),
            _bool(action.action == PlayerAction.DECLARE_ATTACK and opponent.active and attack_damage >= opponent.active.current_hp),
            _bool(action.action == PlayerAction.DECLARE_ATTACK and any(p and attack_damage >= p.current_hp for p in opponent.bench)),
        ]
        values.extend(self._profile_card_flags(card, getattr(self, "_active_deck_key", None)))
        return values

    def _action_target_pokemon(self, state, player_idx: int, action):
        params = getattr(action, "params", {}) or {}
        player = state.get_player(player_idx)
        opponent = state.get_player(1 - player_idx)
        if action.action == PlayerAction.RETREAT:
            bench_idx = params.get("bench_idx")
            if isinstance(bench_idx, int) and 0 <= bench_idx < len(player.bench):
                return player.bench[bench_idx]
        slot_name = params.get("target_slot") or params.get("target") or params.get("slot")
        if isinstance(slot_name, str):
            if slot_name.startswith("opponent_"):
                return opponent.get_pokemon(slot_name.removeprefix("opponent_"))
            return player.get_pokemon(slot_name)
        return None

    def _attack_features(self, state, player_idx: int, action) -> list[float]:
        if action.action != PlayerAction.DECLARE_ATTACK:
            return [0.0] * 24
        player = state.get_player(player_idx)
        attack_idx = (getattr(action, "params", {}) or {}).get("attack_idx")
        if not player.active or not isinstance(attack_idx, int) or attack_idx >= len(player.active.card.attacks):
            return [0.0] * 24
        attack = player.active.card.attacks[attack_idx]
        effects = attack_runtime_effects(attack)
        effect_names = [
            name
            for effect in self._iter_effects_recursive(effects)
            for name in effect_feature_names(effect)
        ]
        joined_names = self._normalized_effect_tokens(effect_names)
        features = [
            1.0,
            _norm(self._damage_value(getattr(attack, "damage", 0)), 340.0),
            _norm(len(getattr(attack, "cost", []) or []), 5.0),
            _norm(len(effects), 6.0),
        ]
        features.extend(_bool(t in joined_names) for t in EFFECT_TYPES)
        features.extend(_bool(t in getattr(attack, "cost", []) or []) for t in ENERGY_TYPES[:8])
        return features

    def _missing_energy_count(self, pokemon, cost: list[str]) -> int:
        available = list(getattr(pokemon, "available_energy", []) or [])
        missing = 0
        for required in cost:
            if required == "Colorless":
                continue
            if required in available:
                available.remove(required)
            elif "Rainbow" in available:
                available.remove("Rainbow")
            else:
                missing += 1
        colorless = sum(1 for c in cost if c == "Colorless")
        return missing + max(0, colorless - len(available))

    def _best_missing_energy(self, pokemon) -> int:
        if pokemon is None:
            return 5
        attacks = getattr(getattr(pokemon, "card", None), "attacks", []) or []
        return min((self._missing_energy_count(pokemon, getattr(atk, "cost", []) or []) for atk in attacks), default=5)

    def _best_attack_damage(self, pokemon) -> int:
        if pokemon is None:
            return 0
        attacks = getattr(getattr(pokemon, "card", None), "attacks", []) or []
        return max((self._damage_value(getattr(atk, "damage", 0)) for atk in attacks), default=0)

    def _damage_value(self, value) -> int:
        try:
            return int(value or 0)
        except (TypeError, ValueError):
            digits = "".join(ch for ch in str(value) if ch.isdigit())
            return int(digits) if digits else 0

    def _damaged_bench_count(self, player) -> int:
        return sum(1 for pokemon in player.bench if pokemon and getattr(pokemon, "damage_counters", 0) > 0)

    def _low_hp_bench_count(self, player) -> int:
        return sum(1 for pokemon in player.bench if pokemon and pokemon.current_hp <= 80)

    def _bench_ready_count(self, player) -> int:
        return sum(1 for pokemon in player.bench if pokemon and self._best_missing_energy(pokemon) <= 0)

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

    def _effect_tokens_for_action_card(self, card) -> set[str]:
        if card is None:
            return set()
        names = [
            self._effect_name(effect)
            for effect in self._iter_effects_recursive(trainer_runtime_effects(card))
        ]
        for attack in getattr(card, "attacks", []) or []:
            names.extend(
                self._effect_name(effect)
                for effect in self._iter_effects_recursive(attack_runtime_effects(attack))
            )
        for ability in getattr(card, "abilities", []) or []:
            names.extend(
                self._effect_name(effect)
                for effect in self._iter_effects_recursive(ability_runtime_effects(ability))
            )
        return self._normalized_effect_tokens(names)

    def _discard_cost_amount(self, card) -> int:
        if card is None:
            return 0
        amount = 0
        for effect in self._iter_effects_recursive(trainer_runtime_effects(card)):
            if "discard" not in effect_feature_names(effect):
                continue
            params = self._effect_params(effect)
            from_zone = str(params.get("from", params.get("from_zone", "hand")) or "hand")
            if from_zone == "hand":
                amount += int(params.get("amount", 1) or 1)
        return amount

    def _effect_name(self, effect) -> str:
        return " ".join(effect_feature_names(effect))

    def _effect_params(self, effect) -> dict[str, Any]:
        return effect_params(effect)

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
