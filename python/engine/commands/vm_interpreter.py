"""Python VM interpreter loop for resolving command stacks."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Optional

from engine.commands.base import CommandResult
from engine.commands.continuation_registry import (
    build_resolution_stack_continuation_registry,
)
from engine.commands.vm_registry import ContinuationRegistry


@dataclass
class ResolutionResult:
    """Aggregated result of resolving a stack of commands."""

    success: bool = True
    log_messages: list[str] = field(default_factory=list)
    damage_dealt: int = 0
    cards_drawn: list = field(default_factory=list)
    cards_discarded: int = 0
    pokemon_ko: list[str] = field(default_factory=list)
    status_applied: list[str] = field(default_factory=list)
    pending_choice: Optional[Any] = None
    attack_failed: bool = False

    def merge(self, cr: CommandResult):
        self.damage_dealt += cr.damage_dealt
        self.cards_drawn.extend(cr.cards_drawn)
        self.cards_discarded += getattr(cr, "cards_discarded", 0)
        self.pokemon_ko.extend(cr.pokemon_ko)
        self.status_applied.extend(cr.status_applied)
        if cr.log_message:
            self.log_messages.append(cr.log_message)
        if cr.pending_choice:
            self.pending_choice = cr.pending_choice
        self.attack_failed = self.attack_failed or cr.attack_failed
        self.success = self.success and cr.success


class VMInterpreter:
    """Executes commands and registered continuations against a stack."""

    def __init__(self, continuation_registry_factory=None) -> None:
        self._continuation_registry_factory = (
            continuation_registry_factory
            or build_resolution_stack_continuation_registry
        )

    def build_continuation_registry(self, stack) -> ContinuationRegistry:
        return self._continuation_registry_factory(stack)

    def resolve_all(
        self,
        stack,
        player_idx: int = 0,
        source_slot: str = "active",
    ) -> ResolutionResult:
        """Resolve commands until the stack is empty or a choice is needed."""
        from engine.commands.base import ResolutionContext

        result = ResolutionResult()
        ctx = ResolutionContext(stack.state, player_idx, source_slot, stack)

        while stack.has_commands():
            cmd = stack.pop_next()
            try:
                cr = cmd.execute(ctx)
            except Exception as exc:
                cr = CommandResult(success=False, log_message=str(exc))

            result.merge(cr)
            stack.mark_attack_failed(cr.attack_failed)

            if not cr.success:
                stack.run_abort_handlers()
                return result

            if cr.pending_choice:
                result.pending_choice = self.wrap_pending_choice(
                    stack,
                    cr.pending_choice,
                    player_idx,
                    source_slot,
                )
                return result

        stack.clear_abort_handlers()
        return result

    def resume_after_choice(
        self,
        stack,
        player_idx: int = 0,
        source_slot: str = "active",
    ) -> ResolutionResult:
        """Continue resolving after a UI choice was made."""
        return self.resolve_all(stack, player_idx, source_slot)

    def wrap_pending_choice(self, stack, req, player_idx: int, source_slot: str):
        """Resume remaining commands after a pending choice resolves."""
        if req is None or getattr(req, "_resolution_stack_wrapped", False):
            return req

        original_callback = req.callback
        setattr(req, "_resolution_stack_wrapped", True)
        setattr(req, "_resolution_stack_had_callback", original_callback is not None)

        def chained(choice):
            original_result = self.resolve_request_continuation(
                stack,
                req,
                choice,
                player_idx,
                source_slot,
            )
            if original_callback:
                callback_result = original_callback(choice)
                original_result = self.merge_callback_results(
                    original_result,
                    callback_result,
                )
            return self.continue_after_callback_result(
                stack,
                original_result,
                player_idx,
                source_slot,
            )

        req.callback = chained
        return req

    def resolve_request_continuation(
        self,
        stack,
        req,
        choice,
        player_idx: int,
        source_slot: str,
    ):
        continuation = dict(getattr(req, "continuation", {}) or {})
        kind = str(continuation.get("kind", "") or "")
        if kind == "":
            return None

        return self.dispatch_registered_continuation(
            stack,
            kind,
            req,
            continuation,
            choice,
            player_idx,
            source_slot,
        )

    def dispatch_registered_continuation(
        self,
        stack,
        kind: str,
        req,
        continuation: dict,
        choice,
        player_idx: int,
        source_slot: str,
    ):
        registry = stack.continuation_registry
        if not registry.supports(kind):
            from engine.game_state import ActionResult

            return ActionResult(False, f"Unknown VM continuation: {kind}")
        return registry.dispatch(
            kind,
            req,
            continuation,
            choice,
            player_idx,
            source_slot,
        )

    @staticmethod
    def merge_callback_results(first, second):
        if first is None:
            return second
        if second is None:
            return first
        from engine.game_state import ActionRequest, ActionResult

        if isinstance(first, ActionResult) and isinstance(second, ActionResult):
            return VMInterpreter.merge_action_results(first, second)
        if isinstance(second, ActionRequest):
            return second
        return first

    def continue_after_callback_result(
        self,
        stack,
        original_result,
        player_idx: int,
        source_slot: str,
    ):
        from engine.game_state import ActionRequest, ActionResult

        if isinstance(original_result, ActionRequest):
            return self.wrap_pending_choice(
                stack,
                original_result,
                player_idx,
                source_slot,
            )

        if isinstance(original_result, ActionResult):
            stack.mark_attack_failed(bool(getattr(original_result, "attack_failed", False)))
            if original_result.pending_action:
                original_result.pending_action = self.wrap_pending_choice(
                    stack,
                    original_result.pending_action,
                    player_idx,
                    source_slot,
                )
                return original_result
            if not original_result.success:
                stack.run_abort_handlers()
                return original_result

        if not stack.has_commands():
            return original_result

        continuation = self.resolution_result_to_action_result(
            self.resume_after_choice(stack, player_idx, source_slot)
        )
        if isinstance(original_result, ActionResult):
            return self.merge_action_results(original_result, continuation)
        return continuation

    @staticmethod
    def resolution_result_to_action_result(rr: ResolutionResult):
        from engine.game_state import ActionResult

        return ActionResult(
            success=rr.success,
            log_message=" ".join(rr.log_messages),
            damage_dealt=rr.damage_dealt,
            cards_drawn=rr.cards_drawn,
            cards_discarded=rr.cards_discarded,
            pokemon_ko=rr.pokemon_ko,
            status_applied=rr.status_applied,
            pending_action=rr.pending_choice,
            attack_failed=rr.attack_failed,
        )

    @staticmethod
    def merge_action_results(first, second):
        if second.log_message:
            first.log_message = (
                f"{first.log_message} {second.log_message}".strip()
                if first.log_message else second.log_message
            )
        first.success = first.success and second.success
        first.damage_dealt += second.damage_dealt
        first.cards_drawn.extend(second.cards_drawn)
        first.cards_discarded += second.cards_discarded
        first.pokemon_ko.extend(second.pokemon_ko)
        first.status_applied.extend(second.status_applied)
        first.attack_failed = first.attack_failed or second.attack_failed
        if second.pending_action:
            first.pending_action = second.pending_action
        return first
