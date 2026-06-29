"""Board-state, healing, switching, and discard VM commands."""
from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from engine.rules_constants import DAMAGE_PER_COUNTER

if TYPE_CHECKING:
    from engine.commands.base import CommandResult, ResolutionContext


def _energy_card_matches(card, energy_type: str) -> bool:
    energy_type = str(energy_type or "any")
    if not getattr(card, "is_energy", False):
        return False
    if energy_type in {"any", "energy"}:
        return True
    if energy_type in {"basic", "basic_energy"}:
        return bool(getattr(card, "is_basic_energy", False))
    return any(
        str(provided).lower() == energy_type.lower()
        for provided in getattr(card, "provides_energy", [])
    )


@dataclass
class DiscardEnergy:
    amount: int = 1
    from_target: str = "self"
    energy_filter: str = "any"

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        from_target = str(self.from_target or "self")
        amount = int(self.amount or 0)
        owner = ctx.player if from_target == "self" else ctx.opponent
        pokemon = ctx.player.active if from_target == "self" else ctx.opponent.active

        if pokemon is None:
            return CommandResult.fail("没有可丢弃能量的目标。")

        if from_target != "self" and getattr(pokemon, "all_prevented_next_turn", False):
            pokemon.all_prevented_next_turn = False
            ctx.state._log(f"{pokemon.card.name}免疫了能量丢弃的效果！")
            return CommandResult.ok("免疫了效果。")

        discarded = 0
        kept = []
        for card in pokemon.energy_cards:
            if discarded < amount and _energy_card_matches(card, self.energy_filter):
                owner.discard.append(card)
                discarded += 1
            else:
                kept.append(card)
        pokemon.energy_cards = kept

        ctx.state._log(f"从{pokemon.card.name}丢弃了{discarded}个能量。")
        return CommandResult.ok(
            f"丢弃了{discarded}个能量。",
            cards_discarded=discarded,
        )


@dataclass
class HealDamage:
    amount: int = 0
    target: str = "self"

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        if self.target == "all":
            healed = []
            for _, poke in ctx.player.get_all_pokemon():
                if poke and poke.damage_counters > 0:
                    if self.amount == 0:
                        actual = poke.damage_counters
                        poke.damage_counters = 0
                    else:
                        heal_counters = self.amount // DAMAGE_PER_COUNTER
                        actual = min(poke.damage_counters, heal_counters)
                        poke.damage_counters -= actual
                    if actual > 0:
                        healed.append(poke.card.name)
            if healed:
                ctx.player.healed_this_turn = True
                names = "、".join(healed)
                ctx.state._log(f"{ctx.player.name}的所有宝可梦各回复了{self.amount}点HP（{names}）。")
                return CommandResult.ok(f"全场回复{self.amount}HP。")
            ctx.state._log(f"{ctx.player.name}的宝可梦都没有受伤。")
            return CommandResult.ok("没有宝可梦需要回复。")

        if self.target == "self":
            target = ctx.player.active
        elif self.target.startswith("bench_"):
            target = ctx.player.get_pokemon(self.target)
        else:
            target = ctx.player.get_pokemon(ctx.source_slot) or ctx.player.active
        if not target:
            return CommandResult.fail("没有回复目标。")
        if self.amount == 0:
            target.damage_counters = 0
        else:
            target.damage_counters = max(0, target.damage_counters - self.amount // DAMAGE_PER_COUNTER)
        ctx.player.healed_this_turn = True
        ctx.state._log(f"回复了{target.card.name}的{self.amount}点伤害。")
        return CommandResult.ok(f"回复了{self.amount}点。")


@dataclass
class ChooseHealDamage:
    """Choose one injured Pokemon controlled by the player and heal it."""

    amount: int = 30
    target_player: str = "self"

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player_idx = ctx.player_idx if self.target_player == "self" else 1 - ctx.player_idx
        player = ctx.state.get_player(player_idx)
        injured = [
            (slot_name, pokemon)
            for slot_name, pokemon in player.get_all_pokemon()
            if pokemon is not None and pokemon.damage_counters > 0
        ]

        if not injured:
            return CommandResult.fail("没有受伤的宝可梦，卡牌保留在手牌中。")

        def heal_target(_slot_name, pokemon):
            counters = int(self.amount or 0) // DAMAGE_PER_COUNTER
            pokemon.damage_counters = max(0, pokemon.damage_counters - counters)
            player.healed_this_turn = True
            ctx.state._log(f"{pokemon.card.name}回复了{self.amount}点HP。")
            return f"{pokemon.card.name}回复了{self.amount}点HP。"

        if len(injured) == 1:
            slot_name, pokemon = injured[0]
            return CommandResult.ok(heal_target(slot_name, pokemon))

        return CommandResult.ok(
            f"选择1只宝可梦回复{self.amount}HP。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"选择1只宝可梦回复{self.amount}HP（伤药）",
                min_select=1,
                max_select=1,
                from_zone="bench",
                target_player=self.target_player,
                card_list=[pokemon.card for _slot_name, pokemon in injured],
                continuation={
                    "kind": "choose_heal_damage",
                    "target_player_idx": player_idx,
                    "amount": int(self.amount or 0),
                },
            ),
        )


@dataclass
class SwitchPokemon:
    target: str = "self"
    optional: bool = False
    you_choose: bool = False

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        target_idx = ctx.player_idx if self.target == "self" else 1 - ctx.player_idx
        player = ctx.state.get_player(target_idx)

        if self.target == "opponent" and player.active and player.active.all_prevented_next_turn:
            player.active.all_prevented_next_turn = False
            ctx.state._log(f"{player.active.card.name}免疫了强制替换的效果！")
            return CommandResult.ok("免疫了效果。")

        if self.you_choose and self.target == "opponent":
            chooser_idx = ctx.player_idx
            request_type = "select_opponent_bench"
            request_target_player = "opponent"
        elif self.target == "opponent":
            chooser_idx = target_idx
            request_type = "select_bench"
            request_target_player = "self"
        else:
            chooser_idx = ctx.player_idx
            request_type = "select_bench"
            request_target_player = "self"

        if not player.active or player.bench_count() == 0:
            if self.optional:
                return CommandResult.ok("没有备战宝可梦，无法替换。")
            return CommandResult.ok("无法交换——没有备战宝可梦。")

        bench_indices = [i for i, p in enumerate(player.bench) if p is not None]

        if self.optional:
            return CommandResult.ok(
                "请选择是否替换宝可梦。",
                pending_choice=ActionRequest(
                    request_type="confirm",
                    player=chooser_idx,
                    prompt="是否替换战斗宝可梦？",
                    continuation={
                        "kind": "switch_confirm",
                        "target_player_idx": target_idx,
                        "chooser_idx": chooser_idx,
                        "request_type": request_type,
                        "request_target_player": request_target_player,
                        "bench_indices": bench_indices,
                    },
                ),
            )

        if len(bench_indices) == 1 and not (self.target == "opponent" and self.you_choose):
            self._switch(ctx, player, bench_indices[0])
            return CommandResult.ok("替换了战斗宝可梦。")

        return CommandResult.ok(
            "选择替换的宝可梦。",
            pending_choice=ActionRequest(
                request_type=request_type,
                player=chooser_idx,
                prompt="选择要替换上场的宝可梦",
                min_select=1,
                max_select=1,
                target_player=request_target_player,
                bench_indices=bench_indices,
                continuation={
                    "kind": "switch_bench",
                    "target_player_idx": target_idx,
                },
            ),
        )

    @staticmethod
    def _switch(ctx: ResolutionContext, player, bench_idx: int):
        if bench_idx < 0 or bench_idx >= len(player.bench) or player.bench[bench_idx] is None:
            return
        active_name = player.active.card.name if player.active else ""
        bench_name = player.bench[bench_idx].card.name
        player.switch_active_to_bench(bench_idx)
        ctx.state._log(f"将{active_name}与{bench_name}互换了。")


@dataclass
class SearchZone:
    from_zone: str = "deck"
    filter_spec: str = "pokemon"
    destination: str = "hand"
    count: int = 1
    reveal: bool = True

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        player_idx = ctx.player_idx

        source = player.deck if self.from_zone == "deck" else (
            player.discard if self.from_zone == "discard" else player.hand
        )
        filtered = self._apply_filter(source, ctx)

        if not filtered:
            return CommandResult.ok("没有符合条件的卡牌。")

        return CommandResult.ok(
            f"从{self.from_zone}搜索...",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=player_idx,
                prompt=f"选择最多{self.count}张卡",
                min_select=1,
                max_select=self.count,
                card_list=[c.api_id for c in filtered],
                from_zone=self.from_zone,
            ),
        )

    def _apply_filter(self, cards: list, _ctx: ResolutionContext) -> list:
        spec = self.filter_spec
        if spec == "pokemon":
            return [c for c in cards if hasattr(c, "is_pokemon") and c.is_pokemon]
        if spec == "basic_pokemon":
            return [c for c in cards if hasattr(c, "is_basic_pokemon") and c.is_basic_pokemon]
        if spec == "basic_energy":
            return [c for c in cards if c.is_energy and not getattr(c, "is_special_energy", False)]
        if spec == "energy":
            return [c for c in cards if c.is_energy]
        if spec == "supporter":
            return [c for c in cards if getattr(c, "is_trainer_supporter", False)]
        if spec == "item_or_tool":
            return [c for c in cards if getattr(c, "is_trainer_item", False) or getattr(c, "is_trainer_tool", False)]
        return [c for c in cards]


@dataclass
class DiscardCards:
    amount: int = 1
    from_zone: str = "hand"
    player: str = "self"

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        p = ctx.player if self.player == "self" else ctx.opponent
        player_idx = ctx.player_idx if self.player == "self" else 1 - ctx.player_idx
        amount = int(self.amount or 0)

        if amount <= 0:
            return CommandResult.fail("没有可丢弃的卡。")

        if self.from_zone == "hand":
            hand_count = len(p.hand)
            if hand_count == 0:
                return CommandResult.fail("手牌为空，无法丢弃。")
            if hand_count < amount:
                return CommandResult.fail(f"手牌不足，必须丢弃{amount}张。")
            if hand_count == amount:
                discarded = p.discard_from_hand(list(range(hand_count)))
                ctx.state._log(f"从手牌丢弃了{len(discarded)}张卡。")
                return CommandResult.ok(
                    f"丢弃了{len(discarded)}张手牌。",
                    cards_discarded=len(discarded),
                )

            return CommandResult.ok(
                f"选择{amount}张手牌丢弃。",
                pending_choice=ActionRequest(
                    request_type="select_hand_to_discard",
                    player=player_idx,
                    prompt=f"选择{amount}张手牌丢弃",
                    min_select=amount,
                    max_select=amount,
                    from_zone="hand",
                    card_list=list(p.hand),
                    continuation={
                        "kind": "discard_hand_cards",
                        "player_idx": player_idx,
                        "amount": amount,
                    },
                ),
            )
        if self.from_zone == "deck":
            milled = p.mill_from_deck(amount)
            return CommandResult.ok(
                f"从牌库丢弃了{len(milled)}张卡。",
                cards_discarded=len(milled),
            )
        return CommandResult.ok("")


@dataclass
class DiscardThenDrawCards:
    """Discard hand cards, then draw cards as one resumable VM command."""

    discard_hand: bool = False
    discard_amount: int = 1
    draw_amount: int = 0

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest, ActionResult

        player = ctx.player
        discard_amount = int(self.discard_amount or 0)
        draw_amount = int(self.draw_amount or 0)

        def draw_after_discard(discarded_count: int):
            drawn = player.draw_cards(draw_amount)
            ctx.state._log(f"{ctx.player.name}丢弃了{discarded_count}张手牌并抽取了{len(drawn)}张卡。")
            return ActionResult(
                True,
                f"丢弃{discarded_count}张手牌并抽取了{len(drawn)}张。",
                cards_drawn=drawn,
                cards_discarded=discarded_count,
            )

        if self.discard_hand:
            discarded_count = len(player.hand)
            player.discard_entire_hand()
            action_result = draw_after_discard(discarded_count)
            return CommandResult.ok(
                action_result.log_message,
                cards_drawn=action_result.cards_drawn,
                cards_discarded=action_result.cards_discarded,
            )

        if not player.hand:
            return CommandResult.ok("手牌为空，无需操作。")
        if discard_amount <= 0:
            return CommandResult.fail("没有可丢弃的卡。")
        if len(player.hand) <= discard_amount:
            discarded_count = len(player.hand)
            player.discard_entire_hand()
            action_result = draw_after_discard(discarded_count)
            return CommandResult.ok(
                action_result.log_message,
                cards_drawn=action_result.cards_drawn,
                cards_discarded=action_result.cards_discarded,
            )

        return CommandResult.ok(
            f"选择{discard_amount}张手牌丢弃。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"选择{discard_amount}张手牌丢弃",
                min_select=1,
                max_select=discard_amount,
                from_zone="hand",
                card_list=list(player.hand),
                continuation={
                    "kind": "discard_hand_then_draw",
                    "player_idx": ctx.player_idx,
                    "discard_amount": discard_amount,
                    "draw_amount": draw_amount,
                },
            ),
        )


__all__ = [
    "_energy_card_matches",
    "DiscardEnergy",
    "HealDamage",
    "ChooseHealDamage",
    "SwitchPokemon",
    "SearchZone",
    "DiscardCards",
    "DiscardThenDrawCards",
]
