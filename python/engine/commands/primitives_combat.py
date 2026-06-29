"""Atomic command primitives for card game effects.

~15 primitives cover all card effects. Complex effects compose primitives
via the DSL compiler. Each primitive is a self-contained ICommand.
"""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any, TYPE_CHECKING

from engine.rules_constants import DAMAGE_PER_COUNTER

if TYPE_CHECKING:
    from engine.commands.base import ResolutionContext, CommandResult


def _command_result_from_action_result(action_result) -> CommandResult:
    from engine.commands.base import CommandResult

    return CommandResult(
        success=action_result.success,
        log_message=action_result.log_message,
        damage_dealt=action_result.damage_dealt,
        cards_drawn=action_result.cards_drawn,
        cards_discarded=getattr(action_result, "cards_discarded", 0),
        pokemon_ko=action_result.pokemon_ko,
        status_applied=action_result.status_applied,
        pending_choice=getattr(action_result, "pending_action", None),
        attack_failed=getattr(action_result, "attack_failed", False),
    )


def _attack_context_for_opponent_active(state, player_idx: int, opponent, stack=None):
    from engine.commands.attack_frames import (
        attack_context_for_opponent_active as current_attack_context_for_opponent_active,
    )

    return current_attack_context_for_opponent_active(
        state,
        player_idx,
        opponent,
        stack,
    )


def _consume_effect_damage_prevention(state, defender) -> bool:
    if getattr(defender, "damage_prevented_next_turn", False):
        defender.damage_prevented_next_turn = False
        if getattr(defender, "all_prevented_next_turn", False):
            defender.all_prevented_next_turn = False
        state._log(f"{defender.card.name}免疫了伤害！")
        return True
    if getattr(defender, "all_prevented_next_turn", False):
        defender.all_prevented_next_turn = False
        state._log(f"{defender.card.name}免疫了附加效果伤害！")
        return True
    return False


def _check_bench_protection(target_state) -> bool:
    all_pokemon = [target_state.active] if target_state.active else []
    all_pokemon.extend(pokemon for pokemon in target_state.bench if pokemon is not None)
    for pokemon in all_pokemon:
        for ability in pokemon.card.abilities or []:
            text = ability.text if hasattr(ability, "text") else ""
            if "备战宝可梦不会受到" in text:
                return True
    return False


def _discard_pokemon_for_effect(state, player_idx: int, slot: str):
    player = state.get_player(player_idx)
    pokemon = player.get_pokemon(slot)
    if pokemon is None:
        return None
    try:
        from engine.commands.modifier_registration import unregister_pokemon_modifiers

        unregister_pokemon_modifiers(
            pokemon.card.api_id,
            slot,
            event_bus=state.event_bus,
            player_idx=player_idx,
        )
    except Exception:
        pass
    state.discard_pokemon(player_idx, slot)
    return pokemon


def _award_prizes_for_effect_ko(state, knocked_player_idx: int, pokemon) -> None:
    prize_taker_idx = 1 - knocked_player_idx
    prize_taker = state.get_player(prize_taker_idx)
    for _ in range(getattr(pokemon.card, "prize_value", 1)):
        if prize_taker.prizes:
            prize_taker.take_prize()
            state._log(
                f"{prize_taker.name}获得了奖品卡！"
                f"（剩余{len(prize_taker.prizes)}张）"
            )


def _set_promotion_or_game_over(state, player_idx: int) -> None:
    from engine.enums import TurnPhase

    player = state.get_player(player_idx)
    opponent = state.get_player(1 - player_idx)
    if player.active is not None:
        return
    if not player.has_any_pokemon_in_play():
        state.winner = 1 - player_idx
        state.phase = TurnPhase.GAME_OVER
        state._log(f"{opponent.name}获胜——对手场上没有宝可梦了！")
        return
    state.pending_promotion_player = player_idx


def _handle_effect_ko_if_needed(
    state,
    player_idx: int,
    slot: str,
    pokemon,
    ko_slots: list[str],
) -> None:
    from engine.enums import TurnPhase

    if pokemon is None or not pokemon.is_knocked_out:
        return
    knocked = _discard_pokemon_for_effect(state, player_idx, slot)
    if knocked is None:
        return
    ko_slots.append(f"p{player_idx}_{slot}")
    state._log(f"{state.get_player(player_idx).name}的{knocked.card.name}被击倒了！")
    _award_prizes_for_effect_ko(state, player_idx, knocked)
    from engine.rules_validator import check_win_condition

    winner = check_win_condition(state)
    if winner is not None:
        state.winner = winner
        state.phase = TurnPhase.GAME_OVER
        state._log(f"{state.get_player(winner).name}获胜！")
        return
    if slot == "active":
        state.pending_promotion_player = player_idx


def _queue_or_apply_opponent_active_damage(
    state,
    player_idx: int,
    player,
    opponent,
    amount: int,
    log_msg: str = "",
    result_msg: str = "",
    prevent_msg: str = "伤害被免疫。",
    ignore_defender_effects: bool = False,
    piercing: bool = False,
    stack=None,
):
    from engine.game_state import ActionResult

    if opponent.active is None:
        return None

    damage = max(0, int(amount or 0))
    from engine.commands.attack_frames import add_attack_damage, set_attack_damage_flags

    if add_attack_damage(state, player_idx, opponent, damage, stack=stack):
        set_attack_damage_flags(
            state,
            stack=stack,
            piercing=True if piercing else None,
            ignore_defender_effects=True if ignore_defender_effects else None,
        )
        if log_msg:
            state._log(log_msg)
        return ActionResult(True, result_msg or f"伤害: {damage}", damage_dealt=0)

    defender = opponent.active
    if (
        not ignore_defender_effects
        and _consume_effect_damage_prevention(state, defender)
    ):
        return ActionResult(True, prevent_msg)
    defender.damage_counters += damage // DAMAGE_PER_COUNTER
    if log_msg:
        state._log(log_msg)
    else:
        state._log(f"对{defender.card.name}造成{damage}点伤害。")
    return ActionResult(True, result_msg or f"伤害: {damage}", damage_dealt=damage)


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
    formula_ast: Any = None
    consume_condition: str = ""
    check_self_ko: bool = False

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        damage = self.amount
        if self.formula_ast is not None:
            from engine.commands.formula_ast import evaluate_formula_ast
            try:
                damage = evaluate_formula_ast(self.formula_ast, ctx)
            except ValueError as exc:
                return CommandResult.fail(str(exc))
        elif self.formula:
            from engine.commands.formula import evaluate_formula
            damage = evaluate_formula(self.formula, ctx)

        result = CommandResult(success=True, damage_dealt=0)

        if self.target == "opponent_active":
            if ctx.opponent.active is None:
                return result

            msg = f"对{ctx.opponent.active.card.name}造成{int(damage or 0)}点伤害。"
            action_result = _queue_or_apply_opponent_active_damage(
                ctx.state,
                ctx.player_idx,
                ctx.player,
                ctx.opponent,
                damage,
                msg,
                msg,
                ignore_defender_effects=self.piercing,
                piercing=self.piercing,
                stack=ctx.stack,
            )
            if action_result is None:
                return result
            self._consume_condition_if_needed(ctx)
            return CommandResult(
                success=action_result.success,
                log_message=action_result.log_message,
                damage_dealt=action_result.damage_dealt,
                pokemon_ko=action_result.pokemon_ko,
            )

        elif self.target == "self":
            slot = ctx.source_slot
            active = ctx.player.get_pokemon(slot) or ctx.player.active
            if active:
                counters = damage // DAMAGE_PER_COUNTER
                active.damage_counters += counters
                result.damage_dealt = damage
                ctx.state._log(f"{active.card.name}自身受到{damage}点伤害。")
                result.log_message = f"自身伤害: {damage}"
                if self.check_self_ko and active.is_knocked_out:
                    ko_slots: list[str] = []

                    if ctx.player.get_pokemon(slot) is None:
                        slot = "active"
                    _handle_effect_ko_if_needed(ctx.state, ctx.player_idx, slot, active, ko_slots)
                    result.pokemon_ko.extend(ko_slots)

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

    def _consume_condition_if_needed(self, ctx: ResolutionContext) -> None:
        condition = str(self.consume_condition or "")
        if condition == "ko_by_attack_last_turn":
            try:
                from engine.commands.formula_ast import condition_applies

                if condition_applies(condition, ctx):
                    ctx.player.was_ko_by_attack = False
            except ValueError:
                return


@dataclass
class DealDamageFormula:
    """Compute a migrated damage formula and deal it to opponent active."""

    formula_kind: str = ""
    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        if ctx.opponent.active is None:
            if self.formula_kind == "per_hand_size":
                ctx.state._log("手牌为0张，造成0点伤害。")
                return CommandResult.ok("手牌为0张，造成0点伤害。")
            return CommandResult.fail("没有目标。")

        total = self._compute_total(ctx)
        msg = f"对{ctx.opponent.active.card.name}造成{total}点伤害。"
        action_result = _queue_or_apply_opponent_active_damage(
            ctx.state,
            ctx.player_idx,
            ctx.player,
            ctx.opponent,
            total,
            msg,
            f"伤害: {total}",
            stack=ctx.stack,
        )
        if action_result is None:
            return CommandResult.fail("没有目标。")
        return CommandResult(
            success=action_result.success,
            log_message=action_result.log_message,
            damage_dealt=action_result.damage_dealt,
            pokemon_ko=action_result.pokemon_ko,
        )

    def _compute_total(self, ctx: ResolutionContext) -> int:
        params = self.params or {}
        formula_kind = self.formula_kind
        if formula_kind == "per_hand_size":
            return len(ctx.player.hand) * int(params.get("per", 0) or 0)
        if formula_kind == "plus_bench":
            return (
                int(params.get("base", 0) or 0)
                + ctx.player.bench_count() * int(params.get("per_bench", 0) or 0)
            )
        if formula_kind == "per_self_damage":
            source = ctx.player.get_pokemon(ctx.source_slot) or ctx.player.active
            return (
                int(params.get("base", 0) or 0)
                + (source.damage_counters if source else 0) * int(params.get("per_counter", 0) or 0)
            )
        if formula_kind == "per_energy":
            return self._damage_per_energy(ctx, params)
        if formula_kind == "per_self_energy":
            source = ctx.player.get_pokemon(ctx.source_slot) or ctx.player.active
            energy_filter = str(params.get("energy_filter", "fire") or "fire").lower()
            matching = self._count_matching_energy(source, energy_filter)
            return int(params.get("base", 60) or 0) + matching * int(params.get("per_energy", 20) or 0)
        if formula_kind == "per_self_energy_type":
            source = ctx.player.get_pokemon(ctx.source_slot) or ctx.player.active
            energy_type = str(params.get("energy_type", "Grass") or "Grass").lower()
            matching = self._count_matching_energy(source, energy_type)
            return int(params.get("base", 60) or 0) + matching * int(params.get("per_energy", 20) or 0)
        if formula_kind == "per_discard_psychic":
            psychic_count = sum(
                1
                for card in ctx.player.discard
                if getattr(card, "is_pokemon", False)
                and "Psychic" in getattr(card, "energy_types", [])
            )
            return int(params.get("base", 80) or 0) + psychic_count * int(params.get("per_card", 10) or 0)
        if formula_kind == "per_evolved":
            evolved_count = sum(
                1
                for _slot, pokemon in ctx.player.get_all_pokemon()
                if pokemon is not None and not pokemon.card.is_basic_pokemon
            )
            return evolved_count * int(params.get("per_evolved", 50) or 0)
        raise ValueError(f"No native formula compiler for formula_kind={formula_kind!r}")

    def _damage_per_energy(self, ctx: ResolutionContext, params: dict) -> int:
        count_from = str(params.get("count_from", "self") or "self")
        energy_count = 0
        if count_from == "opponent_active":
            energy_count = len(ctx.opponent.active.energy_cards) if ctx.opponent.active else 0
        elif count_from == "all_opponent":
            for _slot, pokemon in ctx.opponent.get_all_pokemon():
                if pokemon is not None:
                    energy_count += len(pokemon.energy_cards)
        else:
            source = ctx.player.get_pokemon(ctx.source_slot) or ctx.player.active
            energy_count = len(source.energy_cards) if source else 0
        return int(params.get("base", 0) or 0) + energy_count * int(params.get("per_energy", 0) or 0)

    @staticmethod
    def _count_matching_energy(pokemon, energy_type: str) -> int:
        if pokemon is None:
            return 0
        if energy_type in {"", "any"}:
            return len(pokemon.energy_cards)
        return sum(
            1
            for card in pokemon.energy_cards
            if any(str(provided).lower() == energy_type for provided in card.provides_energy)
        )


@dataclass
class SetAttackDamageFormula:
    """Set or resolve a primary attack damage formula through the VM."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.commands.damage_pipeline import resolve_damage as event_damage_pipeline

        attacker = ctx.player.get_pokemon(ctx.source_slot) or ctx.player.active
        defender = ctx.opponent.active
        if attacker is None or defender is None:
            return CommandResult.fail("没有目标。")

        total = self._compute_total(ctx, attacker, defender)
        ignore_defender_effects = bool(self.params.get("ignore_defender_effects", False))
        from engine.commands.attack_frames import set_attack_damage_total

        attack_ctx_updated = set_attack_damage_total(
            ctx.state,
            ctx.player_idx,
            ctx.opponent,
            total,
            stack=ctx.stack,
            piercing=bool(self.params.get("piercing", False)),
            ignore_defender_effects=ignore_defender_effects,
        )
        if attack_ctx_updated:
            return CommandResult.ok("攻击伤害公式已设置。")

        if (
            not ignore_defender_effects
            and _consume_effect_damage_prevention(ctx.state, defender)
        ):
            return CommandResult.ok("伤害被免疫。")

        attacker_type = attacker.card.energy_types[0] if attacker.card.energy_types else "Colorless"
        final_damage, mod_logs = event_damage_pipeline(
            ctx.state,
            attacker,
            defender,
            total,
            attacker_type,
            piercing=bool(self.params.get("piercing", False)),
            ignore_defender_effects=ignore_defender_effects,
        )
        for log_msg in mod_logs:
            ctx.state._log(log_msg)

        defender.damage_counters += final_damage // DAMAGE_PER_COUNTER
        ctx.state._log(f"对{defender.card.name}造成{final_damage}点伤害。")
        return CommandResult.ok(f"伤害: {final_damage}", damage_dealt=final_damage)

    def _compute_total(self, ctx: ResolutionContext, attacker, defender) -> int:
        params = self.params or {}
        total = int(params.get("base", 0) or 0)

        per_own_bench = int(params.get("per_own_bench", 0) or 0)
        if per_own_bench:
            total += ctx.player.bench_count() * per_own_bench

        energy_type = params.get("per_self_energy_type")
        if energy_type:
            per_energy = int(params.get("per_energy", 0) or 0)
            total += self._count_attached_energy_of_type(attacker, str(energy_type)) * per_energy

        per_self_damage_counter = int(params.get("per_self_damage_counter", 0) or 0)
        if per_self_damage_counter:
            total += attacker.damage_counters * per_self_damage_counter

        condition_bonus = params.get("condition_bonus") or {}
        if isinstance(condition_bonus, dict) and self._condition_applies(
            ctx,
            defender,
            str(condition_bonus.get("condition", "") or ""),
        ):
            total += int(condition_bonus.get("bonus", 0) or 0)
            if (
                str(condition_bonus.get("condition", "") or "") == "ko_by_attack_last_turn"
                and bool(condition_bonus.get("consume", True))
            ):
                ctx.player.was_ko_by_attack = False

        return total

    @staticmethod
    def _condition_applies(ctx: ResolutionContext, defender, condition: str) -> bool:
        if condition == "ko_by_attack_last_turn":
            return bool(ctx.player.was_ko_by_attack)
        if condition == "own_bench_damaged":
            return any(poke is not None and poke.damage_counters > 0 for poke in ctx.player.bench)
        if condition == "opponent_active_evolved":
            return defender is not None and not defender.card.is_basic_pokemon
        if condition == "opponent_active_damaged":
            return defender is not None and defender.damage_counters > 0
        if condition == "own_hand_empty":
            return len(ctx.player.hand) == 0
        return False

    @staticmethod
    def _count_attached_energy_of_type(pokemon, energy_type: str) -> int:
        if pokemon is None:
            return 0
        energy_type = str(energy_type or "").lower()
        return sum(
            1
            for card in pokemon.energy_cards
            if any(str(provided).lower() == energy_type for provided in card.provides_energy)
        )


@dataclass
class ConditionalDamageHeal:
    """Deal damage with a bonus if this player healed this turn."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        base = int(self.params.get("base", 60) or 0)
        bonus = int(self.params.get("bonus", 90) or 0)
        healed_flag = bool(getattr(ctx.player, "healed_this_turn", False))
        total = base + (bonus if healed_flag else 0)

        if ctx.opponent.active is None:
            return CommandResult.fail("没有目标。")

        heal_msg = "（本回合回复过HP，追加90伤害！）" if healed_flag else ""
        msg = f"对{ctx.opponent.active.card.name}造成{total}点伤害。{heal_msg}"
        action_result = _queue_or_apply_opponent_active_damage(
            ctx.state,
            ctx.player_idx,
            ctx.player,
            ctx.opponent,
            total,
            msg,
            f"伤害: {total}",
            stack=ctx.stack,
        )
        return _command_result_from_action_result(action_result)


@dataclass
class DamageAndSelfHeal:
    """Deal damage, then heal the source side."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        damage = int(self.params.get("damage", 10) or 0)
        heal = int(self.params.get("heal", 10) or 0)
        source = ctx.player.get_pokemon(ctx.source_slot) or ctx.player.active
        damage_result = None

        if ctx.opponent.active and damage > 0:
            damage_result = _queue_or_apply_opponent_active_damage(
                ctx.state,
                ctx.player_idx,
                ctx.player,
                ctx.opponent,
                damage,
                f"对{ctx.opponent.active.card.name}造成{damage}点伤害。",
                f"伤害: {damage}",
                stack=ctx.stack,
            )

        if source and heal > 0 and source.damage_counters > 0:
            heal_counters = heal // DAMAGE_PER_COUNTER
            actual = min(source.damage_counters, heal_counters)
            source.damage_counters -= actual
            ctx.state._log(f"{source.card.name}回复了{actual * DAMAGE_PER_COUNTER}点HP。")
            ctx.player.healed_this_turn = True

        dealt = damage_result.damage_dealt if damage_result is not None else 0
        return CommandResult.ok(
            f"造成{damage}点伤害并回复{heal}点HP。",
            damage_dealt=dealt,
        )


@dataclass
class ConditionalDamageBonus:
    """Apply conditional bonus damage through the VM."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        bonus = int(self.params.get("bonus", 0) or 0)
        condition = str(self.params.get("condition", "") or "")

        if condition == "opponent_active_damaged" and ctx.opponent.active:
            if ctx.opponent.active.damage_counters > 0:
                return _command_result_from_action_result(
                    _queue_or_apply_opponent_active_damage(
                        ctx.state,
                        ctx.player_idx,
                        ctx.player,
                        ctx.opponent,
                        bonus,
                        f"追加造成{bonus}点伤害！（激流斩条件触发）",
                        f"追加{bonus}点伤害。",
                        "追加伤害被免疫。",
                        stack=ctx.stack,
                    )
                )

        if condition == "ko_by_attack_last_turn":
            if ctx.player.was_ko_by_attack:
                ctx.player.was_ko_by_attack = False
                if ctx.opponent.active:
                    return _command_result_from_action_result(
                        _queue_or_apply_opponent_active_damage(
                            ctx.state,
                            ctx.player_idx,
                            ctx.player,
                            ctx.opponent,
                            bonus,
                            f"追加造成{bonus}点伤害！（嫉妒业火条件触发）",
                            f"追加{bonus}点伤害。",
                            "追加伤害被免疫。",
                            stack=ctx.stack,
                        )
                    )
            else:
                ctx.state._log("上个对手回合没有宝可梦因招式伤害昏厥，嫉妒业火追加伤害不触发。")

        if condition == "opponent_active_evolved" and ctx.opponent.active:
            if not ctx.opponent.active.card.is_basic_pokemon:
                return _command_result_from_action_result(
                    _queue_or_apply_opponent_active_damage(
                        ctx.state,
                        ctx.player_idx,
                        ctx.player,
                        ctx.opponent,
                        bonus,
                        f"追加造成{bonus}点伤害！（对手为进化宝可梦）",
                        f"追加{bonus}点伤害。",
                        "追加伤害被免疫。",
                        stack=ctx.stack,
                    )
                )
            ctx.state._log("对手战斗宝可梦不是进化宝可梦，挥落追加伤害不触发。")

        if condition == "field_energy_ge_5":
            total_energy = sum(
                len(poke.energy_cards)
                for _slot_name, poke in ctx.player.get_all_pokemon()
                if poke is not None
            )
            if total_energy >= 5:
                if ctx.opponent.active:
                    return _command_result_from_action_result(
                        _queue_or_apply_opponent_active_damage(
                            ctx.state,
                            ctx.player_idx,
                            ctx.player,
                            ctx.opponent,
                            bonus,
                            f"追加造成{bonus}点伤害！（场上能量{total_energy}≥5）",
                            f"追加{bonus}点伤害。",
                            "追加伤害被免疫。",
                            stack=ctx.stack,
                        )
                    )
            else:
                ctx.state._log(f"场上能量{total_energy}不足5个，光子镭射追加伤害不触发。")

        return CommandResult.ok("无追加伤害。")


@dataclass
class DiscardHandThenDamage:
    """Discard the whole hand, then deal conditional damage."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        threshold = int(self.params.get("threshold", 5) or 0)
        base_damage = int(self.params.get("base_damage", 60) or 0)
        bonus = int(self.params.get("bonus", 150) or 0)

        hand_size = len(ctx.player.hand)
        ctx.player.discard_entire_hand()
        ctx.state._log(f"{ctx.player.name}将{hand_size}张手牌全部丢弃。")

        total = base_damage
        if hand_size >= threshold:
            total += bonus
            ctx.state._log(f"丢弃了{hand_size}张（≥{threshold}张），追加{bonus}点伤害！")

        if ctx.opponent.active:
            action_result = _queue_or_apply_opponent_active_damage(
                ctx.state,
                ctx.player_idx,
                ctx.player,
                ctx.opponent,
                total,
                f"对{ctx.opponent.active.card.name}造成{total}点伤害。",
                f"倾倒一空: {total}伤害。",
                stack=ctx.stack,
            )
            return _command_result_from_action_result(action_result)

        return CommandResult.ok(f"倾倒一空: {total}伤害。")


@dataclass
class DiscardEnergyThenDamage:
    """Discard matching source energy, then deal scaled damage."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        base = int(self.params.get("base", 10) or 0)
        per_energy = int(self.params.get("per_energy", 60) or 0)
        source = ctx.player.get_pokemon(ctx.source_slot) or ctx.player.active
        if source is None:
            return CommandResult.fail("没有战斗宝可梦。")

        fighting_count = 0
        kept_energy = []
        for card in source.energy_cards:
            if any(str(energy).lower() == "fighting" for energy in card.provides_energy):
                ctx.player.discard.append(card)
                fighting_count += 1
            else:
                kept_energy.append(card)
        source.energy_cards = kept_energy

        total_damage = base + per_energy * fighting_count
        ctx.state._log(f"丢弃了{fighting_count}个斗能量，造成{total_damage}点伤害。")

        if ctx.opponent.active and total_damage > 0:
            return _command_result_from_action_result(
                _queue_or_apply_opponent_active_damage(
                    ctx.state,
                    ctx.player_idx,
                    ctx.player,
                    ctx.opponent,
                    total_damage,
                    "",
                    f"连续波导弹造成{total_damage}点伤害。",
                    stack=ctx.stack,
                )
            )

        return CommandResult.ok(f"丢弃了{fighting_count}个斗能量。")


@dataclass
class MillThenDamage:
    """Reveal cards from deck, discard energies, shuffle the rest, then deal damage."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        mill_count = int(self.params.get("mill_count", 5) or 0)
        damage_per = int(self.params.get("damage_per", 80) or 0)

        milled = [ctx.player.deck.pop() for _ in range(min(mill_count, len(ctx.player.deck)))]
        energy_cards = [card for card in milled if card.is_energy]
        non_energy = [card for card in milled if not card.is_energy]

        ctx.player.discard.extend(energy_cards)
        ctx.player.deck.extend(non_energy)
        ctx.player.shuffle_deck()

        total_damage = damage_per * len(energy_cards)
        ctx.state._log(f"翻开了{len(milled)}张卡，其中{len(energy_cards)}张能量卡。")

        if total_damage > 0 and ctx.opponent.active:
            return _command_result_from_action_result(
                _queue_or_apply_opponent_active_damage(
                    ctx.state,
                    ctx.player_idx,
                    ctx.player,
                    ctx.opponent,
                    total_damage,
                    f"对{ctx.opponent.active.card.name}造成{total_damage}点伤害！",
                    f"螺旋业火: {total_damage}伤害。",
                    stack=ctx.stack,
                )
            )

        return CommandResult.ok("螺旋业火: 无能量卡，造成0伤害。")


@dataclass
class BenchDamage:
    """Deal damage to benched Pokemon, optionally asking the player to choose."""

    amount: int = 0
    count: int = 1
    target_player: str = "opponent"
    choose_targets: bool = True

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        target_state = ctx.opponent if self.target_player == "opponent" else ctx.player
        if _check_bench_protection(target_state):
            ctx.state._log(f"{target_state.name}的备战宝可梦受到特性保护，不会受到伤害。")
            return CommandResult.ok("Bench protected by ability.")

        bench_indices = [
            index
            for index, pokemon in enumerate(target_state.bench)
            if pokemon is not None
            and not pokemon.damage_prevented_next_turn
            and not getattr(pokemon, "all_prevented_next_turn", False)
        ]
        if not bench_indices:
            ctx.state._log(f"{target_state.name}的备战区没有可攻击的宝可梦。")
            return CommandResult.ok("No bench targets.")

        actual_count = min(int(self.count or 0), len(bench_indices))
        if actual_count <= 0:
            return CommandResult.ok("No bench targets.")

        def apply_to_indices(selected_indices):
            counters = int(self.amount or 0) // DAMAGE_PER_COUNTER
            hits = 0
            for index in list(selected_indices)[:actual_count]:
                if 0 <= index < len(target_state.bench) and target_state.bench[index]:
                    target_state.bench[index].damage_counters += counters
                    hits += 1
            ctx.state._log(f"对{target_state.name}的备战区造成了{hits}次{self.amount}点伤害。")
            return hits

        if not self.choose_targets or len(bench_indices) == 1:
            hits = apply_to_indices(bench_indices)
            return CommandResult.ok(f"Bench damage dealt to {hits} Pokemon.")

        return CommandResult.ok(
            f"选择{actual_count}个备战宝可梦作为目标。",
            pending_choice=ActionRequest(
                request_type="select_bench_targets",
                player=ctx.player_idx,
                prompt=f"选择{actual_count}个对手备战宝可梦作为目标。",
                min_select=actual_count,
                max_select=actual_count,
                target_player=self.target_player,
                bench_indices=bench_indices,
                continuation={
                    "kind": "bench_damage_targets",
                    "target_player_idx": (
                        1 - ctx.player_idx
                        if self.target_player == "opponent"
                        else ctx.player_idx
                    ),
                    "amount": int(self.amount or 0),
                    "count": actual_count,
                    "bench_indices": bench_indices,
                },
            ),
        )


@dataclass
class ChooseDamageTarget:
    """Deal direct effect damage to one Pokemon chosen from a target board."""

    amount: int = 0
    target_player: str = "opponent"

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        target_state = ctx.opponent if self.target_player == "opponent" else ctx.player
        targets = []
        if target_state.active:
            targets.append(("active", target_state.active))
        for index, pokemon in enumerate(target_state.bench):
            if pokemon is not None:
                targets.append((f"bench_{index}", pokemon))

        if not targets:
            return CommandResult.ok("对手场上没有宝可梦。")

        def apply_damage(target_poke):
            if _consume_effect_damage_prevention(ctx.state, target_poke):
                return False
            counters = int(self.amount or 0) // DAMAGE_PER_COUNTER
            target_poke.damage_counters += counters
            ctx.state._log(f"对{target_poke.card.name}造成了{self.amount}点伤害。")
            return True

        if len(targets) == 1:
            _slot_name, target_poke = targets[0]
            applied = apply_damage(target_poke)
            return CommandResult.ok(
                f"对{target_poke.card.name}造成{self.amount}点伤害。",
                damage_dealt=int(self.amount or 0) if applied else 0,
            )

        return CommandResult.ok(
            "选择1只对手的宝可梦作为目标。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"选择1只对手的宝可梦，造成{self.amount}点伤害",
                min_select=1,
                max_select=1,
                from_zone="board",
                target_player=self.target_player,
                card_list=[target.card for _slot_name, target in targets],
                continuation={
                    "kind": "choose_damage_target",
                    "target_player_idx": (
                        1 - ctx.player_idx
                        if self.target_player == "opponent"
                        else ctx.player_idx
                    ),
                    "amount": int(self.amount or 0),
                },
            ),
        )


@dataclass
class PlaceCountersThenSelfKo:
    """Place counters on one opposing Pokemon, then discard the source Pokemon."""

    counters: int = 2
    target_player: str = "opponent"

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest
        from engine.enums import TurnPhase

        target_state = ctx.opponent if self.target_player == "opponent" else ctx.player
        target_player_idx = 1 - ctx.player_idx if self.target_player == "opponent" else ctx.player_idx
        targets = []
        if target_state.active:
            targets.append(("active", target_state.active))
        for index, pokemon in enumerate(target_state.bench):
            if pokemon is not None:
                targets.append((f"bench_{index}", pokemon))

        if not targets:
            return CommandResult.ok("对手场上没有宝可梦。")

        ko_slots: list[str] = []

        def do_effect(slot_name, target_poke):
            target_poke.damage_counters += int(self.counters or 0)
            ctx.state._log(f"在{target_poke.card.name}身上放置了{self.counters}个伤害指示物。")
            _handle_effect_ko_if_needed(
                ctx.state,
                target_player_idx,
                slot_name,
                target_poke,
                ko_slots,
            )
            if ctx.state.phase == TurnPhase.GAME_OVER:
                return

            source = _discard_pokemon_for_effect(ctx.state, ctx.player_idx, ctx.source_slot)
            if source:
                ctx.state._log(f"{source.card.name}被放置于弃牌区。")
                if ctx.source_slot == "active":
                    _set_promotion_or_game_over(ctx.state, ctx.player_idx)

        if len(targets) == 1:
            do_effect(*targets[0])
            return CommandResult.ok("神秘彗星结算完毕。", pokemon_ko=list(ko_slots))

        return CommandResult.ok(
            "选择1只对手的宝可梦放置伤害指示物。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"选择1只对手的宝可梦，放置{self.counters}个伤害指示物",
                min_select=1,
                max_select=1,
                from_zone="board",
                target_player=self.target_player,
                card_list=[target.card for _slot_name, target in targets],
                continuation={
                    "kind": "place_counters_then_self_ko",
                    "target_player_idx": target_player_idx,
                    "counters": int(self.counters or 0),
                },
            ),
        )



__all__ = [
    "_command_result_from_action_result",
    "_attack_context_for_opponent_active",
    "_consume_effect_damage_prevention",
    "_check_bench_protection",
    "_discard_pokemon_for_effect",
    "_award_prizes_for_effect_ko",
    "_set_promotion_or_game_over",
    "_handle_effect_ko_if_needed",
    "_queue_or_apply_opponent_active_damage",
    "DealDamage",
    "DealDamageFormula",
    "SetAttackDamageFormula",
    "ConditionalDamageHeal",
    "DamageAndSelfHeal",
    "ConditionalDamageBonus",
    "DiscardHandThenDamage",
    "DiscardEnergyThenDamage",
    "MillThenDamage",
    "BenchDamage",
    "ChooseDamageTarget",
    "PlaceCountersThenSelfKo",
]
