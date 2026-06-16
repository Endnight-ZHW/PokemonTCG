"""Fog-of-war masking and cloning helpers for ChallengeAI."""
from __future__ import annotations

from typing import Any

from engine.game_state import GameState
from engine.snapshot import clone_state


class ChallengeAIFogMixin:
    """Owns hidden-zone masking used by fair-information AI search."""

    def _card_fow_profile(self, card) -> str:
        """Return the fog-of-war type profile key for a card."""
        if getattr(card, "is_pokemon", False):
            if getattr(card, "is_basic_pokemon", False):
                return self._FOW_POKEMON_BASIC
            if getattr(card, "is_stage1", False):
                return self._FOW_POKEMON_STAGE1
            if getattr(card, "is_stage2", False):
                return self._FOW_POKEMON_STAGE2
            return self._FOW_POKEMON_BASIC
        if getattr(card, "is_energy", False):
            if getattr(card, "is_basic_energy", False):
                return self._FOW_ENERGY_BASIC
            return self._FOW_ENERGY_SPECIAL
        if getattr(card, "is_trainer", False):
            if getattr(card, "is_trainer_item", False):
                return self._FOW_TRAINER_ITEM
            if getattr(card, "is_trainer_supporter", False):
                return self._FOW_TRAINER_SUPPORTER
            if getattr(card, "is_trainer_stadium", False):
                return self._FOW_TRAINER_STADIUM
            if getattr(card, "is_trainer_tool", False):
                return self._FOW_TRAINER_TOOL
            return self._FOW_TRAINER_ITEM
        return self._FOW_UNKNOWN

    def _get_fow_card(self, original_card):
        """Return a fog-of-war placeholder preserving type tags, hiding identity."""
        from data.card_models import AttackDef, Card as CardModel

        profile = self._card_fow_profile(original_card)
        idx = self._fow_counter[profile]
        self._fow_counter[profile] = idx + 1
        key = f"_fow_{profile}_{idx}"

        if key in self._fow_cache:
            self._register_fow_card(key, self._fow_cache[key])
            return self._fow_cache[key]

        subtypes = list(getattr(original_card, "subtypes", []))
        supertype = getattr(original_card, "supertype", "")

        if profile == self._FOW_POKEMON_BASIC:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype=supertype,
                subtypes=subtypes, hp=100, energy_types=["Colorless"],
                attacks=[AttackDef("???", [], 0, "")],
            )
        elif profile == self._FOW_POKEMON_STAGE1:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype=supertype,
                subtypes=subtypes, hp=110, energy_types=["Colorless"],
                evolves_from="???",
                attacks=[AttackDef("???", [], 0, "")],
            )
        elif profile == self._FOW_POKEMON_STAGE2:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype=supertype,
                subtypes=subtypes, hp=150, energy_types=["Colorless"],
                evolves_from="???",
                attacks=[AttackDef("???", [], 0, "")],
            )
        elif profile == self._FOW_ENERGY_BASIC:
            placeholder = CardModel(
                api_id=key, name="? Energy", supertype="Energy",
                subtypes=["Basic"],
            )
        elif profile == self._FOW_ENERGY_SPECIAL:
            placeholder = CardModel(
                api_id=key, name="? Energy", supertype="Energy",
                subtypes=["Special"],
            )
        elif profile == self._FOW_TRAINER_ITEM:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype="Trainer",
                subtypes=["Item"],
            )
        elif profile == self._FOW_TRAINER_SUPPORTER:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype="Trainer",
                subtypes=["Supporter"],
            )
        elif profile == self._FOW_TRAINER_STADIUM:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype="Trainer",
                subtypes=["Stadium"],
            )
        elif profile == self._FOW_TRAINER_TOOL:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype="Trainer",
                subtypes=["Tool"],
            )
        else:
            placeholder = CardModel(
                api_id=key, name="? ? ?", supertype=supertype,
                subtypes=subtypes,
            )

        self._register_fow_card(key, placeholder)
        self._fow_cache[key] = placeholder
        return placeholder

    @staticmethod
    def _register_fow_card(key: str, card: Any) -> None:
        """Keep a fog-of-war placeholder resolvable by snapshot restore."""
        from data.card_registry import CardRegistry

        CardRegistry._cards[key] = card
        if card.name not in CardRegistry._by_name:
            CardRegistry._by_name[card.name] = []
        if key not in CardRegistry._by_name[card.name]:
            CardRegistry._by_name[card.name].append(key)

    @staticmethod
    def _is_opponent_masked(state: GameState, opponent_idx: int) -> bool:
        """Check if opponent hidden zones are already masked."""
        opponent = state.get_player(opponent_idx)
        if opponent.hand and getattr(opponent.hand[0], "api_id", "").startswith("_fow_"):
            return True
        if opponent.deck and getattr(opponent.deck[0], "api_id", "").startswith("_fow_"):
            return True
        return False

    def _cleanup_fow_registry(self) -> None:
        """Remove fog-of-war placeholders from the global CardRegistry."""
        from data.card_registry import CardRegistry

        for key in list(self._fow_cache):
            CardRegistry._cards.pop(key, None)
        for name, ids in list(CardRegistry._by_name.items()):
            CardRegistry._by_name[name] = [i for i in ids if not i.startswith("_fow_")]
            if not CardRegistry._by_name[name]:
                del CardRegistry._by_name[name]

    def _masked_clone_for_eval(self, state: GameState, player_idx: int) -> GameState:
        """Clone and scrub hidden information for fair beam-search evaluation."""
        # Do not remove cached placeholders here. Beam-search frontier nodes may
        # still snapshot/restore masked states containing these _fow_* ids.
        self._fow_counter.clear()

        clone = self._clone_state(state)
        self.random.shuffle(clone.get_player(player_idx).deck)

        opponent_idx = 1 - player_idx
        opponent = clone.get_player(opponent_idx)
        opponent.hand = [self._get_fow_card(c) for c in opponent.hand]
        opponent.deck = [self._get_fow_card(c) for c in opponent.deck]
        opponent.prizes = [self._get_fow_card(c) for c in opponent.prizes]

        return clone

    def _clone_state(self, state: GameState) -> GameState:
        return clone_state(state, rebuild_event_bus=True)

    def _rebuild_event_bus(self, state: GameState):
        from engine.commands.modifier_registration import register_pokemon_modifiers

        state.event_bus.clear()
        for player_idx in (0, 1):
            player = state.get_player(player_idx)
            for slot, pokemon in player.get_all_pokemon():
                if pokemon:
                    register_pokemon_modifiers(pokemon, player_idx, slot, event_bus=state.event_bus)
