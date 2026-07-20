"""Attack-state, prevention, and modifier-registration VM commands."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from engine.commands.base import CommandResult, ResolutionContext


def _register_attack_modifier(
    ctx,
    target,
    *,
    target_player_idx: int,
    hook: str,
    layer: str,
    duration: str,
    condition: dict,
    operation: dict,
    stacking: str = "replace_same_source",
) -> None:
    from engine.effects.modifier_manager import (
        build_modifier_descriptor,
        register_serialized_modifier,
    )

    source = ctx.player.get_pokemon(ctx.source_slot)
    if source is None or target is None:
        return
    descriptor = build_modifier_descriptor(
        hook=hook,
        layer=layer,
        controller=target_player_idx,
        source_ref={
            "kind": "pokemon",
            "player": int(ctx.player_idx),
            "slot": str(ctx.source_slot),
            "card_id": str(source.card.api_id),
        },
        scope="self",
        duration=duration,
        stacking=stacking,
        condition=condition,
        operation=operation,
    )
    register_serialized_modifier(target, descriptor)


def _register_persistent_modifier(ctx, pokemon, modifier_kind: str, params: dict) -> bool:
    from engine.effects.modifier_manager import (
        build_modifier_descriptor,
        register_serialized_modifier,
    )

    hook = layer = ""
    scope = "self"
    condition: dict = {}
    operation: dict = {}
    if modifier_kind == "aura_damage_boost":
        hook, layer, scope = "MODIFY_DAMAGE", "attacker_adjust", "allied_board"
        condition = {
            "attacker_subtype": str(params.get("attacker_subtype", "")),
            "defender_type": str(params.get("defender_type", "")),
        }
        operation = {"kind": "damage_delta", "amount": int(params.get("amount", 0))}
    elif modifier_kind == "aura_damage_reduction":
        hook, layer = "MODIFY_DAMAGE", "defender_adjust"
        condition = {
            "requires_attached_energy": bool(params.get("requires_attached_energy", False)),
        }
        operation = {
            "kind": "damage_delta",
            "amount": -abs(int(params.get("reduction", 20))),
        }
    elif modifier_kind == "conditional_hp_boost":
        hook, layer = "MAX_HP", "add"
        condition = {
            "energy_type": str(params.get("energy_type", "")),
            "threshold": int(params.get("threshold", 0)),
        }
        operation = {"kind": "hp_delta", "amount": int(params.get("amount", 0))}
    elif modifier_kind == "conditional_zero_retreat":
        hook, layer = "CAN_RETREAT", "set"
        condition = {"energy_type": str(params.get("energy_type", ""))}
        operation = {"kind": "retreat_set", "value": 0}
    elif modifier_kind == "tool":
        effect = str(params.get("effect", ""))
        if effect == "damage_boost_10":
            hook, layer, scope = "MODIFY_DAMAGE", "attacker_adjust", "attached_attacker"
            operation = {"kind": "damage_delta", "amount": 10}
        elif effect == "damage_boost_when_behind":
            hook, layer, scope = "MODIFY_DAMAGE", "attacker_adjust", "attached_attacker"
            condition = {"behind_on_prizes": True}
            operation = {"kind": "damage_delta", "amount": 30}
        elif effect == "damage_reduction_stage1":
            hook, layer, scope = "MODIFY_DAMAGE", "defender_adjust", "attached_defender"
            condition = {"target_stage": "stage1"}
            operation = {
                "kind": "damage_delta",
                "amount": -abs(int(params.get("amount", 30))),
            }
        elif effect == "hp_boost_basic":
            hook, layer = "MAX_HP", "add"
            condition = {"target_basic": True}
            operation = {"kind": "hp_delta", "amount": int(params.get("amount", 50))}
    if not operation:
        return False
    descriptor = build_modifier_descriptor(
        hook=hook,
        layer=layer,
        priority=int(params.get("priority", 0)),
        controller=ctx.player_idx,
        source_ref={
            "kind": "pokemon",
            "player": int(ctx.player_idx),
            "slot": str(ctx.source_slot),
            "card_id": str(pokemon.card.api_id),
        },
        scope=scope,
        duration="until_leave_play",
        stacking="replace_same_source",
        condition=condition,
        operation=operation,
    )
    register_serialized_modifier(pokemon, descriptor)
    return True


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
    ignore_defender_damage_effects: bool = False

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.commands.attack_frames import set_attack_damage_flags

        set_attack_damage_flags(
            ctx.state,
            stack=ctx.stack,
            ignore_weakness=self.ignore_weakness,
            ignore_resistance=self.ignore_resistance,
            ignore_defender_damage_effects=(
                True if self.ignore_defender_damage_effects else None
            ),
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
        # Preserve the shared cross-runtime zone order: Pokemon card, lower
        # evolution stages, Energy, then Tool.  The rules do not let a caller
        # choose an order here, so both runtimes must produce one deterministic
        # hand sequence for snapshots, replays, and action encoders.
        returned_cards = [
            source_card,
            *source.evolution_stack,
            *source.energy_cards,
        ]
        if source.attached_tool:
            returned_cards.append(source.attached_tool)
        source.attached_tool = None
        source.evolution_stack.clear()
        source.energy_cards.clear()
        player.hand.extend(returned_cards)

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
                _register_attack_modifier(
                    ctx,
                    target,
                    target_player_idx=ctx.player_idx,
                    hook="MODIFY_DAMAGE",
                    layer="prevent",
                    duration="until_end_of_opponents_next_turn",
                    condition={"expires_after_turn": ctx.state.turn_number + 1},
                    operation={"kind": "prevent_damage"},
                )
            if self.effects:
                target.all_prevented_next_turn = True
                _register_attack_modifier(
                    ctx,
                    target,
                    target_player_idx=ctx.player_idx,
                    hook="PREVENT_EFFECTS",
                    layer="prevent",
                    duration="until_end_of_opponents_next_turn",
                    condition={"expires_after_turn": ctx.state.turn_number + 1},
                    operation={"kind": "prevent_effects"},
                )
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
        from engine.commands.attack_frames import is_opponent_attack_effect

        if (
            getattr(target, "all_prevented_next_turn", False)
            and is_opponent_attack_effect(ctx.state, ctx.stack, target)
        ):
            ctx.state._log(f"{target.card.name}免疫了炫目光束的效果！")
            return CommandResult.ok("免疫了效果。")
        target.dazzled = True
        target_player_idx = 1 - ctx.player_idx if self.target == "opponent_active" else ctx.player_idx
        _register_attack_modifier(
            ctx,
            target,
            target_player_idx=target_player_idx,
            hook="CAN_ATTACK",
            layer="gate",
            duration="until_next_attack",
            condition={"expires_after_turn": ctx.state.turn_number + 1},
            operation={"kind": "attack_gate_coin", "reason": "dazzled"},
        )
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
        from engine.commands.attack_frames import is_opponent_attack_effect

        if (
            getattr(target, "all_prevented_next_turn", False)
            and is_opponent_attack_effect(ctx.state, ctx.stack, target)
        ):
            ctx.state._log(f"{target.card.name}免疫了攻击封锁的效果！")
            return CommandResult.ok("免疫了效果。")
        if target.card.is_basic_pokemon:
            target.attack_locked = True
            target_player_idx = 1 - ctx.player_idx if self.target == "opponent_active" else ctx.player_idx
            _register_attack_modifier(
                ctx,
                target,
                target_player_idx=target_player_idx,
                hook="CAN_ATTACK",
                layer="permission",
                duration="until_end_of_turn",
                condition={
                    "target_basic": True,
                    "expires_after_turn": ctx.state.turn_number + 1,
                },
                operation={"kind": "attack_lock", "attack_name": "__all__"},
            )
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
        from engine.commands.attack_frames import is_opponent_attack_effect

        if (
            getattr(target, "all_prevented_next_turn", False)
            and is_opponent_attack_effect(ctx.state, ctx.stack, target)
        ):
            ctx.state._log(f"{target.card.name}免疫了恫吓的效果！")
            return CommandResult.ok("免疫了效果。")
        target.outgoing_damage_reduction_next_turn = max(
            int(getattr(target, "outgoing_damage_reduction_next_turn", 0) or 0),
            amount,
        )
        target_player_idx = 1 - ctx.player_idx if self.target == "opponent_active" else ctx.player_idx
        _register_attack_modifier(
            ctx,
            target,
            target_player_idx=target_player_idx,
            hook="MODIFY_DAMAGE",
            layer="attacker_adjust",
            duration="until_end_of_turn",
            stacking="maximum",
            condition={
                "expires_after_turn": ctx.state.turn_number
                + (1 if target_player_idx != ctx.player_idx else 0),
            },
            operation={"kind": "damage_delta", "amount": -amount},
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
            _register_attack_modifier(
                ctx,
                target,
                target_player_idx=ctx.player_idx,
                hook="CAN_ATTACK",
                layer="permission",
                duration="until_end_of_opponents_next_turn",
                condition={"expires_after_turn": ctx.state.turn_number + 2},
                operation={"kind": "attack_lock", "attack_name": lock_key},
            )
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
        _register_persistent_modifier(ctx, pokemon, modifier_kind, self.params)
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
        _register_persistent_modifier(ctx, pokemon, "tool", self.params)
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
