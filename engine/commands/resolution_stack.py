"""LIFO Resolution Stack for card game effects.

The stack ensures that triggered effects resolve before the triggering
effect continues — modeling the nested trigger tree correctly.
"""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional, TYPE_CHECKING

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
    pokemon_ko: list[str] = field(default_factory=list)
    status_applied: list[str] = field(default_factory=list)
    pending_choice: Optional[Any] = None
    attack_failed: bool = False

    def merge(self, cr: CommandResult):
        self.damage_dealt += cr.damage_dealt
        self.cards_drawn.extend(cr.cards_drawn)
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
                result.pending_choice = cr.pending_choice
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
