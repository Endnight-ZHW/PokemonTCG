"""Public action enumeration and stale-reference validation."""
from __future__ import annotations

from itertools import combinations

from engine.actions import AttachmentRef, CardRef, GameAction, PokemonRef, SlotRef
from engine.enums import PlayerAction, TurnPhase
from engine.effects.availability import (
    effect_params,
    effect_type,
    effects_have_legal_target,
)
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

    # ``enumerate_actions`` already applies the resource/target checks for
    # these single-effect release cards. Their VM handlers either complete
    # immediately or create a validated choice request, so replaying the
    # entire action on a cloned state cannot reject them. Branching effects,
    # multi-effect sequences, and non-registry cards deliberately fall back
    # to the authoritative simulation in ``GameEngine.legal_actions``.
    STATICALLY_VALIDATED_EFFECT_TYPES = frozenset({
        "ability_discard_revive",
        "arven",
        "attach_from_discard",
        "aura_damage_boost",
        "aura_damage_reduction",
        "clara",
        "conditional_hp_boost",
        "conditional_zero_retreat",
        "discard_then_draw",
        "draw",
        "draw_and_attach_energy",
        "draw_until_more",
        "energy_relocate",
        "hand_to_bottom_draw",
        "heal",
        "heal_all",
        "judge",
        "look_top_deck",
        "place_counters_and_self_ko",
        "potion_heal",
        "reactive_thorns",
        "search",
        "shuffle_draw",
        "shuffle_from_discard",
        "switch_self",
        "tool",
        "tool_exp_share",
        "trekking_shoes",
        "zinnia_resolve",
    })

    def can_skip_effect_simulation(
        self,
        state: GameState,
        actor: int,
        action: GameAction,
    ) -> bool:
        """Return whether enumeration fully proved this effect action legal.

        This is intentionally conservative. It only recognizes canonical
        release cards with zero or one top-level effect whose preconditions
        are already checked by ``enumerate_actions``. Everything extensible
        or order-sensitive retains the previous clone-and-execute behavior.
        """
        owner_and_effects = self._effect_owner_and_effects(state, actor, action)
        if owner_and_effects is None:
            return False
        owner, effects = owner_and_effects
        if not self._is_registered_card(owner):
            return False
        if not effects:
            return True
        if len(effects) != 1:
            return False
        return effect_type(effects[0]) in self.STATICALLY_VALIDATED_EFFECT_TYPES

    @staticmethod
    def _is_registered_card(card) -> bool:
        if card is None:
            return False
        from data.card_registry import CardRegistry

        card_id = str(getattr(card, "api_id", "") or "")
        return bool(card_id) and CardRegistry.get(card_id) is card

    @staticmethod
    def _effect_owner_and_effects(
        state: GameState,
        actor: int,
        action: GameAction,
    ):
        player = state.get_player(actor)
        if action.action == PlayerAction.PLAY_TRAINER:
            hand_idx = action.params.get("hand_idx")
            if type(hand_idx) is not int or not (0 <= hand_idx < len(player.hand)):
                return None
            card = player.hand[hand_idx]
            return card, trainer_runtime_effects(card)
        if action.action == PlayerAction.USE_ABILITY:
            if isinstance(action.source, CardRef) and action.source.zone == "discard":
                if not (0 <= action.source.index < len(player.discard)):
                    return None
                card = player.discard[action.source.index]
                ability_name = str(action.params.get("ability_name", "") or "")
                ability = next(
                    (candidate for candidate in card.abilities
                     if candidate.name.lower() == ability_name.lower()),
                    None,
                )
                return (card, ability_runtime_effects(ability)) if ability else None
            slot = str(action.params.get("slot", "") or "")
            ability_name = str(action.params.get("ability_name", "") or "")
            pokemon = player.get_pokemon(slot)
            if pokemon is None:
                return None
            ability = next(
                (
                    candidate
                    for candidate in pokemon.card.abilities
                    if candidate.name.lower() == ability_name.lower()
                ),
                None,
            )
            if ability is None:
                return None
            return pokemon.card, ability_runtime_effects(ability)
        if action.action == PlayerAction.USE_STADIUM:
            stadium = state.stadium_card
            if stadium is None:
                return None
            return stadium, trainer_runtime_effects(stadium)
        return None

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
                        target=SlotRef(actor, target_slot),
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

        # Zone-activated abilities are enumerated from their declared effect
        # source rather than pretending the card is already in play.
        if not player.hand and player.bench_has_space():
            for discard_idx, card in enumerate(player.discard):
                for ability in getattr(card, "abilities", []) or []:
                    effects = ability_runtime_effects(ability)
                    if not any(
                        effect_type(effect) == "ability_discard_revive"
                        for effect in effects
                    ):
                        continue
                    if not effects_have_legal_target(state, actor, effects, source_slot="discard"):
                        continue
                    add(GameAction(
                        PlayerAction.USE_ABILITY,
                        {
                            "slot": "discard",
                            "discard_idx": discard_idx,
                            "card_id": card.api_id,
                            "ability_name": ability.name,
                        },
                        actor=actor,
                        source=CardRef(actor, "discard", discard_idx, card.api_id),
                    ))

        if self.stadium_is_activatable(state) and not player.stadium_used_this_turn:
            stadium = state.stadium_card
            effects = trainer_runtime_effects(stadium) if stadium is not None else []
            if stadium is None or effects_have_legal_target(state, actor, effects):
                add(GameAction(PlayerAction.USE_STADIUM, {}, actor=actor))

        for bench_idx, pokemon in enumerate(player.bench):
            if pokemon is None:
                continue
            if can_retreat(state, actor, bench_idx)[0]:
                add(GameAction(
                    PlayerAction.RETREAT,
                    {"bench_idx": bench_idx},
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
        stage = str(getattr(state, "setup_stage", ""))
        if actor != int(getattr(state, "setup_actor_idx", -1)):
            return []
        if stage not in {"INITIAL_PLACEMENT", "BONUS_PLACEMENT"}:
            return []
        player = state.get_player(actor)
        actions: list[GameAction] = []
        empty_slots = [idx for idx, pokemon in enumerate(player.bench) if pokemon is None]
        eligible_bonus_ids = list(
            getattr(state, "setup_bonus_card_ids", ([], []))[actor]
        )
        for hand_idx, card in enumerate(player.hand):
            if not card.is_basic_pokemon:
                continue
            if stage == "BONUS_PLACEMENT" and card.api_id not in eligible_bonus_ids:
                continue
            source = CardRef(actor, "hand", hand_idx, card.api_id)
            if stage == "INITIAL_PLACEMENT" and player.active is None:
                actions.append(GameAction(
                    PlayerAction.PLAY_BASIC,
                    {"hand_idx": hand_idx, "target": "active"},
                    actor=actor,
                    source=source,
                    target=SlotRef(actor, "active"),
                ))
            elif empty_slots:
                for bench_idx in empty_slots:
                    target = f"bench_{bench_idx}"
                    actions.append(GameAction(
                        PlayerAction.PLAY_BASIC,
                        {"hand_idx": hand_idx, "target": target},
                        actor=actor,
                        source=source,
                        target=SlotRef(actor, target),
                    ))
        if (
            (stage == "INITIAL_PLACEMENT" and player.active is not None)
            or stage == "BONUS_PLACEMENT"
        ):
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
    def validate_action_references(
        state: GameState,
        action: GameAction,
        actor: int | None = None,
    ) -> str:
        actor = action.actor if actor is None else actor
        for ref in (action.source, action.target):
            if ref is None:
                continue
            if isinstance(ref, CardRef):
                if type(ref.player) is not int or ref.player not in (0, 1):
                    return "卡牌引用的玩家无效。"
                if (
                    not isinstance(ref.zone, str)
                    or not isinstance(ref.card_id, str)
                    or type(ref.index) is not int
                ):
                    return "卡牌引用格式无效。"
                zone = getattr(state.get_player(ref.player), ref.zone, None)
                if not isinstance(zone, list):
                    return "卡牌引用的区域无效。"
                if not (0 <= ref.index < len(zone)):
                    return "卡牌引用已失效。"
                card = zone[ref.index]
                if ref.card_id and getattr(card, "api_id", "") != ref.card_id:
                    return "卡牌引用与当前局面不一致。"
            elif isinstance(ref, PokemonRef):
                if type(ref.player) is not int or ref.player not in (0, 1):
                    return "宝可梦引用的玩家无效。"
                if not isinstance(ref.slot, str) or not isinstance(ref.card_id, str):
                    return "宝可梦引用格式无效。"
                pokemon = state.get_player(ref.player).get_pokemon(ref.slot)
                # Empty setup destinations intentionally have no current card.
                if pokemon is None:
                    if ref.card_id:
                        return "宝可梦引用已失效。"
                    continue
                if ref.card_id and pokemon.card.api_id != ref.card_id:
                    return "宝可梦引用与当前局面不一致。"
            elif isinstance(ref, SlotRef):
                if type(ref.player) is not int or ref.player not in (0, 1):
                    return "位置引用的玩家无效。"
                if not isinstance(ref.slot, str) or not ref.slot:
                    return "位置引用格式无效。"
                if state.get_player(ref.player).get_pokemon(ref.slot) is not None:
                    return "动作目标位置已被占用。"
            elif isinstance(ref, AttachmentRef):
                if type(ref.player) is not int or ref.player not in (0, 1):
                    return "附着卡引用的玩家无效。"
                if (
                    not isinstance(ref.slot, str)
                    or not isinstance(ref.attachment_type, str)
                    or not isinstance(ref.card_id, str)
                    or type(ref.index) is not int
                ):
                    return "附着卡引用格式无效。"
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
            else:
                return "动作引用类型无效。"
            if actor in (0, 1) and ref.player != actor:
                return "动作引用的玩家与动作执行者不一致。"

        params = action.params if isinstance(action.params, dict) else {}
        action_name = (
            action.action.name
            if isinstance(action.action, PlayerAction)
            else str(action.action)
        )
        source = action.source
        target = action.target

        if isinstance(source, CardRef):
            if action_name in {
                "PLAY_BASIC", "EVOLVE", "ATTACH_ENERGY", "PLAY_TRAINER",
            }:
                if source.zone != "hand" or params.get("hand_idx") != source.index:
                    return "动作来源引用与手牌参数不一致。"
            elif action_name == "USE_ABILITY":
                if (
                    params.get("slot") != "discard"
                    or source.zone != "discard"
                    or params.get("discard_idx") != source.index
                    or params.get("card_id") != source.card_id
                ):
                    return "弃牌区能力来源引用与动作参数不一致。"
        elif isinstance(source, PokemonRef):
            if action_name == "USE_ABILITY" and params.get("slot") != source.slot:
                return "能力来源引用与动作参数不一致。"
            if action_name == "DECLARE_ATTACK" and source.slot != "active":
                return "攻击来源必须是战斗宝可梦。"

        if isinstance(target, (PokemonRef, SlotRef)):
            expected_slot = None
            if action_name == "PLAY_BASIC":
                expected_slot = params.get("target")
            elif action_name == "EVOLVE":
                expected_slot = params.get("slot")
            elif action_name in {"ATTACH_ENERGY", "PLAY_TRAINER"}:
                expected_slot = params.get("target_slot")
            elif action_name in {"RETREAT", "PROMOTE"}:
                bench_idx = params.get("bench_idx")
                if type(bench_idx) is int:
                    expected_slot = f"bench_{bench_idx}"
            if expected_slot is not None and target.slot != expected_slot:
                return "动作目标引用与动作参数不一致。"
        return ""
