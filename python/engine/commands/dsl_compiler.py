"""DSL Compiler — translates EffectDef data into atomic primitive Commands.

This is the bridge between existing card effect data (effect_type + params)
and the new atomic primitives. Effect types must be explicitly registered as
native primitives; unknown effects fail instead of falling back to legacy
effect dispatch.
"""
from __future__ import annotations
from typing import Callable, TYPE_CHECKING

from engine.commands.ir import (
    CommandSpec,
    compile_effect_to_spec,
    compile_effects_to_payload,
    compile_effects_to_specs,
    missing_ir_effect_types,
)

if TYPE_CHECKING:
    from engine.commands.base import ICommand
    from engine.commands.primitives import DealDamage

# Registry: effect_type -> factory(parsed_params) -> ICommand
_primitives_registry: dict[str, Callable] = {}


def register_primitive(effect_type: str, factory: Callable):
    """Register a primitive compiler for an effect type."""
    _primitives_registry[effect_type] = factory


def compile_effect(effect_def, **overrides) -> ICommand:
    """Compile a single EffectDef into a native ICommand.

    Args:
        effect_def: EffectDef object or dict with effect_type + params
        **overrides: passed through to the command factory
    """
    if hasattr(effect_def, 'effect_type'):
        etype = effect_def.effect_type
        params = dict(effect_def.params)
    elif isinstance(effect_def, dict):
        etype = effect_def.get("effect_type", "")
        params = dict(effect_def.get("params", {}))
    else:
        raise ValueError(f"Invalid effect_def: {effect_def}")

    factory = _primitives_registry.get(etype)
    if factory is not None:
        return factory(params, **overrides)

    raise ValueError(f"No native command registered for effect_type={etype!r}")


def compile_effects(effect_defs: list, **overrides) -> list[ICommand]:
    """Compile a list of EffectDefs into ICommands."""
    return [compile_effect(e, **overrides) for e in effect_defs]


def compile_command_spec(spec) -> ICommand:
    """Compile a VM CommandSpec/dict directly into a native ICommand.

    This bypasses effect_type dispatch entirely for migrated atomic ops.
    """
    if isinstance(spec, CommandSpec):
        op = spec.op
        args = dict(spec.args)
        branches = {key: list(value) for key, value in spec.branches.items()}
    elif isinstance(spec, dict):
        op = str(spec.get("op", "") or "")
        args = dict(spec.get("args", {}) or {})
        branches = dict(spec.get("branches", {}) or {})
    else:
        raise ValueError(f"Invalid command spec: {spec!r}")

    if "effect_type" in args:
        raise ValueError("VM command specs must not carry legacy effect_type args")

    if op == "deal_damage":
        from engine.commands.primitives import DealDamage
        return DealDamage(
            amount=int(args.get("amount", 0) or 0),
            target=str(args.get("target", "opponent_active") or "opponent_active"),
            piercing=bool(args.get("piercing", False)),
        )
    if op == "deal_bench_damage":
        from engine.commands.primitives import BenchDamage
        return BenchDamage(
            amount=int(args.get("amount", 0) or 0),
            count=int(args.get("count", 1) or 1),
            target_player=str(args.get("player", args.get("target_player", "opponent")) or "opponent"),
            choose_targets=bool(args.get("choose_targets", True)),
        )
    if op == "choose_damage_target":
        from engine.commands.primitives import ChooseDamageTarget
        return ChooseDamageTarget(
            amount=int(args.get("amount", 0) or 0),
            target_player=str(args.get("player", args.get("target_player", "opponent")) or "opponent"),
        )
    if op == "place_counters_then_self_ko":
        from engine.commands.primitives import PlaceCountersThenSelfKo
        return PlaceCountersThenSelfKo(
            counters=int(args.get("counters", 2) or 2),
            target_player=str(args.get("player", args.get("target_player", "opponent")) or "opponent"),
        )
    formula_ops = {
        "deal_damage_per_discard_psychic": "per_discard_psychic",
        "deal_damage_per_energy": "per_energy",
        "deal_damage_per_evolved": "per_evolved",
        "deal_damage_per_hand_size": "per_hand_size",
        "deal_damage_per_self_damage": "per_self_damage",
        "deal_damage_per_self_energy": "per_self_energy",
        "deal_damage_per_self_energy_type": "per_self_energy_type",
        "deal_damage_plus_bench": "plus_bench",
    }
    if op in formula_ops:
        return _make_damage_formula_command(formula_ops[op], args)
    if op == "set_attack_damage_formula":
        from engine.commands.primitives import SetAttackDamageFormula
        return SetAttackDamageFormula(params=dict(args))
    if op == "conditional_damage_then_heal":
        from engine.commands.primitives import ConditionalDamageHeal
        return ConditionalDamageHeal(params=dict(args))
    if op == "conditional_damage":
        from engine.commands.primitives import ConditionalDamageBonus
        return ConditionalDamageBonus(params=dict(args))
    if op == "conditional":
        from engine.commands.primitives import Conditional
        return Conditional(
            params=dict(args),
            cost=list(branches.get("cost", []) or []),
            on_pay=list(branches.get("on_pay", []) or []),
        )
    if op == "discard_hand_then_damage":
        from engine.commands.primitives import DiscardHandThenDamage
        return DiscardHandThenDamage(params=dict(args))
    if op == "discard_energy_then_damage":
        from engine.commands.primitives import DiscardEnergyThenDamage
        return DiscardEnergyThenDamage(params=dict(args))
    if op == "mill_then_damage":
        from engine.commands.primitives import MillThenDamage
        return MillThenDamage(params=dict(args))
    if op == "deal_damage_then_heal":
        from engine.commands.primitives import DamageAndSelfHeal
        return DamageAndSelfHeal(params=dict(args))
    if op == "deal_damage_with_self_penalty":
        from engine.commands.primitives import DealDamage

        return DealDamage(
            amount=0,
            target="opponent_active",
            formula=(
                f"{int(args.get('base', 0) or 0)}"
                f" - self_damage_counters * {int(args.get('per_counter', 0) or 0)}"
            ),
        )
    if op == "place_damage_counters":
        from engine.commands.primitives import DealDamage
        return DealDamage(
            amount=int(args.get("amount", 0) or 0),
            target="self",
            check_self_ko=True,
        )
    if op == "apply_status":
        from engine.commands.primitives import ApplyStatus
        return ApplyStatus(
            status=str(args.get("status", "") or ""),
            target=str(args.get("target", "opponent_active") or "opponent_active"),
            condition=str(args.get("condition", "") or ""),
        )
    if op == "draw_cards":
        from engine.commands.primitives import DrawCards
        return DrawCards(
            count=int(args.get("amount", args.get("count", 1)) or 1),
            player=str(args.get("player", "self") or "self"),
        )
    if op == "draw_until":
        from engine.commands.primitives import DrawUntil
        return DrawUntil(target_hand_size=int(args.get("target_hand_size", 5) or 5))
    if op == "draw_until_more_than_opponent":
        from engine.commands.primitives import DrawUntilMore
        return DrawUntilMore(margin=int(args.get("margin", 1) or 1))
    if op == "shuffle_then_draw_cards":
        from engine.commands.primitives import ShuffleThenDrawCards
        return ShuffleThenDrawCards(
            draw_amount=int(args.get("draw", args.get("amount", 5)) or 5),
            shuffle_hand=bool(args.get("shuffle_hand", False)),
        )
    if op == "judge":
        from engine.commands.primitives import Judge
        return Judge(draw_amount=int(args.get("draw", args.get("amount", 4)) or 4))
    if op == "shuffle_from_discard_to_deck":
        from engine.commands.primitives import RecoverFromDiscard
        return RecoverFromDiscard(mode="shuffle_to_deck", params=dict(args))
    if op == "recover_clara":
        from engine.commands.primitives import RecoverFromDiscard
        return RecoverFromDiscard(mode="clara", params=dict(args))
    if op == "hand_to_bottom_then_draw":
        from engine.commands.primitives import HandToBottomThenDraw
        return HandToBottomThenDraw()
    if op == "hand_to_bottom_draw_until":
        from engine.commands.primitives import HandToBottomDrawUntil
        return HandToBottomDrawUntil(target_hand_size=int(args.get("target_hand_size", 5) or 5))
    if op == "zinnia_resolve":
        from engine.commands.primitives import ZinniaResolve
        return ZinniaResolve()
    if op == "search_cards":
        from engine.commands.primitives import SearchCards
        return SearchCards(params=dict(args))
    if op == "look_top_deck":
        from engine.commands.primitives import LookTopDeck
        return LookTopDeck(params=dict(args))
    if op == "look_top_attach_energy":
        from engine.commands.primitives import LookTopAttachEnergy
        return LookTopAttachEnergy(params=dict(args))
    if op == "draw_and_attach_energy":
        from engine.commands.primitives import DrawAndAttachEnergy
        return DrawAndAttachEnergy(params=dict(args))
    if op == "attach_energy":
        from engine.commands.primitives import EnergyAttach
        return EnergyAttach(params=dict(args))
    if op == "attach_energy_from_discard":
        from engine.commands.primitives import AttachEnergyFromDiscard
        return AttachEnergyFromDiscard(params=dict(args))
    if op == "relocate_energy":
        from engine.commands.primitives import EnergyRelocate
        return EnergyRelocate(params=dict(args))
    if op == "search_item_and_tool":
        from engine.commands.primitives import SearchItemAndTool
        return SearchItemAndTool()
    if op == "trekking_shoes":
        from engine.commands.primitives import TrekkingShoes
        return TrekkingShoes()
    if op in {"flip_coin_repeat_damage", "flip_coin_then_ko", "flip_until_tails"}:
        from engine.commands.primitives import CoinFlipSpecial

        coin_kind = {
            "flip_coin_repeat_damage": "repeat_damage",
            "flip_coin_then_ko": "double_ko",
            "flip_until_tails": "until_tails",
        }[op]
        return CoinFlipSpecial(coin_kind=coin_kind, params=dict(args))
    if op == "flip_coin_then_discard_energy":
        from engine.commands.primitives import CoinFlipEnergyDiscard
        return CoinFlipEnergyDiscard()
    if op == "conditional_search":
        from engine.commands.primitives import ConditionalSearchExtra
        return ConditionalSearchExtra(params=dict(args))
    if op == "search_any_and_switch":
        from engine.commands.primitives import SearchAnyAndSwitch
        return SearchAnyAndSwitch(params=dict(args))
    if op == "discard_then_revive":
        from engine.commands.primitives import AbilityDiscardRevive
        return AbilityDiscardRevive(card_id=str(args.get("card_id", "") or ""))
    if op == "evolve_skip_stage":
        from engine.commands.primitives import EvolveSkipStage
        return EvolveSkipStage()
    if op == "discard_cards":
        from engine.commands.primitives import DiscardCards
        return DiscardCards(
            amount=int(args.get("amount", 1) or 1),
            from_zone=str(args.get("from", args.get("from_zone", "hand")) or "hand"),
            player=str(args.get("player", "self") or "self"),
        )
    if op == "discard_then_draw_cards":
        from engine.commands.primitives import DiscardThenDrawCards
        return DiscardThenDrawCards(
            discard_hand=bool(args.get("discard_hand", False)),
            discard_amount=int(args.get("discard_amount", args.get("amount", 1)) or 1),
            draw_amount=int(args.get("draw_amount", args.get("draw", 0)) or 0),
        )
    if op == "discard_energy":
        from engine.commands.primitives import DiscardEnergy
        return DiscardEnergy(
            amount=int(args.get("amount", 1) or 1),
            from_target=str(args.get("from", "self") or "self"),
            energy_filter=str(args.get("filter", args.get("energy_type", "any")) or "any"),
        )
    if op == "heal_damage":
        from engine.commands.primitives import HealDamage
        return HealDamage(
            amount=int(args.get("amount", 0) or 0),
            target=str(args.get("target", "self") or "self"),
        )
    if op == "choose_heal_damage":
        from engine.commands.primitives import ChooseHealDamage
        return ChooseHealDamage(
            amount=int(args.get("amount", 30) or 30),
            target_player=str(args.get("player", args.get("target_player", "self")) or "self"),
        )
    if op == "heal_all":
        from engine.commands.primitives import HealDamage
        return HealDamage(
            amount=int(args.get("amount", 0) or 0),
            target="all",
        )
    if op == "switch_pokemon":
        from engine.commands.primitives import SwitchPokemon

        target = str(args.get("target", "") or "")
        if not target:
            raise ValueError("switch_pokemon VM op requires explicit target")
        return SwitchPokemon(
            target=target,
            optional=bool(args.get("optional", False)),
            you_choose=bool(args.get("you_choose", False)),
        )
    if op == "conditional_status":
        from engine.commands.primitives import ApplyStatus
        return ApplyStatus(
            status=str(args.get("status", "") or ""),
            target=str(args.get("target", "opponent_active") or "opponent_active"),
            condition=str(args.get("condition", "") or ""),
        )
    if op == "flip_coin":
        from engine.commands.primitives import FlipCoin
        return FlipCoin(
            on_heads=list(branches.get("on_heads", []) or []),
            on_tails=list(branches.get("on_tails", []) or []),
        )
    if op == "fail_attack":
        from engine.commands.primitives import AttackFail
        return AttackFail()
    if op == "set_attack_flags":
        from engine.commands.primitives import SetAttackFlags
        return SetAttackFlags(
            ignore_weakness=bool(args.get("ignore_weakness", True)),
            ignore_resistance=bool(args.get("ignore_resistance", True)),
            ignore_effects=bool(args.get("ignore_effects", False)),
        )
    if op == "return_to_hand":
        from engine.commands.primitives import ReturnToHand
        return ReturnToHand()
    if op == "apply_dazzling_beam":
        return _make_dazzling_beam(args)
    if op == "apply_attack_lock_basic":
        return _make_attack_lock_basic(args)
    if op == "apply_outgoing_damage_reduction":
        return _make_outgoing_damage_reduction(args)
    if op == "apply_self_attack_lock":
        return _make_self_attack_lock(args)
    if op == "prevent_damage":
        return _make_prevent_damage(args)
    if op == "prevent_effects":
        return _make_prevent_effects(args)
    if op == "prevent_all":
        return _make_prevent_all(args)
    explicit_modifier_ops = {
        "register_aura_damage_boost": "aura_damage_boost",
        "register_aura_damage_reduction": "aura_damage_reduction",
        "register_conditional_hp_boost": "conditional_hp_boost",
        "register_conditional_zero_retreat": "conditional_zero_retreat",
        "register_reactive_thorns": "reactive_thorns",
        "register_tool_exp_share": "tool_exp_share",
    }
    if op in explicit_modifier_ops:
        from engine.commands.primitives import RegisterModifier

        return RegisterModifier(modifier_kind=explicit_modifier_ops[op], params=dict(args))
    if op == "register_tool_modifier":
        from engine.commands.primitives import RegisterToolModifier
        return RegisterToolModifier(params=dict(args))

    raise ValueError(f"No native ICommand registered for VM op={op!r}")


__all__ = [
    "CommandSpec",
    "compile_effect",
    "compile_effects",
    "compile_command_spec",
    "compile_effect_to_spec",
    "compile_effects_to_payload",
    "compile_effects_to_specs",
    "missing_ir_effect_types",
    "register_primitive",
]


# ═══════════════════════════════════════════════════════
# Primitive Mappings
# ═══════════════════════════════════════════════════════

def _make_damage(params: dict, **_kw):
    from engine.commands.primitives import DealDamage
    return DealDamage(
        amount=params.get("amount", 0),
        target=params.get("target", "opponent_active"),
        piercing=params.get("piercing", False),
    )


def _make_damage_counter_self(params: dict, **_kw):
    from engine.commands.primitives import DealDamage
    return DealDamage(
        amount=params.get("amount", 0),
        target="self",
        check_self_ko=True,
    )


def _make_bench_damage(params: dict, **_kw):
    from engine.commands.primitives import BenchDamage
    return BenchDamage(
        amount=int(params.get("amount", 0) or 0),
        count=int(params.get("count", 1) or 1),
        target_player=str(params.get("player", "opponent") or "opponent"),
        choose_targets=bool(params.get("choose_targets", True)),
    )


def _make_any_pokemon_damage(params: dict, **_kw):
    from engine.commands.primitives import ChooseDamageTarget
    return ChooseDamageTarget(
        amount=int(params.get("amount", 0) or 0),
        target_player=str(params.get("player", "opponent") or "opponent"),
    )


def _make_place_counters_self_ko(params: dict, **_kw):
    from engine.commands.primitives import PlaceCountersThenSelfKo
    return PlaceCountersThenSelfKo(
        counters=int(params.get("counters", 2) or 2),
        target_player=str(params.get("player", "opponent") or "opponent"),
    )


def _make_damage_per_hand_size(params: dict, **_kw):
    return _make_damage_formula_command("per_hand_size", params)


def _make_damage_formula_command(formula_kind: str, params: dict):
    from engine.commands.primitives import DealDamageFormula

    return DealDamageFormula(formula_kind=formula_kind, params=dict(params))


def _make_damage_plus_bench(params: dict, **_kw):
    return _make_damage_formula_command("plus_bench", params)


def _make_damage_per_self_damage(params: dict, **_kw):
    return _make_damage_formula_command("per_self_damage", params)


def _make_damage_per_energy(params: dict, **_kw):
    return _make_damage_formula_command("per_energy", params)


def _make_damage_per_self_energy(params: dict, **_kw):
    return _make_damage_formula_command("per_self_energy", params)


def _make_damage_per_self_energy_type(params: dict, **_kw):
    return _make_damage_formula_command("per_self_energy_type", params)


def _make_damage_per_discard_psychic(params: dict, **_kw):
    return _make_damage_formula_command("per_discard_psychic", params)


def _make_damage_per_evolved(params: dict, **_kw):
    return _make_damage_formula_command("per_evolved", params)


def _make_damage_self_penalty(params: dict, **_kw):
    from engine.commands.primitives import DealDamage
    return DealDamage(
        amount=0,
        target="opponent_active",
        formula=(
            f"{int(params.get('base', 0) or 0)}"
            f" - self_damage_counters * {int(params.get('per_counter', 0) or 0)}"
        ),
    )


def _make_attack_damage_formula(params: dict, **_kw):
    from engine.commands.primitives import SetAttackDamageFormula
    return SetAttackDamageFormula(params=dict(params))


def _make_conditional_damage_heal(params: dict, **_kw):
    from engine.commands.primitives import ConditionalDamageHeal
    return ConditionalDamageHeal(params=dict(params))


def _make_conditional_damage_bonus(params: dict, **_kw):
    from engine.commands.primitives import ConditionalDamageBonus
    return ConditionalDamageBonus(params=dict(params))


def _as_branch_list(value):
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return list(value)
    return [value]


def _make_conditional(params: dict, **_kw):
    from engine.commands.primitives import Conditional
    return Conditional(
        params={key: value for key, value in params.items() if key not in {"cost", "on_pay"}},
        cost=_as_branch_list(params.get("cost")),
        on_pay=_as_branch_list(params.get("on_pay")),
    )


def _make_damage_and_self_heal(params: dict, **_kw):
    from engine.commands.primitives import DamageAndSelfHeal
    return DamageAndSelfHeal(params=dict(params))


def _make_discard_hand_damage(params: dict, **_kw):
    from engine.commands.primitives import DiscardHandThenDamage
    return DiscardHandThenDamage(params=dict(params))


def _make_discard_energy_damage(params: dict, **_kw):
    from engine.commands.primitives import DiscardEnergyThenDamage
    return DiscardEnergyThenDamage(params=dict(params))


def _make_mill_then_damage(params: dict, **_kw):
    from engine.commands.primitives import MillThenDamage
    return MillThenDamage(params=dict(params))


def _make_status(params: dict, **_kw):
    from engine.commands.primitives import ApplyStatus
    return ApplyStatus(
        status=params.get("status", ""),
        target=params.get("target", "opponent_active"),
    )


def _make_conditional_status(params: dict, **_kw):
    from engine.commands.primitives import ApplyStatus
    return ApplyStatus(
        status=params.get("status", ""),
        target=params.get("target", "opponent_active"),
        condition=params.get("condition", ""),
    )


def _make_draw(params: dict, **_kw):
    from engine.commands.primitives import DrawCards
    return DrawCards(
        count=params.get("amount", 1),
        player=params.get("player", "self"),
    )


def _make_draw_until(params: dict, **_kw):
    from engine.commands.primitives import DrawUntil
    return DrawUntil(target_hand_size=int(params.get("target_hand_size", 5) or 5))


def _make_draw_until_more(params: dict, **_kw):
    from engine.commands.primitives import DrawUntilMore
    return DrawUntilMore(margin=int(params.get("margin", 1) or 1))


def _make_shuffle_draw(params: dict, **_kw):
    from engine.commands.primitives import ShuffleThenDrawCards
    return ShuffleThenDrawCards(
        draw_amount=int(params.get("draw", 5) or 5),
        shuffle_hand=bool(params.get("shuffle_hand", False)),
    )


def _make_judge(params: dict, **_kw):
    from engine.commands.primitives import Judge
    return Judge(draw_amount=int(params.get("draw", 4) or 4))


def _make_recover_from_discard(mode: str):
    def factory(params: dict, **_kw):
        from engine.commands.primitives import RecoverFromDiscard
        return RecoverFromDiscard(mode=mode, params=dict(params))
    return factory


def _make_hand_to_bottom_draw(params: dict, **_kw):
    from engine.commands.primitives import HandToBottomThenDraw
    return HandToBottomThenDraw()


def _make_houb(params: dict, **_kw):
    from engine.commands.primitives import HandToBottomDrawUntil
    return HandToBottomDrawUntil(target_hand_size=int(params.get("target_hand_size", 5) or 5))


def _make_zinnia_resolve(params: dict, **_kw):
    from engine.commands.primitives import ZinniaResolve
    return ZinniaResolve()


def _make_search(params: dict, **_kw):
    from engine.commands.primitives import SearchCards
    return SearchCards(params=dict(params))


def _make_look_top_deck(params: dict, **_kw):
    from engine.commands.primitives import LookTopDeck
    return LookTopDeck(params=dict(params))


def _make_look_top_attach_energy(params: dict, **_kw):
    from engine.commands.primitives import LookTopAttachEnergy
    return LookTopAttachEnergy(params=dict(params))


def _make_draw_and_attach_energy(params: dict, **_kw):
    from engine.commands.primitives import DrawAndAttachEnergy
    return DrawAndAttachEnergy(params=dict(params))


def _make_energy_attach(params: dict, **_kw):
    from engine.commands.primitives import EnergyAttach
    return EnergyAttach(params=dict(params))


def _make_attach_from_discard(params: dict, **_kw):
    from engine.commands.primitives import AttachEnergyFromDiscard
    return AttachEnergyFromDiscard(params=dict(params))


def _make_energy_relocate(params: dict, **_kw):
    from engine.commands.primitives import EnergyRelocate
    return EnergyRelocate(params=dict(params))


def _make_arven(params: dict, **_kw):
    from engine.commands.primitives import SearchItemAndTool
    return SearchItemAndTool()


def _make_trekking_shoes(params: dict, **_kw):
    from engine.commands.primitives import TrekkingShoes
    return TrekkingShoes()


def _make_coin_flip_special(coin_kind: str):
    def factory(params: dict, **_kw):
        from engine.commands.primitives import CoinFlipSpecial
        return CoinFlipSpecial(coin_kind=coin_kind, params=dict(params))
    return factory


def _make_coin_flip_energy_discard(params: dict, **_kw):
    from engine.commands.primitives import CoinFlipEnergyDiscard
    return CoinFlipEnergyDiscard()


def _make_conditional_search_extra(params: dict, **_kw):
    from engine.commands.primitives import ConditionalSearchExtra
    return ConditionalSearchExtra(params=dict(params))


def _make_search_any_and_switch(params: dict, **_kw):
    from engine.commands.primitives import SearchAnyAndSwitch
    return SearchAnyAndSwitch(params=dict(params))


def _make_ability_discard_revive(params: dict, **_kw):
    from engine.commands.primitives import AbilityDiscardRevive
    return AbilityDiscardRevive(card_id=str(params.get("card_id", "") or ""))


def _make_evolve_skip_stage(params: dict, **_kw):
    from engine.commands.primitives import EvolveSkipStage
    return EvolveSkipStage()


def _make_coin_flip(params: dict, **_kw):
    from engine.commands.primitives import FlipCoin
    return FlipCoin(
        on_heads=list(params.get("on_heads", []) or []),
        on_tails=list(params.get("on_tails", []) or []),
    )


def _make_discard_energy(params: dict, **_kw):
    from engine.commands.primitives import DiscardEnergy
    return DiscardEnergy(
        amount=params.get("amount", 1),
        from_target=params.get("from", "self"),
        energy_filter=params.get("filter", "any"),
    )


def _make_heal(params: dict, **_kw):
    from engine.commands.primitives import HealDamage
    return HealDamage(
        amount=params.get("amount", 0),
        target=params.get("target", "self"),
    )


def _make_heal_all(params: dict, **_kw):
    from engine.commands.primitives import HealDamage
    return HealDamage(
        amount=params.get("amount", 0),
        target="all",
    )


def _make_potion_heal(params: dict, **_kw):
    from engine.commands.primitives import ChooseHealDamage
    return ChooseHealDamage(
        amount=params.get("amount", 30),
        target_player=params.get("player", "self"),
    )


def _make_switch_self(params: dict, **_kw):
    from engine.commands.primitives import SwitchPokemon
    return SwitchPokemon(
        target="self",
        optional=params.get("optional", False),
    )


def _make_switch_opponent(params: dict, **_kw):
    from engine.commands.primitives import SwitchPokemon
    return SwitchPokemon(
        target="opponent",
        you_choose=params.get("you_choose", False),
    )


def _make_discard(params: dict, **_kw):
    from engine.commands.primitives import DiscardCards
    return DiscardCards(
        amount=params.get("amount", 1),
        from_zone=params.get("from", "hand"),
        player="self",
    )


def _make_discard_draw(params: dict, **_kw):
    from engine.commands.primitives import DiscardThenDrawCards
    return DiscardThenDrawCards(
        discard_hand=bool(params.get("discard_hand", False)),
        discard_amount=int(params.get("discard_amount", 1) or 1),
        draw_amount=int(params.get("draw", 7) or 7),
    )


def _make_discard_then_draw(params: dict, **_kw):
    from engine.commands.primitives import DiscardThenDrawCards
    return DiscardThenDrawCards(
        discard_hand=False,
        discard_amount=int(params.get("discard_amount", 1) or 1),
        draw_amount=int(params.get("draw_amount", 3) or 3),
    )


def _make_attack_fail(params: dict, **_kw):
    from engine.commands.primitives import AttackFail
    return AttackFail()


def _make_attack_flags(params: dict, **_kw):
    from engine.commands.primitives import SetAttackFlags
    return SetAttackFlags(
        ignore_weakness=bool(params.get("ignore_weakness", True)),
        ignore_resistance=bool(params.get("ignore_resistance", True)),
        ignore_effects=bool(params.get("ignore_effects", False)),
    )


def _make_return_to_hand(params: dict, **_kw):
    from engine.commands.primitives import ReturnToHand
    return ReturnToHand()


def _make_prevent_damage(params: dict, **_kw):
    from engine.commands.primitives import SetPrevention
    return SetPrevention(
        damage=True,
        log_template="{pokemon}下回合将免疫所有伤害。",
        result_message="已设置伤害免疫。",
    )


def _make_prevent_effects(params: dict, **_kw):
    from engine.commands.primitives import SetPrevention
    return SetPrevention(
        effects=True,
        log_template="{pokemon}下回合将免疫招式的附加效果！",
        result_message="已设置效果免疫。",
    )


def _make_prevent_all(params: dict, **_kw):
    from engine.commands.primitives import SetPrevention
    return SetPrevention(
        damage=True,
        effects=True,
        log_template="{pokemon}下回合将免疫所有伤害和效果！",
        result_message="已设置全部免疫。",
    )


def _make_dazzling_beam(params: dict, **_kw):
    from engine.commands.primitives import DazzlingBeam
    return DazzlingBeam(target=str(params.get("target", "opponent_active") or "opponent_active"))


def _make_attack_lock_basic(params: dict, **_kw):
    from engine.commands.primitives import AttackLockBasic
    return AttackLockBasic(target=str(params.get("target", "opponent_active") or "opponent_active"))


def _make_outgoing_damage_reduction(params: dict, **_kw):
    from engine.commands.primitives import OutgoingDamageReduction
    return OutgoingDamageReduction(
        amount=int(params.get("amount", 0) or 0),
        target=str(params.get("target", "opponent_active") or "opponent_active"),
    )


def _make_self_attack_lock(params: dict, **_kw):
    from engine.commands.primitives import SelfAttackLock
    return SelfAttackLock(attack_name=str(params.get("attack_name", "") or ""))


def _make_register_modifier(modifier_kind: str):
    def factory(params: dict, **_kw):
        from engine.commands.primitives import RegisterModifier

        return RegisterModifier(modifier_kind=modifier_kind, params=dict(params))
    return factory


def _make_register_tool_modifier(params: dict, **_kw):
    from engine.commands.primitives import RegisterToolModifier
    return RegisterToolModifier(params=dict(params))


# Primitive mappings are intentionally explicit. Many release effects have
# card-specific prompts, failure semantics, logging, and discard ownership; add
# new effect types here only after parity tests prove equivalent behavior.
_EFFECT_TO_PRIMITIVE = {
    "damage": _make_damage,
    "any_pokemon_damage": _make_any_pokemon_damage,
    "bench_damage": _make_bench_damage,
    "place_counters_and_self_ko": _make_place_counters_self_ko,
    "damage_counter_self": _make_damage_counter_self,
    "damage_per_discard_psychic": _make_damage_per_discard_psychic,
    "damage_per_energy": _make_damage_per_energy,
    "damage_per_evolved": _make_damage_per_evolved,
    "damage_per_hand_size": _make_damage_per_hand_size,
    "damage_plus_bench": _make_damage_plus_bench,
    "damage_per_self_damage": _make_damage_per_self_damage,
    "damage_per_self_energy": _make_damage_per_self_energy,
    "damage_per_self_energy_type": _make_damage_per_self_energy_type,
    "damage_self_penalty": _make_damage_self_penalty,
    "attack_damage_formula": _make_attack_damage_formula,
    "conditional_damage_bonus": _make_conditional_damage_bonus,
    "conditional_damage_heal": _make_conditional_damage_heal,
    "conditional": _make_conditional,
    "damage_and_self_heal": _make_damage_and_self_heal,
    "discard_hand_conditional_bonus": _make_discard_hand_damage,
    "discard_fighting_energy_damage": _make_discard_energy_damage,
    "mill_and_damage_per_energy": _make_mill_then_damage,
    "status": _make_status,
    "conditional_status": _make_conditional_status,
    "draw": _make_draw,
    "draw_until": _make_draw_until,
    "draw_until_more": _make_draw_until_more,
    "shuffle_draw": _make_shuffle_draw,
    "judge": _make_judge,
    "shuffle_from_discard": _make_recover_from_discard("shuffle_to_deck"),
    "clara": _make_recover_from_discard("clara"),
    "hand_to_bottom_draw": _make_hand_to_bottom_draw,
    "houb": _make_houb,
    "zinnia_resolve": _make_zinnia_resolve,
    "search": _make_search,
    "look_top_deck": _make_look_top_deck,
    "look_top_attach_energy": _make_look_top_attach_energy,
    "draw_and_attach_energy": _make_draw_and_attach_energy,
    "energy_attach": _make_energy_attach,
    "attach_from_discard": _make_attach_from_discard,
    "energy_relocate": _make_energy_relocate,
    "arven": _make_arven,
    "trekking_shoes": _make_trekking_shoes,
    "coin_flip_triple": _make_coin_flip_special("repeat_damage"),
    "coin_flip_double_ko": _make_coin_flip_special("double_ko"),
    "coin_flip_until_tails": _make_coin_flip_special("until_tails"),
    "coin_flip_energy_discard": _make_coin_flip_energy_discard,
    "conditional_search_extra": _make_conditional_search_extra,
    "search_any_and_switch": _make_search_any_and_switch,
    "ability_discard_revive": _make_ability_discard_revive,
    "evolve_skip_stage": _make_evolve_skip_stage,
    "discard": _make_discard,
    "discard_draw": _make_discard_draw,
    "discard_then_draw": _make_discard_then_draw,
    "energy_discard": _make_discard_energy,
    "heal": _make_heal,
    "heal_all": _make_heal_all,
    "potion_heal": _make_potion_heal,
    "switch_self": _make_switch_self,
    "switch_opponent": _make_switch_opponent,
    "coin_flip": _make_coin_flip,
    "attack_fail": _make_attack_fail,
    "piercing_marker": _make_attack_flags,
    "return_to_hand": _make_return_to_hand,
    "dazzling_beam": _make_dazzling_beam,
    "attack_lock_basic": _make_attack_lock_basic,
    "apply_outgoing_damage_reduction": _make_outgoing_damage_reduction,
    "self_attack_lock": _make_self_attack_lock,
    "prevent_damage": _make_prevent_damage,
    "prevent_effects": _make_prevent_effects,
    "prevent_all": _make_prevent_all,
    "tool": _make_register_tool_modifier,
    "tool_exp_share": _make_register_modifier("tool_exp_share"),
    "aura_damage_reduction": _make_register_modifier("aura_damage_reduction"),
    "aura_damage_boost": _make_register_modifier("aura_damage_boost"),
    "conditional_hp_boost": _make_register_modifier("conditional_hp_boost"),
    "conditional_zero_retreat": _make_register_modifier("conditional_zero_retreat"),
    "reactive_thorns": _make_register_modifier("reactive_thorns"),
}


for etype, factory in _EFFECT_TO_PRIMITIVE.items():
    register_primitive(etype, factory)
