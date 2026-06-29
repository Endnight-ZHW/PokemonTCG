"""VM effect execution helpers for ActionResolver and compatibility callers."""
from __future__ import annotations

from engine.commands.attack_frames import (
    FinalizeAttackDamage,
    FinalizeAttackTurn,
    begin_attack_damage_context,
    apply_accumulated_attack_damage,
    apply_attack_damage,
    check_kos,
    clear_attack_damage_context,
    do_attack_ko_checks,
    handle_ko,
)
from engine.commands.base import CommandResult
from engine.commands.dsl_compiler import (
    CommandSpec,
    compile_command_spec as default_compile_command_spec,
)
from engine.commands.registry import build_command as default_build_command
from engine.commands.resolution_stack import ResolutionStack
from engine.effects.runtime_effects import strict_attack_runtime_effects as attack_runtime_effects
from engine.game_state import ActionResult, GameState


FULL_DAMAGE_EFFECT_TYPES = {
    "damage_per_self_damage",
    "damage_per_self_energy",
    "damage_per_self_energy_type",
    "damage_plus_bench",
    "damage_per_hand_size",
    "damage_per_energy",
    "damage_per_evolved",
    "damage_self_penalty",
    "damage_per_discard_psychic",
    "conditional_damage_heal",
    "damage_and_self_heal",
    "discard_fighting_energy_damage",
    "discard_hand_conditional_bonus",
    "coin_flip_triple",
    "coin_flip_until_tails",
    "mill_and_damage_per_energy",
    "attack_damage_formula",
}


FULL_DAMAGE_VM_OPS = {
    "conditional_damage_then_heal",
    "deal_damage_per_discard_psychic",
    "deal_damage_per_energy",
    "deal_damage_per_evolved",
    "deal_damage_per_hand_size",
    "deal_damage_per_self_damage",
    "deal_damage_per_self_energy",
    "deal_damage_per_self_energy_type",
    "deal_damage_then_heal",
    "discard_energy_then_damage",
    "discard_hand_then_damage",
    "flip_coin_repeat_damage",
    "flip_until_tails",
    "mill_then_damage",
    "set_attack_damage_formula",
}


def command_result_to_action_result(cr: CommandResult) -> ActionResult:
    """Convert CommandResult to ActionResult for transitional callers."""
    return ActionResult(
        success=cr.success,
        log_message=cr.log_message,
        damage_dealt=cr.damage_dealt,
        cards_drawn=cr.cards_drawn,
        cards_discarded=getattr(cr, "cards_discarded", 0),
        pokemon_ko=cr.pokemon_ko,
        status_applied=cr.status_applied,
        pending_action=cr.pending_choice,
        attack_failed=cr.attack_failed,
    )


def merge_action_results(target: ActionResult, source: ActionResult) -> ActionResult:
    """Merge source into target, preserving all user-visible result fields."""
    if source.log_message:
        target.log_message = (
            f"{target.log_message} {source.log_message}".strip()
            if target.log_message else source.log_message
        )
    target.success = target.success and source.success
    target.damage_dealt += source.damage_dealt
    target.cards_drawn.extend(source.cards_drawn)
    target.cards_discarded += source.cards_discarded
    target.pokemon_ko.extend(source.pokemon_ko)
    target.status_applied.extend(source.status_applied)
    target.prize_taken = target.prize_taken or source.prize_taken
    target.attack_failed = target.attack_failed or source.attack_failed
    if source.pending_action:
        target.pending_action = source.pending_action
    return target


def effect_type(effect) -> str:
    if isinstance(effect, dict):
        return str(effect.get("type") or effect.get("effect_type") or "")
    return str(getattr(effect, "type", "") or getattr(effect, "effect_type", ""))


def effect_op(effect) -> str:
    if isinstance(effect, CommandSpec):
        return str(effect.op or "")
    if isinstance(effect, dict):
        return str(effect.get("op", "") or "")
    return ""


def effect_args(effect) -> dict:
    if isinstance(effect, CommandSpec):
        return dict(effect.args)
    if isinstance(effect, dict):
        args = effect.get("args", {}) or {}
        return dict(args) if isinstance(args, dict) else {}
    return {}


def build_runtime_command(
    effect,
    *,
    compile_command_spec=default_compile_command_spec,
    build_command=default_build_command,
):
    if isinstance(effect, CommandSpec) or (
        isinstance(effect, dict) and "op" in effect
    ):
        return compile_command_spec(effect)
    return build_command(effect)


def effect_replaces_base_damage(effect) -> bool:
    if effect_type(effect) in FULL_DAMAGE_EFFECT_TYPES:
        return True
    op = effect_op(effect)
    if op in FULL_DAMAGE_VM_OPS:
        return True
    return op == "deal_damage" and "formula_ast" in effect_args(effect)


def attack_effects_replace_base_damage(attack) -> bool:
    return any(
        effect_replaces_base_damage(effect)
        for effect in attack_runtime_effects(attack)
    )


class VMEffectRunner:
    """Builds VM commands and resolves them through a ResolutionStack."""

    def __init__(
        self,
        state: GameState,
        *,
        compile_command_spec=default_compile_command_spec,
        build_command=default_build_command,
    ) -> None:
        self.state = state
        self.compile_command_spec = compile_command_spec
        self.build_command = build_command

    def execute_effects(
        self,
        effects: list,
        player_idx: int,
        source_slot: str,
    ) -> ActionResult:
        stack = ResolutionStack(self.state)
        try:
            commands = [self._build_runtime_command(effect) for effect in effects]
        except (KeyError, ValueError) as exc:
            return ActionResult(False, str(exc))
        stack.push_many(commands)
        rr = stack.resolve_all(player_idx, source_slot)
        return self.resolution_result_to_action_result(rr)

    def execute_attack_effects(
        self,
        effects: list,
        player_idx: int,
        source_slot: str,
        attack_damage_context: dict,
        *,
        finish_attack_in_stack: bool = False,
    ) -> ActionResult:
        stack = ResolutionStack(self.state)
        begin_attack_damage_context(self.state, stack, attack_damage_context)
        stack.add_abort_handler(lambda: clear_attack_damage_context(self.state, stack))
        try:
            commands = [self._build_runtime_command(effect) for effect in effects]
        except (KeyError, ValueError) as exc:
            clear_attack_damage_context(self.state, stack)
            return ActionResult(False, str(exc))
        commands.append(FinalizeAttackDamage())
        if finish_attack_in_stack:
            commands.append(FinalizeAttackTurn(player_idx))
        stack.push_many(commands)
        rr = stack.resolve_all(player_idx, source_slot)
        return self.resolution_result_to_action_result(rr)

    @staticmethod
    def resolution_result_to_action_result(rr) -> ActionResult:
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

    def apply_accumulated_attack_damage(self, result):
        apply_accumulated_attack_damage(
            self.state,
            result,
            attack_failed=bool(getattr(result, "attack_failed", False)),
        )

    def apply_attack_damage(
        self,
        defender,
        attacker,
        base_damage: int,
        attacker_type: str,
        result,
        *,
        piercing: bool = False,
        ignore_defender_effects: bool = False,
    ):
        apply_attack_damage(
            self.state,
            defender,
            attacker,
            base_damage,
            attacker_type,
            result,
            piercing=piercing,
            ignore_defender_effects=ignore_defender_effects,
        )

    def do_attack_ko_checks(self, result):
        do_attack_ko_checks(self.state, result)

    def check_kos(self) -> list[str]:
        return check_kos(self.state)

    def handle_ko(self, player_idx: int, slot: str):
        handle_ko(self.state, player_idx, slot)

    def prompt_bench_promotion(self, player_idx: int):
        self.state.pending_promotion_player = player_idx

    def _build_runtime_command(self, effect):
        return build_runtime_command(
            effect,
            compile_command_spec=self.compile_command_spec,
            build_command=self.build_command,
        )
