"""Search and deck-manipulation effect handlers."""
from engine.game_state import GameState, ActionResult, ActionRequest


def _handle_search(state, player_idx, params):
    """Search a zone for cards matching a filter. Requires UI callback."""
    from_zone = params.get("from_zone", "deck")
    filter_type = params.get("filter", "pokemon")
    filter_name = params.get("filter_name", "")  # Match by exact card name
    destination = params.get("destination", "hand")
    reveal = params.get("reveal", True)
    count = params.get("count", 1)

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

    # Build callback that moves selected cards to destination
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
            elif destination == "bench":
                slot = player.find_empty_bench_slot()
                if slot is not None:
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
                            min_select=min(1, count),
                            max_select=count,
                            from_zone=from_zone,
                            card_list=valid_cards,
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

    # Callback after player picks
    def look_callback(selected_cards):
        taken = list(selected_cards[:take])
        if destination == "bench_energy":
            # Put untaken cards back to bottom of deck immediately
            for card in top_cards:
                if card not in taken:
                    if rest_bottom:
                        player.deck.insert(0, card)
                    else:
                        player.deck.append(card)
            state._log(f"{player.name}查看了牌库顶{count}张卡，选择了{len(taken)}张。")

            bench_pokes = [(i, p) for i, p in enumerate(player.bench)
                          if p is not None and p.card.energy_types and
                          "Lightning" in p.card.energy_types]
            if not bench_pokes:
                state._log("备战区没有雷属性宝可梦可附着能量。")
                return
            if len(bench_pokes) == 1 and len(taken) <= 1:
                # Auto-attach single energy to the only bench Pokemon
                idx, bp = bench_pokes[0]
                for card in taken:
                    bp.energy_cards.append(card)
                state._log(f"将{len(taken)}张能量附着于备战区{bp.card.name}。")
                return

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
                source_name="电气发生器",
                callback=on_distributed,
            )
        else:
            # Put selected cards into hand (Pokegear etc.)
            for card in top_cards:
                if card in taken:
                    player.hand.append(card)
                    state._log(f"{player.name}将{card.name}加入手牌。")
                elif rest_bottom:
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
                            min_select=0 if take >= 99 else 1,
                            max_select=take,
                            from_zone="deck",
                            card_list=display_cards,
                            callback=look_callback,
                        ))


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
                    return ActionRequest(
                        request_type="select_bench",
                        player=player_idx,
                        prompt="选择替换战斗区的宝可梦。",
                        max_select=1,
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
                            min_select=1,
                            max_select=count,
                            from_zone="deck",
                            card_list=list(player.deck),
                            callback=survival_callback,
                        ))


def _handle_conditional_search_extra(state, player_idx, params):
    """Search deck for Grass Pokemon. If going second and first turn, search up to 3.
    Used by 萨戮德 唤群之歌."""
    player = state.get_player(player_idx)
    filter_type = params.get("filter", "grass_pokemon")
    max_count = params.get("max_count", 3)
    default_count = params.get("default_count", 1)

    # Check if this is the player's first turn AND they went second
    is_first_turn = (state.turn_number == 1)
    is_going_second = (state.first_player_idx != player_idx) if hasattr(state, 'first_player_idx') else False

    search_count = max_count if (is_first_turn and is_going_second) else default_count

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

    return ActionResult(True, f"从牌库选择最多{search_count}张G宝可梦。",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=player_idx,
                            prompt=f"选择最多{search_count}张G宝可梦加入手牌（唤群之歌）{prompt_extra}",
                            min_select=1,
                            max_select=search_count,
                            from_zone="deck",
                            card_list=search_pool,
                            callback=grass_search_callback,
                        ))
