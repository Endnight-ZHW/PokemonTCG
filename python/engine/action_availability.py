"""Public action enumeration and stale-reference validation."""
from __future__ import annotations

from itertools import combinations

from engine.actions import AttachmentRef, CardRef, GameAction, PokemonRef
from engine.enums import PlayerAction, TurnPhase
from engine.effects.availability import effect_params, effects_have_legal_target
from engine.effects.runtime_effects import (
    strict_ability_runtime_effects as ability_runtime_effects,
    strict_trainer_runtime_effects as trainer_runtime_effects,
)
from engine.game_state import GameState
from engine.rules_validator import (
    can_attach_energy,
    can_declare_attack,
    can_evolve,
    can_play_item,
    can_play_stadium,
    can_play_supporter,
    can_play_tool,
    can_retreat,
    can_use_ability,
    effective_retreat_cost,
    energy_card_units,
)


class VMActionAvailability:
    """Owns legal public action enumeration and reference freshness checks."""

    def enumerate_actions(self, state: GameState, actor: int) -> list[GameAction]:
        if state.pending_promotion_player >= 0:
            if actor != state.pending_promotion_player:
                return []
            player = state.get_player(actor)
            return [
                GameAction(
                    "PROMOTE",
                    {"bench_idx": bench_idx},
                    actor=actor,
                    target=PokemonRef(actor, f"bench_{bench_idx}", pokemon.card.api_id),
                )
                for bench_idx, pokemon in enumerate(player.bench)
                if pokemon is not None
            ]
        if state.phase == TurnPhase.SETUP:
            return self.setup_actions(state, actor)
        if state.phase == TurnPhase.ATTACK:
            if state.active_player_idx == actor:
                return [GameAction(PlayerAction.END_TURN, {}, True, actor)]
            return []
        if state.phase != TurnPhase.MAIN or state.active_player_idx != actor:
            return []

        player = state.get_player(actor)
        actions: list[GameAction] = []
        seen: set[tuple] = set()

        def add(action: GameAction):
            if action.signature not in seen:
                seen.add(action.signature)
                actions.append(action)

        empty_slots = [f"bench_{idx}" for idx, pokemon in enumerate(player.bench) if pokemon is None]
        for hand_idx, card in enumerate(player.hand):
            source = CardRef(actor, "hand", hand_idx, card.api_id)
            if card.is_basic_pokemon:
                for target_slot in empty_slots:
                    add(GameAction(
                        PlayerAction.PLAY_BASIC,
                        {"hand_idx": hand_idx, "target": target_slot},
                        actor=actor,
                        source=source,
                        target=PokemonRef(actor, target_slot, ""),
                    ))
            elif card.is_stage1 or card.is_stage2:
                for slot, pokemon in player.get_all_pokemon():
                    if pokemon and can_evolve(state, actor, slot, card)[0]:
                        add(GameAction(
                            PlayerAction.EVOLVE,
                            {"hand_idx": hand_idx, "slot": slot},
                            actor=actor,
                            source=source,
                            target=PokemonRef(actor, slot, pokemon.card.api_id),
                        ))
            elif card.is_energy:
                for slot, pokemon in player.get_all_pokemon():
                    if pokemon and can_attach_energy(state, actor, card, slot)[0]:
                        add(GameAction(
                            PlayerAction.ATTACH_ENERGY,
                            {"hand_idx": hand_idx, "target_slot": slot},
                            actor=actor,
                            source=source,
                            target=PokemonRef(actor, slot, pokemon.card.api_id),
                        ))
            elif card.is_trainer_tool:
                for slot, pokemon in player.get_all_pokemon():
                    if pokemon and can_play_tool(state, actor, slot)[0]:
                        add(GameAction(
                            PlayerAction.PLAY_TRAINER,
                            {"hand_idx": hand_idx, "target_slot": slot},
                            actor=actor,
                            source=source,
                            target=PokemonRef(actor, slot, pokemon.card.api_id),
                        ))
            elif card.is_trainer_supporter and can_play_supporter(state, actor)[0]:
                effects = trainer_runtime_effects(card)
                if not effects or effects_have_legal_target(
                    state, actor, effects, exclude_hand_index=hand_idx
                ):
                    add(GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": hand_idx}, actor=actor, source=source))
            elif card.is_trainer_stadium and can_play_stadium(state, actor, card)[0]:
                effects = trainer_runtime_effects(card)
                if not effects or effects_have_legal_target(
                    state, actor, effects, exclude_hand_index=hand_idx
                ):
                    add(GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": hand_idx}, actor=actor, source=source))
            elif card.is_trainer_item and can_play_item(state, actor)[0]:
                effects = trainer_runtime_effects(card)
                if not effects or effects_have_legal_target(
                    state, actor, effects, exclude_hand_index=hand_idx
                ):
                    add(GameAction(PlayerAction.PLAY_TRAINER, {"hand_idx": hand_idx}, actor=actor, source=source))

        for slot, pokemon in player.get_all_pokemon():
            if pokemon is None:
                continue
            for ability in pokemon.card.abilities:
                if can_use_ability(state, actor, slot, ability.name)[0]:
                    effects = ability_runtime_effects(ability)
                    if not effects or effects_have_legal_target(
                        state, actor, effects, source_slot=slot
                    ):
                        add(GameAction(
                            PlayerAction.USE_ABILITY,
                            {"slot": slot, "ability_name": ability.name},
                            actor=actor,
                            source=PokemonRef(actor, slot, pokemon.card.api_id),
                        ))

        if self.stadium_is_activatable(state) and not player.stadium_used_this_turn:
            stadium = state.stadium_card
            effects = trainer_runtime_effects(stadium) if stadium is not None else []
            if stadium is None or effects_have_legal_target(state, actor, effects):
                add(GameAction(PlayerAction.USE_STADIUM, {}, actor=actor))

        for bench_idx, pokemon in enumerate(player.bench):
            if pokemon is None:
                continue
            for payment in self.retreat_payments(state, actor, bench_idx):
                add(GameAction(
                    PlayerAction.RETREAT,
                    {"bench_idx": bench_idx, "energy_indices": list(payment)},
                    actor=actor,
                    target=PokemonRef(actor, f"bench_{bench_idx}", pokemon.card.api_id),
                ))

        if player.active:
            for attack_idx, _attack in enumerate(player.active.card.attacks):
                if can_declare_attack(state, actor, attack_idx)[0]:
                    add(GameAction(
                        PlayerAction.DECLARE_ATTACK,
                        {"attack_idx": attack_idx},
                        True,
                        actor,
                        source=PokemonRef(actor, "active", player.active.card.api_id),
                    ))

        add(GameAction(PlayerAction.END_TURN, {}, True, actor))
        return actions

    @staticmethod
    def setup_actions(state: GameState, actor: int) -> list[GameAction]:
        player = state.get_player(actor)
        actions: list[GameAction] = []
        empty_slots = [idx for idx, pokemon in enumerate(player.bench) if pokemon is None]
        for hand_idx, card in enumerate(player.hand):
            if not card.is_basic_pokemon:
                continue
            source = CardRef(actor, "hand", hand_idx, card.api_id)
            if player.active is None:
                actions.append(GameAction(
                    PlayerAction.PLAY_BASIC,
                    {"hand_idx": hand_idx, "target": "active"},
                    actor=actor,
                    source=source,
                    target=PokemonRef(actor, "active", ""),
                ))
            elif empty_slots:
                for bench_idx in empty_slots:
                    target = f"bench_{bench_idx}"
                    actions.append(GameAction(
                        PlayerAction.PLAY_BASIC,
                        {"hand_idx": hand_idx, "target": target},
                        actor=actor,
                        source=source,
                        target=PokemonRef(actor, target, ""),
                    ))
        if player.active is not None:
            actions.append(GameAction("SETUP_DONE", {}, True, actor))
        return actions

    @staticmethod
    def retreat_payments(
        state: GameState,
        actor: int,
        bench_idx: int,
    ) -> tuple[tuple[int, ...], ...]:
        player = state.get_player(actor)
        if not can_retreat(state, actor, bench_idx)[0] or player.active is None:
            return ()
        cost = effective_retreat_cost(state, player)
        if cost <= 0:
            return ((),)
        cards = player.active.energy_cards
        payments: list[tuple[int, ...]] = []
        for size in range(1, len(cards) + 1):
            for indices in combinations(range(len(cards)), size):
                units = sum(energy_card_units(cards[index], player.active) for index in indices)
                if units < cost:
                    continue
                if any(
                    sum(energy_card_units(cards[index], player.active) for index in subset) >= cost
                    for subset_size in range(1, len(indices))
                    for subset in combinations(indices, subset_size)
                ):
                    continue
                payments.append(indices)
        return tuple(payments)

    @staticmethod
    def stadium_is_activatable(state: GameState) -> bool:
        stadium = state.stadium_card
        if stadium is None:
            return False
        return any(
            effect_params(effect).get("stadium_type") == "activatable"
            for effect in trainer_runtime_effects(stadium)
        )

    @staticmethod
    def validate_action_references(state: GameState, action: GameAction) -> str:
        for ref in (action.source, action.target):
            if ref is None:
                continue
            if isinstance(ref, CardRef):
                if ref.player not in (0, 1):
                    return "卡牌引用的玩家无效。"
                zone = getattr(state.get_player(ref.player), ref.zone, None)
                if not isinstance(zone, list):
                    continue
                if not (0 <= ref.index < len(zone)):
                    return "卡牌引用已失效。"
                card = zone[ref.index]
                if ref.card_id and getattr(card, "api_id", "") != ref.card_id:
                    return "卡牌引用与当前局面不一致。"
            elif isinstance(ref, PokemonRef):
                if ref.player not in (0, 1):
                    return "宝可梦引用的玩家无效。"
                pokemon = state.get_player(ref.player).get_pokemon(ref.slot)
                # Empty setup destinations intentionally have no current card.
                if pokemon is None:
                    if ref.card_id:
                        return "宝可梦引用已失效。"
                    continue
                if ref.card_id and pokemon.card.api_id != ref.card_id:
                    return "宝可梦引用与当前局面不一致。"
            elif isinstance(ref, AttachmentRef):
                if ref.player not in (0, 1):
                    return "附着卡引用的玩家无效。"
                pokemon = state.get_player(ref.player).get_pokemon(ref.slot)
                if pokemon is None:
                    return "附着卡所属宝可梦已不存在。"
                attachments = (
                    pokemon.energy_cards
                    if ref.attachment_type == "energy"
                    else [pokemon.attached_tool] if pokemon.attached_tool else []
                )
                if not (0 <= ref.index < len(attachments)):
                    return "附着卡引用已失效。"
                if ref.card_id and attachments[ref.index].api_id != ref.card_id:
                    return "附着卡引用与当前局面不一致。"
        return ""
