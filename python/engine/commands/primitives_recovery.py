"""Recovery, hand-bottom, revive, and skip-stage evolution VM commands."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from engine.commands.base import CommandResult, ResolutionContext


def _build_runtime_command(effect):
    from engine.commands.dsl_compiler import compile_command_spec
    from engine.commands.registry import build_command

    if isinstance(effect, dict) and "op" in effect:
        return compile_command_spec(effect)
    return build_command(effect)


@dataclass
class RecoverFromDiscard:
    """Recover selected cards from discard to deck or hand."""

    mode: str = "shuffle_to_deck"
    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        if self.mode == "clara":
            return self._execute_clara(ctx)
        return self._execute_shuffle_from_discard(ctx)

    def _execute_shuffle_from_discard(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        count = int(self.params.get("count", 3) or 3)
        filter_type = str(self.params.get("filter", "any") or "any")

        def matches(card):
            if filter_type == "supporter":
                return bool(getattr(card, "is_trainer_supporter", False))
            if filter_type == "basic_energy":
                return bool(getattr(card, "is_basic_energy", False))
            if filter_type == "pokemon_and_energy":
                return bool(getattr(card, "is_pokemon", False) or getattr(card, "is_basic_energy", False))
            return True

        available = [card for card in player.discard if matches(card)]
        if not available:
            return CommandResult.fail("弃牌区没有符合条件的卡，卡牌保留在手牌中。")
        max_select = min(count, len(available))

        return CommandResult.ok(
            f"Choose up to {count} cards from discard.",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"从弃牌区选择最多{count}张卡",
                min_select=1,
                max_select=max_select,
                from_zone="discard",
                card_list=available,
                can_cancel=True,
                continuation={
                    "kind": "recover_from_discard_to_deck",
                    "player_idx": ctx.player_idx,
                    "count": count,
                },
            ),
        )

    def _execute_clara(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        pokemon_count = int(self.params.get("pokemon_count", 2) or 2)
        energy_count = int(self.params.get("energy_count", 2) or 2)
        available = [
            card for card in player.discard
            if getattr(card, "is_pokemon", False) or getattr(card, "is_basic_energy", False)
        ]
        if not available:
            return CommandResult.ok("弃牌区没有可回收的卡。")

        return CommandResult.ok(
            "选择弃牌区中的宝可梦和基本能量回收。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"从弃牌区选择最多{pokemon_count}只宝可梦和最多{energy_count}张基本能量",
                min_select=0,
                max_select=pokemon_count + energy_count,
                from_zone="discard",
                card_list=available,
                continuation={
                    "kind": "recover_clara",
                    "player_idx": ctx.player_idx,
                    "pokemon_count": pokemon_count,
                    "energy_count": energy_count,
                },
            ),
        )


@dataclass
class HandToBottomThenDraw:
    """Choose hand cards, put them on the bottom of the deck, then draw that many."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        if not player.hand:
            return CommandResult.ok("手牌为空，无需操作。")

        return CommandResult.ok(
            "选择任意张手牌放回牌库底。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt="选择任意张手牌放回牌库底",
                min_select=0,
                max_select=len(player.hand),
                from_zone="hand",
                card_list=list(player.hand),
                continuation={
                    "kind": "hand_to_bottom_then_draw",
                    "player_idx": ctx.player_idx,
                },
            ),
        )


@dataclass
class HandToBottomDrawUntil:
    """Choose one hand card, put it on the deck bottom, then draw to a target size."""

    target_hand_size: int = 5

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest, ActionResult

        player = ctx.player
        target = int(self.target_hand_size or 5)
        if len(player.hand) <= 1:
            return CommandResult.fail("手牌仅有1张，无法使用凰檗（需要至少有1张其他手牌）。")

        def move_and_draw(card):
            moved = False
            if card in player.hand:
                player.hand.remove(card)
                player.deck.insert(0, card)
                moved = True
            to_draw = max(0, target - len(player.hand))
            drawn = player.draw_cards(to_draw)
            if moved:
                ctx.state._log(f"{player.name}将1张手牌放回牌库底，抽取了{len(drawn)}张。")
            return ActionResult(
                True,
                f"抽取了{len(drawn)}张卡。",
                cards_drawn=drawn,
            )

        if len(player.hand) == 2:
            action_result = move_and_draw(player.hand[0])
            return CommandResult.ok(
                action_result.log_message,
                cards_drawn=action_result.cards_drawn,
            )

        return CommandResult.ok(
            "选择1张手牌放回牌库底部（凰檗）。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt="选择1张手牌放回牌库底部，然后抽到5张（凰檗）",
                min_select=1,
                max_select=1,
                from_zone="hand",
                card_list=list(player.hand),
                continuation={
                    "kind": "hand_to_bottom_draw_until",
                    "player_idx": ctx.player_idx,
                    "target_hand_size": target,
                },
            ),
        )


@dataclass
class ZinniaResolve:
    """Discard two hand cards, then draw for each opposing Pokemon in play."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest, ActionResult

        player = ctx.player
        if len(player.hand) < 2:
            return CommandResult.fail("手牌不足2张，无法使用希嘉娜的决心。")

        draw_amount = (1 if ctx.opponent.active else 0) + ctx.opponent.bench_count()

        def draw_after_discard(discarded_count: int):
            drawn = player.draw_cards(draw_amount)
            ctx.state._log(
                f"{player.name}抽取了{len(drawn)}张卡（对手场上有{draw_amount}只宝可梦）。"
            )
            return ActionResult(
                True,
                f"丢弃{discarded_count}张手牌，抽取了{len(drawn)}张。",
                cards_drawn=drawn,
                cards_discarded=discarded_count,
            )

        if len(player.hand) == 2:
            player.discard_entire_hand()
            ctx.state._log(f"{player.name}丢弃了2张手牌。")
            action_result = draw_after_discard(2)
            return CommandResult.ok(
                action_result.log_message,
                cards_drawn=action_result.cards_drawn,
                cards_discarded=action_result.cards_discarded,
            )

        return CommandResult.ok(
            "选择2张手牌丢弃（希嘉娜的决心）。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"选择2张手牌丢弃（希嘉娜的决心：抽{draw_amount}张）",
                min_select=2,
                max_select=2,
                from_zone="hand",
                card_list=list(player.hand),
                continuation={
                    "kind": "zinnia_resolve",
                    "player_idx": ctx.player_idx,
                    "discard_count": 2,
                    "draw_amount": draw_amount,
                },
            ),
        )


@dataclass
class AbilityDiscardRevive:
    """Revive a named Pokemon from discard when the player's hand is empty."""

    card_id: str = ""
    discard_idx: int = -1

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        player = ctx.player
        target_card = None
        if (
            type(self.discard_idx) is int
            and 0 <= self.discard_idx < len(player.discard)
            and getattr(player.discard[self.discard_idx], "api_id", "") == self.card_id
        ):
            target_card = player.discard[self.discard_idx]
        elif self.discard_idx < 0:
            # Compatibility for directly constructed legacy commands.
            target_card = next(
                (card for card in player.discard if getattr(card, "api_id", "") == self.card_id),
                None,
            )
        if target_card is None:
            return CommandResult.fail("弃牌区中没有此卡。")
        if player.hand:
            return CommandResult.fail("手牌不为空，无法使用紧急上浮。")
        bench_slot = player.find_empty_bench_slot()
        if bench_slot is None:
            return CommandResult.fail("备战区已满。")

        player.discard.remove(target_card)
        pokemon = player.place_bench(target_card, bench_slot)
        if pokemon is not None:
            pokemon.placed_this_turn = True
            # The ability has already been consumed to enter play.  Persist
            # that fact on the revived instance so it cannot be activated a
            # second time during the same turn after another zone cycle.
            pokemon.used_abilities.add("紧急上浮")
        ctx.state._log(f"{player.name}使用紧急上浮将{target_card.name}放置于备战区。")
        drawn = player.draw_cards(3)
        ctx.state._log(f"{player.name}抽取了{len(drawn)}张卡。")
        return CommandResult.ok(
            f"紧急上浮: {target_card.name}放置于备战区，抽取了{len(drawn)}张。",
            cards_drawn=drawn,
        )


@dataclass
class EvolveSkipStage:
    """Evolve a Basic Pokemon directly into a matching Stage 2 Pokemon."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        if ctx.state.is_player_first_turn(ctx.player_idx):
            return CommandResult.fail("第一回合不能使用神奇糖果。")

        candidates = []
        for slot_name, pokemon in player.get_all_pokemon():
            if pokemon is None or not pokemon.card.is_basic_pokemon:
                continue
            if pokemon.placed_this_turn or not pokemon.can_evolve_this_turn:
                continue
            for hand_index, card in enumerate(player.hand):
                if (
                    getattr(card, "is_stage2", False)
                    and self._stage2_matches_basic(card, pokemon.card.name)
                ):
                    candidates.append({
                        "slot": slot_name,
                        "base_card_id": pokemon.card.api_id,
                        "base_name": pokemon.card.name,
                        "hand_index": hand_index,
                        "card_id": card.api_id,
                        "evolution_name": card.name,
                        "name": f"{pokemon.card.name} → {card.name}",
                    })

        if not candidates:
            ctx.state._log(f"{player.name}场上没有符合条件的基础宝可梦可以使用神奇糖果。")
            return CommandResult.fail("没有有效的进化目标，卡牌保留在手牌中。")

        return CommandResult.ok(
            "选择神奇糖果进化目标。",
            pending_choice=ActionRequest(
                request_type="evolve_skip_stage",
                player=ctx.player_idx,
                prompt="选择神奇糖果进化目标。",
                min_select=1,
                max_select=1,
                target_info=candidates,
                continuation={"kind": "evolve_skip_stage", "player_idx": ctx.player_idx},
            ),
        )

    @staticmethod
    def _stage2_matches_basic(stage2_card, target_basic_name: str) -> bool:
        from data.card_registry import CardRegistry

        stage1_name = getattr(stage2_card, "evolves_from", "") or ""
        if not stage1_name:
            return False
        for stage1 in CardRegistry.get_by_name(stage1_name):
            if getattr(stage1, "evolves_from", "").lower() == target_basic_name.lower():
                return True
        return False


__all__ = [
    "RecoverFromDiscard",
    "HandToBottomThenDraw",
    "HandToBottomDrawUntil",
    "ZinniaResolve",
    "AbilityDiscardRevive",
    "EvolveSkipStage",
]
