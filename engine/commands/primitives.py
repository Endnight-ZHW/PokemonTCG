"""Atomic command primitives for card game effects.

~15 primitives cover all card effects. Complex effects compose primitives
via the DSL compiler. Each primitive is a self-contained ICommand.
"""
from __future__ import annotations
import random
from dataclasses import dataclass, field
from typing import Optional, TYPE_CHECKING

from config import DAMAGE_PER_COUNTER, COIN_FLIP_THRESHOLD
from engine.enums import StatusType

if TYPE_CHECKING:
    from engine.commands.base import ResolutionContext, CommandResult
    from engine.game_state import ActionRequest


# ═══════════════════════════════════════════════════════
# 1. DealDamage — apply damage to a target
# ═══════════════════════════════════════════════════════

@dataclass
class DealDamage:
    """Apply damage to a target pokemon.

    target: 'opponent_active', 'opponent_bench', 'self', 'any_opponent'
    amount: fixed damage value (use formula for dynamic damage)
    piercing: if True, ignores weakness/resistance/effects
    spread_count: for bench/any targets, number of pokemon to hit
    """
    amount: int = 0
    target: str = "opponent_active"
    piercing: bool = False
    spread_count: int = 1
    formula: str = ""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        damage = self.amount
        if self.formula:
            from engine.commands.formula import evaluate_formula
            damage = evaluate_formula(self.formula, ctx)

        result = CommandResult(success=True, damage_dealt=0)

        if self.target == "opponent_active":
            defender = ctx.opponent.active
            if defender is None:
                return result
            if defender.damage_prevented_next_turn:
                defender.damage_prevented_next_turn = False
                defender.all_prevented_next_turn = False
                return CommandResult.ok(f"{defender.card.name}免疫了所有伤害！")
            if getattr(defender, 'all_prevented_next_turn', False):
                defender.all_prevented_next_turn = False
                return CommandResult.ok(f"{defender.card.name}免疫了附加效果伤害！")
            counters = damage // DAMAGE_PER_COUNTER
            defender.damage_counters += counters
            result.damage_dealt = damage
            result.log_message = f"对{defender.card.name}造成{damage}点伤害。"
            ctx.emit_event("damage_dealt", amount=damage, target=defender.card.name,
                          target_slot="opponent_active")

        elif self.target == "self":
            active = ctx.player.active
            if active:
                counters = damage // DAMAGE_PER_COUNTER
                active.damage_counters += counters
                result.damage_dealt = damage
                result.log_message = f"{active.card.name}受到了{damage}点伤害。"

        elif self.target == "any_opponent":
            opponent = ctx.opponent
            targets = []
            if opponent.active:
                targets.append(("active", opponent.active))
            for i, poke in enumerate(opponent.bench):
                if poke and len(targets) < self.spread_count:
                    targets.append((f"bench_{i}", poke))
            for slot, poke in targets[:self.spread_count]:
                poke.damage_counters += damage // DAMAGE_PER_COUNTER
                result.damage_dealt += damage
                result.log_message += f"对{poke.card.name}造成{damage}点伤害。"

        elif self.target == "opponent_bench":
            opponent = ctx.opponent
            count = 0
            for i, poke in enumerate(opponent.bench):
                if poke and count < self.spread_count:
                    poke.damage_counters += damage // DAMAGE_PER_COUNTER
                    result.damage_dealt += damage
                    count += 1
            result.log_message = f"对备战区{count}只宝可梦造成{damage}点伤害。"

        return result


# ═══════════════════════════════════════════════════════
# 2. ApplyStatus — add/remove status conditions
# ═══════════════════════════════════════════════════════

@dataclass
class ApplyStatus:
    status: str = ""  # 'poisoned', 'burned', 'asleep', 'paralyzed', 'confused'
    target: str = "opponent_active"
    condition: str = ""  # optional: condition to check before applying

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        if self.condition:
            if not self._check_condition(ctx):
                return CommandResult.ok("")

        if self.target == "opponent_active":
            target = ctx.opponent.active
        else:
            target = ctx.player.active

        if target is None:
            return CommandResult.ok("")

        status_map = {
            "poisoned": StatusType.POISONED,
            "burned": StatusType.BURNED,
            "asleep": StatusType.ASLEEP,
            "paralyzed": StatusType.PARALYZED,
            "confused": StatusType.CONFUSED,
        }
        st = status_map.get(self.status)
        if st is None:
            return CommandResult.fail(f"未知状态: {self.status}")

        target.status_conditions.add(st)
        return CommandResult.ok(
            f"{target.card.name}陷入{self.status}状态！",
            status_applied=[self.status],
        )

    def _check_condition(self, ctx: ResolutionContext) -> bool:
        if self.condition == "ko_by_attack_last_turn":
            return ctx.player.was_ko_by_attack
        return False


# ═══════════════════════════════════════════════════════
# 3. DrawCards — draw N cards from deck
# ═══════════════════════════════════════════════════════

@dataclass
class DrawCards:
    count: int = 1
    player: str = "self"  # 'self' or 'opponent'

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        p = ctx.player if self.player == "self" else ctx.opponent
        drawn = p.draw_cards(self.count)
        names = [c.name for c in drawn]
        return CommandResult.ok(
            f"抽取了{len(drawn)}张卡。",
            cards_drawn=names,
        )


# ═══════════════════════════════════════════════════════
# 4. DiscardEnergy — remove energy from a Pokemon
# ═══════════════════════════════════════════════════════

@dataclass
class DiscardEnergy:
    amount: int = 1
    from_target: str = "self"  # 'self' or 'opponent'
    energy_filter: str = "any"

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        if self.from_target == "self":
            pokemon = ctx.player.active
        else:
            pokemon = ctx.opponent.active

        if pokemon is None:
            return CommandResult.ok("")

        discarded = 0
        for _ in range(self.amount):
            if pokemon.energy_cards:
                card = pokemon.energy_cards.pop()
                ctx.player.discard.append(card)
                discarded += 1

        return CommandResult.ok(f"丢弃了{discarded}个能量。")


# ═══════════════════════════════════════════════════════
# 5. HealDamage — remove damage counters
# ═══════════════════════════════════════════════════════

@dataclass
class HealDamage:
    amount: int = 0  # 0 = heal all
    target: str = "self"  # 'self' or 'all'

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        if self.target == "all":
            for _, poke in ctx.player.get_all_pokemon():
                if poke:
                    if self.amount == 0:
                        poke.damage_counters = 0
                    else:
                        poke.damage_counters = max(0, poke.damage_counters - self.amount // DAMAGE_PER_COUNTER)
            return CommandResult.ok("全部宝可梦回复了HP。")

        target = ctx.player.get_pokemon(ctx.source_slot) or ctx.player.active
        if target:
            if self.amount == 0:
                target.damage_counters = 0
            else:
                target.damage_counters = max(0, target.damage_counters - self.amount // DAMAGE_PER_COUNTER)
        return CommandResult.ok(f"回复了{self.amount}点HP。")


# ═══════════════════════════════════════════════════════
# 6. FlipCoin — coin flip with conditional branches
# ═══════════════════════════════════════════════════════

@dataclass
class FlipCoin:
    on_heads: list = field(default_factory=list)  # list of effect dicts
    on_tails: list = field(default_factory=list)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult, ICommand

        coin = random.choice(["heads", "tails"])
        effects = self.on_heads if coin == "heads" else self.on_tails

        for eff_data in effects:
            if isinstance(eff_data, dict):
                from engine.commands.registry import build_command
                cmd = build_command(eff_data)
                ctx.push_side(cmd)
            elif hasattr(eff_data, 'execute'):
                ctx.push_side(eff_data)

        if coin == "tails" and not effects:
            # Empty on_tails with attack_fail effects → mark attack as failed
            pass

        return CommandResult.ok(f"掷硬币: {coin}!")


# ═══════════════════════════════════════════════════════
# 7. SwitchPokemon — swap active with bench
# ═══════════════════════════════════════════════════════

@dataclass
class SwitchPokemon:
    target: str = "self"  # 'self' or 'opponent'
    optional: bool = False

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player if self.target == "self" else ctx.opponent
        player_idx = ctx.player_idx if self.target == "self" else (1 - ctx.player_idx)
        target_player = self.target

        if not player.active or player.bench_count() == 0:
            if self.optional:
                return CommandResult.ok("没有备战宝可梦，无法替换。")
            return CommandResult.ok("无法交换——没有备战宝可梦。")

        bench_indices = [i for i, p in enumerate(player.bench) if p is not None]

        if self.optional:
            # Ask the player first, then show bench selection only if confirmed
            def on_confirm(confirmed: bool):
                if not confirmed:
                    return None
                # Single bench: switch directly, no need to ask which slot
                if len(bench_indices) == 1:
                    player.switch_active_to_bench(bench_indices[0])
                    return None
                # Multiple bench: return a bench selection request
                return ActionRequest(
                    request_type="select_bench",
                    player=player_idx,
                    prompt="选择要替换上场的宝可梦",
                    min_select=1, max_select=1,
                    target_player=target_player,
                    bench_indices=bench_indices,
                )

            return CommandResult.ok(
                "请选择是否替换宝可梦。",
                pending_choice=ActionRequest(
                    request_type="confirm",
                    player=player_idx,
                    prompt="是否替换战斗宝可梦？",
                    callback=on_confirm,
                ),
            )

        # Non-optional: request bench choice directly
        return CommandResult.ok(
            "选择替换的宝可梦。",
            pending_choice=ActionRequest(
                request_type="select_bench",
                player=player_idx,
                prompt="选择要替换上场的宝可梦",
                min_select=1, max_select=1,
                target_player=target_player,
                bench_indices=bench_indices,
            ),
        )


# ═══════════════════════════════════════════════════════
# 8. SearchZone — search a zone for cards
# ═══════════════════════════════════════════════════════

@dataclass
class SearchZone:
    from_zone: str = "deck"
    filter_spec: str = "pokemon"  # 'pokemon', 'basic_pokemon', 'energy', etc.
    destination: str = "hand"
    count: int = 1
    reveal: bool = True

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        player_idx = ctx.player_idx

        # Build card list from the source zone
        source = player.deck if self.from_zone == "deck" else (
            player.discard if self.from_zone == "discard" else player.hand
        )

        # Apply filter
        filtered = self._apply_filter(source, ctx)

        if not filtered:
            return CommandResult.ok("没有符合条件的卡牌。")

        return CommandResult.ok(
            f"从{self.from_zone}搜索...",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=player_idx,
                prompt=f"选择最多{self.count}张卡",
                min_select=1, max_select=self.count,
                card_list=[c.api_id for c in filtered],
                from_zone=self.from_zone,
            ),
        )

    def _apply_filter(self, cards: list, ctx: ResolutionContext) -> list:
        spec = self.filter_spec
        if spec == "pokemon":
            return [c for c in cards if hasattr(c, 'is_pokemon') and c.is_pokemon]
        elif spec == "basic_pokemon":
            return [c for c in cards if hasattr(c, 'is_basic_pokemon') and c.is_basic_pokemon]
        elif spec == "basic_energy":
            return [c for c in cards if c.is_energy and not getattr(c, 'is_special_energy', False)]
        elif spec == "energy":
            return [c for c in cards if c.is_energy]
        elif spec == "supporter":
            return [c for c in cards if getattr(c, 'is_trainer_supporter', False)]
        elif spec == "item_or_tool":
            return [c for c in cards if getattr(c, 'is_trainer_item', False) or getattr(c, 'is_trainer_tool', False)]
        return [c for c in cards]


# ═══════════════════════════════════════════════════════
# 9. DiscardCards — discard from hand/deck
# ═══════════════════════════════════════════════════════

@dataclass
class DiscardCards:
    amount: int = 1
    from_zone: str = "hand"
    player: str = "self"

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        p = ctx.player if self.player == "self" else ctx.opponent
        if self.from_zone == "hand":
            discarded = p.discard_from_hand(list(range(min(self.amount, len(p.hand)))))
            return CommandResult.ok(f"丢弃了{len(discarded)}张手牌。")
        elif self.from_zone == "deck":
            milled = p.mill_from_deck(self.amount)
            return CommandResult.ok(f"从牌库丢弃了{len(milled)}张卡。")
        return CommandResult.ok("")
