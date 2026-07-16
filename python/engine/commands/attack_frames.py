"""Commands and helpers for stack-driven attack settlement."""
from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from engine.commands.base import CommandResult
from engine.commands.damage_pipeline import resolve_damage
from engine.enums import EventType, PlayerAction, TurnPhase
from engine.rules_constants import DAMAGE_PER_COUNTER

ATTACK_DAMAGE_CONTEXT_KEY = "attack_damage"
ATTACK_RESOLUTION_CONTEXT_KEY = "attack_resolution"
PENDING_AFTER_DAMAGE_TRIGGERS_KEY = "pending_after_damage_trigger_specs"
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


def begin_attack_resolution_context(stack, player_idx: int) -> None:
    """Mark commands in this stack as consequences of one declared attack."""
    stack.context[ATTACK_RESOLUTION_CONTEXT_KEY] = {
        "active": True,
        "player_idx": int(player_idx),
    }


def clear_attack_resolution_context(stack=None) -> None:
    if stack is None:
        return
    stack_context = getattr(stack, "context", {})
    if isinstance(stack_context, dict):
        stack_context.pop(ATTACK_RESOLUTION_CONTEXT_KEY, None)


def is_opponent_attack_effect(state: GameState, stack, pokemon) -> bool:
    """Return whether ``pokemon`` is targeted by the marked opponent attack.

    The marker deliberately outlives the primary damage frame so protection
    applies to every effect of the attack, including commands resumed after a
    choice. Trainer and Ability stacks do not carry this marker.
    """
    if stack is None or pokemon is None:
        return False
    stack_context = getattr(stack, "context", {})
    context = (
        stack_context.get(ATTACK_RESOLUTION_CONTEXT_KEY)
        if isinstance(stack_context, dict)
        else None
    )
    if not isinstance(context, dict) or not context.get("active"):
        return False
    player_idx = context.get("player_idx", -1)
    if type(player_idx) is not int or player_idx not in (0, 1):
        return False
    return any(
        candidate is pokemon
        for _slot, candidate in state.get_player(1 - player_idx).get_all_pokemon()
    )


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


def finalize_game_over_if_needed(state: GameState, *, reason: str = "knockout") -> int | None:
    """Finalize a terminal rules state once, after the whole KO batch."""
    from engine.events.game_events import GameEvent
    from engine.rules_validator import evaluate_game_result

    status, evaluated_winner, conditions = evaluate_game_result(state)
    if state.winner in (0, 1):
        status, evaluated_winner = "WIN", int(state.winner)
    state.result_conditions = [list(row) for row in conditions]
    if status == "ONGOING":
        state.result_status = "ONGOING"
        state.result_reason = "NONE"
        return None

    winner = evaluated_winner

    was_terminal = (
        state.phase == TurnPhase.GAME_OVER
        and state.result_status == status
        and state.winner == winner
    )
    state.set_result(
        status,
        winner=(int(winner) if winner in (0, 1) else -1),
        reason="RULE_CONDITIONS",
        conditions=[list(row) for row in conditions],
    )
    state.pending_promotions.clear()
    clear_finish_attack_after_promotions(state)
    if not was_terminal:
        if status == "DRAW":
            state._log("双方同时达成相同数量的胜利条件，本局平局。")
        else:
            state._log(f"{state.get_player(winner).name}获胜！")

    events = getattr(getattr(state, "event_stream", None), "_events", ())
    if not any(getattr(event, "event_type", "") == "game_over" for event in events):
        state.event_stream.push(GameEvent(
            "game_over",
            {
                "winner": int(winner) if winner in (0, 1) else -1,
                "result_status": status,
                "reason": str(reason or "knockout"),
                "conditions": [list(row) for row in conditions],
            },
        ))
    return int(winner) if winner in (0, 1) else None


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
    ignore_weakness: bool | None = None,
    ignore_resistance: bool | None = None,
    ignore_defender_damage_effects: bool | None = None,
) -> bool:
    context = attack_context_for_opponent_active(state, player_idx, opponent, stack)
    if context is None:
        return False
    context["base_damage"] = int(amount or 0)
    if ignore_weakness is not None:
        context["ignore_weakness"] = bool(ignore_weakness)
    if ignore_resistance is not None:
        context["ignore_resistance"] = bool(ignore_resistance)
    if ignore_defender_damage_effects is not None:
        context["ignore_defender_damage_effects"] = bool(ignore_defender_damage_effects)
    return True


def set_attack_damage_flags(
    state: GameState,
    *,
    stack=None,
    ignore_weakness: bool | None = None,
    ignore_resistance: bool | None = None,
    ignore_defender_damage_effects: bool | None = None,
) -> dict | None:
    context = attack_damage_context(state, stack)
    if isinstance(context, dict):
        if ignore_weakness is not None:
            context["ignore_weakness"] = bool(ignore_weakness)
        if ignore_resistance is not None:
            context["ignore_resistance"] = bool(ignore_resistance)
        if ignore_defender_damage_effects is not None:
            context["ignore_defender_damage_effects"] = bool(ignore_defender_damage_effects)
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
        ignore_weakness=bool(ctx.get("ignore_weakness", False)),
        ignore_resistance=bool(ctx.get("ignore_resistance", False)),
        ignore_defender_damage_effects=bool(
            ctx.get("ignore_defender_damage_effects", False)
        ),
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
    ignore_weakness: bool = False,
    ignore_resistance: bool = False,
    ignore_defender_damage_effects: bool = False,
    trigger_commands: list | None = None,
) -> None:
    final_damage, mod_logs = resolve_damage(
        state,
        attacker,
        defender,
        base_damage,
        attacker_type,
        ignore_weakness=ignore_weakness,
        ignore_resistance=ignore_resistance,
        ignore_defender_damage_effects=ignore_defender_damage_effects,
        trigger_commands=trigger_commands,
    )
    for log_msg in mod_logs:
        state._log(log_msg)

    before_hp = defender.current_hp
    defender.damage_counters += final_damage // DAMAGE_PER_COUNTER
    if final_damage > 0 and before_hp > 0 and defender.current_hp <= 0:
        defender.pending_ko_cause = "attack_damage"
    result.damage_dealt += final_damage
    state._log(
        f"对{defender.card.name}造成了{final_damage}点伤害"
        f"（剩余HP {defender.current_hp}）。"
    )


def do_attack_ko_checks(state: GameState, result: CommandResult, *, stack=None) -> None:
    if stack is not None:
        queue_knockout_batch(
            state,
            result,
            stack,
            default_cause="attack_effect",
            source_player=state.active_player_idx,
        )
        return
    prize_awards: list[int] | None = [] if stack is not None else None
    state._ko_from_attack = True
    try:
        result.pokemon_ko.extend(check_kos(state, prize_awards=prize_awards))
    finally:
        state._ko_from_attack = False

    refresh_pending_promotions(state)
    finalize_game_over_if_needed(state, reason="knockout")


def queue_knockout_batch(
    state: GameState,
    result: CommandResult,
    stack,
    *,
    default_cause: str = "rule",
    source_player: int | None = None,
) -> None:
    """Snapshot all current KOs, queue their triggers, then discard the batch.

    The same staged barrier is used for attack damage, attack effects, card
    effects, failed-confusion counters, and Pokemon Checkup.  ``source_player``
    is a causal fact only; Learning Device eligibility remains tied strictly to
    the recorded ``attack_damage`` cause.
    """
    from engine.commands.trigger_commands import (
        TriggerOrderFrame,
        _trigger_group_order,
        _trigger_owner,
        command_specs_from_trigger_results,
    )

    entries: list[dict] = []
    trigger_specs_by_owner: dict[int, list[dict]] = {0: [], 1: []}
    causal_player = source_player if source_player in (0, 1) else None
    for player_idx in (0, 1):
        player = state.get_player(player_idx)
        candidates = [("active", player.active)] + [
            (f"bench_{index}", pokemon)
            for index, pokemon in enumerate(player.bench)
        ]
        for slot, pokemon in candidates:
            if pokemon is None or not pokemon.is_knocked_out:
                continue
            cause = str(
                getattr(pokemon, "pending_ko_cause", "")
                or default_cause
                or "rule"
            )
            player.was_ko_last_turn = True
            if cause == "attack_damage":
                player.was_ko_by_attack = True
            state.record_knockout_fact(
                owner=player_idx,
                cause=cause,
                source_player=causal_player,
                card_id=getattr(pokemon.card, "api_id", ""),
                slot=slot,
            )
            state._log(f"{player.name}的{pokemon.card.name}被击倒了！")
            result.pokemon_ko.append(f"p{player_idx}_{slot}")
            entries.append({
                "player_idx": player_idx,
                "slot": slot,
                "card_id": str(getattr(pokemon.card, "api_id", "") or ""),
                "prize_count": int(getattr(pokemon.card, "prize_value", 1) or 1),
            })

            hook_results = state.event_bus.emit(
                EventType.POKEMON_KO,
                state=state,
                player_idx=player_idx,
                slot=slot,
                knocked_out=pokemon,
                from_attack=(cause == "attack_damage"),
            )
            for spec in command_specs_from_trigger_results(hook_results):
                owner = _trigger_owner(spec, player_idx)
                trigger_specs_by_owner[owner].append(spec)
            for hook_result in hook_results:
                if isinstance(hook_result, dict) and hook_result.get("log"):
                    state._log(str(hook_result["log"]))

    commands = []
    # Simultaneous triggers are ordered independently by their owners. During
    # a turn the current player resolves first; during Pokemon Checkup the
    # incoming player resolves first. No player may inspect or reorder the
    # opponent's trigger entities. ``push_many`` preserves this list order
    # despite the stack's LIFO storage.
    for owner in _trigger_group_order(state):
        owned_specs = trigger_specs_by_owner[owner]
        if owned_specs:
            commands.append(TriggerOrderFrame(owned_specs))
    commands.append(DiscardKnockoutBatch(entries))
    stack.push_many(commands)


def _queue_attack_knockout_batch(state: GameState, result: CommandResult, stack) -> None:
    """Compatibility wrapper for older attack-frame callers."""
    queue_knockout_batch(
        state,
        result,
        stack,
        default_cause="attack_effect",
        source_player=state.active_player_idx,
    )


@dataclass
class DiscardKnockoutBatch:
    """Discard every still-KO'd entity only after all KO triggers resolve."""

    entries: list[dict]

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.commands.modifier_registration import unregister_pokemon_modifiers

        prize_awards: list[int] = []
        for entry in list(self.entries or []):
            player_idx = int(entry.get("player_idx", -1))
            slot = str(entry.get("slot", "") or "")
            if player_idx not in (0, 1) or not slot:
                continue
            player = ctx.state.get_player(player_idx)
            pokemon = player.get_pokemon(slot)
            if pokemon is None or not pokemon.is_knocked_out:
                continue
            if str(getattr(pokemon.card, "api_id", "") or "") != str(
                entry.get("card_id", "") or ""
            ):
                return CommandResult.fail("昏厥宝可梦实体已变化。")
            unregister_pokemon_modifiers(
                pokemon.card.api_id,
                slot,
                event_bus=ctx.state.event_bus,
                player_idx=player_idx,
            )
            ctx.state.discard_pokemon(player_idx, slot)
            prize_taker = 1 - player_idx
            for _ in range(max(0, int(entry.get("prize_count", 1) or 1))):
                if ctx.state.get_player(prize_taker).prizes:
                    prize_awards.append(prize_taker)

        refresh_pending_promotions(ctx.state)
        frames = [PrizeSelectionFrame(player_idx) for player_idx in prize_awards]
        frames.append(FinalizeKnockoutBatch())
        ctx.stack.push_many(frames)
        return CommandResult.ok()


def check_kos(state: GameState, *, prize_awards: list[int] | None = None) -> list[str]:
    ko_slots: list[str] = []
    for player_idx in (0, 1):
        player = state.get_player(player_idx)
        if player.active and player.active.is_knocked_out:
            ko_slots.append(f"p{player_idx}_active")
            handle_ko(state, player_idx, "active", prize_awards=prize_awards)

        for index, pokemon in enumerate(player.bench):
            if pokemon and pokemon.is_knocked_out:
                ko_slots.append(f"p{player_idx}_bench_{index}")
                handle_ko(state, player_idx, f"bench_{index}", prize_awards=prize_awards)
    refresh_pending_promotions(state)
    return ko_slots


def refresh_pending_promotions(state: GameState) -> None:
    turn_owner = int(state.active_player_idx)
    state.pending_promotions = [
        player_idx
        # When both Active Pokemon are Knocked Out, the player who will take
        # the next turn promotes first.
        for player_idx in (1 - turn_owner, turn_owner)
        if state.get_player(player_idx).active is None
        and state.get_player(player_idx).has_any_pokemon_in_play()
    ]


def handle_ko(
    state: GameState,
    player_idx: int,
    slot: str,
    *,
    prize_awards: list[int] | None = None,
) -> None:
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

    cause = str(getattr(pokemon, "pending_ko_cause", "") or "")
    if not cause:
        cause = "attack_effect" if state._ko_from_attack else "rule"
    player.was_ko_last_turn = True
    if cause == "attack_damage":
        player.was_ko_by_attack = True
    state.record_knockout_fact(
        owner=player_idx,
        cause=cause,
        source_player=(state.active_player_idx if state._ko_from_attack else None),
        card_id=getattr(pokemon.card, "api_id", ""),
        slot=slot,
    )

    prize_count = pokemon.card.prize_value
    unregister_pokemon_modifiers(
        pokemon.card.api_id,
        slot,
        event_bus=state.event_bus,
        player_idx=player_idx,
    )

    # Announce the KO before attachment-moving triggers. The Pokemon remains in
    # play until those atomic trigger commands have finished.
    state._log(f"{player.name}的{pokemon.card.name}被击倒了！")

    hook_results = state.event_bus.emit(
        EventType.POKEMON_KO,
        state=state,
        player_idx=player_idx,
        slot=slot,
        knocked_out=pokemon,
        from_attack=(cause == "attack_damage"),
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

    for _ in range(prize_count):
        if not opponent.prizes:
            break
        if prize_awards is not None:
            prize_awards.append(1 - player_idx)
        else:
            opponent.take_prize()
            state._log(
                f"{opponent.name}获得了奖赏卡！"
                f"（剩余{len(opponent.prizes)}张）"
            )

    # Winner and simultaneous-promotion decisions are made only after the full
    # KO batch, avoiding loop/index bias.


@dataclass
class FinalizeAttackDamage:
    """Commit the primary hit and retain its serializable reactive trigger specs."""

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
        deferred = list(ctx.stack.context.pop("conditional_post_hit_commands", []) or [])
        if deferred:
            ctx.stack.push_many(deferred)
        # Authored and conditional post-hit effects resolve before reactions to
        # the damage.  Keeping raw command specs in context also makes a pause
        # (for example an optional self-switch) snapshot-safe.
        ctx.stack.context[PENDING_AFTER_DAMAGE_TRIGGERS_KEY] = list(trigger_commands)
        return result


@dataclass
class FinalizeAfterDamageTriggers:
    """Run reactions only after every authored post-hit consequence."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        trigger_specs = list(
            ctx.stack.context.pop(PENDING_AFTER_DAMAGE_TRIGGERS_KEY, []) or []
        )
        if trigger_specs:
            from engine.commands.trigger_commands import push_trigger_command_specs

            push_trigger_command_specs(ctx.stack, trigger_specs)
        return CommandResult.ok()


@dataclass
class FinalizeAttackKoChecks:
    """Resolve KOs after attack-damage trigger commands have finished."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        result = CommandResult.ok()
        do_attack_ko_checks(ctx.state, result, stack=ctx.stack)
        return result


@dataclass
class PrizeSelectionFrame:
    """Request one face-down prize position without revealing its identity."""

    player_idx: int

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.game_state import ActionRequest

        player = ctx.state.get_player(self.player_idx)
        if not player.prizes:
            return CommandResult.ok()
        return CommandResult.ok(
            "选择1张奖赏卡。",
            pending_choice=ActionRequest(
                request_type="select_prize",
                player=self.player_idx,
                prompt="选择1张反面朝上的奖赏卡。",
                min_select=1,
                max_select=1,
                target_info=[
                    {"index": index, "label": f"奖赏卡 {index + 1}"}
                    for index in range(len(player.prizes))
                ],
                continuation={
                    "kind": "select_prize",
                    "domain": "prize",
                    "player_idx": self.player_idx,
                },
            ),
        )


@dataclass
class FinalizeKnockoutBatch:
    """Check terminal conditions only after every prize has resolved."""

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        refresh_pending_promotions(ctx.state)
        finalize_game_over_if_needed(ctx.state, reason="knockout")
        clear_attack_resolution_context(ctx.stack)
        return CommandResult.ok()


@dataclass
class FinalizeCheckupTurn:
    """Start the incoming turn only after a complete Checkup KO batch."""

    actor: int

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.turn_manager import TurnManager

        result = TurnManager(ctx.state).finish_checkup_after_settlement(self.actor)
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


@dataclass
class FinalizeAttackTurn:
    """Finish an attack from inside the resolution stack when no promotion pauses it."""

    actor: int

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        if ctx.state.is_terminal():
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
