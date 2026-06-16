"""LIFO Resolution Stack for card game effects.

The stack ensures that triggered effects resolve before the triggering
effect continues — modeling the nested trigger tree correctly.
"""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any, Optional, TYPE_CHECKING

from engine.commands.base import CommandResult

if TYPE_CHECKING:
    from engine.game_state import GameState
    from engine.commands.base import ICommand, ResolutionContext, ResolutionContext


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
        self.cards_discarded += getattr(cr, 'cards_discarded', 0)
        self.pokemon_ko.extend(cr.pokemon_ko)
        self.status_applied.extend(cr.status_applied)
        if cr.log_message:
            self.log_messages.append(cr.log_message)
        if cr.pending_choice:
            self.pending_choice = cr.pending_choice
        self.attack_failed = self.attack_failed or cr.attack_failed
        self.success = self.success and cr.success


class ResolutionStack:
    """LIFO stack for resolving card game commands.

    Usage:
        stack = ResolutionStack(state)
        stack.push(DealDamageCommand(100))
        stack.push_many([DrawCommand(2), ApplyStatusCommand("poisoned")])
        result = stack.resolve_all()
    """

    def __init__(self, state: GameState):
        self.state = state
        self._stack: list[ICommand] = []
        self._context: Optional[ResolutionContext] = None

    def push(self, command: ICommand):
        """Push a single command onto the stack (resolves next)."""
        self._stack.append(command)

    def push_many(self, commands: list[ICommand]):
        """Push multiple commands. First in list resolves first (so push in reverse)."""
        for cmd in reversed(commands):
            self._stack.append(cmd)

    def resolve_all(self, player_idx: int = 0,
                    source_slot: str = "active") -> ResolutionResult:
        """Resolve everything on the stack until empty or a choice is needed."""
        from engine.commands.base import ResolutionContext

        result = ResolutionResult()
        ctx = ResolutionContext(self.state, player_idx, source_slot, self)

        while self._stack:
            cmd = self._stack.pop()
            try:
                cr = cmd.execute(ctx)
            except Exception as e:
                cr = CommandResult(success=False, log_message=str(e))

            result.merge(cr)

            if not cr.success:
                # On failure, stop resolution and return
                return result

            if cr.pending_choice:
                # Pause for UI input — store remaining stack for resume
                result.pending_choice = self._wrap_pending_choice(
                    cr.pending_choice, player_idx, source_slot
                )
                return result

            # Side effects are already on the stack (pushed via ctx.push_side
            # during execute), so the loop just continues.

        return result

    def resume_after_choice(self, player_idx: int = 0,
                            source_slot: str = "active") -> ResolutionResult:
        """Continue resolving after a UI choice was made. Reuses remaining stack."""
        return self.resolve_all(player_idx, source_slot)

    @property
    def depth(self) -> int:
        return len(self._stack)

    def clear(self):
        self._stack.clear()

    # ---- Pending continuation helpers ---------------------------------

    def _wrap_pending_choice(self, req, player_idx: int, source_slot: str):
        """Resume the remaining command stack after a pending choice resolves.

        A ResolutionStack can pause in the middle of a multi-effect card, for
        example "choose a Pokemon, attach an energy, then draw 2". The old
        callback resolved only the choice effect and then dropped the remaining
        commands because the local stack was no longer reachable. Wrapping the
        callback keeps the rest of the effect chain alive for UI, AI simulation,
        and training.
        """
        if req is None or getattr(req, "_resolution_stack_wrapped", False):
            return req

        original_callback = req.callback
        setattr(req, "_resolution_stack_wrapped", True)
        setattr(req, "_resolution_stack_had_callback", original_callback is not None)

        def chained(choice):
            original_result = (
                original_callback(choice) if original_callback else None
            )
            return self._continue_after_callback_result(
                original_result, player_idx, source_slot
            )

        req.callback = chained
        return req

    def _continue_after_callback_result(
        self,
        original_result,
        player_idx: int,
        source_slot: str,
    ):
        from engine.game_state import ActionRequest, ActionResult

        if isinstance(original_result, ActionRequest):
            return self._wrap_pending_choice(
                original_result, player_idx, source_slot
            )

        if isinstance(original_result, ActionResult):
            if original_result.pending_action:
                original_result.pending_action = self._wrap_pending_choice(
                    original_result.pending_action, player_idx, source_slot
                )
                return original_result
            if not original_result.success:
                return original_result

        if not self._stack:
            return original_result

        continuation = self._to_action_result(
            self.resume_after_choice(player_idx, source_slot)
        )
        if isinstance(original_result, ActionResult):
            return self._merge_action_results(original_result, continuation)
        return continuation

    @staticmethod
    def _to_action_result(rr: ResolutionResult):
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
    def _merge_action_results(first, second):
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
