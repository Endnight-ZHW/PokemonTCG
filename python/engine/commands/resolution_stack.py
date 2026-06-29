"""LIFO ResolutionStack state container for card game effects."""
from __future__ import annotations
from typing import Any, TYPE_CHECKING

from engine.commands.vm_registry import ContinuationRegistry
from engine.commands.vm_interpreter import ResolutionResult, VMInterpreter

if TYPE_CHECKING:
    from engine.game_state import GameState
    from engine.commands.base import ICommand


class ResolutionStack:
    """LIFO stack for resolving card game commands.

    Usage:
        stack = ResolutionStack(state)
        stack.push(DealDamageCommand(100))
        stack.push_many([DrawCommand(2), ApplyStatusCommand("poisoned")])
        result = stack.resolve_all()
    """

    def __init__(
        self,
        state: GameState,
        *,
        vm_interpreter: VMInterpreter | None = None,
        continuation_registry: ContinuationRegistry | None = None,
    ):
        self.state = state
        self._stack: list[ICommand] = []
        self.context: dict[str, Any] = {}
        self._abort_handlers: list[Any] = []
        self._attack_failed: bool = False
        self.vm_interpreter = vm_interpreter or VMInterpreter()
        self.continuation_registry = (
            continuation_registry
            or self.vm_interpreter.build_continuation_registry(self)
        )

    def push(self, command: ICommand):
        """Push a single command onto the stack (resolves next)."""
        self._stack.append(command)

    def push_many(self, commands: list[ICommand]):
        """Push multiple commands. First in list resolves first (so push in reverse)."""
        for cmd in reversed(commands):
            self._stack.append(cmd)

    def add_abort_handler(self, handler):
        self._abort_handlers.append(handler)

    def has_commands(self) -> bool:
        return bool(self._stack)

    def pop_next(self) -> ICommand:
        return self._stack.pop()

    def mark_attack_failed(self, attack_failed: bool) -> None:
        self._attack_failed = self._attack_failed or bool(attack_failed)

    def run_abort_handlers(self):
        handlers = list(self._abort_handlers)
        self._abort_handlers.clear()
        for handler in handlers:
            handler()

    def _run_abort_handlers(self):
        self.run_abort_handlers()

    def clear_abort_handlers(self) -> None:
        self._abort_handlers.clear()

    def resolve_all(self, player_idx: int = 0,
                    source_slot: str = "active") -> ResolutionResult:
        """Resolve commands through the VM interpreter compatibility layer."""
        return self.vm_interpreter.resolve_all(self, player_idx, source_slot)

    def resume_after_choice(self, player_idx: int = 0,
                            source_slot: str = "active") -> ResolutionResult:
        """Continue resolving after a UI choice was made. Reuses remaining stack."""
        return self.vm_interpreter.resume_after_choice(self, player_idx, source_slot)

    @property
    def depth(self) -> int:
        return len(self._stack)

    def clear(self):
        self._stack.clear()
        self.context.clear()
        self._abort_handlers.clear()
        self._attack_failed = False

    @property
    def attack_failed(self) -> bool:
        return self._attack_failed

    # ---- Pending continuation helpers ---------------------------------

    def _wrap_pending_choice(self, req, player_idx: int, source_slot: str):
        return self.vm_interpreter.wrap_pending_choice(
            self, req, player_idx, source_slot
        )

    def _resolve_request_continuation(
        self,
        req,
        choice,
        player_idx: int,
        source_slot: str,
    ):
        return self.vm_interpreter.resolve_request_continuation(
            self, req, choice, player_idx, source_slot
        )

    def _dispatch_registered_continuation(
        self,
        kind: str,
        req,
        continuation: dict,
        choice,
        player_idx: int,
        source_slot: str,
    ):
        return self.vm_interpreter.dispatch_registered_continuation(
            self,
            kind,
            req,
            continuation,
            choice,
            player_idx,
            source_slot,
        )

    def _continuation_registry(self) -> ContinuationRegistry:
        return self.continuation_registry

    @staticmethod
    def _merge_callback_results(first, second):
        return VMInterpreter.merge_callback_results(first, second)

    def _continue_after_callback_result(
        self,
        original_result,
        player_idx: int,
        source_slot: str,
    ):
        return self.vm_interpreter.continue_after_callback_result(
            self, original_result, player_idx, source_slot
        )

    @staticmethod
    def _to_action_result(rr: ResolutionResult):
        return VMInterpreter.resolution_result_to_action_result(rr)

    @staticmethod
    def _merge_action_results(first, second):
        return VMInterpreter.merge_action_results(first, second)
