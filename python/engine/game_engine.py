"""Authoritative action enumeration and execution facade."""
from __future__ import annotations

from typing import Callable

from engine.actions import (
    AttachmentRef,
    CardRef,
    ChoiceOption,
    ChoiceRequest,
    ChoiceResponse,
    GameAction,
    PokemonRef,
    StepResult,
)
from engine.action_availability import VMActionAvailability
from engine.commands.attack_frames import set_finish_attack_after_promotions
from engine.choice_manager import VMChoiceManager
from engine.enums import PlayerAction, TurnPhase
from engine.game_state import ActionRequest, ActionResult, GameState
from engine.random_source import RandomSource
from engine.pending_continuation import (
    PendingContinuationError,
    rebuild_choice_request,
)
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
        if (
            not isinstance(action, GameAction)
            or not isinstance(action.params, dict)
            or not isinstance(action.action, (PlayerAction, str))
        ):
            return StepResult(
                False,
                "动作格式无效。",
                error_code="invalid_action",
                winner=state.winner,
            )
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
        request_structure_error = self._choice_request_structure_error(request)
        if request_structure_error:
            return StepResult(
                False,
                request_structure_error,
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
        if (
            not isinstance(response.request_id, str)
            or not isinstance(response.option_ids, (tuple, list))
            or not all(isinstance(option_id, str) for option_id in response.option_ids)
            or type(response.cancelled) is not bool
        ):
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
        state_revision = getattr(state, "revision", 0)
        revision_matches = (
            type(authoritative_revision) is int
            and type(state_revision) is int
            and authoritative_revision == state_revision
        )
        if not revision_matches:
            return StepResult(False, "局面已变化，选择请求已过期。", error_code="stale_choice")
        try:
            request_payload = self.transaction_manager.choice_request_to_dict(request)
        except (TypeError, ValueError, AttributeError, OverflowError):
            return StepResult(
                False,
                "选择请求格式无效。",
                error_code="invalid_choice_request",
                winner=state.winner,
            )
        if request_payload != authoritative:
            return StepResult(
                False,
                "选择请求与当前待处理请求不一致。",
                error_code="stale_choice",
                winner=state.winner,
            )
        try:
            # Resolve exclusively from state-owned data.  The caller's
            # ``legacy_request`` is intentionally ignored so an otherwise
            # identical public request cannot substitute an arbitrary
            # callback.  Live requests retain their command stack; restored
            # snapshots rebuild the callback from continuation kind+payload.
            request = self.pending_choice_request(state)
        except PendingContinuationError as exc:
            return StepResult(
                False,
                str(exc),
                error_code=exc.error_code,
                winner=state.winner,
            )
        if request is None:
            return StepResult(
                False,
                "当前没有可恢复的待处理选择。",
                error_code="no_pending_choice",
                winner=state.winner,
            )
        choice_cancelled = False
        if response.cancelled:
            if not request.can_cancel:
                return StepResult(False, "该选择不可取消。", error_code="choice_not_cancellable")
            cancel_guard = self.transaction_manager.capture_transaction(state, rng)
            try:
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
            except Exception as exc:
                self.transaction_manager.rollback_transaction(state, rng, cancel_guard)
                return StepResult(
                    False,
                    str(exc),
                    error_code="choice_exception",
                    winner=state.winner,
                )

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
        target_limit_error = self._choice_target_limit_error(request, selected)
        if target_limit_error:
            return StepResult(
                False,
                target_limit_error,
                error_code="choice_target_limit",
                winner=state.winner,
            )

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

    def pending_choice_request(self, state: GameState) -> ChoiceRequest | None:
        """Return the state-authoritative pending choice, rebuilding if needed."""
        payload = self.transaction_manager.pending_choice_payload(state)
        if payload is None:
            return None

        metadata = payload.get("metadata", {})
        if isinstance(metadata, dict) and "finish_attack_actor" in metadata:
            finish_actor = metadata.get("finish_attack_actor")
            if type(finish_actor) is not int or finish_actor not in (0, 1):
                raise PendingContinuationError(
                    "待处理攻击选择的玩家无效。",
                    error_code="invalid_pending_choice",
                )
        continuation = metadata.get("continuation", {}) if isinstance(metadata, dict) else {}
        kind = (
            str(continuation.get("kind", "") or "")
            if isinstance(continuation, dict)
            else ""
        )
        if kind:
            # Validate even when a live request exists; unknown serialized
            # kinds must never fall through to a caller-provided callback.
            from engine.commands.resolution_stack import ResolutionStack

            try:
                supported = ResolutionStack(state).continuation_registry.supports(kind)
            except Exception as exc:
                raise PendingContinuationError(
                    f"无法验证 VM continuation：{exc}",
                    error_code="invalid_continuation",
                ) from exc
            if not supported:
                raise PendingContinuationError(
                    f"Unknown VM continuation: {kind}",
                    error_code="unknown_continuation",
                )

        runtime = getattr(state, "_pending_choice_runtime", None)
        if isinstance(runtime, ChoiceRequest):
            try:
                if (
                    not self._choice_request_structure_error(runtime)
                    and self.transaction_manager.choice_request_to_dict(runtime) == payload
                ):
                    return runtime
            except (TypeError, ValueError, AttributeError, OverflowError):
                # A damaged ephemeral request must not escape validation or
                # override the serialized state-owned request.
                pass

        rebuilt = rebuild_choice_request(state, payload)
        if not kind:
            raise PendingContinuationError(
                "待处理选择缺少可序列化 continuation。",
                error_code="missing_continuation",
            )
        return rebuilt

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
    def _choice_target_limit_error(
        request: ChoiceRequest,
        selected: list[ChoiceOption],
    ) -> str:
        if (
            request.request_type != "distribute_energy"
            or request.metadata.get("distribute_mode") == "source_select"
            or not selected
        ):
            return ""
        try:
            max_per_target = int(request.metadata.get("max_per_target", 99))
        except (TypeError, ValueError, OverflowError):
            return "分配目标上限无效。"
        counts: dict[str, int] = {}
        for option in selected:
            value = option.value
            slot = (
                str(value.get("slot", "") or "")
                if isinstance(value, dict)
                else str(getattr(option.ref, "slot", "") or "")
            )
            if not slot:
                return "分配目标无效。"
            counts[slot] = counts.get(slot, 0) + 1
        effective_count = sum(
            min(count, max(0, max_per_target))
            for count in counts.values()
        )
        if effective_count < request.min_select:
            return "有效分配数量不足，重复目标超过单目标上限。"
        return ""

    @staticmethod
    def _choice_request_structure_error(request: ChoiceRequest) -> str:
        if (
            not isinstance(request.request_id, str)
            or not request.request_id
            or not isinstance(request.request_type, str)
            or not request.request_type
            or not isinstance(request.prompt, str)
            or not isinstance(request.options, (tuple, list))
            or not all(isinstance(option, ChoiceOption) for option in request.options)
            or not isinstance(request.metadata, dict)
            or type(request.min_select) is not int
            or type(request.max_select) is not int
            or request.min_select < 0
            or request.max_select < request.min_select
            or type(request.allow_duplicates) is not bool
            or type(request.can_cancel) is not bool
        ):
            return "选择请求格式无效。"
        option_ids = [option.option_id for option in request.options]
        if any(not isinstance(option_id, str) or not option_id for option_id in option_ids):
            return "选择请求包含无效选项标识。"
        if any(not isinstance(option.label, str) for option in request.options):
            return "选择请求包含无效选项标签。"
        if len(set(option_ids)) != len(option_ids):
            return "选择请求包含重复选项标识。"
        if any(
            not GameEngine._is_well_formed_entity_ref(option.ref)
            for option in request.options
        ):
            return "选择请求包含无效实体引用。"
        return ""

    @staticmethod
    def _is_well_formed_entity_ref(ref) -> bool:
        if ref is None:
            return True
        if isinstance(ref, CardRef):
            return (
                type(ref.player) is int
                and ref.player in (0, 1)
                and isinstance(ref.zone, str)
                and type(ref.index) is int
                and isinstance(ref.card_id, str)
            )
        if isinstance(ref, PokemonRef):
            return (
                type(ref.player) is int
                and ref.player in (0, 1)
                and isinstance(ref.slot, str)
                and isinstance(ref.card_id, str)
            )
        if isinstance(ref, AttachmentRef):
            return (
                type(ref.player) is int
                and ref.player in (0, 1)
                and isinstance(ref.slot, str)
                and isinstance(ref.attachment_type, str)
                and type(ref.index) is int
                and isinstance(ref.card_id, str)
            )
        return False

    @staticmethod
    def _is_valid_actor(actor) -> bool:
        return type(actor) is int and actor in (0, 1)

DEFAULT_GAME_ENGINE = GameEngine()
