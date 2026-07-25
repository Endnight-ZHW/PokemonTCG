"""Public-information observations and fair search determinizations."""
from __future__ import annotations

import random
from collections import Counter
from dataclasses import dataclass
from typing import Any

from data.card_registry import CardRegistry
from engine.snapshot import clone_state


@dataclass(frozen=True)
class Observation:
    perspective: int
    turn_number: int
    phase: str
    active_player: int
    winner: int | None
    own_hand: tuple[str, ...]
    own_discard: tuple[str, ...]
    own_deck_count: int
    own_prize_count: int
    opponent_hand_count: int
    opponent_discard: tuple[str, ...]
    opponent_deck_count: int
    opponent_prize_count: int
    board: tuple[tuple[Any, ...], ...]
    stadium_id: str
    public_deck_keys: tuple[str | None, str | None]
    apply_type_matchups: bool

    @classmethod
    def from_state(cls, state, perspective: int) -> "Observation":
        own = state.get_player(perspective)
        opponent = state.get_player(1 - perspective)
        board = []
        for player_idx in (0, 1):
            player = state.get_player(player_idx)
            for slot, pokemon in player.get_all_pokemon():
                if pokemon is None:
                    board.append((player_idx, slot, "", 0, (), (), ""))
                    continue
                board.append((
                    player_idx,
                    slot,
                    pokemon.card.api_id,
                    pokemon.damage_counters,
                    tuple(card.api_id for card in pokemon.energy_cards),
                    tuple(sorted(status.name for status in pokemon.status_conditions)),
                    pokemon.attached_tool.api_id if pokemon.attached_tool else "",
                ))
        return cls(
            perspective=perspective,
            turn_number=state.turn_number,
            phase=getattr(state.phase, "name", str(state.phase)),
            active_player=state.active_player_idx,
            winner=state.winner,
            own_hand=tuple(card.api_id for card in own.hand),
            own_discard=tuple(card.api_id for card in own.discard),
            own_deck_count=len(own.deck),
            own_prize_count=len(own.prizes),
            opponent_hand_count=opponent.hand_count,
            opponent_discard=tuple(card.api_id for card in opponent.discard),
            opponent_deck_count=len(opponent.deck),
            opponent_prize_count=len(opponent.prizes),
            board=tuple(board),
            stadium_id=getattr(getattr(state, "stadium_card", None), "api_id", ""),
            public_deck_keys=tuple(getattr(state, "public_deck_keys", (None, None))),
            apply_type_matchups=bool(getattr(state, "apply_type_matchups", False)),
        )

    @property
    def information_key(self) -> tuple:
        return (
            self.perspective,
            self.turn_number,
            self.phase,
            self.active_player,
            self.winner,
            self.own_hand,
            self.own_discard,
            self.own_deck_count,
            self.own_prize_count,
            self.opponent_hand_count,
            self.opponent_discard,
            self.opponent_deck_count,
            self.opponent_prize_count,
            self.board,
            self.stadium_id,
            self.public_deck_keys,
            self.apply_type_matchups,
        )


def fair_search_clone(state, perspective: int, seed: int = 0):
    """Sample a hidden world from public information and known deck priors."""
    cloned = clone_state(state)
    rng = random.Random(seed)
    deck_keys = tuple(getattr(state, "public_deck_keys", (None, None)))

    own = cloned.get_player(perspective)
    own_deck_count = len(own.deck)
    own_prize_count = len(own.prizes)
    own_prior = _deck_prior(deck_keys[perspective] if perspective < len(deck_keys) else None)
    own_unknown_count = own_deck_count + own_prize_count
    if own_prior:
        own_pool = _remaining_prior_cards(own_prior, _visible_card_ids(own, include_hand=True))
    else:
        # A player knows their submitted deck list, but not current deck order
        # or which cards are prized. Shuffling this union hides both.
        own_pool = list(own.deck) + list(own.prizes)
    own_pool = _fit_hidden_pool(own_pool, own_unknown_count)
    rng.shuffle(own_pool)
    own.deck = own_pool[:own_deck_count]
    own.prizes = own_pool[own_deck_count:own_unknown_count]

    opponent_idx = 1 - perspective
    opponent = cloned.get_player(opponent_idx)
    hand_count = opponent.hand_count
    deck_count = len(opponent.deck)
    prize_count = len(opponent.prizes)
    opponent_prior = _deck_prior(
        deck_keys[opponent_idx] if opponent_idx < len(deck_keys) else None
    )
    if opponent_prior:
        opponent_pool = _remaining_prior_cards(
            opponent_prior,
            _visible_card_ids(opponent, include_hand=False),
        )
    else:
        # Without a publicly disclosed deck profile, identities remain fully
        # unknown. Neutral cards preserve counts without leaking categories.
        opponent_pool = []
    opponent_pool = _fit_hidden_pool(
        opponent_pool,
        hand_count + deck_count + prize_count,
    )
    rng.shuffle(opponent_pool)
    opponent.hand = opponent_pool[:hand_count]
    opponent.deck = opponent_pool[hand_count:hand_count + deck_count]
    opponent.prizes = opponent_pool[
        hand_count + deck_count:hand_count + deck_count + prize_count
    ]
    return cloned


def _deck_prior(deck_key: str | None):
    if not deck_key:
        return []
    from data.deck_definitions import DECK_SPECS, expand_deck

    spec = DECK_SPECS.get(str(deck_key))
    if spec is None:
        return []
    return [
        card
        for card_id in expand_deck(spec)
        if (card := CardRegistry.get(card_id)) is not None
    ]


def _visible_card_ids(player, *, include_hand: bool) -> list[str]:
    cards = list(player.discard)
    if include_hand:
        cards.extend(player.hand)
    for _slot, pokemon in player.get_all_pokemon():
        if pokemon is None:
            continue
        cards.append(pokemon.card)
        cards.extend(pokemon.evolution_stack)
        cards.extend(pokemon.energy_cards)
        if pokemon.attached_tool is not None:
            cards.append(pokemon.attached_tool)
    return [card.api_id for card in cards if card is not None]


def _remaining_prior_cards(prior: list, visible_ids: list[str]) -> list:
    remaining = Counter(card.api_id for card in prior)
    for card_id in visible_ids:
        if remaining[card_id] > 0:
            remaining[card_id] -= 1
    cards = []
    for card in prior:
        if remaining[card.api_id] <= 0:
            continue
        cards.append(card)
        remaining[card.api_id] -= 1
    return cards


def _fit_hidden_pool(cards: list, count: int) -> list:
    result = list(cards[:count])
    placeholder = _neutral_hidden_card()
    if placeholder is not None and len(result) < count:
        result.extend([placeholder] * (count - len(result)))
    return result


def _neutral_hidden_card():
    for card_id in (
        "sv1-ener-1",
        "sv1-ener-2",
        "sv1-ener-3",
        "sv1-ener-4",
        "sv1-ener-5",
        "sv1-ener-6",
        "sv1-ener-8",
    ):
        card = CardRegistry.get(card_id)
        if card is not None:
            return card
    return None
