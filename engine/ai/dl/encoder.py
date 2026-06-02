"""Feature encoders for the optional deep-learning AI.

The model scores legal candidate actions rather than predicting a fixed action
ID.  This keeps the rules engine authoritative and lets future card/deck
additions work through card metadata plus hashed card identity features.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Any

from engine.enums import PlayerAction, TurnPhase


CARD_BUCKET_COUNT = 4096
STATE_NUMERIC_SIZE = 256
STATE_CARD_SLOTS = 32
ACTION_NUMERIC_SIZE = 96

ACTION_TYPES = [
    "NOOP",
    "SETUP_DONE",
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


def _norm(value: float, divisor: float) -> float:
    if divisor <= 0:
        return 0.0
    return max(-4.0, min(4.0, float(value) / divisor))


class ActionStateEncoder:
    """Encode GameState and AIAction candidates into fixed-size features."""

    state_numeric_size = STATE_NUMERIC_SIZE
    state_card_slots = STATE_CARD_SLOTS
    action_numeric_size = ACTION_NUMERIC_SIZE
    card_bucket_count = CARD_BUCKET_COUNT
    deck_keys: tuple[str, ...] = (
        "fire", "water", "psychic", "lightning", "fighting", "colorless", "dragon", "grass",
    )

    def encode_state(self, state, player_idx: int, deck_key: str | None = None) -> EncodedState:
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
        numeric.extend(self._deck_context(player))
        numeric.extend(self._deck_key_features(deck_key))

        for _, pokemon in player.get_all_pokemon():
            numeric.extend(self._pokemon_features(pokemon))
        for _, pokemon in opponent.get_all_pokemon():
            numeric.extend(self._pokemon_features(pokemon))

        card_ids = []
        card_ids.extend(card_bucket(p.card) if p else 0 for _, p in player.get_all_pokemon())
        card_ids.extend(card_bucket(p.card) if p else 0 for _, p in opponent.get_all_pokemon())
        card_ids.extend(card_bucket(card) for card in list(player.hand)[:12])
        card_ids.extend(card_bucket(card) for card in list(player.discard)[-4:])
        card_ids.append(card_bucket(getattr(state, "stadium_card", None)))
        card_ids.extend(card_bucket(card) for card in list(player.deck)[-3:])

        return EncodedState(
            numeric=_pad(numeric, STATE_NUMERIC_SIZE),
            card_ids=_pad_ids(card_ids, STATE_CARD_SLOTS),
        )

    def encode_action(self, state, player_idx: int, action) -> EncodedAction:
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
        numeric.extend(self._card_features(card))
        numeric.extend(self._attack_features(state, player_idx, action))

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

    def _deck_context(self, player) -> list[float]:
        zones = [player.deck, player.hand, player.discard]
        values: list[float] = []
        for zone in zones:
            total = max(1, len(zone))
            values.extend([
                sum(1 for c in zone if getattr(c, "is_pokemon", False)) / total,
                sum(1 for c in zone if getattr(c, "is_trainer", False)) / total,
                sum(1 for c in zone if getattr(c, "is_energy", False)) / total,
            ])
            energy_seen = set()
            for card in zone:
                energy_seen.update(getattr(card, "provides_energy", []) or [])
                energy_seen.update(getattr(card, "energy_types", []) or [])
            values.extend(_bool(t in energy_seen) for t in ENERGY_TYPES)
        return values

    def _deck_key_features(self, deck_key: str | None) -> list[float]:
        return _one_hot(self.deck_keys.index(deck_key), len(self.deck_keys)) if deck_key in self.deck_keys else [0.0] * len(self.deck_keys)

    def _pokemon_features(self, pokemon) -> list[float]:
        if pokemon is None:
            return [0.0] * 18
        card = pokemon.card
        status_count = len(getattr(pokemon, "status_conditions", []) or [])
        return [
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
            _norm(len(getattr(pokemon, "available_energy", []) or []), 8.0),
        ]

    def _card_features(self, card) -> list[float]:
        if card is None:
            return [0.0] * 20
        text = " ".join(getattr(card, "rules", []) or [])
        if getattr(card, "trainer_text", ""):
            text += " " + str(getattr(card, "trainer_text", ""))
        text = text.lower()
        energy_types = set(getattr(card, "energy_types", []) or [])
        energy_types.update(getattr(card, "provides_energy", []) or [])
        return [
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
            _bool("draw" in text),
            _bool("search" in text),
            _bool("discard" in text),
            _bool(energy_types),
        ]

    def _attack_features(self, state, player_idx: int, action) -> list[float]:
        if action.action != PlayerAction.DECLARE_ATTACK:
            return [0.0] * 12
        player = state.get_player(player_idx)
        attack_idx = (getattr(action, "params", {}) or {}).get("attack_idx")
        if not player.active or not isinstance(attack_idx, int) or attack_idx >= len(player.active.card.attacks):
            return [0.0] * 12
        attack = player.active.card.attacks[attack_idx]
        effects = getattr(attack, "effects", []) or []
        effect_names = [str(getattr(e, "effect_type", e.get("effect_type", "")) if isinstance(e, dict) else getattr(e, "effect_type", "")) for e in effects]
        joined = " ".join(effect_names).lower()
        return [
            1.0,
            _norm(getattr(attack, "damage", 0), 340.0),
            _norm(len(getattr(attack, "cost", []) or []), 5.0),
            _norm(len(effects), 6.0),
            _bool("draw" in joined),
            _bool("search" in joined),
            _bool("energy" in joined or "attach" in joined),
            _bool("heal" in joined),
            _bool("coin" in joined),
            _bool("switch" in joined),
            _bool("discard" in joined),
            _bool("prevent" in joined or "lock" in joined),
        ]
