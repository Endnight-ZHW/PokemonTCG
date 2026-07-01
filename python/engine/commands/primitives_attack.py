"""Attack-state, prevention, and modifier-registration VM commands."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from engine.commands.base import CommandResult, ResolutionContext


@dataclass
class AttackFail:
    """Mark the current attack as failed."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        ctx.state._log("招式失败了！")
        return CommandResult.ok("招式失败了！", attack_failed=True)


@dataclass
class SetAttackFlags:
    """Set flags consumed by the accumulated attack damage pipeline."""

    ignore_weakness: bool = True
    ignore_resistance: bool = True
    ignore_effects: bool = False

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.commands.attack_frames import set_attack_damage_flags

        set_attack_damage_flags(
            ctx.state,
            stack=ctx.stack,
            piercing=True if self.ignore_weakness or self.ignore_resistance else None,
            ignore_defender_effects=True if self.ignore_effects else None,
        )
        return CommandResult.ok("穿透攻击标记已设置。")


@dataclass
class ReturnToHand:
    """Return the source Pokemon and all attached cards to the owner's hand."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        player = ctx.player
        source = player.get_pokemon(ctx.source_slot)
        if source is None:
            return CommandResult.fail("没有宝可梦。")

        source_card = source.card
        if source.attached_tool:
            player.hand.append(source.attached_tool)
            source.attached_tool = None
        player.hand.extend(source.evolution_stack)
        source.evolution_stack.clear()
        player.hand.extend(source.energy_cards)
        source.energy_cards.clear()
        player.hand.append(source_card)

        if ctx.source_slot == "active":
            player.active = None
        elif ctx.source_slot.startswith("bench_"):
            try:
                bench_idx = int(ctx.source_slot.split("_", 1)[1])
            except ValueError:
                return CommandResult.fail("无效的备战区位置。")
            if 0 <= bench_idx < len(player.bench):
                player.bench[bench_idx] = None

        ctx.state._log(f"{source_card.name}和所有附着卡回到了{player.name}的手牌。")
        return CommandResult.ok(f"{source_card.name}回到了手牌。")


@dataclass
class SetPrevention:
    """Set next-turn prevention flags on the source Pokemon."""

    damage: bool = False
    effects: bool = False
    log_template: str = "{pokemon}下回合将免疫。"
    result_message: str = "已设置免疫。"

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        target = ctx.player.get_pokemon(ctx.source_slot)
        if target:
            if self.damage:
                target.damage_prevented_next_turn = True
            if self.effects:
                target.all_prevented_next_turn = True
            ctx.state._log(self.log_template.format(pokemon=target.card.name))
        return CommandResult.ok(self.result_message)


@dataclass
class DazzlingBeam:
    """Mark the target so its next attack requires a coin flip."""

    target: str = "opponent_active"

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        target = ctx.opponent.active if self.target == "opponent_active" else ctx.player.active
        if target is None:
            return CommandResult.ok("没有目标。")
        if getattr(target, "all_prevented_next_turn", False):
            target.all_prevented_next_turn = False
            ctx.state._log(f"{target.card.name}免疫了炫目光束的效果！")
            return CommandResult.ok("免疫了效果。")
        target.dazzled = True
        ctx.state._log(f"{target.card.name}被炫目光束命中！下次使用招式时将掷硬币。")
        return CommandResult.ok(f"{target.card.name}被炫目光束命中。")


@dataclass
class AttackLockBasic:
    """Lock opponent active from attacking next turn if it is Basic."""

    target: str = "opponent_active"

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        target = ctx.opponent.active if self.target == "opponent_active" else ctx.player.active
        if target is None:
            return CommandResult.ok("没有目标。")
        if getattr(target, "all_prevented_next_turn", False):
            target.all_prevented_next_turn = False
            ctx.state._log(f"{target.card.name}免疫了攻击封锁的效果！")
            return CommandResult.ok("免疫了效果。")
        if target.card.is_basic_pokemon:
            target.attack_locked = True
            ctx.state._log(f"{target.card.name}在下一个回合无法使用招式！")
            return CommandResult.ok(f"{target.card.name}被封锁了招式。")
        ctx.state._log(f"{target.card.name}不是基础宝可梦，冻结无效。")
        return CommandResult.ok("目标不是基础宝可梦，冻结无效。")


@dataclass
class OutgoingDamageReduction:
    """Reduce the target Pokemon's next outgoing attack damage."""

    amount: int = 0
    target: str = "opponent_active"

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        target = ctx.opponent.active if self.target == "opponent_active" else ctx.player.active
        amount = int(self.amount or 0)
        if target is None or amount <= 0:
            return CommandResult.ok("没有目标。")
        if getattr(target, "all_prevented_next_turn", False):
            target.all_prevented_next_turn = False
            ctx.state._log(f"{target.card.name}免疫了恫吓的效果！")
            return CommandResult.ok("免疫了效果。")
        target.outgoing_damage_reduction_next_turn = max(
            int(getattr(target, "outgoing_damage_reduction_next_turn", 0) or 0),
            amount,
        )
        ctx.state._log(f"{target.card.name}下次使用招式的伤害-{amount}。")
        return CommandResult.ok(f"{target.card.name}被恫吓。")


@dataclass
class SelfAttackLock:
    """Lock a named source attack from being used consecutively."""

    attack_name: str = ""
    scope: str = "attack"

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        target = ctx.player.get_pokemon(ctx.source_slot)
        lock_key = "__all__" if str(self.scope).lower() == "all" else self.attack_name
        if target and lock_key:
            target.attack_locked_names[lock_key] = ctx.state.turn_number
            if lock_key == "__all__":
                ctx.state._log(f"{target.card.name}下回合无法使用招式。")
                return CommandResult.ok("下回合无法使用招式。")
            ctx.state._log(f"{target.card.name}下回合无法使用「{self.attack_name}」。")
        return CommandResult.ok(f"「{self.attack_name}」已锁定，下回合无法使用。")


@dataclass
class RegisterModifier:
    """Register a data-defined modifier hook for the source Pokemon."""

    modifier_kind: str = ""
    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.commands.modifier_registration import (
            register_effect_modifier,
            register_tool_effect_modifier,
        )

        pokemon = ctx.player.get_pokemon(ctx.source_slot)
        modifier_kind = str(self.modifier_kind or "")
        if pokemon is None or not modifier_kind:
            return CommandResult.ok("")
        if modifier_kind == "tool_exp_share":
            source = f"pokemon:{ctx.player_idx}:{pokemon.card.api_id}:{ctx.source_slot}:vm_tool_exp_share"
            registered = register_tool_effect_modifier(
                "tool_exp_share",
                self.params,
                pokemon,
                ctx.player_idx,
                source=source,
                event_bus=ctx.state.event_bus,
                source_name="学习装置",
            )
            return CommandResult.ok("学习装置已装备。击倒时自动转附基本能量。" if registered else "")
        source = f"pokemon:{ctx.player_idx}:{pokemon.card.api_id}:{ctx.source_slot}:vm:{modifier_kind}"
        registered = register_effect_modifier(
            modifier_kind,
            self.params,
            pokemon,
            ctx.player_idx,
            source=source,
            event_bus=ctx.state.event_bus,
            source_name=pokemon.card.name,
        )
        return CommandResult.ok("效果已注册。" if registered else "")


@dataclass
class RegisterToolModifier:
    """Register a data-defined tool modifier hook for the source Pokemon."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.commands.modifier_registration import register_tool_effect_modifier

        pokemon = ctx.player.get_pokemon(ctx.source_slot)
        effect_name = str(self.params.get("effect", "") or "")
        if pokemon is None or not effect_name:
            return CommandResult.ok("")
        source = f"pokemon:{ctx.player_idx}:{pokemon.card.api_id}:{ctx.source_slot}:vm_tool:{effect_name}"
        registered = register_tool_effect_modifier(
            effect_name,
            self.params,
            pokemon,
            ctx.player_idx,
            source=source,
            event_bus=ctx.state.event_bus,
            source_name=effect_name,
        )
        return CommandResult.ok("道具效果已注册。" if registered else "")


__all__ = [
    "AttackFail",
    "SetAttackFlags",
    "ReturnToHand",
    "SetPrevention",
    "DazzlingBeam",
    "AttackLockBasic",
    "OutgoingDamageReduction",
    "SelfAttackLock",
    "RegisterModifier",
    "RegisterToolModifier",
]
