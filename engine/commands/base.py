"""Core types for the Command pattern and Resolution Stack."""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Any, Protocol, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from engine.game_state import GameState, ActionRequest
    from engine.events.game_events import GameEvent


@dataclass
class CommandResult:
    """Result of executing a single ICommand.

    mutations: atomic state changes to apply to GameState
    side_effects: new ICommands to push onto the resolution stack (LIFO)
    pending_choice: if set, pause resolution for UI input
    events: structured events for the UI layer to consume
    """
    success: bool = True
    log_message: str = ""
    damage_dealt: int = 0
    cards_drawn: list[Any] = field(default_factory=list)
    pokemon_ko: list[str] = field(default_factory=list)
    status_applied: list[str] = field(default_factory=list)
    pending_choice: Optional[ActionRequest] = None
    attack_failed: bool = False
    side_effects: list[ICommand] = field(default_factory=list)
    events: list[GameEvent] = field(default_factory=list)

    @classmethod
    def ok(cls, msg: str = "", **kwargs) -> CommandResult:
        return cls(success=True, log_message=msg, **kwargs)

    @classmethod
    def fail(cls, msg: str) -> CommandResult:
        return cls(success=False, log_message=msg)


class ResolutionContext:
    """Context passed to each ICommand.execute().

    Provides access to game state, the executing player, source slot,
    and a reference to the ResolutionStack so commands can push side effects.
    """
    __slots__ = ("state", "player_idx", "source_slot", "stack")

    def __init__(self, state: GameState, player_idx: int,
                 source_slot: str, stack: ResolutionStack):
        self.state = state
        self.player_idx = player_idx
        self.source_slot = source_slot
        self.stack = stack

    @property
    def player(self):
        return self.state.get_player(self.player_idx)

    @property
    def opponent(self):
        return self.state.get_opponent()

    def push_side(self, command: ICommand):
        """Push a new command onto the stack (for triggered effects)."""
        self.stack.push(command)

    def emit_event(self, event_type: str, **data):
        """Push a game event to the state's event stream for UI consumption."""
        from engine.events.game_events import GameEvent
        event = GameEvent(event_type=event_type, data=data)
        if hasattr(self.state, 'event_stream'):
            self.state.event_stream.push(event)


class ICommand(Protocol):
    """A single executable game effect.

    Each card effect (deal damage, draw cards, apply status, etc.)
    is an ICommand. Commands are pushed onto a LIFO ResolutionStack.
    When a command triggers additional effects, it pushes new commands
    via ctx.push_side() — those resolve BEFORE the current command's
    caller continues, correctly modeling nested trigger chains.
    """

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        """Execute this command and return the result.

        Side effects (triggered abilities, chained effects) should be
        pushed via ctx.push_side(), not returned directly.
        """
        ...
