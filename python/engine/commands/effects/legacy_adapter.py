"""Adapter that wraps existing effect handlers as ICommand objects.

This bridges the old engine/effects/__init__.py:execute_effect() to the
new ResolutionStack. Existing handler functions remain in place; each
effect type gets a LegacyEffectCommand that delegates to execute_effect().

Over time, individual handlers are ported to native ICommand subclasses
and registered directly — this adapter only handles effects not yet ported.
"""
from __future__ import annotations
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from engine.commands.base import ResolutionContext, CommandResult
    from engine.commands.resolution_stack import ResolutionStack


@dataclass
class LegacyEffectCommand:
    """Wraps an existing effect handler call as an ICommand.

    Delegates to engine.effects.execute_effect() for the actual logic,
    then converts the ActionResult to a CommandResult.
    """
    effect_type: str
    params: dict

    def execute(self, ctx: ResolutionContext) -> CommandResult:
        from engine.effects import execute_effect
        from engine.commands.base import CommandResult

        effect_def = {"effect_type": self.effect_type, "params": self.params}
        action_result = execute_effect(
            ctx.state, effect_def, ctx.player_idx, ctx.source_slot
        )
        return CommandResult(
            success=action_result.success,
            log_message=action_result.log_message,
            damage_dealt=action_result.damage_dealt,
            cards_drawn=action_result.cards_drawn,
            cards_discarded=action_result.cards_discarded,
            pokemon_ko=action_result.pokemon_ko,
            status_applied=action_result.status_applied,
            pending_choice=action_result.pending_action,
            attack_failed=action_result.attack_failed,
            side_effects=[],
            events=[],
        )
