"""Support/status/search/energy DSL compiler factories for VM commands."""
from __future__ import annotations


def make_status(params: dict, **_kw):
    from engine.commands.primitives_status import ApplyStatus

    return ApplyStatus(
        status=params.get("status", ""),
        target=params.get("target", "opponent_active"),
    )


def make_conditional_status(params: dict, **_kw):
    from engine.commands.primitives_status import ApplyStatus

    return ApplyStatus(
        status=params.get("status", ""),
        target=params.get("target", "opponent_active"),
        condition=params.get("condition", ""),
    )


def make_draw(params: dict, **_kw):
    from engine.commands.primitives_draw import DrawCards

    return DrawCards(
        count=params.get("amount", 1),
        player=params.get("player", "self"),
    )


def make_draw_until(params: dict, **_kw):
    from engine.commands.primitives_draw import DrawUntil

    return DrawUntil(target_hand_size=int(params.get("target_hand_size", 5) or 5))


def make_draw_until_more(params: dict, **_kw):
    from engine.commands.primitives_draw import DrawUntilMore

    return DrawUntilMore(margin=int(params.get("margin", 1) or 1))


def make_shuffle_draw(params: dict, **_kw):
    from engine.commands.primitives_draw import ShuffleThenDrawCards

    return ShuffleThenDrawCards(
        draw_amount=int(params.get("draw", 5) or 5),
        shuffle_hand=bool(params.get("shuffle_hand", False)),
    )


def make_judge(params: dict, **_kw):
    from engine.commands.primitives_draw import Judge

    return Judge(draw_amount=int(params.get("draw", 4) or 4))


def make_recover_from_discard(mode: str):
    def factory(params: dict, **_kw):
        from engine.commands.primitives_recovery import RecoverFromDiscard

        return RecoverFromDiscard(mode=mode, params=dict(params))

    return factory


def make_hand_to_bottom_draw(params: dict, **_kw):
    from engine.commands.primitives_recovery import HandToBottomThenDraw

    return HandToBottomThenDraw()


def make_houb(params: dict, **_kw):
    from engine.commands.primitives_recovery import HandToBottomDrawUntil

    return HandToBottomDrawUntil(target_hand_size=int(params.get("target_hand_size", 5) or 5))


def make_zinnia_resolve(params: dict, **_kw):
    from engine.commands.primitives_recovery import ZinniaResolve

    return ZinniaResolve()


def make_search(params: dict, **_kw):
    from engine.commands.primitives_search import SearchCards

    return SearchCards(params=dict(params))


def make_look_top_deck(params: dict, **_kw):
    from engine.commands.primitives_search import LookTopDeck

    return LookTopDeck(params=dict(params))


def make_look_top_attach_energy(params: dict, **_kw):
    from engine.commands.primitives_search import LookTopAttachEnergy

    return LookTopAttachEnergy(params=dict(params))


def make_draw_and_attach_energy(params: dict, **_kw):
    from engine.commands.primitives_energy import DrawAndAttachEnergy

    return DrawAndAttachEnergy(params=dict(params))


def make_energy_attach(params: dict, **_kw):
    from engine.commands.primitives_energy import EnergyAttach

    return EnergyAttach(params=dict(params))


def make_attach_from_discard(params: dict, **_kw):
    from engine.commands.primitives_energy import AttachEnergyFromDiscard

    return AttachEnergyFromDiscard(params=dict(params))


def make_energy_relocate(params: dict, **_kw):
    from engine.commands.primitives_energy import EnergyRelocate

    return EnergyRelocate(params=dict(params))


def make_arven(params: dict, **_kw):
    from engine.commands.primitives_search import SearchItemAndTool

    return SearchItemAndTool()


def make_trekking_shoes(params: dict, **_kw):
    from engine.commands.primitives_search import TrekkingShoes

    return TrekkingShoes()


def make_conditional_search_extra(params: dict, **_kw):
    from engine.commands.primitives_search import ConditionalSearchExtra

    return ConditionalSearchExtra(params=dict(params))


def make_search_any_and_switch(params: dict, **_kw):
    from engine.commands.primitives_search import SearchAnyAndSwitch

    return SearchAnyAndSwitch(params=dict(params))


def make_ability_discard_revive(params: dict, **_kw):
    from engine.commands.primitives_recovery import AbilityDiscardRevive

    return AbilityDiscardRevive(
        card_id=str(params.get("card_id", "") or ""),
        discard_idx=int(params.get("discard_idx", -1)),
    )


def make_evolve_skip_stage(params: dict, **_kw):
    from engine.commands.primitives_recovery import EvolveSkipStage

    return EvolveSkipStage()


def _draw_cards(args: dict, _branches: dict):
    from engine.commands.primitives_draw import DrawCards

    return DrawCards(
        count=int(args.get("amount", args.get("count", 1)) or 1),
        player=str(args.get("player", "self") or "self"),
    )


def _apply_status(args: dict, _branches: dict):
    from engine.commands.primitives_status import ApplyStatus

    return ApplyStatus(
        status=str(args.get("status", "") or ""),
        target=str(args.get("target", "opponent_active") or "opponent_active"),
        condition=str(args.get("condition", "") or ""),
    )


def _draw_until(args: dict, _branches: dict):
    from engine.commands.primitives_draw import DrawUntil

    return DrawUntil(target_hand_size=int(args.get("target_hand_size", 5) or 5))


def _shuffle_then_draw(args: dict, _branches: dict):
    from engine.commands.primitives_draw import ShuffleThenDrawCards

    return ShuffleThenDrawCards(
        draw_amount=int(args.get("draw", args.get("amount", 5)) or 5),
        shuffle_hand=bool(args.get("shuffle_hand", False)),
    )


SUPPORT_EFFECT_FACTORIES = {
    "status": make_status,
    "conditional_status": make_conditional_status,
    "draw": make_draw,
    "draw_until": make_draw_until,
    "draw_until_more": make_draw_until_more,
    "shuffle_draw": make_shuffle_draw,
    "judge": make_judge,
    "shuffle_from_discard": make_recover_from_discard("shuffle_to_deck"),
    "clara": make_recover_from_discard("clara"),
    "hand_to_bottom_draw": make_hand_to_bottom_draw,
    "houb": make_houb,
    "zinnia_resolve": make_zinnia_resolve,
    "search": make_search,
    "look_top_deck": make_look_top_deck,
    "look_top_attach_energy": make_look_top_attach_energy,
    "draw_and_attach_energy": make_draw_and_attach_energy,
    "energy_attach": make_energy_attach,
    "attach_from_discard": make_attach_from_discard,
    "energy_relocate": make_energy_relocate,
    "arven": make_arven,
    "trekking_shoes": make_trekking_shoes,
    "conditional_search_extra": make_conditional_search_extra,
    "search_any_and_switch": make_search_any_and_switch,
    "ability_discard_revive": make_ability_discard_revive,
    "evolve_skip_stage": make_evolve_skip_stage,
}


SUPPORT_COMMAND_FACTORIES = {
    "apply_status": _apply_status,
    "draw_cards": _draw_cards,
    "draw_until": _draw_until,
    "draw_until_more_than_opponent": lambda args, _branches: make_draw_until_more(args),
    "shuffle_then_draw_cards": _shuffle_then_draw,
    "judge": lambda args, _branches: make_judge(args),
    "shuffle_from_discard_to_deck": lambda args, _branches: make_recover_from_discard("shuffle_to_deck")(args),
    "recover_clara": lambda args, _branches: make_recover_from_discard("clara")(args),
    "hand_to_bottom_then_draw": lambda args, _branches: make_hand_to_bottom_draw(args),
    "hand_to_bottom_draw_until": lambda args, _branches: make_houb(args),
    "zinnia_resolve": lambda args, _branches: make_zinnia_resolve(args),
    "search_cards": lambda args, _branches: make_search(args),
    "look_top_deck": lambda args, _branches: make_look_top_deck(args),
    "look_top_attach_energy": lambda args, _branches: make_look_top_attach_energy(args),
    "draw_and_attach_energy": lambda args, _branches: make_draw_and_attach_energy(args),
    "attach_energy": lambda args, _branches: make_energy_attach(args),
    "attach_energy_from_discard": lambda args, _branches: make_attach_from_discard(args),
    "relocate_energy": lambda args, _branches: make_energy_relocate(args),
    "search_item_and_tool": lambda args, _branches: make_arven(args),
    "trekking_shoes": lambda args, _branches: make_trekking_shoes(args),
    "conditional_search": lambda args, _branches: make_conditional_search_extra(args),
    "search_any_and_switch": lambda args, _branches: make_search_any_and_switch(args),
    "discard_then_revive": lambda args, _branches: make_ability_discard_revive(args),
    "evolve_skip_stage": lambda args, _branches: make_evolve_skip_stage(args),
    "conditional_status": lambda args, _branches: make_conditional_status(args),
}


__all__ = [
    "SUPPORT_EFFECT_FACTORIES",
    "SUPPORT_COMMAND_FACTORIES",
    "make_draw",
    "make_status",
]
