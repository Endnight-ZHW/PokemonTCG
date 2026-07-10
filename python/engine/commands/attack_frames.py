"""Commands and helpers for stack-driven attack settlement."""
from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from engine.commands.base import CommandResult
from engine.commands.damage_pipeline import resolve_damage
from engine.enums import EventType, PlayerAction, TurnPhase
from engine.rules_constants import DAMAGE_PER_COUNTER

ATTACK_DAMAGE_CONTEXT_KEY = "attack_damage"
FINISH_ATTACK_AFTER_PROMOTIONS_KEY = "finish_attack_after_promotions"


if TYPE_CHECKING:
    from engine.commands.base import ResolutionContext
    from engine.game_state import GameState


def begin_attack_damage_context(state: GameState, stack, context: dict) -> dict:
    stack.context[ATTACK_DAMAGE_CONTEXT_KEY] = context
    return context


def attack_damage_context(state: GameState, stack=None) -> dict | None:
    if stack is not None:
        stack_context = getattr(stack, "context", {})
        context = stack_context.get(ATTACK_DAMAGE_CONTEXT_KEY)
        if isinstance(context, dict):
            return context
    return None


def clear_attack_damage_context(state: GameState, stack=None) -> None:
    if stack is not None:
        stack_context = getattr(stack, "context", {})
        if isinstance(stack_context, dict):
            stack_context.pop(ATTACK_DAMAGE_CONTEXT_KEY, None)


def _resolution_stack_context(state: GameState) -> dict:
    stack_data = getattr(state, "resolution_stack", None)
    if not isinstance(stack_data, dict):
        stack_data = {"frames": [], "pending_request": None, "sequence": 0, "context": {}}
        state.resolution_stack = stack_data
    context = stack_data.get("context")
    if not isinstance(context, dict):
        context = {}
        stack_data["context"] = context
    return context


def set_finish_attack_after_promotions(state: GameState, actor: int) -> None:
    _resolution_stack_context(state)[FINISH_ATTACK_AFTER_PROMOTIONS_KEY] = int(actor)


def finish_attack_after_promotions_actor(state: GameState) -> int | None:
    value = _resolution_stack_context(state).get(FINISH_ATTACK_AFTER_PROMOTIONS_KEY)
    if type(value) is int and value in (0, 1):
        return int(value)
    return None


def clear_finish_attack_after_promotions(state: GameState) -> None:
    _resolution_stack_context(state).pop(FINISH_ATTACK_AFTER_PROMOTIONS_KEY, None)


def attack_context_for_opponent_active(
    state: GameState,
    player_idx: int,
    opponent,
    stack=None,
) -> dict | None:
    context = attack_damage_context(state, stack)
    if not isinstance(context, dict) or not context.get("active"):
        return None
    if int(context.get("player_idx", -1)) != int(player_idx):
        return None
    if getattr(opponent, "active", None) is None:
        return None
    return context


def add_attack_damage(
    state: GameState,
    player_idx: int,
    opponent,
    amount: int,
    *,
    stack=None,
) -> bool:
    context = attack_context_for_opponent_active(state, player_idx, opponent, stack)
    if context is None:
        return False
    context["base_damage"] = int(context.get("base_damage", 0) or 0) + int(amount or 0)
    return True


def set_attack_damage_total(
    state: GameState,
    player_idx: int,
    opponent,
    amount: int,
    *,
    stack=None,
    piercing: bool | None = None,
    ignore_defender_effects: bool | None = None,
) -> bool:
    context = attack_context_for_opponent_active(state, player_idx, opponent, stack)
    if context is None:
        return False
    context["base_damage"] = int(amount or 0)
    if piercing is not None:
        context["piercing"] = bool(piercing)
    if ignore_defender_effects is not None:
        context["ignore_defender_effects"] = bool(ignore_defender_effects)
    return True


def set_attack_damage_flags(
    state: GameState,
    *,
    stack=None,
    piercing: bool | None = None,
    ignore_defender_effects: bool | None = None,
) -> dict | None:
    context = attack_damage_context(state, stack)
    if isinstance(context, dict):
        if piercing is not None:
            context["piercing"] = bool(piercing)
        if ignore_defender_effects is not None:
            context["ignore_defender_effects"] = bool(ignore_defender_effects)
        return context
    return None


def apply_accumulated_attack_damage(
    state: GameState,
    result: CommandResult,
    *,
    attack_failed: bool = False,
    trigger_commands: list | None = None,
    stack=None,
) -> None:
    ctx = attack_damage_context(state, stack)
    if not ctx:
        return
    clear_attack_damage_context(state, stack)
    if attack_failed:
        return

    player_idx = int(ctx.get("player_idx", state.active_player_idx))
    attacker = ctx.get("attacker") or state.get_player(player_idx).active
    defender = state.get_player(1 - player_idx).active
    base_damage = int(ctx.get("base_damage", 0) or 0)
    if attacker is None or defender is None or base_damage <= 0:
        return

    apply_attack_damage(
        state,
        defender,
        attacker,
        base_damage,
        str(ctx.get("attacker_type", "Colorless")),
        result,
        piercing=bool(ctx.get("piercing", False)),
        ignore_defender_effects=bool(ctx.get("ignore_defender_effects", False)),
        trigger_commands=trigger_commands,
    )


def apply_attack_damage(
    state: GameState,
    defender,
    attacker,
    base_damage: int,
    attacker_type: str,
    result: CommandResult,
    *,
    piercing: bool = False,
    ignore_defender_effects: bool = False,
    trigger_commands: list | None = None,
) -> None:
    if defender.damage_prevented_next_turn and not ignore_defender_effects:
        defender.damage_prevented_next_turn = False
        defender.all_prevented_next_turn = False
        state._log(f"{defender.card.name}免疫了所有伤害！")
        return

    final_damage, mod_logs = resolve_damage(
        state,
        attacker,
        defender,
        base_damage,
        attacker_type,
        piercing=piercing,
        ignore_defender_effects=ignore_defender_effects,
        trigger_commands=trigger_commands,
    )
    for log_msg in mod_logs:
        state._log(log_msg)

    defender.damage_counters += final_damage // DAMAGE_PER_COUNTER
    result.damage_dealt += final_damage
    state._log(
        f"对{defender.card.name}造成了{final_damage}点伤害"
        f"（剩余HP {defender.current_hp}）。"
    )


def do_attack_ko_checks(state: GameState, result: CommandResult) -> None:
    state._ko_from_attack = True
    try:
        result.pokemon_ko.extend(check_kos(state))
    finally:
        state._ko_from_attack = False

    for player_idx in (0, 1):
        player = state.get_player(player_idx)
        if player.active is None and player.has_any_pokemon_in_play():
            state.pending_promotion_player = player_idx

    from engine.rules_validator import check_win_condition

    winner = check_win_condition(state)
    if winner is not None:
        state.winner = winner
        state.phase = TurnPhase.GAME_OVER
        state._log(f"{state.get_player(winner).name}获胜！")


def check_kos(state: GameState) -> list[str]:
    ko_slots: list[str] = []
    for player_idx in (0, 1):
        player = state.get_player(player_idx)
        if player.active and player.active.is_knocked_out:
            ko_slots.append(f"p{player_idx}_active")
            handle_ko(state, player_idx, "active")

        for index, pokemon in enumerate(player.bench):
            if pokemon and pokemon.is_knocked_out:
                ko_slots.append(f"p{player_idx}_bench_{index}")
                handle_ko(state, player_idx, f"bench_{index}")
    return ko_slots


def handle_ko(state: GameState, player_idx: int, slot: str) -> None:
    from engine.commands.modifier_registration import unregister_pokemon_modifiers
    from engine.commands.trigger_commands import (
        command_specs_from_trigger_results,
        execute_trigger_commands,
    )

    player = state.get_player(player_idx)
    opponent = state.get_player(1 - player_idx)
    pokemon = player.get_pokemon(slot)
    if pokemon is None:
        return

    if state._ko_from_attack:
        player.was_ko_by_attack = True

    prize_count = pokemon.card.prize_value
    unregister_pokemon_modifiers(
        pokemon.card.api_id,
        slot,
        event_bus=state.event_bus,
        player_idx=player_idx,
    )

    hook_results = state.event_bus.emit(
        EventType.POKEMON_KO,
        state=state,
        player_idx=player_idx,
        slot=slot,
        knocked_out=pokemon,
        from_attack=bool(state._ko_from_attack),
    )
    hook_commands = command_specs_from_trigger_results(hook_results)
    if hook_commands:
        trigger_result = execute_trigger_commands(
            state,
            hook_commands,
            player_idx=player_idx,
            source_slot=slot,
        )
        if not trigger_result.success:
            raise ValueError(
                trigger_result.log_message
                or "Pokemon KO trigger settlement failed"
            )
    for hook_result in hook_results:
        if isinstance(hook_result, dict) and hook_result.get("log"):
            state._log(str(hook_result["log"]))

    state.discard_pokemon(player_idx, slot)
    state._log(f"{player.name}的{pokemon.card.name}被击倒了！")

    for _ in range(prize_count):
        if opponent.prizes:
            opponent.take_prize()
            state._log(
                f"{opponent.name}获得了奖品卡！"
                f"（剩余{len(opponent.prizes)}张）"
            )

    if not player.has_any_pokemon_in_play():
        state.winner = 1 - player_idx
        state.phase = TurnPhase.GAME_OVER
        state._log(f"{opponent.name}获胜——对手场上没有宝可梦了！")
        return

    if slot == "active":
        state.pending_promotion_player = player_idx


@dataclass
class FinalizeAttackDamage:
    """Final attack damage packet; trigger commands resolve before KO checks."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        result = CommandResult.ok()
        trigger_commands: list = []
        apply_accumulated_attack_damage(
            ctx.state,
            result,
            attack_failed=ctx.stack.attack_failed,
            trigger_commands=trigger_commands,
            stack=ctx.stack,
        )
        ctx.stack.push(FinalizeAttackKoChecks())
        if trigger_commands:
            from engine.commands.trigger_commands import push_trigger_command_specs

            push_trigger_command_specs(ctx.stack, trigger_commands)
        return result


@dataclass
class FinalizeAttackKoChecks:
    """Resolve KOs after attack-damage trigger commands have finished."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        result = CommandResult.ok()
        do_attack_ko_checks(ctx.state, result)
        return result


@dataclass
class FinalizeAttackTurn:
    """Finish an attack from inside the resolution stack when no promotion pauses it."""

    actor: int

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        if ctx.state.winner is not None or ctx.state.phase == TurnPhase.GAME_OVER:
            return CommandResult.ok()
        if ctx.state.pending_promotion_player >= 0:
            ctx.state.phase = TurnPhase.ATTACK
            set_finish_attack_after_promotions(ctx.state, self.actor)
            return CommandResult.ok()
        if ctx.state.phase == TurnPhase.MAIN:
            ctx.state.phase = TurnPhase.ATTACK
        if ctx.state.phase != TurnPhase.ATTACK:
            return CommandResult.ok()

        from engine.turn_manager import TurnManager

        result = TurnManager(ctx.state).perform_action(
            PlayerAction.END_TURN,
            player_idx=self.actor,
            bump_revision=False,
        )
        return CommandResult(
            success=result.success,
            log_message=result.log_message,
            damage_dealt=result.damage_dealt,
            cards_drawn=result.cards_drawn,
            cards_discarded=result.cards_discarded,
            pokemon_ko=result.pokemon_ko,
            status_applied=result.status_applied,
            pending_choice=result.pending_action,
            attack_failed=result.attack_failed,
        )
