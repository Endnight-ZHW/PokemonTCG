"""Board-target pending-choice continuation handlers."""
from __future__ import annotations

from engine.commands.choice_helpers import resolve_board_choice


def register_board_continuations(registry, stack) -> None:
    registry.register(
        "switch_confirm",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_switch_confirm(stack, cont, choice),
    )
    registry.register(
        "switch_bench",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_switch_bench(stack, cont, choice),
    )
    registry.register(
        "bench_damage_targets",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_bench_damage_targets(stack, cont, choice),
    )
    registry.register(
        "choose_damage_target",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_choose_damage_target(stack, cont, choice),
    )
    registry.register(
        "evolve_skip_stage",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_evolve_skip_stage(stack, cont, choice),
    )
    registry.register(
        "place_counters_then_self_ko",
        lambda _req, cont, choice, player_idx, slot:
            resolve_place_counters_then_self_ko(stack, cont, choice, player_idx, slot),
    )
    registry.register(
        "choose_heal_damage",
        lambda _req, cont, choice, _player_idx, _slot:
            resolve_choose_heal_damage(stack, cont, choice),
    )


def resolve_switch_confirm(
    stack,
    continuation: dict,
    choice,
):
    from engine.game_state import ActionRequest, ActionResult

    if not bool(choice):
        return ActionResult(True, "未替换宝可梦。")

    bench_indices = [
        int(index)
        for index in continuation.get("bench_indices", []) or []
    ]
    target_player_idx = int(continuation.get("target_player_idx", 0) or 0)
    if len(bench_indices) == 1:
        return resolve_switch_bench(
            stack,
            {
                "target_player_idx": target_player_idx,
                "bench_indices": bench_indices,
            },
            bench_indices[0],
        )

    return ActionRequest(
        request_type=str(continuation.get("request_type", "select_bench")),
        player=int(continuation.get("chooser_idx", target_player_idx) or 0),
        prompt="选择要替换上场的宝可梦",
        min_select=1,
        max_select=1,
        target_player=str(continuation.get("request_target_player", "self")),
        bench_indices=bench_indices,
        continuation={
            "kind": "switch_bench",
            "target_player_idx": target_player_idx,
            "bench_indices": bench_indices,
        },
    )


def resolve_switch_bench(stack, continuation: dict, choice):
    from engine.game_state import ActionResult

    try:
        bench_idx = int(choice)
    except (TypeError, ValueError):
        return ActionResult(False, "没有选择有效的备战宝可梦。")

    allowed = continuation.get("bench_indices", None)
    if allowed is not None:
        allowed_indices = {int(index) for index in allowed or []}
        if allowed_indices and bench_idx not in allowed_indices:
            return ActionResult(False, "选择的备战宝可梦不在可用范围内。")

    target_player_idx = int(continuation.get("target_player_idx", 0) or 0)
    player = stack.state.get_player(target_player_idx)
    if (
        bench_idx < 0
        or bench_idx >= len(player.bench)
        or player.active is None
        or player.bench[bench_idx] is None
    ):
        return ActionResult(False, "选择的备战宝可梦已不存在。")

    active_name = player.active.card.name
    bench_name = player.bench[bench_idx].card.name
    player.switch_active_to_bench(bench_idx)
    stack.state._log(f"将{active_name}与{bench_name}互换了。")
    return ActionResult(True, "替换了战斗宝可梦。")


def resolve_bench_damage_targets(
    stack,
    continuation: dict,
    choice,
):
    from engine.game_state import ActionResult
    from engine.rules_constants import DAMAGE_PER_COUNTER

    target_player_idx = int(continuation.get("target_player_idx", 0) or 0)
    target_state = stack.state.get_player(target_player_idx)
    amount = int(continuation.get("amount", 0) or 0)
    count = int(continuation.get("count", 1) or 1)
    counters = amount // DAMAGE_PER_COUNTER
    allowed = {
        int(index)
        for index in continuation.get("bench_indices", []) or []
    }
    selected_indices = []
    for item in list(choice or [])[:count]:
        try:
            selected_indices.append(int(item))
        except (TypeError, ValueError):
            continue

    hits = 0
    for index in selected_indices:
        if allowed and index not in allowed:
            continue
        if 0 <= index < len(target_state.bench) and target_state.bench[index]:
            target = target_state.bench[index]
            from engine.commands.primitives_combat import _consume_effect_damage_prevention

            if _consume_effect_damage_prevention(stack.state, target, stack=stack):
                continue
            target.damage_counters += counters
            hits += 1
    stack.state._log(
        f"对{target_state.name}的备战区造成了{hits}次{amount}点伤害。"
    )
    return ActionResult(True, f"Bench damage dealt to {hits} Pokemon.")


def resolve_choose_damage_target(
    stack,
    continuation: dict,
    choice,
):
    from engine.game_state import ActionResult
    from engine.rules_constants import DAMAGE_PER_COUNTER
    from engine.commands.primitives_combat import _consume_effect_damage_prevention

    target_player_idx = int(continuation.get("target_player_idx", 0) or 0)
    _slot_name, target_poke = resolve_board_choice(
        stack.state,
        target_player_idx,
        choice,
    )
    if target_poke is None:
        return ActionResult(True, "")
    if _consume_effect_damage_prevention(stack.state, target_poke, stack=stack):
        return ActionResult(True, "")

    amount = int(continuation.get("amount", 0) or 0)
    target_poke.damage_counters += amount // DAMAGE_PER_COUNTER
    stack.state._log(f"对{target_poke.card.name}造成了{amount}点伤害。")
    return ActionResult(True, "")


def resolve_evolve_skip_stage(stack, continuation: dict, choice):
    from engine.commands.modifier_registration import (
        register_pokemon_modifiers,
        unregister_pokemon_modifiers,
    )
    from engine.commands.primitives_recovery import (
        EvolveSkipStage,
        _build_runtime_command,
    )
    from engine.commands.resolution_stack import ResolutionStack
    from engine.effects.runtime_effects import (
        strict_ability_runtime_effects as ability_runtime_effects,
    )
    from engine.game_state import ActionResult

    player_idx = int(continuation.get("player_idx", 0) or 0)
    state = stack.state
    if state.is_player_first_turn(player_idx):
        return ActionResult(False, "第一回合不能使用神奇糖果。")
    selected = choice
    if isinstance(selected, (list, tuple)):
        selected = selected[0] if selected else None
    if not isinstance(selected, dict):
        return ActionResult(False, "没有选择神奇糖果进化目标。")

    player = state.get_player(player_idx)
    slot_name = str(selected.get("slot", "") or "")
    hand_index = int(selected.get("hand_index", -1))
    stage2_id = str(selected.get("card_id", "") or "")
    base_id = str(selected.get("base_card_id", "") or "")
    if hand_index < 0 or hand_index >= len(player.hand):
        return ActionResult(False, "进化卡已不在手牌中。")
    stage2 = player.hand[hand_index]
    if getattr(stage2, "api_id", "") != stage2_id:
        return ActionResult(False, "进化卡已变化。")
    pokemon = player.get_pokemon(slot_name)
    if pokemon is None:
        return ActionResult(False, "进化目标已不存在。")
    if getattr(pokemon.card, "api_id", "") != base_id:
        return ActionResult(False, "进化目标已变化。")
    if (
        not pokemon.card.is_basic_pokemon
        or pokemon.placed_this_turn
        or not pokemon.can_evolve_this_turn
        or not getattr(stage2, "is_stage2", False)
        or not EvolveSkipStage._stage2_matches_basic(stage2, pokemon.card.name)
    ):
        return ActionResult(False, "选择的神奇糖果进化不合法。")

    old_name = pokemon.card.name
    old_api_id = pokemon.card.api_id
    player.hand.pop(hand_index)
    player.evolve_pokemon(slot_name, stage2)

    unregister_pokemon_modifiers(
        old_api_id,
        slot_name,
        event_bus=state.event_bus,
        player_idx=player_idx,
    )
    register_pokemon_modifiers(pokemon, player_idx, slot_name, event_bus=state.event_bus)

    for ability in stage2.abilities or []:
        if ability.trigger == "on_enter_play":
            effect_stack = ResolutionStack(state)
            effect_stack.push_many([
                _build_runtime_command(effect)
                for effect in ability_runtime_effects(ability)
            ])
            effect_stack.resolve_all(player_idx, slot_name)

    state._log(f"{player.name}使用神奇糖果将{old_name}进化成了{stage2.name}！")
    return ActionResult(True, f"Rare Candy: {old_name} -> {stage2.name}")


def resolve_place_counters_then_self_ko(
    stack,
    continuation: dict,
    choice,
    player_idx: int,
    source_slot: str,
):
    from engine.game_state import ActionResult
    from engine.commands.primitives_combat import (
        _discard_pokemon_for_effect,
    )

    target_player_idx = int(continuation.get("target_player_idx", 0) or 0)
    slot_name, target_poke = resolve_board_choice(
        stack.state,
        target_player_idx,
        choice,
    )
    if target_poke is None or not slot_name:
        return ActionResult(True, "神秘彗星没有选择目标。")

    counters = int(continuation.get("counters", 0) or 0)
    target_poke.damage_counters += counters
    stack.state._log(f"在{target_poke.card.name}身上放置了{counters}个伤害指示物。")
    source = _discard_pokemon_for_effect(
        stack.state,
        player_idx,
        source_slot,
    )
    if source:
        stack.state._log(f"{source.card.name}被放置于弃牌区。")

    return ActionResult(
        True,
        "神秘彗星结算完毕。",
    )


def resolve_choose_heal_damage(
    stack,
    continuation: dict,
    choice,
):
    from engine.game_state import ActionResult
    from engine.rules_constants import DAMAGE_PER_COUNTER

    target_player_idx = int(continuation.get("target_player_idx", 0) or 0)
    _slot_name, target_poke = resolve_board_choice(
        stack.state,
        target_player_idx,
        choice,
    )
    if target_poke is None:
        return ActionResult(False, "无效的回复目标。")

    amount = int(continuation.get("amount", 0) or 0)
    counters = amount // DAMAGE_PER_COUNTER
    target_poke.damage_counters = max(0, target_poke.damage_counters - counters)
    stack.state.get_player(target_player_idx).healed_this_turn = True
    stack.state._log(f"{target_poke.card.name}回复了{amount}点HP。")
    return ActionResult(True, f"{target_poke.card.name}回复了{amount}点HP。")
