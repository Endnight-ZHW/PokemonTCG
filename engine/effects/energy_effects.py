"""Energy-related effect handlers.

All energy operations use PokemonInPlay.energy_cards, a single unified
list of Card objects (basic and special energy together).
"""
from engine.rules_constants import DAMAGE_PER_COUNTER
from engine.game_state import GameState, ActionResult, ActionRequest


def _energy_source(player, from_zone):
    return (player.hand, "手牌") if from_zone == "hand" else (player.deck, "牌库")


def _matching_energy_cards(source_zone, filter_type):
    return [
        c for c in source_zone
        if c.is_energy and (
            filter_type == "any" or
            any(et.lower() == filter_type.lower() for et in c.provides_energy)
        )
    ]


def _handle_energy_attach(state, player, player_idx, params, source_slot):
    """Attach energy from hand or deck to a Pokemon."""
    amount = params.get("amount", 1)
    from_zone = params.get("from_zone", "hand")
    filter_type = params.get("filter", "any")
    to_target = params.get("to", "self")
    going_second_bonus = params.get("going_second_bonus", 0)
    optional = params.get("optional", False)

    if going_second_bonus > 0:
        if state.is_going_second_first_turn(player_idx):
            amount = going_second_bonus
            state._log(f"后攻最初回合！可附着最多{amount}张能量。")

    source_pool, zone_name = _energy_source(player, from_zone)
    if not _matching_energy_cards(source_pool, filter_type):
        return ActionResult(True, f"{zone_name}中无匹配的能量。")

    if to_target == "self":
        target_slot = source_slot
    elif to_target == "any":
        all_slots = []
        if player.active:
            all_slots.append(("active", player.active))
        all_slots.extend([(f"bench_{i}", p) for i, p in enumerate(player.bench) if p is not None])
        if not all_slots:
            if optional:
                return ActionResult(True, "场上没有宝可梦。")
            return ActionResult(False, "场上没有宝可梦可附着能量。")
        if len(all_slots) == 1:
            target_slot = all_slots[0][0]
        else:
            def _do_any_attach(selected_cards):
                for card in selected_cards:
                    for slot_name, poke in all_slots:
                        if poke.card.api_id == card.api_id:
                            _attach_energy_to_target(state, player, from_zone, filter_type, amount, poke, optional)
                            return
            any_cards = [p.card for _, p in all_slots]
            return ActionResult(True, "选择1只宝可梦附着能量。",
                                pending_action=ActionRequest(
                                    request_type="search_deck",
                                    player=player_idx,
                                    prompt="选择1只宝可梦附着能量。",
                                    min_select=1,
                                    max_select=1,
                                    from_zone="board",
                                    card_list=any_cards,
                                    callback=_do_any_attach,
                                ))
    elif to_target == "bench":
        bench_slots = [(i, p) for i, p in enumerate(player.bench) if p is not None]
        if not bench_slots:
            if optional:
                return ActionResult(True, "备战区无宝可梦。")
            return ActionResult(False, "备战区没有宝可梦可附着能量。")
        if len(bench_slots) == 1:
            target_slot = f"bench_{bench_slots[0][0]}"
        elif amount <= 1:
            # Single energy: simple bench pick
            def _do_bench_attach(selected_bench_idx):
                t_slot = f"bench_{selected_bench_idx}"
                t = player.get_pokemon(t_slot)
                if t is None:
                    return
                _attach_energy_to_target(state, player, from_zone, filter_type, amount, t)
            bench_indices = [i for i, _ in bench_slots]
            return ActionResult(True, "选择备战宝可梦附着能量。",
                                pending_action=ActionRequest(
                                    request_type="select_own_bench_energy",
                                    player=player_idx,
                                    prompt="选择1只备战宝可梦附着能量。",
                                    max_select=1,
                                    bench_indices=bench_indices,
                                    callback=_do_bench_attach,
                                ))
        else:
            # Multiple energy: use distribution screen
            from_zone_name = zone_name
            matching = _matching_energy_cards(source_pool, filter_type)
            energy_to_distribute = matching[:amount]
            targets_info = [
                {"slot": f"bench_{i}", "name": p.card.name, "bench_idx": i}
                for i, p in bench_slots
            ]

            def _on_distributed(assignments):
                for ei, tgt_slot in assignments:
                    if ei < len(energy_to_distribute):
                        card = energy_to_distribute[ei]
                        if card in source_pool:
                            source_pool.remove(card)
                            bp = player.get_pokemon(tgt_slot)
                            if bp:
                                bp.energy_cards.append(card)
                if from_zone == "deck":
                    player.shuffle_deck()
                state._log(
                    f"从{from_zone_name}将{len(assignments)}个能量附着于备战区。"
                )

            return ActionResult(True, f"分配能量 — {from_zone_name}",
                                pending_action=ActionRequest(
                                    request_type="distribute_energy",
                                    player=player_idx,
                                    prompt=f"分配能量 — 从{from_zone_name}附着",
                                    card_list=energy_to_distribute,
                                    target_info=targets_info,
                                    distribute_mode="distribute",
                                    source_name=from_zone_name,
                                    callback=_on_distributed,
                                ))
    elif to_target == "self_basic":
        basic_pokemon = []
        if player.active and player.active.card.is_basic_pokemon:
            basic_pokemon.append(("active", player.active))
        for i, p in enumerate(player.bench):
            if p and p.card.is_basic_pokemon:
                basic_pokemon.append((f"bench_{i}", p))
        if not basic_pokemon:
            return ActionResult(False, "没有基础宝可梦可附着能量。")
        if len(basic_pokemon) == 1:
            target_slot = basic_pokemon[0][0]
        else:
            def _do_basic_attach(selected_cards):
                for card in selected_cards:
                    for slot_name, poke in basic_pokemon:
                        if poke.card.api_id == card.api_id:
                            _attach_energy_to_target(state, player, from_zone, filter_type, amount, poke, optional)
                            return
            basic_cards = [p.card for _, p in basic_pokemon]
            return ActionResult(True, "选择1只基础宝可梦附着能量。",
                                pending_action=ActionRequest(
                                    request_type="search_deck",
                                    player=player_idx,
                                    prompt="选择1只基础宝可梦附着能量。",
                                    min_select=1,
                                    max_select=1,
                                    from_zone="board",
                                    card_list=basic_cards,
                                    callback=_do_basic_attach,
                                ))
    else:
        target_slot = to_target

    target = player.get_pokemon(target_slot)
    if target is None:
        if optional:
            return ActionResult(True, "无目标宝可梦。")
        return ActionResult(False, f"No Pokemon at {target_slot}.")

    return _attach_energy_to_target(state, player, from_zone, filter_type, amount, target, optional)


def _attach_energy_to_target(state, player, from_zone, filter_type, amount, target, optional=False):
    """Attach energy cards from hand/deck to a specific target Pokemon."""
    source_zone, zone_name = _energy_source(player, from_zone)
    matching = _matching_energy_cards(source_zone, filter_type)
    if not matching and optional:
        return ActionResult(True, f"{zone_name}中无匹配的能量。")

    count = min(amount, len(matching))
    attached = 0
    for i in range(count):
        card = matching[i]
        if card in source_zone:
            source_zone.remove(card)
            target.energy_cards.append(card)
            attached += 1

    if from_zone == "deck":
        player.shuffle_deck()

    state._log(f"从{zone_name}向{target.card.name}附着了{attached}个能量。")
    return ActionResult(True, f"Attached {attached} energy from {from_zone}.")


def _handle_energy_discard(state, player, opponent, params, source_slot):
    """Discard energy from a Pokemon."""
    amount = params.get("amount", 1)
    from_target = params.get("from", "self")
    filter_type = params.get("filter", "any")

    target = player.active if from_target == "self" else opponent.active
    discard_pile = player.discard if from_target == "self" else opponent.discard
    if target is None:
        return ActionResult(False, "没有可丢弃能量的目标。")

    # Check if opponent's active is immune to attack effects
    if from_target != "self" and getattr(target, 'all_prevented_next_turn', False):
        target.all_prevented_next_turn = False
        state._log(f"{target.card.name}免疫了能量丢弃的效果！")
        return ActionResult(True, "免疫了效果。")

    discarded = 0
    remaining = []
    for card in target.energy_cards:
        if discarded < amount and (filter_type == "any" or
                                    any(et.lower() == filter_type.lower()
                                        for et in card.provides_energy)):
            discard_pile.append(card)
            discarded += 1
        else:
            remaining.append(card)

    target.energy_cards = remaining
    state._log(f"从{target.card.name}丢弃了{discarded}个能量。")
    return ActionResult(True, f"Discarded {discarded} energy.")


def _do_energy_relocate(state, source_poke, target_poke, move_count):
    """Move energy cards from source to target Pokemon."""
    moved = 0
    for _ in range(move_count):
        if source_poke.energy_cards:
            card = source_poke.energy_cards.pop()
            target_poke.energy_cards.append(card)
            moved += 1

    state._log(f"将{moved}个能量从{source_poke.card.name}转附到{target_poke.card.name}。")


def _handle_energy_relocate(state, player, player_idx, params):
    """Move energy between Pokemon. Used by 波琵, 代欧奇希斯, etc."""
    amount = params.get("amount", 2)
    from_self = params.get("from_self", False)

    if from_self:
        # ── 代欧奇希斯 / 投掷猴: move energy from active to bench ──
        source_poke = player.active
        if source_poke is None or not source_poke.energy_cards:
            return ActionResult(True, "没有能量可转附。")

        bench_pokemon = [(i, p) for i, p in enumerate(player.bench) if p is not None]
        if not bench_pokemon:
            return ActionResult(True, "备战区没有宝可梦可转附能量。")

        move_count = min(amount, len(source_poke.energy_cards))

        # Single bench: auto-transfer
        if len(bench_pokemon) == 1:
            target_poke = bench_pokemon[0][1]
            _do_energy_relocate(state, source_poke, target_poke, move_count)
            return ActionResult(True,
                f"将{move_count}个能量从{source_poke.card.name}转附到{target_poke.card.name}。")

        # Multi bench: show distribution screen
        energy_cards_to_move = list(source_poke.energy_cards[:move_count])
        targets_info = [
            {"slot": f"bench_{i}", "name": p.card.name, "bench_idx": i}
            for i, p in bench_pokemon
        ]

        def _on_distributed(assignments):
            # assignments: list of (energy_card_index_in_list, target_slot)
            cards_to_move = list(source_poke.energy_cards)
            for ei, tgt_slot in assignments:
                if ei >= len(cards_to_move):
                    continue
                card = cards_to_move[ei]
                if card in source_poke.energy_cards:
                    source_poke.energy_cards.remove(card)
                    tgt = player.get_pokemon(tgt_slot)
                    if tgt:
                        tgt.energy_cards.append(card)
            state._log(
                f"将{len(assignments)}个能量从{source_poke.card.name}转附到备战区。"
            )

        return ActionResult(True, "选择能量卡分配到备战宝可梦。",
                            pending_action=ActionRequest(
                                request_type="distribute_energy",
                                player=player_idx,
                                prompt=f"分配能量 — {source_poke.card.name}",
                                card_list=energy_cards_to_move,
                                target_info=targets_info,
                                distribute_mode="distribute",
                                source_name=source_poke.card.name,
                                callback=_on_distributed,
                            ))

    # ── 波琵 / Energy Switch: player chooses source, then distributes ──
    all_pokemon = [
        (slot_name, p) for slot_name, p in player.get_all_pokemon()
        if p is not None and p.energy_cards
    ]
    if not all_pokemon:
        return ActionResult(True, "场上没有宝可梦附着能量。")

    if sum(1 for _, p in player.get_all_pokemon() if p is not None) <= 1:
        return ActionResult(True, "没有其他宝可梦可转附能量。")

    # Step 1: choose source Pokemon
    source_options = []
    for sname, p in all_pokemon:
        if sname == "active":
            source_options.append({"slot": "active", "name": p.card.name, "bench_idx": -1})
        elif sname.startswith("bench_"):
            source_options.append({
                "slot": sname,
                "name": p.card.name,
                "bench_idx": int(sname.split("_")[1]),
            })

    def _on_source_chosen(assignments):
        if not assignments:
            return None
        ei, src_slot = assignments[0]
        src = player.get_pokemon(src_slot)
        if src is None or not src.energy_cards:
            return None

        move_n = min(amount, len(src.energy_cards))
        # Build target list (all Pokemon except source)
        targets_info = []
        for sname, p in player.get_all_pokemon():
            if p is not None and p is not src:
                targets_info.append({
                    "slot": sname,
                    "name": p.card.name,
                    "bench_idx": int(sname.split("_")[1]) if sname.startswith("bench_") else -1,
                })

        if not targets_info:
            return None

        energy_cards_to_move = list(src.energy_cards[:move_n])

        def _on_distributed(dist_assignments):
            cards_list = list(src.energy_cards)
            for ei, tgt_slot in dist_assignments:
                if ei >= len(cards_list):
                    continue
                card = cards_list[ei]
                if card in src.energy_cards:
                    src.energy_cards.remove(card)
                    tgt = player.get_pokemon(tgt_slot)
                    if tgt:
                        tgt.energy_cards.append(card)
            state._log(f"将{len(dist_assignments)}个能量从{src.card.name}转附。")

        return ActionRequest(
            request_type="distribute_energy",
            player=player_idx,
            prompt=f"分配能量 — {src.card.name}",
            card_list=energy_cards_to_move,
            target_info=targets_info,
            distribute_mode="paired",
            max_per_target=move_n,
            source_name=src.card.name,
            callback=_on_distributed,
        )

    # Show source selection using the same distribution screen (mode='source_select')
    # For source selection, the "energy cards" are the Pokemon choices
    return ActionResult(True, "选择来源宝可梦。",
                        pending_action=ActionRequest(
                            request_type="distribute_energy",
                            player=player_idx,
                            prompt="选择来源宝可梦",
                            card_list=[],  # No energy cards — just selecting source
                            target_info=source_options,
                            distribute_mode="source_select",
                            source_name="选择来源",
                            callback=_on_source_chosen,
                        ))


def _handle_attach_from_discard(state, player, player_idx, params, source_slot):
    """Attach basic energy from discard pile to Pokemon(s)."""
    amount = params.get("amount", 1)
    energy_type = params.get("energy_type", "any")
    target_spec = params.get("target", "self")

    matching = [
        c for c in player.discard
        if c.is_basic_energy and (energy_type in ("any", "basic", "basic_energy") or
                                  any(et.lower() == energy_type.lower()
                                      for et in c.provides_energy))
    ]
    count = min(amount, len(matching))
    if count == 0:
        return ActionResult(True, "弃牌区没有符合条件的能量。")

    if target_spec == "self":
        target_pokemon = player.active
        if target_pokemon is None:
            return ActionResult(False, "没有战斗宝可梦。")
        _attach_cards_to_pokemon(state, player, matching, count, target_pokemon, energy_type)

    elif target_spec == "bench":
        bench_slots = [(i, p) for i, p in enumerate(player.bench) if p is not None]
        if not bench_slots:
            return ActionResult(True, "备战区无宝可梦。")
        if len(bench_slots) == 1:
            target_pokemon = bench_slots[0][1]
            _attach_cards_to_pokemon(state, player, matching, count, target_pokemon, energy_type)
        elif count <= 1:
            # Single energy: simple bench pick
            def _do_bench_attach(selected_idx):
                t = player.get_pokemon(f"bench_{selected_idx}")
                if t is None:
                    return
                _attach_cards_to_pokemon(state, player, matching, count, t, energy_type)
            return ActionResult(True, "选择备战宝可梦附着能量。",
                                pending_action=ActionRequest(
                                    request_type="select_own_bench_energy",
                                    player=player_idx,
                                    prompt="选择1只备战宝可梦附着能量。",
                                    max_select=1,
                                    bench_indices=[i for i, _ in bench_slots],
                                    callback=_do_bench_attach,
                                ))
        else:
            # Multiple energy: use distribution screen
            energy_to_distribute = matching[:count]
            targets_info = [
                {"slot": f"bench_{i}", "name": p.card.name, "bench_idx": i}
                for i, p in bench_slots
            ]
            def _on_distributed(assignments):
                for ei, tgt_slot in assignments:
                    if ei < len(energy_to_distribute):
                        card = energy_to_distribute[ei]
                        if card in player.discard:
                            player.discard.remove(card)
                            bp = player.get_pokemon(tgt_slot)
                            if bp:
                                bp.energy_cards.append(card)
                state._log(f"将{len(assignments)}个能量从弃牌区附着于备战区。")

            return ActionResult(True, "分配能量到备战宝可梦。",
                                pending_action=ActionRequest(
                                    request_type="distribute_energy",
                                    player=player_idx,
                                    prompt="分配能量 — 从弃牌区附着",
                                    card_list=energy_to_distribute,
                                    target_info=targets_info,
                                    distribute_mode="distribute",
                                    source_name="弃牌区",
                                    callback=_on_distributed,
                                ))

    elif target_spec == "self_or_bench":
        all_pokemon = []
        if player.active:
            all_pokemon.append(("active", player.active))
        for i, p in enumerate(player.bench):
            if p is not None:
                all_pokemon.append((f"bench_{i}", p))
        if not all_pokemon:
            return ActionResult(False, "没有目标宝可梦。")
        if len(all_pokemon) == 1:
            _attach_cards_to_pokemon(state, player, matching, count, all_pokemon[0][1], energy_type)
        else:
            def _do_any_attach(selected_cards):
                for card in selected_cards:
                    for slot_name, poke in all_pokemon:
                        if poke.card.api_id == card.api_id:
                            _attach_cards_to_pokemon(state, player, matching, count, poke, energy_type)
                            return
            any_cards = [p.card for _, p in all_pokemon]
            return ActionResult(True, "选择1只宝可梦附着能量。",
                                pending_action=ActionRequest(
                                    request_type="search_deck",
                                    player=player_idx,
                                    prompt="选择1只宝可梦附着能量。",
                                    min_select=1,
                                    max_select=1,
                                    from_zone="board",
                                    card_list=any_cards,
                                    callback=_do_any_attach,
                                ))

    else:
        return ActionResult(False, f"未知目标: {target_spec}")

    return ActionResult(True, f"从弃牌区附着了{count}个能量。")


def _attach_cards_to_pokemon(state, player, matching, count, target_pokemon, energy_type):
    """Move energy cards from discard to a target Pokemon."""
    attached = 0
    for i in range(count):
        card = matching[i]
        if card in player.discard:
            player.discard.remove(card)
            target_pokemon.energy_cards.append(card)
            attached += 1

    if params := {}:
        pass  # self_damage handled in caller context

    state._log(f"从弃牌区将{attached}个{energy_type}能量附着于{target_pokemon.card.name}。")
    return attached
