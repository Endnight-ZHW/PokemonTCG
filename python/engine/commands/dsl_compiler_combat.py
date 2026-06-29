"""Combat-related DSL compiler factories for VM commands."""
from __future__ import annotations


def make_damage(params: dict, **_kw):
    from engine.commands.primitives_combat import DealDamage

    formula = params.get("formula", "")
    formula_ast = params.get("formula_ast")
    if formula_ast is None and isinstance(formula, dict):
        formula_ast = dict(formula)
        formula = ""
    return DealDamage(
        amount=params.get("amount", 0),
        target=params.get("target", "opponent_active"),
        piercing=params.get("piercing", False),
        formula=str(formula or ""),
        formula_ast=formula_ast,
        consume_condition=str(params.get("consume_condition", "") or ""),
    )


def make_damage_counter_self(params: dict, **_kw):
    from engine.commands.primitives_combat import DealDamage

    return DealDamage(
        amount=params.get("amount", 0),
        target="self",
        check_self_ko=True,
    )


def make_bench_damage(params: dict, **_kw):
    from engine.commands.primitives_combat import BenchDamage

    return BenchDamage(
        amount=int(params.get("amount", 0) or 0),
        count=int(params.get("count", 1) or 1),
        target_player=str(params.get("player", "opponent") or "opponent"),
        choose_targets=bool(params.get("choose_targets", True)),
    )


def make_any_pokemon_damage(params: dict, **_kw):
    from engine.commands.primitives_combat import ChooseDamageTarget

    return ChooseDamageTarget(
        amount=int(params.get("amount", 0) or 0),
        target_player=str(params.get("player", "opponent") or "opponent"),
    )


def make_place_counters_self_ko(params: dict, **_kw):
    from engine.commands.primitives_combat import PlaceCountersThenSelfKo

    return PlaceCountersThenSelfKo(
        counters=int(params.get("counters", 2) or 2),
        target_player=str(params.get("player", "opponent") or "opponent"),
    )


def make_damage_formula_command(formula_kind: str, params: dict):
    from engine.commands.primitives_combat import DealDamageFormula

    return DealDamageFormula(formula_kind=formula_kind, params=dict(params))


def make_damage_per_hand_size(params: dict, **_kw):
    return make_damage_formula_command("per_hand_size", params)


def make_damage_plus_bench(params: dict, **_kw):
    return make_damage_formula_command("plus_bench", params)


def make_damage_per_self_damage(params: dict, **_kw):
    return make_damage_formula_command("per_self_damage", params)


def make_damage_per_energy(params: dict, **_kw):
    return make_damage_formula_command("per_energy", params)


def make_damage_per_self_energy(params: dict, **_kw):
    return make_damage_formula_command("per_self_energy", params)


def make_damage_per_self_energy_type(params: dict, **_kw):
    return make_damage_formula_command("per_self_energy_type", params)


def make_damage_per_discard_psychic(params: dict, **_kw):
    return make_damage_formula_command("per_discard_psychic", params)


def make_damage_per_evolved(params: dict, **_kw):
    return make_damage_formula_command("per_evolved", params)


def make_damage_self_penalty(params: dict, **_kw):
    from engine.commands.primitives_combat import DealDamage

    return DealDamage(
        amount=0,
        target="opponent_active",
        formula=(
            f"{int(params.get('base', 0) or 0)}"
            f" - self_damage_counters * {int(params.get('per_counter', 0) or 0)}"
        ),
    )


def make_attack_damage_formula(params: dict, **_kw):
    from engine.commands.primitives_combat import SetAttackDamageFormula

    return SetAttackDamageFormula(params=dict(params))


def make_conditional_damage_heal(params: dict, **_kw):
    from engine.commands.primitives_combat import ConditionalDamageHeal

    return ConditionalDamageHeal(params=dict(params))


def make_conditional_damage_bonus(params: dict, **_kw):
    from engine.commands.primitives_combat import ConditionalDamageBonus

    return ConditionalDamageBonus(params=dict(params))


def make_damage_and_self_heal(params: dict, **_kw):
    from engine.commands.primitives_combat import DamageAndSelfHeal

    return DamageAndSelfHeal(params=dict(params))


def make_discard_hand_damage(params: dict, **_kw):
    from engine.commands.primitives_combat import DiscardHandThenDamage

    return DiscardHandThenDamage(params=dict(params))


def make_discard_energy_damage(params: dict, **_kw):
    from engine.commands.primitives_combat import DiscardEnergyThenDamage

    return DiscardEnergyThenDamage(params=dict(params))


def make_mill_then_damage(params: dict, **_kw):
    from engine.commands.primitives_combat import MillThenDamage

    return MillThenDamage(params=dict(params))


def _damage_formula(formula_kind: str):
    return lambda args, _branches: make_damage_formula_command(formula_kind, args)


COMBAT_EFFECT_FACTORIES = {
    "damage": make_damage,
    "any_pokemon_damage": make_any_pokemon_damage,
    "bench_damage": make_bench_damage,
    "place_counters_and_self_ko": make_place_counters_self_ko,
    "damage_counter_self": make_damage_counter_self,
    "damage_per_discard_psychic": make_damage_per_discard_psychic,
    "damage_per_energy": make_damage_per_energy,
    "damage_per_evolved": make_damage_per_evolved,
    "damage_per_hand_size": make_damage_per_hand_size,
    "damage_plus_bench": make_damage_plus_bench,
    "damage_per_self_damage": make_damage_per_self_damage,
    "damage_per_self_energy": make_damage_per_self_energy,
    "damage_per_self_energy_type": make_damage_per_self_energy_type,
    "damage_self_penalty": make_damage_self_penalty,
    "attack_damage_formula": make_attack_damage_formula,
    "conditional_damage_bonus": make_conditional_damage_bonus,
    "conditional_damage_heal": make_conditional_damage_heal,
    "damage_and_self_heal": make_damage_and_self_heal,
    "discard_hand_conditional_bonus": make_discard_hand_damage,
    "discard_fighting_energy_damage": make_discard_energy_damage,
    "mill_and_damage_per_energy": make_mill_then_damage,
}


COMBAT_COMMAND_FACTORIES = {
    "deal_damage": lambda args, _branches: make_damage(args),
    "deal_bench_damage": lambda args, _branches: make_bench_damage(args),
    "choose_damage_target": lambda args, _branches: make_any_pokemon_damage(args),
    "place_counters_then_self_ko": lambda args, _branches: make_place_counters_self_ko(args),
    "deal_damage_per_discard_psychic": _damage_formula("per_discard_psychic"),
    "deal_damage_per_energy": _damage_formula("per_energy"),
    "deal_damage_per_evolved": _damage_formula("per_evolved"),
    "deal_damage_per_hand_size": _damage_formula("per_hand_size"),
    "deal_damage_per_self_damage": _damage_formula("per_self_damage"),
    "deal_damage_per_self_energy": _damage_formula("per_self_energy"),
    "deal_damage_per_self_energy_type": _damage_formula("per_self_energy_type"),
    "deal_damage_plus_bench": _damage_formula("plus_bench"),
    "set_attack_damage_formula": lambda args, _branches: make_attack_damage_formula(args),
    "conditional_damage_then_heal": lambda args, _branches: make_conditional_damage_heal(args),
    "conditional_damage": lambda args, _branches: make_conditional_damage_bonus(args),
    "discard_hand_then_damage": lambda args, _branches: make_discard_hand_damage(args),
    "discard_energy_then_damage": lambda args, _branches: make_discard_energy_damage(args),
    "mill_then_damage": lambda args, _branches: make_mill_then_damage(args),
    "deal_damage_then_heal": lambda args, _branches: make_damage_and_self_heal(args),
    "deal_damage_with_self_penalty": lambda args, _branches: make_damage_self_penalty(args),
    "place_damage_counters": lambda args, _branches: make_damage_counter_self(args),
}


__all__ = [
    "COMBAT_EFFECT_FACTORIES",
    "COMBAT_COMMAND_FACTORIES",
    "make_damage",
    "make_damage_formula_command",
]
