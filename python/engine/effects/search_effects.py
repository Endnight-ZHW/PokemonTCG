"""Search and deck-manipulation effect handlers."""
from engine.game_state import GameState, ActionResult, ActionRequest
from engine.actions import PokemonRef, resolve_pokemon_ref


def _matches_energy_filter(card, filter_type: str) -> bool:
    filter_type = str(filter_type or "any")
    if filter_type in {"any", "energy"}:
        return card.is_energy
    if filter_type in {"basic", "basic_energy"}:
        return card.is_basic_energy
    return card.is_energy and any(
        str(provided).lower() == filter_type.lower()
        for provided in card.provides_energy
    )


def _handle_search(state, player_idx, params):
    """Search a zone for cards matching a filter. Requires UI callback."""
    from_zone = params.get("from_zone", "deck")
    filter_type = params.get("filter", "pokemon")
    filter_name = params.get("filter_name", "")  # Match by exact card name
    destination = params.get("destination", "hand")
    reveal = params.get("reveal", True)
    count = params.get("count", 1)
    min_select = int(params.get("min_select", 0 if params.get("optional", False) else min(1, count)) or 0)

    player = state.get_player(player_idx)
    search_pool = player.deck if from_zone == "deck" else player.discard

    # Filter cards
    def matches(card):
        if filter_name:
            return card.name == filter_name
        if filter_type == "any":
            return True
        if filter_type == "basic_pokemon":
            return card.is_basic_pokemon
        if filter_type == "pokemon":
            return card.is_pokemon
        if filter_type == "basic_energy":
            return card.is_basic_energy
        if filter_type == "energy":
            return card.is_energy
        if filter_type == "supporter":
            return card.is_trainer_supporter
        if filter_type == "grass_pokemon":
            return card.is_pokemon and card.energy_types and "Grass" in card.energy_types
        if filter_type == "item":
            return card.is_trainer_item
        if filter_type == "item_or_tool":
            return card.is_trainer_item or card.is_trainer_tool
        return True

    valid_cards = [c for c in search_pool if matches(c)]

    if not valid_cards:
        return ActionResult(True, f"No valid cards found in {from_zone}.")

    max_select = min(count, len(valid_cards))
    if destination == "bench":
        max_select = min(
            max_select,
            sum(1 for pokemon in player.bench if pokemon is None),
        )
    if max_select <= 0:
        if from_zone == "deck":
            player.shuffle_deck()
        return ActionResult(True, "No open Bench slots.")

    # Build callback that moves selected cards to destination
    def search_callback(selected_cards):
        for card in selected_cards:
            slot = None
            if destination == "bench":
                slot = player.find_empty_bench_slot()
                if slot is None:
                    continue
            if from_zone == "deck" and card in player.deck:
                player.deck.remove(card)
            elif from_zone == "discard" and card in player.discard:
                player.discard.remove(card)
            else:
                continue

            if destination == "hand":
                player.hand.append(card)
            elif destination == "bench":
                pokemon = player.place_bench(card, slot)
                pokemon.placed_this_turn = True

        if from_zone == "deck":
            player.shuffle_deck()
        state._log(f"{player.name}从{from_zone}选择了{len(selected_cards)}张卡。")

    # Return a pending action for UI to handle
    return ActionResult(True, f"Search {from_zone} for {filter_type}.",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=player_idx,
                            prompt=f"从{from_zone}选择{count}张卡（{filter_type}）",
                            filter_fn=matches,
                            min_select=min(min_select, max_select),
                            max_select=max_select,
                            from_zone=from_zone,
                            card_list=valid_cards,
                            can_cancel=min_select <= 0,
                            callback=search_callback,
                        ))


def _handle_search_any(state, player_idx, params):
    """Search deck for ANY card (no filter). Used by Pidgeot ex Quick Search."""
    player = state.get_player(player_idx)
    from_zone = params.get("from_zone", "deck")
    destination = params.get("destination", "hand")
    reveal = params.get("reveal", True)
    count = params.get("count", 1)

    search_pool = player.deck if from_zone == "deck" else player.discard

    if not search_pool:
        return ActionResult(True, f"{from_zone}中没有卡。")

    def search_callback(selected_cards):
        for card in selected_cards:
            if from_zone == "deck" and card in player.deck:
                player.deck.remove(card)
            elif from_zone == "discard" and card in player.discard:
                player.discard.remove(card)
            else:
                continue
            if destination == "hand":
                player.hand.append(card)

        if from_zone == "deck":
            player.shuffle_deck()
        state._log(f"{player.name}从{from_zone}选择了{len(selected_cards)}张卡。")

    return ActionResult(True, f"Search {from_zone} for any card.",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=player_idx,
                            prompt=f"从{from_zone}选择任意{count}张卡",
                            min_select=min(1, count),
                            max_select=count,
                            from_zone=from_zone,
                            card_list=list(search_pool),
                            callback=search_callback,
                        ))


def _handle_look_top_deck(state, player_idx, params):
    count = params.get("count", 5)
    take = params.get("take", 1)
    rest_bottom = params.get("rest_bottom", True)
    shuffle_rest = params.get("shuffle_rest", False)
    filter_type = params.get("filter", "")
    destination = params.get("destination", "hand")
    min_select = int(params.get("min_select", 0 if take >= 99 else 1) or 0)

    player = state.get_player(player_idx)
    # Take top `count` cards from deck
    top_cards = []
    for _ in range(min(count, len(player.deck))):
        top_cards.append(player.deck.pop())

    # Apply filter if specified
    if filter_type == "lightning_energy":
        display_cards = [c for c in top_cards if c.is_basic_energy and
                         any("Lightning" in et for et in c.provides_energy)]
    elif filter_type == "supporter":
        display_cards = [c for c in top_cards if c.is_trainer_supporter]
    elif filter_type == "energy":
        display_cards = [c for c in top_cards if c.is_energy]
    elif filter_type == "water_pokemon_and_energy":
        # 小菘: Water Pokemon + Water Energy
        display_cards = [c for c in top_cards if (
            (c.is_pokemon and c.energy_types and "Water" in c.energy_types) or
            (c.is_basic_energy and "Water" in str(c.provides_energy))
        )]
    else:
        display_cards = top_cards

    if not display_cards:
        player.deck.extend(top_cards)
        if shuffle_rest:
            player.shuffle_deck()
        return ActionResult(True, f"牌库顶{count}张没有可选择的卡。")

    def _put_rest_back(selected_cards):
        remaining_selected = list(selected_cards)
        rest = []
        for card in top_cards:
            if card in remaining_selected:
                remaining_selected.remove(card)
            else:
                rest.append(card)
        if shuffle_rest:
            player.deck.extend(rest)
            player.shuffle_deck()
        else:
            for card in rest:
                if rest_bottom:
                    player.deck.insert(0, card)
                else:
                    player.deck.append(card)

    # Callback after player picks
    def look_callback(selected_cards):
        taken = list(selected_cards[:take])
        if destination == "bench_energy":
            _put_rest_back(taken)
            state._log(f"{player.name}查看了牌库顶{count}张卡，选择了{len(taken)}张。")

            bench_pokes = [(i, p) for i, p in enumerate(player.bench)
                          if p is not None and p.card.energy_types and
                          "Lightning" in p.card.energy_types]
            if not taken:
                return ActionResult(True, "未选择能量。")
            if not bench_pokes:
                player.deck.extend(taken)
                player.shuffle_deck()
                state._log("备战区没有雷属性宝可梦可附着能量。")
                return ActionResult(True, "备战区没有雷属性宝可梦可附着能量。")
            if len(bench_pokes) == 1 and len(taken) <= 1:
                # Auto-attach single energy to the only bench Pokemon
                idx, bp = bench_pokes[0]
                for card in taken:
                    bp.energy_cards.append(card)
                state._log(f"将{len(taken)}张能量附着于备战区{bp.card.name}。")
                return ActionResult(True, f"附着了{len(taken)}张能量。")

            # Use energy distribution screen
            targets_info = [
                {"slot": f"bench_{i}", "name": p.card.name, "bench_idx": i}
                for i, p in bench_pokes
            ]

            def on_distributed(assignments):
                for ei, tgt_slot in assignments:
                    if ei < len(taken):
                        bp = player.get_pokemon(tgt_slot)
                        if bp:
                            bp.energy_cards.append(taken[ei])
                            state._log(f"将{taken[ei].name}附着于备战区{bp.card.name}。")

            return ActionRequest(
                request_type="distribute_energy",
                player=player_idx,
                prompt=f"分配能量 — 电气发生器",
                card_list=taken,
                target_info=targets_info,
                distribute_mode="distribute",
                min_select=len(taken),
                max_select=len(taken),
                source_name="电气发生器",
                callback=on_distributed,
            )
        else:
            # Put selected cards into hand (Pokegear etc.)
            remaining_taken = list(taken)
            rest = []
            for card in top_cards:
                if card in remaining_taken:
                    remaining_taken.remove(card)
                    player.hand.append(card)
                    state._log(f"{player.name}将{card.name}加入手牌。")
                else:
                    rest.append(card)
            for card in rest:
                if rest_bottom:
                    player.deck.insert(0, card)
                else:
                    player.deck.append(card)
            if shuffle_rest:
                player.shuffle_deck()
            state._log(f"{player.name}查看了牌库顶{count}张卡，选择了{len(taken)}张。")

    return ActionResult(True, f"Look at top {len(display_cards)} cards.",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=player_idx,
                            prompt=f"从牌库顶选择最多{take}张卡。",
                            min_select=min(min_select, min(take, len(display_cards))),
                            max_select=take,
                            from_zone="deck",
                            card_list=display_cards,
                            can_cancel=min_select <= 0,
                            callback=look_callback,
                        ))


def _handle_look_top_attach_energy(state, player_idx, params):
    """Look at the top N cards, attach selected matching energy to one own Pokemon."""
    count = int(params.get("count", 5) or 5)
    take = int(params.get("take", 99) or 99)
    filter_type = str(params.get("filter", "basic_energy") or "basic_energy")

    player = state.get_player(player_idx)
    top_cards = []
    for _ in range(min(count, len(player.deck))):
        top_cards.append(player.deck.pop())

    eligible = [card for card in top_cards if _matches_energy_filter(card, filter_type)]
    if not eligible:
        player.deck.extend(top_cards)
        player.shuffle_deck()
        return ActionResult(True, "没有可附着的能量。")

    def _put_rest_back(selected_cards):
        selected_ids = {id(card) for card in selected_cards}
        for card in top_cards:
            if id(card) not in selected_ids:
                player.deck.append(card)
        player.shuffle_deck()

    def _attach_to_target(target_selection, selected_cards):
        target = None
        for selected in target_selection or []:
            if isinstance(selected, PokemonRef):
                target = resolve_pokemon_ref(state, selected)
                break
            for _slot, candidate in player.get_all_pokemon():
                if candidate is not None and candidate.card is selected:
                    target = candidate
                    break
            if target is not None:
                break
        if target is None:
            return ActionResult(False, "没有有效附着目标。")
        for card in selected_cards:
            target.energy_cards.append(card)
        state._log(f"将{len(selected_cards)}张能量附着于{target.card.name}。")
        return ActionResult(True, f"附着了{len(selected_cards)}张能量。")

    def look_attach_callback(selected_cards):
        selected = list(selected_cards[: min(take, len(selected_cards))])
        _put_rest_back(selected)
        if not selected:
            state._log(f"{player.name}查看了牌库顶{count}张卡，没有选择能量。")
            return ActionResult(True, "未选择能量。")

        targets = [(slot, poke) for slot, poke in player.get_all_pokemon() if poke is not None]
        if not targets:
            return ActionResult(False, "没有宝可梦可附着能量。")
        if len(targets) == 1:
            return _attach_to_target([PokemonRef(player_idx, targets[0][0], targets[0][1].card.api_id)], selected)

        return ActionRequest(
            request_type="search_deck",
            player=player_idx,
            prompt=f"选择1只宝可梦附着{len(selected)}张能量。",
            min_select=1,
            max_select=1,
            from_zone="board",
            target_player="self",
            card_list=[poke.card for _slot, poke in targets],
            callback=lambda target_selection: _attach_to_target(target_selection, selected),
        )

    return ActionResult(
        True,
        f"查看牌库顶{len(top_cards)}张卡。",
        pending_action=ActionRequest(
            request_type="search_deck",
            player=player_idx,
            prompt=f"选择任意数量的基本能量附着于1只宝可梦。",
            min_select=0,
            max_select=min(take, len(eligible)),
            from_zone="deck",
            card_list=eligible,
            callback=look_attach_callback,
        ),
    )


def _handle_search_any_and_switch(state, player_idx, params):
    """Search deck for up to N any cards, add to hand, shuffle.
    Then optionally switch this Pokemon with a bench Pokemon.
    Used by 米立龙 生存战略: search up to 2 any cards + optional switch."""
    player = state.get_player(player_idx)
    count = params.get("count", 2)
    switch_optional = params.get("switch_optional", True)
    source_slot = params.get("source_slot", "active")

    if not player.deck:
        return ActionResult(True, "牌库中没有卡。")

    def survival_callback(selected_cards):
        for card in selected_cards[:count]:
            if card in player.deck:
                player.deck.remove(card)
                player.hand.append(card)
        player.shuffle_deck()
        state._log(f"{player.name}从牌库选择了{len(selected_cards[:count])}张卡。")

        # Optional switch: ask player first
        if switch_optional:
            bench_ix = [i for i, p in enumerate(player.bench) if p is not None]
            if bench_ix:
                def on_confirm_switch(confirmed):
                    if not confirmed:
                        return None
                    if len(bench_ix) == 1:
                        idx = bench_ix[0]
                        player.switch_active_to_bench(idx)
                        state._log(f"将{player.active.card.name}与{player.bench[idx].card.name}互换了。")
                        return None

                    def _on_multi_bench_select(bench_idx):
                        player.switch_active_to_bench(bench_idx)
                        return None

                    return ActionRequest(
                        request_type="select_bench",
                        player=player_idx,
                        prompt="选择替换战斗区的宝可梦。",
                        max_select=1,
                        callback=_on_multi_bench_select,
                    )
                return ActionRequest(
                    request_type="confirm",
                    player=player_idx,
                    prompt="是否替换战斗宝可梦？",
                    callback=on_confirm_switch,
                )

    return ActionResult(True, f"从牌库选择最多{count}张任意卡。",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=player_idx,
                            prompt=f"从牌库选择最多{count}张卡加入手牌（生存战略）",
                            min_select=int(params.get("min_select", 0) or 0),
                            max_select=count,
                            from_zone="deck",
                            card_list=list(player.deck),
                            can_cancel=int(params.get("min_select", 0) or 0) <= 0,
                            callback=survival_callback,
                        ))


def _handle_conditional_search_extra(state, player_idx, params):
    """Search deck for Grass Pokemon. If going second and first turn, search up to 3.
    Used by 萨戮德 唤群之歌."""
    player = state.get_player(player_idx)
    filter_type = params.get("filter", "grass_pokemon")
    max_count = params.get("max_count", 3)
    default_count = params.get("default_count", 1)

    search_count = (
        max_count
        if state.is_going_second_first_turn(player_idx)
        else default_count
    )

    # Filter for Grass Pokemon
    search_pool = [c for c in player.deck
                   if c.is_pokemon and c.energy_types and "Grass" in c.energy_types]

    if not search_pool:
        return ActionResult(True, "牌库中没有G宝可梦。")

    def grass_search_callback(selected_cards):
        for card in selected_cards[:search_count]:
            if card in player.deck:
                player.deck.remove(card)
                player.hand.append(card)
        player.shuffle_deck()
        state._log(f"{player.name}从牌库选择了{len(selected_cards[:search_count])}张G宝可梦。")

    prompt_extra = f"（后攻首回合，可搜索最多{max_count}张）" if search_count == max_count else ""
    min_select = 0 if search_count == max_count else 1

    return ActionResult(True, f"从牌库选择最多{search_count}张G宝可梦。",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=player_idx,
                            prompt=f"选择最多{search_count}张G宝可梦加入手牌（唤群之歌）{prompt_extra}",
                            min_select=min_select,
                            max_select=search_count,
                            from_zone="deck",
                            card_list=search_pool,
                            can_cancel=min_select <= 0,
                            callback=grass_search_callback,
                        ))
