"""Authoritative action enumeration and execution facade."""
from __future__ import annotations

from typing import Callable

from engine.actions import (
    ChoiceRequest,
    ChoiceResponse,
    GameAction,
    StepResult,
)
from engine.action_availability import VMActionAvailability
from engine.commands.attack_frames import set_finish_attack_after_promotions
from engine.choice_manager import VMChoiceManager
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import ActionRequest, ActionResult, GameState
from engine.random_source import RandomSource
from engine.settlement import VMSettlementManager
from engine.snapshot import clone_state
from engine.transaction_manager import VMTransactionManager
from engine.turn_manager import TurnManager


class GameEngine:
    """Single rules-facing API used by gameplay, AI, and training."""

    def __init__(
        self,
        transaction_manager: VMTransactionManager | None = None,
        choice_manager: VMChoiceManager | None = None,
        settlement_manager: VMSettlementManager | None = None,
        availability: VMActionAvailability | None = None,
    ) -> None:
        self.transaction_manager = transaction_manager or VMTransactionManager()
        self.choice_manager = choice_manager or VMChoiceManager()
        self.settlement_manager = settlement_manager or VMSettlementManager(self.choice_manager)
        self.availability = availability or VMActionAvailability()

    def legal_actions(
        self,
        state: GameState,
        actor: int,
        *,
        validate_effects: bool = True,
    ) -> tuple[GameAction, ...]:
        if not self._is_valid_actor(actor):
            return ()
        if self.transaction_manager.has_pending_choice(state):
            return ()
        raw = self.availability.enumerate_actions(state, actor)
        if not validate_effects:
            return tuple(raw)

        validated: list[GameAction] = []
        for action in raw:
            if action.action not in {
                PlayerAction.PLAY_TRAINER,
                PlayerAction.USE_ABILITY,
                PlayerAction.USE_STADIUM,
            }:
                validated.append(action)
                continue
            if self.availability.can_skip_effect_simulation(state, actor, action):
                validated.append(action)
                continue
            simulation = clone_state(state)
            result = self.apply_action(
                simulation,
                action,
                RandomSource(0),
                auto_resolve=True,
                auto_finish_attack=True,
            )
            if result.success:
                validated.append(action)
        return tuple(validated)

    def apply_action(
        self,
        state: GameState,
        action: GameAction,
        rng: RandomSource | None = None,
        *,
        auto_resolve: bool = False,
        choice_policy: Callable[[GameState, ChoiceRequest], ChoiceResponse] | None = None,
        auto_finish_attack: bool = True,
    ) -> StepResult:
        rng = rng or RandomSource()
        actor = state.active_player_idx if action.actor is None else action.actor
        if not self._is_valid_actor(actor):
            return StepResult(
                False,
                "玩家索引无效。",
                error_code="invalid_actor",
                winner=state.winner,
            )
        if self.transaction_manager.has_pending_choice(state):
            return StepResult(
                False,
                "必须先完成当前选择。",
                error_code="pending_choice",
                winner=state.winner,
            )
        reference_error = self.availability.validate_action_references(state, action)
        if reference_error:
            return StepResult(
                False,
                reference_error,
                error_code="stale_action_reference",
                winner=state.winner,
            )

        if action.action == "NOOP":
            return StepResult(True, action_result=ActionResult(True, ""), winner=state.winner)
        if action.action == "SETUP_DONE":
            return StepResult(True, "setup done", ActionResult(True, "setup done"), winner=state.winner)
        if action.action == "PROMOTE":
            checkpoint = self.transaction_manager.capture_transaction(state, rng)
            try:
                step = self.settlement_manager.apply_promotion(state, actor, action, rng)
            except Exception as exc:
                self.transaction_manager.rollback_transaction(state, rng, checkpoint)
                return StepResult(
                    False,
                    str(exc),
                    error_code="promotion_exception",
                    winner=state.winner,
                )
            if not step.success:
                return self.transaction_manager.rollback_failed_step(state, rng, checkpoint, step)
            return step

        checkpoint = self.transaction_manager.capture_transaction(state, rng)
        try:
            event_offset = len(getattr(state.event_stream, "_events", ()))
            with rng.bind_state(state):
                result = TurnManager(state).perform_action(
                    action.action,
                    player_idx=actor,
                    finish_attack_in_stack=(
                        auto_finish_attack
                        and action.action == PlayerAction.DECLARE_ATTACK
                    ),
                    **dict(action.params),
                )
            step = self.settlement_manager.step_from_action_result(
                state,
                result,
                events=self.settlement_manager.events_since(state, event_offset),
            )
            if (
                auto_finish_attack
                and action.action == PlayerAction.DECLARE_ATTACK
                and step.pending_choice is not None
            ):
                step.pending_choice.metadata["finish_attack_actor"] = actor
            if step.pending_choice is not None:
                self.transaction_manager.persist_pending_choice(state, step.pending_choice)
                if (
                    step.pending_choice.can_cancel
                    and action.action == PlayerAction.PLAY_TRAINER
                ):
                    self.transaction_manager.store_cancel_checkpoint(state, checkpoint)
            if auto_resolve:
                try:
                    step = self._resolve_all_choices(state, step, rng, choice_policy)
                except Exception as exc:
                    self.transaction_manager.rollback_transaction(state, rng, checkpoint)
                    return StepResult(
                        False,
                        str(exc),
                        error_code="choice_policy_exception",
                        winner=state.winner,
                    )

            if action.action not in {PlayerAction.DECLARE_ATTACK, PlayerAction.END_TURN}:
                step = self.settlement_manager.resolve_non_attack_knockouts(state, step)

            if (
                auto_finish_attack
                and step.success
                and action.action == PlayerAction.DECLARE_ATTACK
                and bool(getattr(result, "attack_failed", False))
                and state.winner is None
                and state.phase == TurnPhase.ATTACK
                and step.pending_choice is None
            ):
                if state.pending_promotion_player >= 0:
                    set_finish_attack_after_promotions(state, actor)
                else:
                    step = self.settlement_manager.merge_steps(
                        step,
                        self.settlement_manager.resolve_attack_turn_frame(
                            state,
                            actor,
                            rng,
                        ),
                    )

            if (
                auto_finish_attack
                and step.success
                and action.action == PlayerAction.DECLARE_ATTACK
                and state.winner is None
                and state.phase == TurnPhase.ATTACK
                and state.pending_promotion_player >= 0
                and step.pending_choice is None
            ):
                set_finish_attack_after_promotions(state, actor)

            step.winner = state.winner
            step.terminal = state.winner is not None or state.phase == TurnPhase.GAME_OVER
        except Exception as exc:
            self.transaction_manager.rollback_transaction(state, rng, checkpoint)
            return StepResult(
                False,
                str(exc),
                error_code="action_exception",
                winner=state.winner,
            )
        if not step.success:
            return self.transaction_manager.rollback_failed_step(state, rng, checkpoint, step)
        return step

    def apply_choice(
        self,
        state: GameState,
        request: ChoiceRequest,
        response: ChoiceResponse,
        rng: RandomSource | None = None,
    ) -> StepResult:
        rng = rng or RandomSource()
        if not isinstance(request, ChoiceRequest):
            return StepResult(
                False,
                "选择请求格式无效。",
                error_code="invalid_choice_request",
                winner=state.winner,
            )
        if not isinstance(response, ChoiceResponse):
            return StepResult(
                False,
                "选择响应格式无效。",
                error_code="invalid_choice_response",
                winner=state.winner,
            )
        if not self._is_valid_actor(request.player):
            return StepResult(
                False,
                "玩家索引无效。",
                error_code="invalid_actor",
                winner=state.winner,
            )
        authoritative = self.transaction_manager.pending_choice_payload(state)
        if authoritative is None:
            return StepResult(
                False,
                "当前没有待处理的选择。",
                error_code="no_pending_choice",
                winner=state.winner,
            )
        if response.request_id != request.request_id:
            return StepResult(False, "选择请求已过期。", error_code="stale_choice")
        if str(authoritative.get("request_id", "")) != request.request_id:
            return StepResult(False, "局面已变化，选择请求已过期。", error_code="stale_choice")
        authoritative_metadata = authoritative.get("metadata", {})
        authoritative_revision = (
            authoritative_metadata.get("revision", -1)
            if isinstance(authoritative_metadata, dict)
            else -1
        )
        try:
            revision_matches = int(authoritative_revision) == int(
                getattr(state, "revision", 0)
            )
        except (TypeError, ValueError):
            revision_matches = False
        if not revision_matches:
            return StepResult(False, "局面已变化，选择请求已过期。", error_code="stale_choice")
        if self.transaction_manager.choice_request_to_dict(request) != authoritative:
            return StepResult(
                False,
                "选择请求与当前待处理请求不一致。",
                error_code="stale_choice",
                winner=state.winner,
            )
        choice_cancelled = False
        if response.cancelled:
            if not request.can_cancel:
                return StepResult(False, "该选择不可取消。", error_code="choice_not_cancellable")
            if self.transaction_manager.restore_cancel_checkpoint(state, rng, request):
                return StepResult(True, "操作已取消。", winner=state.winner)
            if (
                request.legacy_request is not None
                and request.legacy_request.pending_card is not None
            ):
                self.choice_manager.cancel_pending_card(state, request.legacy_request)
                state.revision = getattr(state, "revision", 0) + 1
                self.transaction_manager.clear_pending_choice_stack(state)
                return StepResult(True, "选择已取消。", winner=state.winner)
            choice_cancelled = True

        option_map = {option.option_id: option for option in request.options}
        selected = []
        for option_id in response.option_ids:
            option = option_map.get(option_id)
            if option is None:
                return StepResult(False, "包含无效选择项。", error_code="invalid_choice")
            selected.append(option)
        if not request.allow_duplicates and len(set(response.option_ids)) != len(response.option_ids):
            return StepResult(False, "该选择不允许重复目标。", error_code="duplicate_choice")
        if (
            not choice_cancelled
            and not (request.min_select <= len(selected) <= request.max_select)
        ):
            return StepResult(False, "选择数量不符合要求。", error_code="choice_count")

        legacy = request.legacy_request
        if legacy is None:
            return StepResult(False, "选择请求缺少解析上下文。", error_code="missing_continuation")

        checkpoint = self.transaction_manager.capture_transaction(state, rng)
        try:
            event_offset = len(getattr(state.event_stream, "_events", ()))
            payload = self.choice_manager.legacy_choice_payload(legacy, selected, response)
            with rng.bind_state(state):
                callback_result = legacy.callback(payload) if legacy.callback else None

            self.choice_manager.consume_pending_card(state, legacy)
            state.revision = getattr(state, "revision", 0) + 1
            if isinstance(callback_result, ActionRequest):
                result = ActionResult(True, pending_action=callback_result)
            elif isinstance(callback_result, ActionResult):
                result = callback_result
            else:
                result = ActionResult(True, "")
            step = self.settlement_manager.step_from_action_result(
                state,
                result,
                events=self.settlement_manager.events_since(state, event_offset),
            )
            attack_actor = request.metadata.get("finish_attack_actor")
            if step.pending_choice is not None:
                if attack_actor in (0, 1):
                    step.pending_choice.metadata["finish_attack_actor"] = int(attack_actor)
                self.transaction_manager.persist_pending_choice(state, step.pending_choice)
            elif (
                step.success
                and attack_actor in (0, 1)
                and state.winner is None
                and state.phase == TurnPhase.ATTACK
                and state.pending_promotion_player >= 0
            ):
                self.transaction_manager.clear_pending_choice_stack(state)
                set_finish_attack_after_promotions(state, int(attack_actor))
            elif step.pending_choice is None:
                self.transaction_manager.clear_pending_choice_stack(state)
                if attack_actor not in (0, 1):
                    step = self.settlement_manager.resolve_non_attack_knockouts(state, step)
            step.winner = state.winner
            step.terminal = state.winner is not None or state.phase == TurnPhase.GAME_OVER
        except Exception as exc:
            self.transaction_manager.rollback_transaction(state, rng, checkpoint)
            return StepResult(False, str(exc), error_code="choice_exception", winner=state.winner)
        if not step.success:
            return self.transaction_manager.rollback_failed_step(state, rng, checkpoint, step)
        return step

    def choice_request(self, state: GameState, request: ActionRequest) -> ChoiceRequest:
        structured = self.choice_manager.choice_request(state, request)
        if not self.transaction_manager.has_pending_choice(state):
            self.transaction_manager.persist_pending_choice(state, structured)
        return structured

    def choice_response_from_legacy(
        self,
        request: ChoiceRequest,
        payload,
        *,
        cancelled: bool = False,
    ) -> ChoiceResponse:
        return self.choice_manager.choice_response_from_legacy(
            request,
            payload,
            cancelled=cancelled,
        )

    def _resolve_all_choices(
        self,
        state: GameState,
        step: StepResult,
        rng: RandomSource,
        choice_policy: Callable[[GameState, ChoiceRequest], ChoiceResponse] | None,
    ) -> StepResult:
        guard = 0
        aggregate = step
        while aggregate.success and aggregate.pending_choice is not None and guard < 32:
            guard += 1
            request = aggregate.pending_choice
            response = (
                choice_policy(state, request)
                if choice_policy is not None
                else self.choice_manager.default_choice_response(request, rng)
            )
            next_step = self.apply_choice(state, request, response, rng)
            aggregate = self.settlement_manager.merge_steps(aggregate, next_step)
        if guard >= 32 and aggregate.pending_choice is not None:
            aggregate.success = False
            aggregate.error_code = "choice_loop"
            aggregate.message = "选择链超过安全上限。"
        return aggregate

    @staticmethod
    def _is_valid_actor(actor) -> bool:
        return type(actor) is int and actor in (0, 1)

DEFAULT_GAME_ENGINE = GameEngine()
