"""Control/board/attack/modifier DSL compiler factories for VM commands."""
from __future__ import annotations


def _as_branch_list(value):
    if value is None:
        return []
    if isinstance(value, (list, tuple)):
        return list(value)
    return [value]


def make_conditional(params: dict, **_kw):
    from engine.commands.primitives_coin import Conditional

    return Conditional(
        params={key: value for key, value in params.items() if key not in {"cost", "on_pay"}},
        cost=_as_branch_list(params.get("cost")),
        on_pay=_as_branch_list(params.get("on_pay")),
    )


def make_coin_flip_special(coin_kind: str):
    def factory(params: dict, **_kw):
        from engine.commands.primitives_coin import CoinFlipSpecial

        return CoinFlipSpecial(coin_kind=coin_kind, params=dict(params))

    return factory


def make_coin_flip_energy_discard(params: dict, **_kw):
    from engine.commands.primitives_coin import CoinFlipEnergyDiscard

    return CoinFlipEnergyDiscard()


def make_coin_flip(params: dict, **_kw):
    from engine.commands.primitives_coin import FlipCoin

    return FlipCoin(
        on_heads=list(params.get("on_heads", []) or []),
        on_tails=list(params.get("on_tails", []) or []),
    )


def make_discard_energy(params: dict, **_kw):
    from engine.commands.primitives_board import DiscardEnergy

    return DiscardEnergy(
        amount=params.get("amount", 1),
        from_target=params.get("from", "self"),
        energy_filter=params.get("filter", "any"),
    )


def make_heal(params: dict, **_kw):
    from engine.commands.primitives_board import HealDamage

    return HealDamage(
        amount=params.get("amount", 0),
        target=params.get("target", "self"),
    )


def make_heal_all(params: dict, **_kw):
    from engine.commands.primitives_board import HealDamage

    return HealDamage(
        amount=params.get("amount", 0),
        target="all",
    )


def make_potion_heal(params: dict, **_kw):
    from engine.commands.primitives_board import ChooseHealDamage

    return ChooseHealDamage(
        amount=params.get("amount", 30),
        target_player=params.get("player", "self"),
    )


def make_switch_self(params: dict, **_kw):
    from engine.commands.primitives_board import SwitchPokemon

    return SwitchPokemon(
        target="self",
        optional=params.get("optional", False),
    )


def make_switch_opponent(params: dict, **_kw):
    from engine.commands.primitives_board import SwitchPokemon

    return SwitchPokemon(
        target="opponent",
        you_choose=params.get("you_choose", False),
    )


def make_discard(params: dict, **_kw):
    from engine.commands.primitives_board import DiscardCards

    return DiscardCards(
        amount=params.get("amount", 1),
        from_zone=params.get("from", "hand"),
        player="self",
    )


def make_discard_draw(params: dict, **_kw):
    from engine.commands.primitives_board import DiscardThenDrawCards

    return DiscardThenDrawCards(
        discard_hand=bool(params.get("discard_hand", False)),
        discard_amount=int(params.get("discard_amount", 1) or 1),
        draw_amount=int(params.get("draw", 7) or 7),
    )


def make_discard_then_draw(params: dict, **_kw):
    from engine.commands.primitives_board import DiscardThenDrawCards

    return DiscardThenDrawCards(
        discard_hand=False,
        discard_amount=int(params.get("discard_amount", 1) or 1),
        draw_amount=int(params.get("draw_amount", 3) or 3),
    )


def make_attack_fail(params: dict, **_kw):
    from engine.commands.primitives_attack import AttackFail

    return AttackFail()


def make_attack_flags(params: dict, **_kw):
    from engine.commands.primitives_attack import SetAttackFlags

    return SetAttackFlags(
        ignore_weakness=bool(params.get("ignore_weakness", True)),
        ignore_resistance=bool(params.get("ignore_resistance", True)),
        ignore_effects=bool(params.get("ignore_effects", False)),
    )


def make_return_to_hand(params: dict, **_kw):
    from engine.commands.primitives_attack import ReturnToHand

    return ReturnToHand()


def make_prevent_damage(params: dict, **_kw):
    from engine.commands.primitives_attack import SetPrevention

    return SetPrevention(
        damage=True,
        log_template="{pokemon}下回合将免疫所有伤害。",
        result_message="已设置伤害免疫。",
    )


def make_prevent_effects(params: dict, **_kw):
    from engine.commands.primitives_attack import SetPrevention

    return SetPrevention(
        effects=True,
        log_template="{pokemon}下回合将免疫招式的附加效果！",
        result_message="已设置效果免疫。",
    )


def make_prevent_all(params: dict, **_kw):
    from engine.commands.primitives_attack import SetPrevention

    return SetPrevention(
        damage=True,
        effects=True,
        log_template="{pokemon}下回合将免疫所有伤害和效果！",
        result_message="已设置全部免疫。",
    )


def make_dazzling_beam(params: dict, **_kw):
    from engine.commands.primitives_attack import DazzlingBeam

    return DazzlingBeam(target=str(params.get("target", "opponent_active") or "opponent_active"))


def make_attack_lock_basic(params: dict, **_kw):
    from engine.commands.primitives_attack import AttackLockBasic

    return AttackLockBasic(target=str(params.get("target", "opponent_active") or "opponent_active"))


def make_outgoing_damage_reduction(params: dict, **_kw):
    from engine.commands.primitives_attack import OutgoingDamageReduction

    return OutgoingDamageReduction(
        amount=int(params.get("amount", 0) or 0),
        target=str(params.get("target", "opponent_active") or "opponent_active"),
    )


def make_self_attack_lock(params: dict, **_kw):
    from engine.commands.primitives_attack import SelfAttackLock

    return SelfAttackLock(attack_name=str(params.get("attack_name", "") or ""))


def make_register_modifier(modifier_kind: str):
    def factory(params: dict, **_kw):
        from engine.commands.primitives_attack import RegisterModifier

        return RegisterModifier(modifier_kind=modifier_kind, params=dict(params))

    return factory


def make_register_tool_modifier(params: dict, **_kw):
    from engine.commands.primitives_attack import RegisterToolModifier

    return RegisterToolModifier(params=dict(params))


def _conditional(args: dict, branches: dict):
    from engine.commands.primitives_coin import Conditional

    return Conditional(
        params=dict(args),
        cost=list(branches.get("cost", []) or []),
        on_pay=list(branches.get("on_pay", []) or []),
    )


def _coin_special(coin_kind: str):
    return lambda args, _branches: make_coin_flip_special(coin_kind)(args)


def _discard_cards(args: dict, _branches: dict):
    from engine.commands.primitives_board import DiscardCards

    return DiscardCards(
        amount=int(args.get("amount", 1) or 1),
        from_zone=str(args.get("from", args.get("from_zone", "hand")) or "hand"),
        player=str(args.get("player", "self") or "self"),
    )


def _discard_then_draw(args: dict, _branches: dict):
    from engine.commands.primitives_board import DiscardThenDrawCards

    return DiscardThenDrawCards(
        discard_hand=bool(args.get("discard_hand", False)),
        discard_amount=int(args.get("discard_amount", args.get("amount", 1)) or 1),
        draw_amount=int(args.get("draw_amount", args.get("draw", 0)) or 0),
    )


def _discard_energy(args: dict, _branches: dict):
    from engine.commands.primitives_board import DiscardEnergy

    return DiscardEnergy(
        amount=int(args.get("amount", 1) or 1),
        from_target=str(args.get("from", "self") or "self"),
        energy_filter=str(args.get("filter", args.get("energy_type", "any")) or "any"),
    )


def _choose_heal(args: dict, _branches: dict):
    from engine.commands.primitives_board import ChooseHealDamage

    return ChooseHealDamage(
        amount=int(args.get("amount", 30) or 30),
        target_player=str(args.get("player", args.get("target_player", "self")) or "self"),
    )


def _switch_pokemon(args: dict, _branches: dict):
    from engine.commands.primitives_board import SwitchPokemon

    target = str(args.get("target", "") or "")
    if not target:
        raise ValueError("switch_pokemon VM op requires explicit target")
    return SwitchPokemon(
        target=target,
        optional=bool(args.get("optional", False)),
        you_choose=bool(args.get("you_choose", False)),
    )


def _flip_coin(_args: dict, branches: dict):
    from engine.commands.primitives_coin import FlipCoin

    return FlipCoin(
        on_heads=list(branches.get("on_heads", []) or []),
        on_tails=list(branches.get("on_tails", []) or []),
    )


def _register_modifier(modifier_kind: str):
    return lambda args, _branches: make_register_modifier(modifier_kind)(args)


CONTROL_EFFECT_FACTORIES = {
    "conditional": make_conditional,
    "coin_flip_triple": make_coin_flip_special("repeat_damage"),
    "coin_flip_double_ko": make_coin_flip_special("double_ko"),
    "coin_flip_until_tails": make_coin_flip_special("until_tails"),
    "coin_flip_energy_discard": make_coin_flip_energy_discard,
    "discard": make_discard,
    "discard_draw": make_discard_draw,
    "discard_then_draw": make_discard_then_draw,
    "energy_discard": make_discard_energy,
    "heal": make_heal,
    "heal_all": make_heal_all,
    "potion_heal": make_potion_heal,
    "switch_self": make_switch_self,
    "switch_opponent": make_switch_opponent,
    "coin_flip": make_coin_flip,
    "attack_fail": make_attack_fail,
    "piercing_marker": make_attack_flags,
    "return_to_hand": make_return_to_hand,
    "dazzling_beam": make_dazzling_beam,
    "attack_lock_basic": make_attack_lock_basic,
    "apply_outgoing_damage_reduction": make_outgoing_damage_reduction,
    "self_attack_lock": make_self_attack_lock,
    "prevent_damage": make_prevent_damage,
    "prevent_effects": make_prevent_effects,
    "prevent_all": make_prevent_all,
    "tool": make_register_tool_modifier,
    "tool_exp_share": make_register_modifier("tool_exp_share"),
    "aura_damage_reduction": make_register_modifier("aura_damage_reduction"),
    "aura_damage_boost": make_register_modifier("aura_damage_boost"),
    "conditional_hp_boost": make_register_modifier("conditional_hp_boost"),
    "conditional_zero_retreat": make_register_modifier("conditional_zero_retreat"),
    "reactive_thorns": make_register_modifier("reactive_thorns"),
}


CONTROL_COMMAND_FACTORIES = {
    "conditional": _conditional,
    "flip_coin_repeat_damage": _coin_special("repeat_damage"),
    "flip_coin_then_ko": _coin_special("double_ko"),
    "flip_until_tails": _coin_special("until_tails"),
    "flip_coin_then_discard_energy": lambda args, _branches: make_coin_flip_energy_discard(args),
    "discard_cards": _discard_cards,
    "discard_then_draw_cards": _discard_then_draw,
    "discard_energy": _discard_energy,
    "heal_damage": lambda args, _branches: make_heal(args),
    "choose_heal_damage": _choose_heal,
    "heal_all": lambda args, _branches: make_heal_all(args),
    "switch_pokemon": _switch_pokemon,
    "flip_coin": _flip_coin,
    "fail_attack": lambda args, _branches: make_attack_fail(args),
    "set_attack_flags": lambda args, _branches: make_attack_flags(args),
    "return_to_hand": lambda args, _branches: make_return_to_hand(args),
    "apply_dazzling_beam": lambda args, _branches: make_dazzling_beam(args),
    "apply_attack_lock_basic": lambda args, _branches: make_attack_lock_basic(args),
    "apply_outgoing_damage_reduction": lambda args, _branches: make_outgoing_damage_reduction(args),
    "apply_self_attack_lock": lambda args, _branches: make_self_attack_lock(args),
    "prevent_damage": lambda args, _branches: make_prevent_damage(args),
    "prevent_effects": lambda args, _branches: make_prevent_effects(args),
    "prevent_all": lambda args, _branches: make_prevent_all(args),
    "register_aura_damage_boost": _register_modifier("aura_damage_boost"),
    "register_aura_damage_reduction": _register_modifier("aura_damage_reduction"),
    "register_conditional_hp_boost": _register_modifier("conditional_hp_boost"),
    "register_conditional_zero_retreat": _register_modifier("conditional_zero_retreat"),
    "register_reactive_thorns": _register_modifier("reactive_thorns"),
    "register_tool_exp_share": _register_modifier("tool_exp_share"),
    "register_tool_modifier": lambda args, _branches: make_register_tool_modifier(args),
}


__all__ = [
    "CONTROL_EFFECT_FACTORIES",
    "CONTROL_COMMAND_FACTORIES",
    "make_coin_flip",
    "make_register_modifier",
]
