"""Atomic command primitives for card game effects.

~15 primitives cover all card effects. Complex effects compose primitives
via the DSL compiler. Each primitive is a self-contained ICommand.
"""
from __future__ import annotations
import random
from dataclasses import dataclass, field
from typing import Optional, TYPE_CHECKING

from engine.rules_constants import DAMAGE_PER_COUNTER, COIN_FLIP_THRESHOLD
from engine.enums import StatusType

if TYPE_CHECKING:
    from engine.commands.base import ResolutionContext, CommandResult
    from engine.game_state import ActionRequest


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


def _attack_context_for_opponent_active(state, player_idx: int, opponent):
    attack_ctx = getattr(state, "_attack_damage_context", None)
    if not isinstance(attack_ctx, dict) or not attack_ctx.get("active"):
        return None
    if int(attack_ctx.get("player_idx", -1)) != int(player_idx):
        return None
    if opponent.active is None:
        return None
    return attack_ctx


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
):
    from engine.game_state import ActionResult

    if opponent.active is None:
        return None

    damage = max(0, int(amount or 0))
    attack_ctx = _attack_context_for_opponent_active(state, player_idx, opponent)
    if attack_ctx is not None:
        attack_ctx["base_damage"] = int(attack_ctx.get("base_damage", 0) or 0) + damage
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
    check_self_ko: bool = False

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        damage = self.amount
        if self.formula:
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
            )
            if action_result is None:
                return result
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
        attack_ctx = _attack_context_for_opponent_active(
            ctx.state,
            ctx.player_idx,
            ctx.opponent,
        )
        if attack_ctx is not None:
            attack_ctx["base_damage"] = total
            attack_ctx["piercing"] = bool(self.params.get("piercing", False))
            attack_ctx["ignore_defender_effects"] = ignore_defender_effects
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
            return CommandResult.fail("没有状态效果的目标。")

        status_map = {
            "poisoned": StatusType.POISONED,
            "burned": StatusType.BURNED,
            "asleep": StatusType.ASLEEP,
            "paralyzed": StatusType.PARALYZED,
            "confused": StatusType.CONFUSED,
        }
        status_key = str(self.status or "").lower()
        st = status_map.get(status_key)
        if st is None:
            return CommandResult.fail(f"未知状态: {self.status}")

        if getattr(target, 'all_prevented_next_turn', False):
            ctx.state._log(f"{target.card.name}免疫了所有效果！")
            return CommandResult.ok("免疫了效果。")

        if st in (StatusType.ASLEEP, StatusType.PARALYZED, StatusType.CONFUSED):
            target.status_conditions -= {
                StatusType.ASLEEP, StatusType.PARALYZED, StatusType.CONFUSED
            }
        target.status_conditions.add(st)
        if st == StatusType.PARALYZED:
            target.paralyzed_since_turn = ctx.state.turn_number
        status_cn_map = {
            "poisoned": "中毒",
            "burned": "灼伤",
            "asleep": "睡眠",
            "paralyzed": "麻痹",
            "confused": "混乱",
        }
        cn_status = status_cn_map.get(status_key, self.status)
        msg = f"{target.card.name}陷入了{cn_status}状态！"
        ctx.state._log(msg)
        return CommandResult.ok(msg, status_applied=[status_key])

    def _check_condition(self, ctx: ResolutionContext) -> bool:
        if self.condition == "ko_by_attack_last_turn":
            if not ctx.player.was_ko_by_attack:
                ctx.state._log(f"上个对手回合没有宝可梦因招式伤害昏厥，{self.status}效果不触发。")
                return False
            ctx.player.was_ko_by_attack = False
            return True
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
        ctx.state._log(f"{p.name}抽取了{len(drawn)}张卡。")
        return CommandResult.ok(
            f"抽取了{len(drawn)}张卡。",
            cards_drawn=drawn,
        )


@dataclass
class DrawUntil:
    target_hand_size: int = 5

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        current = len(ctx.player.hand)
        to_draw = max(0, self.target_hand_size - current)
        if to_draw == 0:
            ctx.state._log(f"{ctx.player.name}的手牌已有{current}张，无需抽取。")
            return CommandResult.ok(f"Hand already has {current} cards.")
        drawn = ctx.player.draw_cards(to_draw)
        ctx.state._log(
            f"{ctx.player.name}抽取了{len(drawn)}张卡，现在手牌有{len(ctx.player.hand)}张。"
        )
        return CommandResult.ok(
            f"Drew {len(drawn)} cards to reach {self.target_hand_size}.",
            cards_drawn=drawn,
        )


@dataclass
class DrawUntilMore:
    """Draw until this player has more cards in hand than the opponent."""

    margin: int = 1

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        target = len(ctx.opponent.hand) + int(self.margin or 1)
        current = len(ctx.player.hand)
        to_draw = max(0, target - current)
        if to_draw == 0:
            ctx.state._log(
                f"{ctx.player.name}的手牌已有{current}张（比对手的{len(ctx.opponent.hand)}张多1张或以上），无需抽取。"
            )
            return CommandResult.ok(f"Hand already has {current} cards.")
        drawn = ctx.player.draw_cards(to_draw)
        ctx.state._log(
            f"{ctx.player.name}抽取了{len(drawn)}张卡（目标比对手多1张，抽了{to_draw}张）。"
        )
        return CommandResult.ok(
            f"抽取了{len(drawn)}张卡。",
            cards_drawn=drawn,
        )


@dataclass
class ShuffleThenDrawCards:
    """Shuffle this player's hand into the deck, then draw cards."""

    draw_amount: int = 5
    shuffle_hand: bool = False

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        player = ctx.player
        if self.shuffle_hand:
            hand_size = len(player.hand)
            player.deck.extend(player.hand)
            player.hand.clear()
            player.shuffle_deck()
            ctx.state._log(f"{player.name}将{hand_size}张手牌洗回牌库。")

        drawn = player.draw_cards(int(self.draw_amount or 0))
        ctx.state._log(f"{player.name}抽取了{len(drawn)}张卡。")
        return CommandResult.ok(
            f"洗回手牌并抽取了{len(drawn)}张卡。",
            cards_drawn=drawn,
        )


@dataclass
class Judge:
    """Both players shuffle their hands into their decks, then draw cards."""

    draw_amount: int = 4

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        drawn_cards = []
        draw_amount = int(self.draw_amount or 0)
        for player_idx in (0, 1):
            player = ctx.state.get_player(player_idx)
            hand_size = len(player.hand)
            if hand_size == 0:
                continue
            player.deck.extend(player.hand)
            player.hand.clear()
            player.shuffle_deck()
            drawn = player.draw_cards(draw_amount)
            drawn_cards.extend(drawn)
            ctx.state._log(f"{player.name}将{hand_size}张手牌洗回牌库，抽取了{len(drawn)}张卡。")

        return CommandResult.ok(
            f"Judge: both players shuffled and drew {draw_amount}.",
            cards_drawn=drawn_cards,
        )


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

        return CommandResult.ok(
            f"Choose up to {count} cards from discard.",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"从弃牌区选择最多{count}张卡",
                min_select=0,
                max_select=count,
                from_zone="discard",
                card_list=available,
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
        from engine.game_state import ActionRequest

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
class SearchCards:
    """Search a player zone for matching cards and move selected cards."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        from_zone = str(self.params.get("from_zone", "deck") or "deck")
        filter_type = str(self.params.get("filter", "pokemon") or "pokemon")
        filter_name = str(self.params.get("filter_name", "") or "")
        destination = str(self.params.get("destination", "hand") or "hand")
        count = int(self.params.get("count", 1) or 1)
        default_min = 0 if bool(self.params.get("optional", False)) else min(1, count)
        min_select = int(self.params.get("min_select", default_min) or 0)

        search_pool = player.deck if from_zone == "deck" else player.discard
        valid_cards = [card for card in search_pool if self._matches(card, filter_type, filter_name)]
        if not valid_cards:
            return CommandResult.ok(f"No valid cards found in {from_zone}.")

        max_select = min(count, len(valid_cards))
        return CommandResult.ok(
            f"Search {from_zone} for {filter_type}.",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"从{from_zone}选择{count}张卡（{filter_type}）",
                min_select=min(min_select, max_select),
                max_select=max_select,
                from_zone=from_zone,
                card_list=valid_cards,
                can_cancel=min_select <= 0,
                continuation={
                    "kind": "search_cards",
                    "player_idx": ctx.player_idx,
                    "from_zone": from_zone,
                    "destination": destination,
                    "count": count,
                },
            ),
        )

    @staticmethod
    def _matches(card, filter_type: str, filter_name: str) -> bool:
        if filter_name:
            return getattr(card, "name", "") == filter_name
        if filter_type == "any":
            return True
        if filter_type == "basic_pokemon":
            return bool(getattr(card, "is_basic_pokemon", False))
        if filter_type == "pokemon":
            return bool(getattr(card, "is_pokemon", False))
        if filter_type == "basic_energy":
            return bool(getattr(card, "is_basic_energy", False))
        if filter_type == "energy":
            return bool(getattr(card, "is_energy", False))
        if filter_type == "supporter":
            return bool(getattr(card, "is_trainer_supporter", False))
        if filter_type == "grass_pokemon":
            return bool(
                getattr(card, "is_pokemon", False)
                and getattr(card, "energy_types", None)
                and "Grass" in card.energy_types
            )
        if filter_type == "item":
            return bool(getattr(card, "is_trainer_item", False))
        if filter_type == "item_or_tool":
            return bool(getattr(card, "is_trainer_item", False) or getattr(card, "is_trainer_tool", False))
        return True


@dataclass
class LookTopDeck:
    """Look at the top deck cards, choose matching cards, then return the rest."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        count = int(self.params.get("count", 5) or 5)
        take = int(self.params.get("take", 1) or 1)
        rest_bottom = bool(self.params.get("rest_bottom", True))
        shuffle_rest = bool(self.params.get("shuffle_rest", False))
        filter_type = str(self.params.get("filter", "") or "")
        destination = str(self.params.get("destination", "hand") or "hand")
        min_select = int(self.params.get("min_select", 0 if take >= 99 else 1) or 0)

        player = ctx.player
        top_cards = [
            player.deck[-1 - index]
            for index in range(min(count, len(player.deck)))
        ]

        display_cards = []
        display_top_positions = []
        for index, card in enumerate(top_cards):
            if self._matches(card, filter_type):
                display_cards.append(card)
                display_top_positions.append(index)
        if not display_cards:
            top_cards = []
            for _ in range(min(count, len(player.deck))):
                top_cards.append(player.deck.pop())
            player.deck.extend(top_cards)
            if shuffle_rest:
                player.shuffle_deck()
            return CommandResult.ok(f"牌库顶{count}张没有可选择的卡。")

        max_select = min(take, len(display_cards))
        return CommandResult.ok(
            f"Look at top {len(display_cards)} cards.",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"从牌库顶选择最多{take}张卡。",
                min_select=min(min_select, max_select),
                max_select=max_select,
                from_zone="deck",
                card_list=display_cards,
                can_cancel=min_select <= 0,
                continuation={
                    "kind": "look_top_deck",
                    "player_idx": ctx.player_idx,
                    "count": len(top_cards),
                    "take": take,
                    "rest_bottom": rest_bottom,
                    "shuffle_rest": shuffle_rest,
                    "destination": destination,
                    "top_card_ids": [getattr(card, "api_id", "") for card in top_cards],
                    "display_top_positions": display_top_positions,
                },
            ),
        )

    @staticmethod
    def _matches(card, filter_type: str) -> bool:
        if filter_type == "lightning_energy":
            return bool(
                getattr(card, "is_basic_energy", False)
                and any("Lightning" in str(energy_type) for energy_type in getattr(card, "provides_energy", []))
            )
        if filter_type == "supporter":
            return bool(getattr(card, "is_trainer_supporter", False))
        if filter_type == "energy":
            return bool(getattr(card, "is_energy", False))
        if filter_type == "water_pokemon_and_energy":
            return bool(
                (
                    getattr(card, "is_pokemon", False)
                    and getattr(card, "energy_types", None)
                    and "Water" in card.energy_types
                )
                or (
                    getattr(card, "is_basic_energy", False)
                    and "Water" in str(getattr(card, "provides_energy", []))
                )
            )
        return True

    @staticmethod
    def _attach_to_lightning_bench(ctx: ResolutionContext, taken: list):
        from engine.game_state import ActionRequest, ActionResult

        player = ctx.player
        if not taken:
            return ActionResult(True, "未选择能量。")

        bench_pokes = [
            (i, pokemon)
            for i, pokemon in enumerate(player.bench)
            if pokemon is not None
            and getattr(pokemon.card, "energy_types", None)
            and "Lightning" in pokemon.card.energy_types
        ]
        if not bench_pokes:
            player.deck.extend(taken)
            player.shuffle_deck()
            ctx.state._log("备战区没有雷属性宝可梦可附着能量。")
            return ActionResult(True, "备战区没有雷属性宝可梦可附着能量。")
        if len(bench_pokes) == 1 and len(taken) <= 1:
            _idx, bench_pokemon = bench_pokes[0]
            for card in taken:
                bench_pokemon.energy_cards.append(card)
            ctx.state._log(f"将{len(taken)}张能量附着于备战区{bench_pokemon.card.name}。")
            return ActionResult(True, f"附着了{len(taken)}张能量。")

        targets_info = [
            {"slot": f"bench_{idx}", "name": pokemon.card.name, "bench_idx": idx}
            for idx, pokemon in bench_pokes
        ]

        return ActionRequest(
            request_type="distribute_energy",
            player=ctx.player_idx,
            prompt="分配能量 — 电气发生器",
            card_list=taken,
            target_info=targets_info,
            distribute_mode="distribute",
            min_select=len(taken),
            max_select=len(taken),
            source_name="电气发生器",
            continuation={
                "kind": "detached_energy_distribution",
                "player_idx": ctx.player_idx,
                "source_name": "电气发生器",
            },
        )


@dataclass
class LookTopAttachEnergy:
    """Look at top deck cards, attach selected matching energy to one Pokemon."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        count = int(self.params.get("count", 5) or 5)
        take = int(self.params.get("take", 99) or 99)
        filter_type = str(self.params.get("filter", "basic_energy") or "basic_energy")

        player = ctx.player
        top_cards = [
            player.deck[-1 - index]
            for index in range(min(count, len(player.deck)))
        ]

        eligible = []
        display_top_positions = []
        for index, card in enumerate(top_cards):
            if self._matches_energy(card, filter_type):
                eligible.append(card)
                display_top_positions.append(index)
        if not eligible:
            top_cards = []
            for _ in range(min(count, len(player.deck))):
                top_cards.append(player.deck.pop())
            player.deck.extend(top_cards)
            player.shuffle_deck()
            return CommandResult.ok("没有可附着的能量。")

        return CommandResult.ok(
            f"查看牌库顶{len(top_cards)}张卡。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt="选择任意数量的基本能量附着于1只宝可梦。",
                min_select=0,
                max_select=min(take, len(eligible)),
                from_zone="deck",
                card_list=eligible,
                continuation={
                    "kind": "look_top_attach_energy",
                    "player_idx": ctx.player_idx,
                    "count": len(top_cards),
                    "take": take,
                    "top_card_ids": [getattr(card, "api_id", "") for card in top_cards],
                    "display_top_positions": display_top_positions,
                },
            ),
        )

    @staticmethod
    def _matches_energy(card, filter_type: str) -> bool:
        filter_type = str(filter_type or "any")
        if filter_type in {"any", "energy"}:
            return bool(getattr(card, "is_energy", False))
        if filter_type in {"basic", "basic_energy"}:
            return bool(getattr(card, "is_basic_energy", False))
        return bool(
            getattr(card, "is_energy", False)
            and any(
                str(provided).lower() == filter_type.lower()
                for provided in getattr(card, "provides_energy", [])
            )
        )


@dataclass
class DrawAndAttachEnergy:
    """Draw cards, then optionally attach matching basic energy from hand to bench."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        energy_count = int(self.params.get("energy_count", 2) or 2)
        energy_type = str(self.params.get("energy_type", "Grass") or "Grass")

        drawn = player.draw_cards(2)
        drawn_count = len(drawn)
        ctx.state._log(f"{player.name}抽取了{drawn_count}张卡。")

        matching_energy = [
            card
            for card in player.hand
            if getattr(card, "is_basic_energy", False)
            and energy_type in str(getattr(card, "provides_energy", []))
        ]
        if not matching_energy:
            return CommandResult.ok(
                f"抽了{drawn_count}张，但手牌中没有G能量可附着。",
                cards_drawn=drawn,
            )

        bench_slots = [(index, pokemon) for index, pokemon in enumerate(player.bench) if pokemon is not None]
        if not bench_slots:
            return CommandResult.ok(
                f"抽了{drawn_count}张，但备战区没有宝可梦。",
                cards_drawn=drawn,
            )

        max_attach = min(energy_count, len(matching_energy))
        min_attach = min(int(self.params.get("min_select", max_attach) or 0), max_attach)

        if len(bench_slots) == 1 and min_attach == max_attach and max_attach <= energy_count:
            _idx, bench_pokemon = bench_slots[0]
            attached = 0
            for card in matching_energy[:max_attach]:
                player.hand.remove(card)
                bench_pokemon.energy_cards.append(card)
                attached += 1
            ctx.state._log(f"将{attached}张G能量附着于备战区{bench_pokemon.card.name}。")
            return CommandResult.ok(
                f"抽了{drawn_count}张，附着了{attached}张G能量。",
                cards_drawn=drawn,
            )

        energy_to_distribute = matching_energy[:max_attach]
        targets_info = [
            {"slot": f"bench_{index}", "name": pokemon.card.name, "bench_idx": index}
            for index, pokemon in bench_slots
        ]

        return CommandResult.ok(
            f"选择最多{max_attach}张G能量分配到备战宝可梦。",
            cards_drawn=drawn,
            pending_choice=ActionRequest(
                request_type="distribute_energy",
                player=ctx.player_idx,
                prompt="分配能量 — 菜种的活力",
                card_list=energy_to_distribute,
                target_info=targets_info,
                distribute_mode="distribute",
                min_select=min_attach,
                max_select=max_attach,
                max_per_target=max_attach,
                source_name="菜种的活力",
                continuation={
                    "kind": "draw_and_attach_energy_distribution",
                    "player_idx": ctx.player_idx,
                    "max_per_target": max_attach,
                    "same_target": True,
                    "energy_type": energy_type,
                },
            ),
        )


@dataclass
class EnergyAttach:
    """Attach matching energy from hand/deck to legal targets."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        amount = int(self.params.get("amount", 1) or 1)
        base_amount = amount
        from_zone = str(self.params.get("from_zone", "hand") or "hand")
        filter_type = str(self.params.get("filter", "any") or "any")
        to_target = str(self.params.get("to", "self") or "self")
        optional = bool(self.params.get("optional", False))
        max_per_target = int(self.params.get("max_per_target", 99) or 99)
        bonus_applied = False

        going_second_bonus = int(self.params.get("going_second_bonus", 0) or 0)
        if going_second_bonus > 0 and ctx.state.is_going_second_first_turn(ctx.player_idx):
            amount = going_second_bonus
            bonus_applied = amount > base_amount
            ctx.state._log(f"后攻最初回合！可附着最多{amount}张能量。")

        optional_count = bool(optional or bonus_applied or "min_select" in self.params)
        min_attach = int(self.params.get("min_select", 0 if optional_count else 1) or 0)
        source_pool, zone_name = self._energy_source(player, from_zone)
        if not self._matching_energy_cards(source_pool, filter_type):
            return CommandResult.ok(f"{zone_name}中无匹配的能量。")

        def distribution(energy_cards, targets_info, *, min_select, max_select, max_per_target=99, same_target=False):
            max_select = min(max(0, int(max_select)), len(energy_cards))
            min_select = min(max_select, max(0, int(min_select)))
            if max_select <= 0:
                return CommandResult.ok(f"{zone_name}中无匹配的能量。")

            return CommandResult.ok(
                f"选择最多{max_select}个能量附着。",
                pending_choice=ActionRequest(
                    request_type="distribute_energy",
                    player=ctx.player_idx,
                    prompt=f"分配能量 — {zone_name}",
                    card_list=list(energy_cards[:max_select]),
                    target_info=targets_info,
                    distribute_mode="distribute",
                    min_select=min_select,
                    max_select=max_select,
                    max_per_target=max_per_target,
                    source_name=zone_name,
                    continuation={
                        "kind": "attach_energy_distribution",
                        "player_idx": ctx.player_idx,
                        "source_zone": from_zone,
                        "zone_name": zone_name,
                        "max_per_target": max_per_target,
                        "same_target": same_target,
                    },
                ),
            )

        def attach_to_target(target, amount_to_attach=amount):
            if target is None:
                if optional:
                    return CommandResult.ok("无目标宝可梦。")
                return CommandResult.fail("没有目标宝可梦。")
            if optional_count:
                matching = self._matching_energy_cards(source_pool, filter_type)
                energy_to_distribute = matching[:min(amount_to_attach, len(matching))]
                target_slot = self._slot_for_pokemon(player, target)
                return distribution(
                    energy_to_distribute,
                    [{"slot": target_slot, "name": target.card.name}],
                    min_select=min_attach,
                    max_select=len(energy_to_distribute),
                    max_per_target=amount_to_attach,
                    same_target=True,
                )
            return self._attach_immediate(ctx, source_pool, zone_name, from_zone, filter_type, amount_to_attach, target)

        if to_target == "self":
            return attach_to_target(player.get_pokemon(ctx.source_slot), amount)

        if to_target == "bench":
            bench_slots = [(index, pokemon) for index, pokemon in enumerate(player.bench) if pokemon is not None]
            if not bench_slots:
                return CommandResult.ok("备战区无宝可梦。") if optional else CommandResult.fail("备战区没有宝可梦可附着能量。")
            if len(bench_slots) == 1:
                target_slot = f"bench_{bench_slots[0][0]}"
                target = player.get_pokemon(target_slot)
                if optional_count:
                    matching = self._matching_energy_cards(source_pool, filter_type)
                    energy_to_distribute = matching[:min(min(amount, max_per_target), len(matching))]
                    return distribution(
                        energy_to_distribute,
                        [{"slot": target_slot, "name": target.card.name, "bench_idx": bench_slots[0][0]}],
                        min_select=min_attach,
                        max_select=len(energy_to_distribute),
                        max_per_target=max_per_target,
                    )
                return attach_to_target(target, min(amount, max_per_target))
            if amount <= 1:
                return CommandResult.ok(
                    "选择备战宝可梦附着能量。",
                    pending_choice=ActionRequest(
                        request_type="select_own_bench_energy",
                        player=ctx.player_idx,
                        prompt="选择1只备战宝可梦附着能量。",
                        min_select=0 if optional_count else 1,
                        max_select=1,
                        bench_indices=[index for index, _pokemon in bench_slots],
                        can_cancel=optional_count,
                        continuation={
                            "kind": "attach_energy_to_bench",
                            "player_idx": ctx.player_idx,
                            "source_zone": from_zone,
                            "zone_name": zone_name,
                            "filter_type": filter_type,
                            "amount": amount,
                            "optional": optional,
                        },
                    ),
                )
            matching = self._matching_energy_cards(source_pool, filter_type)
            targets_info = [
                {"slot": f"bench_{index}", "name": pokemon.card.name, "bench_idx": index}
                for index, pokemon in bench_slots
            ]
            capacity = max(0, len(targets_info) * max_per_target)
            energy_to_distribute = matching[:min(amount, capacity)]
            return distribution(
                energy_to_distribute,
                targets_info,
                min_select=min_attach if optional_count else len(energy_to_distribute),
                max_select=len(energy_to_distribute),
                max_per_target=max_per_target,
            )

        if to_target in {"any", "self_basic"}:
            candidates = []
            for slot_name, pokemon in player.get_all_pokemon():
                if pokemon is None:
                    continue
                if to_target == "self_basic" and not pokemon.card.is_basic_pokemon:
                    continue
                candidates.append((slot_name, pokemon))
            if not candidates:
                message = "没有基础宝可梦可附着能量。" if to_target == "self_basic" else "场上没有宝可梦可附着能量。"
                return CommandResult.ok(message) if optional else CommandResult.fail(message)
            if len(candidates) == 1:
                return attach_to_target(candidates[0][1], amount)
            if optional_count:
                matching = self._matching_energy_cards(source_pool, filter_type)
                energy_to_distribute = matching[:min(amount, len(matching))]
                return distribution(
                    energy_to_distribute,
                    [{"slot": slot_name, "name": pokemon.card.name} for slot_name, pokemon in candidates],
                    min_select=min_attach,
                    max_select=len(energy_to_distribute),
                    max_per_target=amount,
                    same_target=True,
                )

            return CommandResult.ok(
                "选择1只宝可梦附着能量。",
                pending_choice=ActionRequest(
                    request_type="search_deck",
                    player=ctx.player_idx,
                    prompt="选择1只宝可梦附着能量。",
                    min_select=1,
                    max_select=1,
                    from_zone="board",
                    target_player="self",
                    card_list=[pokemon.card for _slot_name, pokemon in candidates],
                    continuation={
                        "kind": "attach_energy_to_board",
                        "player_idx": ctx.player_idx,
                        "source_zone": from_zone,
                        "zone_name": zone_name,
                        "filter_type": filter_type,
                        "amount": amount,
                        "optional": optional,
                    },
                ),
            )

        return attach_to_target(player.get_pokemon(to_target), amount)

    @staticmethod
    def _energy_source(player, from_zone: str):
        return (player.hand, "手牌") if from_zone == "hand" else (player.deck, "牌库")

    @staticmethod
    def _matching_energy_cards(source_zone, filter_type: str):
        filter_type = str(filter_type or "any").lower()
        return [
            card for card in source_zone
            if getattr(card, "is_energy", False)
            and (
                filter_type in {"any", "energy"}
                or (filter_type in {"basic", "basic_energy"} and getattr(card, "is_basic_energy", False))
                or any(str(energy_type).lower() == filter_type for energy_type in getattr(card, "provides_energy", []))
            )
        ]

    @staticmethod
    def _slot_for_pokemon(player, target_pokemon):
        for slot_name, pokemon in player.get_all_pokemon():
            if pokemon is target_pokemon:
                return slot_name
        return ""

    def _attach_immediate(
        self,
        ctx: ResolutionContext,
        source_pool,
        zone_name: str,
        from_zone: str,
        filter_type: str,
        amount: int,
        target,
        optional: bool = False,
    ) -> CommandResult:
        from engine.commands.base import CommandResult

        if target is None:
            return CommandResult.ok("无目标宝可梦。") if optional else CommandResult.fail("没有目标宝可梦。")
        matching = self._matching_energy_cards(source_pool, filter_type)
        if not matching and optional:
            return CommandResult.ok(f"{zone_name}中无匹配的能量。")
        attached = 0
        for card in matching[:min(amount, len(matching))]:
            if card in source_pool:
                source_pool.remove(card)
                target.energy_cards.append(card)
                attached += 1
        if from_zone == "deck":
            ctx.player.shuffle_deck()
        ctx.state._log(f"从{zone_name}向{target.card.name}附着了{attached}个能量。")
        return CommandResult.ok(f"Attached {attached} energy from {from_zone}.")

    @staticmethod
    def _command_to_action(command_result: CommandResult):
        from engine.game_state import ActionResult

        return ActionResult(
            command_result.success,
            command_result.log_message,
            cards_drawn=command_result.cards_drawn,
            cards_discarded=command_result.cards_discarded,
            pending_action=command_result.pending_choice,
        )


@dataclass
class AttachEnergyFromDiscard:
    """Attach matching basic energy from discard to legal targets."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        amount = int(self.params.get("amount", 1) or 1)
        energy_type = str(self.params.get("energy_type", "any") or "any")
        target_spec = str(self.params.get("target", "self") or "self")
        target_pokemon_type = str(self.params.get("target_pokemon_type", "") or "")
        optional_count = bool("min_select" in self.params or self.params.get("optional", False))

        matching = self._matching_discard_energy(player.discard, energy_type)
        count = min(amount, len(matching))
        min_attach = min(count, int(self.params.get("min_select", count if not optional_count else 0) or 0))
        if count == 0:
            return CommandResult.ok("弃牌区没有符合条件的能量。")

        def request_distribution(
            energy_cards,
            targets_info,
            *,
            min_select,
            max_select,
            max_per_target=99,
            same_target=False,
        ):
            max_select = min(max(0, int(max_select)), len(energy_cards))
            min_select = min(max_select, max(0, int(min_select)))
            if max_select <= 0:
                return CommandResult.ok("弃牌区没有符合条件的能量。")

            return CommandResult.ok(
                f"选择最多{max_select}个能量附着。",
                pending_choice=ActionRequest(
                    request_type="distribute_energy",
                    player=ctx.player_idx,
                    prompt="分配能量 — 弃牌区",
                    card_list=list(energy_cards[:max_select]),
                    target_info=targets_info,
                    distribute_mode="distribute",
                    min_select=min_select,
                    max_select=max_select,
                    max_per_target=max_per_target,
                    source_name="弃牌区",
                    continuation={
                        "kind": "attach_discard_energy_distribution",
                        "player_idx": ctx.player_idx,
                        "max_per_target": max_per_target,
                        "same_target": same_target,
                    },
                ),
            )

        if target_spec == "self":
            target_pokemon = player.active
            if target_pokemon is None:
                return CommandResult.fail("没有战斗宝可梦。")
            if not self._pokemon_matches_target_type(target_pokemon, target_pokemon_type):
                return CommandResult.ok("没有符合条件的附着目标。")
            if optional_count:
                return request_distribution(
                    matching[:count],
                    [{"slot": "active", "name": target_pokemon.card.name}],
                    min_select=min_attach,
                    max_select=count,
                    max_per_target=count,
                    same_target=True,
                )
            return self._attach_immediate(ctx, matching, count, target_pokemon, energy_type)

        if target_spec == "bench":
            bench_slots = [
                (index, pokemon)
                for index, pokemon in enumerate(player.bench)
                if pokemon is not None and self._pokemon_matches_target_type(pokemon, target_pokemon_type)
            ]
            if not bench_slots:
                return CommandResult.ok("备战区无符合条件的宝可梦。")
            if len(bench_slots) == 1:
                bench_index, target_pokemon = bench_slots[0]
                if optional_count:
                    return request_distribution(
                        matching[:count],
                        [{"slot": f"bench_{bench_index}", "name": target_pokemon.card.name, "bench_idx": bench_index}],
                        min_select=min_attach,
                        max_select=count,
                        max_per_target=count,
                    )
                return self._attach_immediate(ctx, matching, count, target_pokemon, energy_type)
            if count <= 1:
                return CommandResult.ok(
                    "选择备战宝可梦附着能量。",
                    pending_choice=ActionRequest(
                        request_type="select_own_bench_energy",
                        player=ctx.player_idx,
                        prompt="选择1只备战宝可梦附着能量。",
                        min_select=0 if optional_count else 1,
                        max_select=1,
                        bench_indices=[index for index, _pokemon in bench_slots],
                        can_cancel=optional_count,
                        continuation={
                            "kind": "attach_discard_energy_to_bench",
                            "player_idx": ctx.player_idx,
                            "count": count,
                            "energy_type": energy_type,
                        },
                    ),
                )
            energy_to_distribute = matching[:count]
            targets_info = [
                {"slot": f"bench_{index}", "name": pokemon.card.name, "bench_idx": index}
                for index, pokemon in bench_slots
            ]
            return request_distribution(
                energy_to_distribute,
                targets_info,
                min_select=min_attach if optional_count else len(energy_to_distribute),
                max_select=len(energy_to_distribute),
            )

        if target_spec == "self_or_bench":
            all_pokemon = []
            if player.active and self._pokemon_matches_target_type(player.active, target_pokemon_type):
                all_pokemon.append(("active", player.active))
            for index, pokemon in enumerate(player.bench):
                if pokemon is not None and self._pokemon_matches_target_type(pokemon, target_pokemon_type):
                    all_pokemon.append((f"bench_{index}", pokemon))
            if not all_pokemon:
                return CommandResult.fail("没有目标宝可梦。")
            if optional_count:
                return request_distribution(
                    matching[:count],
                    [{"slot": slot_name, "name": pokemon.card.name} for slot_name, pokemon in all_pokemon],
                    min_select=min_attach,
                    max_select=count,
                    max_per_target=count,
                    same_target=True,
                )
            if len(all_pokemon) == 1:
                return self._attach_immediate(ctx, matching, count, all_pokemon[0][1], energy_type)

            return CommandResult.ok(
                "选择1只宝可梦附着能量。",
                pending_choice=ActionRequest(
                    request_type="search_deck",
                    player=ctx.player_idx,
                    prompt="选择1只宝可梦附着能量。",
                    min_select=1,
                    max_select=1,
                    from_zone="board",
                    target_player="self",
                    card_list=[pokemon.card for _slot_name, pokemon in all_pokemon],
                    continuation={
                        "kind": "attach_discard_energy_to_board",
                        "player_idx": ctx.player_idx,
                        "count": count,
                        "energy_type": energy_type,
                    },
                ),
            )

        return CommandResult.fail(f"未知目标: {target_spec}")

    @staticmethod
    def _matching_discard_energy(discard, energy_type: str):
        energy_type = str(energy_type or "any").lower()
        return [
            card for card in discard
            if getattr(card, "is_basic_energy", False)
            and (
                energy_type in {"any", "basic", "basic_energy"}
                or any(str(provided).lower() == energy_type for provided in getattr(card, "provides_energy", []))
            )
        ]

    @staticmethod
    def _pokemon_matches_target_type(pokemon, target_type: str) -> bool:
        normalized = str(target_type or "").lower()
        if not normalized:
            return True
        return any(str(card_type).lower() == normalized for card_type in pokemon.card.energy_types)

    def _attach_immediate(self, ctx: ResolutionContext, matching, count: int, target_pokemon, energy_type: str):
        from engine.commands.base import CommandResult

        attached = 0
        for card in list(matching[:count]):
            if card in ctx.player.discard:
                ctx.player.discard.remove(card)
                target_pokemon.energy_cards.append(card)
                attached += 1
        ctx.state._log(f"从弃牌区将{attached}个{energy_type}能量附着于{target_pokemon.card.name}。")
        return CommandResult.ok(f"从弃牌区附着了{attached}个能量。")

    @staticmethod
    def _command_to_action(command_result: CommandResult):
        from engine.game_state import ActionResult

        return ActionResult(
            command_result.success,
            command_result.log_message,
            cards_drawn=command_result.cards_drawn,
            cards_discarded=command_result.cards_discarded,
            pending_action=command_result.pending_choice,
        )


@dataclass
class EnergyRelocate:
    """Move attached energy between the player's Pokemon."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest, ActionResult

        player = ctx.player
        amount = int(self.params.get("amount", 2) or 2)
        from_self = bool(self.params.get("from_self", False))
        energy_type = str(self.params.get("energy_type", self.params.get("filter", "any")) or "any")
        same_target = bool(self.params.get("same_target", False))
        optional_count = bool("min_select" in self.params or self.params.get("optional", False))

        if from_self:
            source_pokemon = player.active
            matching_source = (
                self._matching_energy_cards(source_pokemon.energy_cards, energy_type)
                if source_pokemon is not None else []
            )
            if source_pokemon is None or not matching_source:
                return CommandResult.ok("没有能量可转附。")

            bench_pokemon = [(index, pokemon) for index, pokemon in enumerate(player.bench) if pokemon is not None]
            if not bench_pokemon:
                return CommandResult.ok("备战区没有宝可梦可转附能量。")

            move_count = min(amount, len(matching_source))
            min_move = min(move_count, int(self.params.get("min_select", move_count if not optional_count else 0) or 0))

            if len(bench_pokemon) == 1:
                bench_index, target_pokemon = bench_pokemon[0]
                if optional_count:
                    return self._request_distribution(
                        ctx,
                        source_pokemon,
                        list(matching_source[:move_count]),
                        [{"slot": f"bench_{bench_index}", "name": target_pokemon.card.name, "bench_idx": bench_index}],
                        min_select=min_move,
                        max_select=move_count,
                        max_per_target=move_count,
                    )
                moved = self._move_energy(ctx, source_pokemon, target_pokemon, matching_source, move_count)
                return CommandResult.ok(
                    f"将{moved}个能量从{source_pokemon.card.name}转附到{target_pokemon.card.name}。"
                )

            energy_to_move = list(matching_source[:move_count])
            return self._request_distribution(
                ctx,
                source_pokemon,
                energy_to_move,
                [
                    {"slot": f"bench_{index}", "name": pokemon.card.name, "bench_idx": index}
                    for index, pokemon in bench_pokemon
                ],
                min_select=min_move,
                max_select=move_count,
            )

        all_pokemon = [
            (slot_name, pokemon)
            for slot_name, pokemon in player.get_all_pokemon()
            if pokemon is not None
            and self._matching_energy_cards(pokemon.energy_cards, energy_type)
        ]
        if not all_pokemon:
            return CommandResult.ok("场上没有宝可梦附着能量。")

        if sum(1 for _slot_name, pokemon in player.get_all_pokemon() if pokemon is not None) <= 1:
            return CommandResult.ok("没有其他宝可梦可转附能量。")

        source_options = []
        for slot_name, pokemon in all_pokemon:
            source_options.append({
                "slot": slot_name,
                "name": pokemon.card.name,
                "bench_idx": int(slot_name.split("_")[1]) if slot_name.startswith("bench_") else -1,
            })

        return CommandResult.ok(
            "选择来源宝可梦。",
            pending_choice=ActionRequest(
                request_type="distribute_energy",
                player=ctx.player_idx,
                prompt="选择来源宝可梦",
                card_list=[],
                target_info=source_options,
                distribute_mode="source_select",
                source_name="选择来源",
                continuation={
                    "kind": "energy_relocate_source",
                    "player_idx": ctx.player_idx,
                    "amount": amount,
                    "energy_type": energy_type,
                    "same_target": same_target,
                    "optional_count": optional_count,
                    "min_select": self.params.get("min_select", None),
                },
            ),
        )

    @staticmethod
    def _matching_energy_cards(cards, energy_type: str):
        energy_type = str(energy_type or "any").lower()
        return [
            card for card in cards
            if getattr(card, "is_energy", False)
            and (
                energy_type in {"any", "energy"}
                or (energy_type in {"basic", "basic_energy"} and getattr(card, "is_basic_energy", False))
                or any(str(provided).lower() == energy_type for provided in getattr(card, "provides_energy", []))
            )
        ]

    def _request_distribution(
        self,
        ctx: ResolutionContext,
        source_pokemon,
        energy_cards,
        targets_info,
        *,
        min_select,
        max_select,
        max_per_target=99,
        same_target=False,
        mode="distribute",
    ) -> CommandResult:
        from engine.commands.base import CommandResult

        return CommandResult.ok(
            "选择能量卡分配到宝可梦。",
            pending_choice=self._distribution_request(
                ctx,
                source_pokemon,
                energy_cards,
                targets_info,
                min_select=min_select,
                max_select=max_select,
                max_per_target=max_per_target,
                same_target=same_target,
                mode=mode,
            ),
        )

    @staticmethod
    def _distribution_request(
        ctx: ResolutionContext,
        source_pokemon,
        energy_cards,
        targets_info,
        *,
        min_select,
        max_select,
        max_per_target=99,
        same_target=False,
        mode="distribute",
    ):
        from engine.game_state import ActionRequest

        max_select = min(max(0, int(max_select)), len(energy_cards))
        min_select = min(max_select, max(0, int(min_select)))
        source_slot = ""
        for slot_name, pokemon in ctx.player.get_all_pokemon():
            if pokemon is source_pokemon:
                source_slot = slot_name
                break

        return ActionRequest(
            request_type="distribute_energy",
            player=ctx.player_idx,
            prompt=f"分配能量 — {source_pokemon.card.name}",
            card_list=list(energy_cards[:max_select]),
            target_info=targets_info,
            distribute_mode=mode,
            min_select=min_select,
            max_select=max_select,
            max_per_target=max_per_target,
            source_name=source_pokemon.card.name,
            continuation={
                "kind": "energy_relocate_distribution",
                "player_idx": ctx.player_idx,
                "source_slot": source_slot,
                "max_per_target": max_per_target,
                "same_target": same_target,
            },
        )

    def _move_energy(self, ctx: ResolutionContext, source_pokemon, target_pokemon, matching_source, move_count: int) -> int:
        moved = 0
        for card in list(matching_source[:move_count]):
            if card in source_pokemon.energy_cards:
                source_pokemon.energy_cards.remove(card)
                target_pokemon.energy_cards.append(card)
                moved += 1
        ctx.state._log(f"将{moved}个能量从{source_pokemon.card.name}转附到{target_pokemon.card.name}。")
        return moved


@dataclass
class SearchItemAndTool:
    """Search the deck for up to one Item and up to one Tool."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest, ActionResult

        player = ctx.player
        available = [
            card for card in player.deck
            if getattr(card, "is_trainer_item", False) or getattr(card, "is_trainer_tool", False)
        ]
        if not available:
            return CommandResult.ok("牌库中没有物品卡或宝可梦道具卡。")

        return CommandResult.ok(
            "选择1张物品卡和1张宝可梦道具卡加入手牌。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt="选择1张「物品」和1张「宝可梦道具」（派帕）",
                min_select=1,
                max_select=min(2, len(available)),
                from_zone="deck",
                card_list=available,
                continuation={
                    "kind": "search_item_and_tool",
                    "player_idx": ctx.player_idx,
                },
            ),
        )


@dataclass
class TrekkingShoes:
    """Look at the top deck card; keep it or discard it and draw one."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        if not player.deck:
            return CommandResult.ok("牌库为空。")
        top_card = player.deck[-1]

        return CommandResult.ok(
            f"牌库顶是「{top_card.name}」。",
            pending_choice=ActionRequest(
                request_type="confirm",
                player=ctx.player_idx,
                prompt=f"牌库顶是「{top_card.name}」。是否放入手牌？\n（选「否」将丢弃此卡并抽1张）",
                continuation={
                    "kind": "trekking_shoes",
                    "player_idx": ctx.player_idx,
                    "top_card_id": getattr(top_card, "api_id", ""),
                    "top_card_name": getattr(top_card, "name", ""),
                },
            ),
        )


@dataclass
class CoinFlipSpecial:
    """Native coin-flip attack variants with fixed post-flip resolution."""

    coin_kind: str = "repeat_damage"
    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        coin_kind = str(self.coin_kind or "repeat_damage")
        params = dict(self.params or {})

        if coin_kind == "until_tails":
            prompt = "掷硬币直到出现反面（连续旋转）"
            flip_count = 1
            until_tails = True
        elif coin_kind == "double_ko":
            prompt = "掷2次硬币"
            flip_count = 2
            until_tails = False
        else:
            flip_count = int(params.get("flips", 3) or 3)
            prompt = f"掷{flip_count}次硬币"
            until_tails = False

        return CommandResult.ok(
            "掷硬币中...",
            pending_choice=ActionRequest(
                request_type="coin_flip",
                player=ctx.player_idx,
                prompt=prompt,
                flip_count=flip_count,
                until_tails=until_tails,
                continuation={
                    "kind": "coin_special",
                    "coin_kind": coin_kind,
                    "params": params,
                },
            ),
        )


@dataclass
class CoinFlipEnergyDiscard:
    """Flip a coin; on heads choose and discard one opponent energy."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        opponent_idx = 1 - ctx.player_idx
        opponent = ctx.state.get_player(opponent_idx)
        if not any(pokemon and pokemon.energy_cards for _slot, pokemon in opponent.get_all_pokemon()):
            return CommandResult.ok("对手场上没有能量可丢弃。")

        return CommandResult.ok(
            "掷硬币中...",
            pending_choice=ActionRequest(
                request_type="coin_flip",
                player=ctx.player_idx,
                prompt="掷1次硬币（粉碎之锤）",
                flip_count=1,
                continuation={"kind": "coin_energy_discard"},
            ),
        )


@dataclass
class Conditional:
    """VM conditional frame: optional precondition, then cost before on-pay branch."""

    params: dict = field(default_factory=dict)
    cost: list = field(default_factory=list)
    on_pay: list = field(default_factory=list)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        condition = str(self.params.get("condition", "") or "")
        if condition == "ko_by_attack_last_turn":
            if not ctx.player.was_ko_by_attack:
                ctx.state._log(f"{ctx.player.name}上个对手回合没有宝可梦因招式伤害昏厥，无法使用此卡。")
                return CommandResult.fail("不满足使用条件，卡牌保留在手牌中。")
            ctx.player.was_ko_by_attack = False

        sequence = list(self.cost or []) + list(self.on_pay or [])
        if sequence:
            try:
                ctx.stack.push_many([_build_branch_command(item) for item in sequence])
            except Exception as exc:
                return CommandResult.fail(str(exc))
        return CommandResult.ok("条件效果已结算。")


@dataclass
class ConditionalSearchExtra:
    """Search more cards on the second player's first turn."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        search_count = (
            int(self.params.get("max_count", 3) or 3)
            if ctx.state.is_going_second_first_turn(ctx.player_idx)
            else int(self.params.get("default_count", 1) or 1)
        )
        max_count = int(self.params.get("max_count", search_count) or search_count)
        return SearchCards(params={
            "from_zone": "deck",
            "filter": str(self.params.get("filter", "grass_pokemon") or "grass_pokemon"),
            "destination": "hand",
            "count": search_count,
            "min_select": 0 if search_count == max_count else 1,
        }).execute(ctx)


@dataclass
class SearchAnyAndSwitch:
    """Search deck for any cards, then optionally switch the source Pokemon."""

    params: dict = field(default_factory=dict)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        player = ctx.player
        if not player.deck:
            return CommandResult.ok("牌库中没有卡。")
        count = int(self.params.get("count", 2) or 2)
        min_select = int(self.params.get("min_select", 0) or 0)
        switch_optional = bool(self.params.get("switch_optional", True))

        return CommandResult.ok(
            f"从牌库选择最多{count}张任意卡。",
            pending_choice=ActionRequest(
                request_type="search_deck",
                player=ctx.player_idx,
                prompt=f"从牌库选择最多{count}张卡加入手牌（生存战略）",
                min_select=min_select,
                max_select=count,
                from_zone="deck",
                card_list=list(player.deck),
                can_cancel=min_select <= 0,
                continuation={
                    "kind": "search_any_and_switch",
                    "player_idx": ctx.player_idx,
                    "count": count,
                    "switch_optional": switch_optional,
                },
            ),
        )


@dataclass
class AbilityDiscardRevive:
    """Revive a named Pokemon from discard when the player's hand is empty."""

    card_id: str = ""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        player = ctx.player
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
        from engine.commands.modifier_registration import (
            register_pokemon_modifiers,
            unregister_pokemon_modifiers,
        )
        from engine.commands.registry import build_command
        from engine.commands.resolution_stack import ResolutionStack

        player = ctx.player
        if ctx.state.is_player_first_turn(ctx.player_idx):
            return CommandResult.fail("第一回合不能使用神奇糖果。")

        basic_slots = []
        for slot_name, pokemon in player.get_all_pokemon():
            if pokemon is None or not pokemon.card.is_basic_pokemon:
                continue
            if pokemon.placed_this_turn or not pokemon.can_evolve_this_turn:
                continue
            matching_stage2 = [
                card
                for card in player.hand
                if getattr(card, "is_stage2", False)
                and self._stage2_matches_basic(card, pokemon.card.name)
            ]
            if matching_stage2:
                basic_slots.append((slot_name, pokemon, matching_stage2))

        if not basic_slots:
            ctx.state._log(f"{player.name}场上没有符合条件的基础宝可梦可以使用神奇糖果。")
            return CommandResult.fail("没有有效的进化目标，卡牌保留在手牌中。")

        slot_name, pokemon, stage2_cards = basic_slots[0]
        stage2 = stage2_cards[0]
        old_name = pokemon.card.name
        old_api_id = pokemon.card.api_id
        hand_idx = player.hand.index(stage2)
        player.hand.pop(hand_idx)
        player.evolve_pokemon(slot_name, stage2)

        unregister_pokemon_modifiers(
            old_api_id,
            slot_name,
            event_bus=ctx.state.event_bus,
            player_idx=ctx.player_idx,
        )
        register_pokemon_modifiers(pokemon, ctx.player_idx, slot_name, event_bus=ctx.state.event_bus)

        for ability in stage2.abilities or []:
            if ability.trigger == "on_enter_play":
                stack = ResolutionStack(ctx.state)
                stack.push_many([build_command(effect) for effect in ability.effects])
                stack.resolve_all(ctx.player_idx, slot_name)

        ctx.state._log(f"{player.name}使用神奇糖果将{old_name}进化成了{stage2.name}！")
        return CommandResult.ok(f"Rare Candy: {old_name} -> {stage2.name}")

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
        from engine.game_state import ActionRequest, ActionResult
        from engine.actions import PokemonRef, resolve_pokemon_ref

        player_idx = ctx.player_idx if self.target_player == "self" else 1 - ctx.player_idx
        player = ctx.state.get_player(player_idx)
        injured = [
            (slot_name, pokemon)
            for slot_name, pokemon in player.get_all_pokemon()
            if pokemon is not None and pokemon.damage_counters > 0
        ]

        if not injured:
            return CommandResult.fail("没有受伤的宝可梦，卡牌保留在手牌中。")

        def heal_target(slot_name, pokemon):
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


# ═══════════════════════════════════════════════════════
# 6. FlipCoin — coin flip with conditional branches
# ═══════════════════════════════════════════════════════

@dataclass
class FlipCoin:
    on_heads: list = field(default_factory=list)  # list of effect dicts
    on_tails: list = field(default_factory=list)

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult
        from engine.game_state import ActionRequest

        return CommandResult.ok(
            "掷硬币中...",
            pending_choice=ActionRequest(
                request_type="coin_flip",
                player=ctx.player_idx,
                prompt="掷1次硬币",
                flip_count=1,
                continuation={
                    "kind": "flip_coin_branch",
                    "on_heads": _branch_payload(self.on_heads),
                    "on_tails": _branch_payload(self.on_tails),
                },
            ),
        )


def _branch_payload(items):
    payload = []
    for item in items or []:
        if hasattr(item, "to_dict"):
            payload.append(item.to_dict())
        elif hasattr(item, "effect_type"):
            payload.append({
                "effect_type": str(getattr(item, "effect_type", "") or ""),
                "params": dict(getattr(item, "params", {}) or {}),
            })
        elif isinstance(item, dict):
            payload.append(dict(item))
        else:
            payload.append(item)
    return payload


def _build_branch_command(item):
    if isinstance(item, dict) and "op" in item:
        from engine.commands.dsl_compiler import compile_command_spec

        return compile_command_spec(item)
    from engine.commands.registry import build_command

    return build_command(item)


# ═══════════════════════════════════════════════════════
# 7. SwitchPokemon — swap active with bench
# ═══════════════════════════════════════════════════════

@dataclass
class SwitchPokemon:
    target: str = "self"  # 'self' or 'opponent'
    optional: bool = False
    you_choose: bool = False  # When True and target="opponent", the card player chooses

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
            # Ask the player first, then show bench selection only if confirmed
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
                min_select=1, max_select=1,
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
        from engine.game_state import ActionRequest, ActionResult

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
        elif self.from_zone == "deck":
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

        ctx.state._piercing_attack = True
        attack_ctx = getattr(ctx.state, "_attack_damage_context", None)
        if isinstance(attack_ctx, dict):
            if self.ignore_weakness or self.ignore_resistance:
                attack_ctx["piercing"] = True
            if self.ignore_effects:
                attack_ctx["ignore_defender_effects"] = True
                ctx.state._attack_ignore_defender_effects = True
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

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.base import CommandResult

        target = ctx.player.get_pokemon(ctx.source_slot)
        if target and self.attack_name:
            target.attack_locked_names[self.attack_name] = ctx.state.turn_number
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
