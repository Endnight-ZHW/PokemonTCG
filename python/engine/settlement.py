"""Settlement services for promotion, KO, and attack-finalize frames."""
from __future__ import annotations

from typing import Any

from engine.actions import ChoiceRequest, GameAction, StepResult
from engine.choice_manager import VMChoiceManager
from engine.commands.attack_frames import (
    clear_finish_attack_after_promotions,
    finish_attack_after_promotions_actor,
    FinalizeAttackTurn,
)
from engine.commands.resolution_stack import ResolutionStack
from engine.enums import TurnPhase
from engine.game_state import ActionResult, GameState
from engine.random_source import RandomSource
from engine.rules_validator import check_win_condition
from engine.turn_manager import TurnManager


class VMSettlementManager:
    """Owns rule settlement that happens around public action dispatch."""

    def __init__(self, choice_manager: VMChoiceManager | None = None) -> None:
        self.choice_manager = choice_manager or VMChoiceManager()

    def apply_promotion(
        self,
        state: GameState,
        actor: int,
        action: GameAction,
        rng: RandomSource,
    ) -> StepResult:
        if state.pending_promotion_player != actor:
            return StepResult(False, "当前没有该玩家的晋升请求。", error_code="invalid_promotion")
        bench_idx = action.params.get("bench_idx")
        player = state.get_player(actor)
        if (
            not isinstance(bench_idx, int)
            or not (0 <= bench_idx < len(player.bench))
            or player.bench[bench_idx] is None
        ):
            return StepResult(False, "晋升目标无效。", error_code="invalid_promotion_target")
        if player.active is not None:
            return StepResult(False, "战斗区不为空，不能执行晋升。", error_code="active_not_empty")
        player.promote_from_bench(bench_idx)
        message = f"{player.name}将{player.active.card.name}提升至战斗区。"
        state._log(message)
        manager = TurnManager(state)
        if state.phase == TurnPhase.DRAW:
            manager.continue_after_promotion()
        else:
            state.pop_pending_promotion()
        state.revision = getattr(state, "revision", 0) + 1
        step = StepResult(
            True,
            message,
            ActionResult(True, message),
            winner=state.winner,
            terminal=state.winner is not None or state.phase == TurnPhase.GAME_OVER,
        )
        finish_actor = finish_attack_after_promotions_actor(state)
        if (
            finish_actor in (0, 1)
            and not state.pending_promotions
            and state.winner is None
            and state.phase == TurnPhase.ATTACK
        ):
            clear_finish_attack_after_promotions(state)
            step = self.merge_steps(
                step,
                self.resolve_attack_turn_frame(
                    state,
                    int(finish_actor),
                    rng,
                ),
            )
        return step

    def resolve_attack_turn_frame(
        self,
        state: GameState,
        actor: int,
        rng: RandomSource,
    ) -> StepResult:
        event_offset = len(getattr(state.event_stream, "_events", ()))
        stack = ResolutionStack(state)
        stack.push(FinalizeAttackTurn(actor))
        with rng.bind_state(state):
            result = stack.resolve_all(actor, "active")
        action_result = ActionResult(
            success=result.success,
            log_message=" ".join(result.log_messages),
            damage_dealt=result.damage_dealt,
            cards_drawn=result.cards_drawn,
            cards_discarded=result.cards_discarded,
            pokemon_ko=result.pokemon_ko,
            status_applied=result.status_applied,
            pending_action=result.pending_choice,
            attack_failed=result.attack_failed,
        )
        return self.step_from_action_result(
            state,
            action_result,
            events=self.events_since(state, event_offset),
        )

    def step_from_action_result(
        self,
        state: GameState,
        result: ActionResult,
        *,
        events: tuple[dict[str, Any], ...] = (),
    ) -> StepResult:
        pending = (
            self.choice_manager.choice_request(state, result.pending_action)
            if result.pending_action
            else None
        )
        return StepResult(
            success=bool(result.success),
            message=result.log_message,
            action_result=result,
            pending_choice=pending,
            events=events,
            winner=state.winner,
            terminal=state.winner is not None or state.phase == TurnPhase.GAME_OVER,
        )

    @staticmethod
    def resolve_non_attack_knockouts(state: GameState, step: StepResult) -> StepResult:
        if (
            not step.success
            or step.pending_choice is not None
            or state.phase in (TurnPhase.SETUP, TurnPhase.GAME_OVER)
            or state.winner is not None
        ):
            return step
        from engine.action_resolver import ActionResolver

        state._ko_from_attack = False
        try:
            ko_slots = ActionResolver(state)._check_kos()
        except ValueError as exc:
            return StepResult(
                False,
                str(exc),
                action_result=step.action_result,
                events=step.events,
                winner=state.winner,
                terminal=state.winner is not None or state.phase == TurnPhase.GAME_OVER,
                error_code="ko_trigger_failed",
            )
        if not ko_slots:
            return step
        if ko_slots and step.action_result is not None:
            step.action_result.pokemon_ko.extend(ko_slots)
        winner = check_win_condition(state)
        if winner is not None:
            state.winner = winner
            state.phase = TurnPhase.GAME_OVER
            state._log(f"{state.get_player(winner).name}获胜！")
        step.winner = state.winner
        step.terminal = state.winner is not None or state.phase == TurnPhase.GAME_OVER
        return step

    @staticmethod
    def merge_steps(first: StepResult, second: StepResult) -> StepResult:
        message = " ".join(part for part in (first.message, second.message) if part)
        return StepResult(
            success=first.success and second.success,
            message=message,
            action_result=VMSettlementManager.combine_action_results(
                first.action_result,
                second.action_result,
            ),
            pending_choice=second.pending_choice,
            events=first.events + second.events,
            winner=second.winner,
            terminal=second.terminal,
            error_code=second.error_code or first.error_code,
        )

    @staticmethod
    def events_since(state: GameState, offset: int) -> tuple[dict[str, Any], ...]:
        events = list(getattr(state.event_stream, "_events", ()))[offset:]
        return tuple(
            {
                "event_type": getattr(event, "event_type", ""),
                "data": dict(getattr(event, "data", {}) or {}),
            }
            for event in events
        )

    @staticmethod
    def combine_action_results(first: ActionResult | None, second: ActionResult | None):
        if first is None:
            return second
        if second is None:
            return first
        return ActionResult(
            success=first.success and second.success,
            log_message=" ".join(
                part for part in (first.log_message, second.log_message) if part
            ),
            damage_dealt=first.damage_dealt + second.damage_dealt,
            cards_drawn=list(first.cards_drawn) + list(second.cards_drawn),
            cards_discarded=first.cards_discarded + second.cards_discarded,
            pokemon_ko=list(first.pokemon_ko) + list(second.pokemon_ko),
            status_applied=list(first.status_applied) + list(second.status_applied),
            prize_taken=first.prize_taken or second.prize_taken,
            pending_action=second.pending_action,
            attack_failed=first.attack_failed or second.attack_failed,
        )
