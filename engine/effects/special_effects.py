"""Special/trainer effect handlers (heal, switch, coin flip, etc.)."""
import random
from config import DAMAGE_PER_COUNTER
from engine.enums import TurnPhase
from engine.game_state import GameState, ActionResult, ActionRequest
from data.card_registry import CardRegistry


def _handle_heal(state, player, params):
    amount = params.get("amount", 0)
    target_str = params.get("target", "self")

    target = None
    if target_str == "self":
        target = player.active
    elif target_str.startswith("bench_"):
        idx = int(target_str.split("_")[1])
        target = player.bench[idx]

    if target:
        counters = amount // DAMAGE_PER_COUNTER
        target.damage_counters = max(0, target.damage_counters - counters)
        player.healed_this_turn = True
        state._log(f"回复了{target.card.name}的{amount}点伤害。")
        return ActionResult(True, f"回复了{amount}点。")
    return ActionResult(False, "没有回复目标。")


def _handle_potion_heal(state, player, player_idx, params):
    """伤药: choose 1 of your Pokemon and heal 30 HP."""
    amount = params.get("amount", 30)

    # Collect all Pokemon with damage
    injured = []
    for slot_name, poke in player.get_all_pokemon():
        if poke and poke.damage_counters > 0:
            injured.append((slot_name, poke))

    if not injured:
        return ActionResult(True, "没有受伤的宝可梦，卡牌保留在手牌中。")

    if len(injured) == 1:
        # Auto-heal the only injured Pokemon
        slot_name, poke = injured[0]
        counters = amount // DAMAGE_PER_COUNTER
        poke.damage_counters = max(0, poke.damage_counters - counters)
        player.healed_this_turn = True
        state._log(f"{poke.card.name}回复了{amount}点HP。")
        return ActionResult(True, f"{poke.card.name}回复了{amount}点HP。")

    # Let player choose
    def heal_callback(selected_idx):
        slot_name, poke = injured[selected_idx]
        counters = amount // DAMAGE_PER_COUNTER
        poke.damage_counters = max(0, poke.damage_counters - counters)
        player.healed_this_turn = True
        state._log(f"{poke.card.name}回复了{amount}点HP。")

    return ActionResult(True, "选择1只宝可梦回复30HP。",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=player_idx,
                            prompt="选择1只宝可梦回复30HP（伤药）",
                            min_select=1,
                            max_select=1,
                            from_zone="bench",
                            card_list=[p.card for _, p in injured],
                            callback=heal_callback,
                        ))


def _handle_switch_self(state, player, params, player_idx=0):
    """Player chooses a bench Pokemon to switch with active."""
    optional = params.get("optional", False)

    if not player.active:
        if optional:
            return ActionResult(True, "没有战斗宝可梦。")
        return ActionResult(False, "没有战斗宝可梦可替换。")

    bench_indices = [
        i for i, p in enumerate(player.bench) if p is not None
    ]

    if not bench_indices:
        if optional:
            return ActionResult(True, "备战区无宝可梦可换。")
        return ActionResult(False, "备战区没有宝可梦可替换。")

    if optional:
        def on_confirm_switch(confirmed):
            if not confirmed:
                return None
            if len(bench_indices) == 1:
                idx = bench_indices[0]
                player.switch_active_to_bench(idx)
                state._log(f"将{player.active.card.name}与{player.bench[idx].card.name}互换了。")
                return None
            return ActionRequest(
                request_type="select_bench",
                player=player_idx,
                prompt="选择替换战斗区的宝可梦。",
                max_select=1,
            )
        return ActionResult(True, "请选择是否替换宝可梦。",
                            pending_action=ActionRequest(
                                request_type="confirm",
                                player=player_idx,
                                prompt="是否替换战斗宝可梦？",
                                callback=on_confirm_switch,
                            ))

    # Non-optional: auto-switch if only 1 bench, otherwise prompt
    if len(bench_indices) == 1:
        idx = bench_indices[0]
        active_name = player.active.card.name
        bench_name = player.bench[idx].card.name
        player.switch_active_to_bench(idx)
        state._log(f"将{active_name}与{bench_name}互换了。")
        return ActionResult(True, f"互换了{active_name}与{bench_name}。")

    return ActionResult(True, "选择替换的宝可梦。",
                        pending_action=ActionRequest(
                            request_type="select_bench",
                            player=player_idx,
                            prompt="选择替换战斗区的宝可梦。",
                            max_select=1,
                        ))


def _handle_switch_opponent(state, opponent, params, opponent_idx=1):
    """Force opponent to switch their active. Like Boss's Orders."""
    you_choose = params.get("you_choose", False)

    bench_with_pokemon = [
        i for i, p in enumerate(opponent.bench) if p is not None
    ]

    if not bench_with_pokemon:
        return ActionResult(False, "对手备战区没有宝可梦，卡牌保留在手牌中。")

    if len(bench_with_pokemon) == 1 and not you_choose:
        # Auto-switch opponent's only bench
        idx = bench_with_pokemon[0]
        opponent.switch_active_to_bench(idx)
        state._log(f"{opponent.name}的战斗宝可梦被替换了。")
        return ActionResult(True, "对手替换了。")

    return ActionResult(True, "选择对手的新战斗宝可梦。",
                        pending_action=ActionRequest(
                            request_type="select_opponent_bench",
                            player=opponent_idx,
                            prompt="选择对手的新战斗宝可梦。",
                            max_select=1,
                        ))


def _handle_coin_flip(state, params, player_idx, source_slot):
    """Single coin flip. Returns pending_action so UI can animate the coin."""
    from engine.effects import execute_effect

    branch_heads = params.get("on_heads")
    branch_tails = params.get("on_tails")

    def on_flip_complete(results: list[bool]):
        """Called when coin flip animation finishes. results[0] is True for heads."""
        is_heads = results[0]
        cn = "正面" if is_heads else "反面"
        state._log(f"掷硬币: {cn}!")

        branch = branch_heads if is_heads else branch_tails
        if branch:
            if isinstance(branch, list):
                if not branch:
                    return ActionResult(True, f"硬币: {cn}.")
                result_action = ActionResult(True, "")
                for eff in branch:
                    eff_result = execute_effect(state, eff, player_idx, source_slot)
                    result_action.log_message += eff_result.log_message + " "
                    result_action.damage_dealt += eff_result.damage_dealt
                    result_action.pending_action = eff_result.pending_action or result_action.pending_action
                    result_action.attack_failed = result_action.attack_failed or eff_result.attack_failed
                return result_action
            else:
                return execute_effect(state, branch, player_idx, source_slot)

        return ActionResult(True, f"硬币: {cn}.")

    return ActionResult(
        True, "掷硬币中...",
        pending_action=ActionRequest(
            request_type="coin_flip",
            player=player_idx,
            prompt="掷1次硬币",
            flip_count=1,
            callback=on_flip_complete,
        )
    )


def _handle_conditional(state, params, player_idx, source_slot):
    """Conditional effect: pay a cost to get an effect.
    If cost requires UI interaction (pending_action), the on_pay is chained
    to execute after the cost callback completes."""
    from engine.effects import execute_effect
    cost = params.get("cost")
    on_pay = params.get("on_pay")
    optional = params.get("optional", False)
    condition = params.get("condition", "")

    # Pre-condition check (e.g. 梅洛可: must have been KO'd last turn)
    if condition == "ko_by_attack_last_turn":
        player = state.get_player(player_idx)
        if not player.was_ko_by_attack:
            state._log(f"{player.name}上个对手回合没有宝可梦因招式伤害昏厥，无法使用此卡。")
            return ActionResult(False, "不满足使用条件，卡牌保留在手牌中。")
        player.was_ko_by_attack = False

    if cost:
        cost_result = execute_effect(state, cost, player_idx, source_slot)
        if not cost_result.success and not optional:
            return ActionResult(False, "无法支付代价。")

        if cost_result.pending_action and on_pay:
            # Chain: after cost is paid (user selects cards), execute on_pay
            orig_callback = cost_result.pending_action.callback
            def chained(selected_cards):
                if orig_callback:
                    orig_callback(selected_cards)
                pay_result = execute_effect(state, on_pay, player_idx, source_slot)
                # Return the second pending_action so the UI can chain it
                return pay_result.pending_action
            cost_result.pending_action.callback = chained
            return cost_result

    if on_pay:
        if isinstance(on_pay, list):
            result_action = ActionResult(True, "")
            for eff in on_pay:
                eff_result = execute_effect(state, eff, player_idx, source_slot)
                result_action.log_message += eff_result.log_message + " "
                result_action.pending_action = eff_result.pending_action or result_action.pending_action
            return result_action
        else:
            return execute_effect(state, on_pay, player_idx, source_slot)

    return ActionResult(True, "条件效果已结算。")


def _handle_evolve_skip(state, player, params):
    """Rare Candy: evolve a Basic Pokemon directly to Stage 2.
    Traces the evolution chain: Stage2 -> Stage1 -> Basic.
    """
    # Find all Basic Pokemon the player controls
    basic_slots = []
    for slot_name, pokemon in player.get_all_pokemon():
        if pokemon and pokemon.card.is_basic_pokemon:
            matching_stage2 = [
                c for c in player.hand
                if c.is_stage2 and _find_basic_for_stage2(c, pokemon.card.name)
            ]
            if matching_stage2:
                basic_slots.append((slot_name, pokemon, matching_stage2))

    if not basic_slots:
        state._log(f"{player.name}场上没有能够用神奇糖果进化的基础宝可梦。")
        return ActionResult(False, "没有有效的进化目标，卡牌保留在手牌中。")

    # Auto-evolve with the first match
    slot_name, pokemon, stage2_cards = basic_slots[0]
    stage2 = stage2_cards[0]
    old_name = pokemon.card.name

    hand_idx = player.hand.index(stage2)
    player.hand.pop(hand_idx)
    player.evolve_pokemon(slot_name, stage2)
    state._log(f"{player.name}使用神奇糖果将{old_name}进化成了{stage2.name}！")
    return ActionResult(True, f"Rare Candy: {old_name} -> {stage2.name}")


def _find_basic_for_stage2(stage2_card, target_basic_name):
    """Check if a Stage 2 card can evolve from the given Basic Pokemon
    by tracing the evolution chain: Stage2 -> Stage1 -> Basic."""
    from data.card_registry import CardRegistry

    stage1_name = stage2_card.evolves_from  # e.g. 喷火龙ex -> 火恐龙
    if not stage1_name:
        return False

    # Find the Stage 1 card
    stage1_cards = CardRegistry.get_by_name(stage1_name)
    if not stage1_cards:
        return False

    # Check if the Stage 1 evolves from the target Basic
    for s1 in stage1_cards:
        if s1.evolves_from.lower() == target_basic_name.lower():
            return True

    return False


def _handle_discard(state, player, params):
    """Discard cards from hand (used as a cost). Lets player choose which cards."""
    amount = params.get("amount", 1)
    from_zone = params.get("from", "hand")
    # Determine player index from player object for UI callbacks
    player_idx = 0 if player is state.p1 else 1

    if from_zone == "hand":
        hand_count = len(player.hand)
        if hand_count == 0:
            return ActionResult(False, "手牌为空，无法丢弃。")
        if hand_count <= amount:
            # Not enough cards - discard all
            indices = list(range(hand_count))
            player.discard_from_hand(indices)
            state._log(f"从手牌丢弃了{hand_count}张卡。")
            return ActionResult(True, f"Discarded {hand_count}.")

        # Let player choose which cards to discard
        def discard_callback(selected_cards):
            from collections import Counter
            target_counts = Counter(c.api_id for c in selected_cards)
            indices_to_discard = []
            for i, hc in enumerate(player.hand):
                if target_counts.get(hc.api_id, 0) > 0:
                    indices_to_discard.append(i)
                    target_counts[hc.api_id] -= 1
            player.discard_from_hand(sorted(indices_to_discard, reverse=True))
            state._log(f"从手牌丢弃了{len(indices_to_discard)}张卡。")

        return ActionResult(True, f"选择{amount}张手牌丢弃。",
            pending_action=ActionRequest(
                request_type="select_hand_to_discard",
                player=player_idx,
                prompt=f"选择{amount}张手牌丢弃",
                min_select=amount,
                max_select=amount,
                from_zone="hand",
                card_list=list(player.hand),
                callback=discard_callback,
            ))

    return ActionResult(True, "Discarded.")


def _handle_return_to_hand(state, player_idx, params, source_slot):
    """Deal 30 damage and return this Pokemon + all attached cards to hand."""
    player = state.get_player(player_idx)
    source = player.get_pokemon(source_slot)
    opponent = state.get_opponent()

    if source is None:
        return ActionResult(False, "没有宝可梦。")

    # Deal 30 damage to opponent's active
    damage = 30
    if opponent.active:
        if not opponent.active.damage_prevented_next_turn:
            opponent.active.damage_counters += damage // DAMAGE_PER_COUNTER
            state._log(f"对{opponent.active.card.name}造成了{damage}点伤害。")
        else:
            opponent.active.damage_prevented_next_turn = False

    # Return tool
    if source.attached_tool:
        player.hand.append(source.attached_tool)
        source.attached_tool = None

    # Return evolution stack (devolution)
    for evo_card in source.evolution_stack:
        player.hand.append(evo_card)
    source.evolution_stack.clear()

    # Return Pokemon card to hand
    player.hand.append(source.card)

    # Clear the slot
    if source_slot == "active":
        player.active = None
    elif source_slot.startswith("bench_"):
        idx = int(source_slot.split("_")[1])
        player.bench[idx] = None

    state._log(f"{source.card.name}和所有附着卡回到了{player.name}的手牌。")
    return ActionResult(True, f"{source.card.name}回到了手牌。", damage_dealt=damage)


def _handle_piercing_marker(state, params):
    """Mark that the current attack should ignore weakness/resistance.
    This sets a flag on the state that damage_calculator will check."""
    # Store piercing flag on state for this attack resolution
    state._piercing_attack = True
    return ActionResult(True, "穿透攻击标记已设置。")


def _handle_stadium(state, player_idx, params):
    """Handle stadium card effects.
    Artazon (activatable): once per turn, search deck for a basic Pokemon and put on bench.
    Beach Court (passive): basic Pokemon retreat cost -1 (handled in retreat logic)."""
    effect_name = params.get("effect", "")
    player = state.get_player(player_idx)

    if effect_name == "search_basic_pokemon":
        # Artazon: each player may use once per turn — search deck for a basic Pokemon
        search_pool = [c for c in player.deck if c.is_basic_pokemon]
        if not search_pool:
            return ActionResult(True, "牌库中没有基础宝可梦。")

        def stadium_callback(selected_cards):
            for card in selected_cards:
                if card in player.deck:
                    player.deck.remove(card)
                    slot = player.find_empty_bench_slot()
                    if slot is not None:
                        pokemon = player.place_bench(card, slot)
                        pokemon.placed_this_turn = True
                        state._log(f"{player.name}使用竞技场效果将{card.name}放置于备战区。")
                    else:
                        state._log("备战区已满，无法放置。")
            player.shuffle_deck()

        return ActionResult(True, "从牌库选择1张基础宝可梦放置于备战区。",
                            pending_action=ActionRequest(
                                request_type="search_deck",
                                player=player_idx,
                                prompt="选择1张基础宝可梦放置于备战区（阿塔松效果）",
                                min_select=1, max_select=1,
                                from_zone="deck",
                                card_list=search_pool,
                                callback=stadium_callback,
                            ))

    elif effect_name == "reduce_retreat_cost_basics":
        # Beach Court: passive effect, applied during retreat cost calculation
        return ActionResult(True, "沙滩场地: 基础宝可梦撤退费用-1。")

    return ActionResult(True, f"竞技场效果: {effect_name}")


def _handle_escape_rope(state, player_idx, params):
    """Escape Rope: Both players switch their active with a bench Pokemon.
    Opponent switches first."""
    opponent = state.get_opponent()

    # Opponent switches first
    opp_bench = [i for i, p in enumerate(opponent.bench) if p is not None]
    if opp_bench:
        opponent.switch_active_to_bench(opp_bench[0])
        state._log(f"{opponent.name}的战斗宝可梦被替换了。")

    # Then player switches
    player = state.get_player(player_idx)
    own_bench = [i for i, p in enumerate(player.bench) if p is not None]
    if own_bench:
        player.switch_active_to_bench(own_bench[0])
        state._log(f"{player.name}的战斗宝可梦被替换了。")

    return ActionResult(True, "双方战斗宝可梦被替换。")


def _handle_miriam(state, player_idx, params):
    """Miriam: Shuffle up to N Pokemon from discard into deck + heal all Pokemon."""
    shuffle_count = params.get("shuffle_count", 5)
    heal_all = params.get("heal_all", False)
    player = state.get_player(player_idx)

    # Shuffle Pokemon from discard to deck
    pokemon_in_discard = [c for c in player.discard if c.is_pokemon]
    to_shuffle = pokemon_in_discard[:shuffle_count]
    for card in to_shuffle:
        player.discard.remove(card)
        player.deck.append(card)
    player.shuffle_deck()
    if to_shuffle:
        state._log(f"{player.name}将{len(to_shuffle)}张宝可梦卡从弃牌区洗回牌库。")

    # Heal all Pokemon
    if heal_all:
        for slot_name, pokemon in player.get_all_pokemon():
            if pokemon and pokemon.damage_counters > 0:
                pokemon.damage_counters = 0
        state._log(f"{player.name}的所有宝可梦回复了全部HP。")

    return ActionResult(True, f"Miriam: shuffled {len(to_shuffle)} Pokemon, healed all.")


def _handle_clara(state, player_idx, params):
    """Search discard for up to N Pokemon + up to M basic energy.
    Used by 克拉拉."""
    pokemon_count = params.get("pokemon_count", 2)
    energy_count = params.get("energy_count", 2)
    player = state.get_player(player_idx)

    # Build combined list: Pokemon + basic energy from discard
    pokemon_in_discard = [c for c in player.discard if c.is_pokemon]
    energy_in_discard = [c for c in player.discard if c.is_basic_energy]

    available = pokemon_in_discard + energy_in_discard
    if not available:
        return ActionResult(True, "弃牌区没有可回收的卡。")

    max_pick = pokemon_count + energy_count

    def clara_callback(selected_cards):
        pokemon_taken = 0
        energy_taken = 0
        for card in selected_cards:
            if card not in player.discard:
                continue
            if card.is_pokemon and pokemon_taken < pokemon_count:
                player.discard.remove(card)
                player.hand.append(card)
                pokemon_taken += 1
            elif card.is_basic_energy and energy_taken < energy_count:
                player.discard.remove(card)
                player.hand.append(card)
                energy_taken += 1
        state._log(f"{player.name}从弃牌区回收了{pokemon_taken}只宝可梦和{energy_taken}张基本能量。")

    return ActionResult(True, "选择弃牌区中的宝可梦和基本能量回收。",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=player_idx,
                            prompt=f"从弃牌区选择最多{pokemon_count}只宝可梦和最多{energy_count}张基本能量",
                            min_select=0,
                            max_select=max_pick,
                            from_zone="discard",
                            card_list=available,
                            callback=clara_callback,
                        ))


def _handle_arven(state, player_idx, params):
    """Search deck for 1 Item + 1 Tool card.
    Used by 派帕."""
    player = state.get_player(player_idx)

    items = [c for c in player.deck if c.is_trainer_item]
    tools = [c for c in player.deck if c.is_trainer_tool]

    available = items + tools
    if not available:
        return ActionResult(True, "牌库中没有物品卡或宝可梦道具卡。")

    def arven_callback(selected_cards):
        item_taken = False
        tool_taken = False
        for card in selected_cards:
            if card not in player.deck:
                continue
            if card.is_trainer_item and not item_taken:
                player.deck.remove(card)
                player.hand.append(card)
                item_taken = True
            elif card.is_trainer_tool and not tool_taken:
                player.deck.remove(card)
                player.hand.append(card)
                tool_taken = True
        player.shuffle_deck()
        taken = (1 if item_taken else 0) + (1 if tool_taken else 0)
        state._log(f"{player.name}从牌库选择了{taken}张卡（派帕）。")

    return ActionResult(True, "选择1张物品卡和1张宝可梦道具卡加入手牌。",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=player_idx,
                            prompt="选择1张「物品」和1张「宝可梦道具」（派帕）",
                            min_select=1,
                            max_select=2,
                            from_zone="deck",
                            card_list=available,
                            callback=arven_callback,
                        ))


def _handle_zinnia_resolve(state, player, opponent, player_idx, params):
    """希嘉娜的决心: discard 2 cards from hand, then draw = opponent's Pokemon count.
    Only usable if you can discard 2 cards."""
    if len(player.hand) < 2:
        return ActionResult(False, "手牌不足2张，无法使用希嘉娜的决心。")

    # Count opponent's Pokemon in play
    opp_pokemon_count = (1 if opponent.active else 0) + sum(1 for p in opponent.bench if p is not None)

    if len(player.hand) == 2:
        # Auto-discard both
        player.discard_entire_hand()
        state._log(f"{player.name}丢弃了2张手牌。")
        drawn = player.draw_cards(opp_pokemon_count)
        state._log(f"{player.name}抽取了{len(drawn)}张卡（对手场上有{opp_pokemon_count}只宝可梦）。")
        return ActionResult(True, f"丢弃2张手牌，抽取了{len(drawn)}张。")

    # Need player to choose which 2 cards to discard
    def zinnia_callback(selected_cards):
        count = 0
        for card in selected_cards[:2]:
            if card in player.hand:
                player.hand.remove(card)
                player.discard.append(card)
                count += 1
        state._log(f"{player.name}丢弃了{count}张手牌（希嘉娜的决心）。")
        drawn = player.draw_cards(opp_pokemon_count)
        state._log(f"抽取了{len(drawn)}张卡（对手场上有{opp_pokemon_count}只宝可梦）。")

    return ActionResult(True, "选择2张手牌丢弃（希嘉娜的决心）。",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=player_idx,
                            prompt=f"选择2张手牌丢弃（希嘉娜的决心：抽{opp_pokemon_count}张）",
                            min_select=2,
                            max_select=2,
                            from_zone="hand",
                            card_list=list(player.hand),
                            callback=zinnia_callback,
                        ))


def _handle_trekking_shoes(state, player, player_idx, params):
    """健行鞋: look at top 1 card of deck. Choose: add to hand OR discard it and draw 1."""
    if not player.deck:
        return ActionResult(True, "牌库为空。")

    top_card = player.deck[-1]  # deck top is the last element

    def trekking_callback(confirmed: bool):
        if confirmed:
            # Keep: add to hand
            if player.deck:
                card = player.deck.pop()
                player.hand.append(card)
                state._log(f"{player.name}将牌库顶的「{top_card.name}」加入了手牌。")
        else:
            # Discard top card and draw 1
            if player.deck:
                card = player.deck.pop()
                player.discard.append(card)
                state._log(f"{player.name}丢弃了牌库顶的「{top_card.name}」。")
            drawn = player.draw_cards(1)
            if drawn:
                state._log(f"{player.name}抽取了{len(drawn)}张卡。")

    return ActionResult(True, f"牌库顶是「{top_card.name}」。",
                        pending_action=ActionRequest(
                            request_type="confirm",
                            player=player_idx,
                            prompt=f"牌库顶是「{top_card.name}」。是否放入手牌？\n（选「否」将丢弃此卡并抽1张）",
                            callback=trekking_callback,
                        ))


def _handle_heal_all(state, player, params):
    """Heal X damage from ALL of your Pokemon.
    Used by 七夕青鸟ex 哼唱治愈 ability."""
    amount = params.get("amount", 20)
    counters = amount // DAMAGE_PER_COUNTER

    healed = []
    for slot_name, poke in player.get_all_pokemon():
        if poke and poke.damage_counters > 0:
            actual = min(poke.damage_counters, counters)
            poke.damage_counters -= actual
            healed.append(poke.card.name)

    if healed:
        player.healed_this_turn = True
        names = "、".join(healed)
        state._log(f"{player.name}的所有宝可梦各回复了{amount}点HP（{names}）。")
        return ActionResult(True, f"全场回复{amount}HP。")
    else:
        state._log(f"{player.name}的宝可梦都没有受伤。")
        return ActionResult(True, "没有宝可梦需要回复。")


def _handle_coin_flip_until_tails(state, params, player_idx, source_slot):
    """Flip coins until tails. Damage = number of heads × per_head.
    Used by 青绵鸟 连续旋转: coin flip until tails, 20× heads.
    Uses the coin_flip request_type with until_tails flag for animation."""
    per_head = params.get("per_head", 20)
    player = state.get_player(player_idx)
    opponent = state.get_opponent()

    def on_flip_complete(results: list[bool]):
        heads = sum(1 for r in results if r)
        damage = heads * per_head
        cn_results = [("正面" if r else "反面") for r in results]
        state._log(f"掷硬币: {'、'.join(cn_results)}。正面次数: {heads}，造成{damage}点伤害。")

        if damage > 0 and opponent.active:
            if not opponent.active.damage_prevented_next_turn:
                counters = damage // DAMAGE_PER_COUNTER
                opponent.active.damage_counters += counters
            else:
                opponent.active.damage_prevented_next_turn = False

        return ActionResult(True, f"连续旋转: {heads}次正面，{damage}点伤害。", damage_dealt=damage)

    return ActionResult(
        True, "投掷硬币直到出现反面...",
        pending_action=ActionRequest(
            request_type="coin_flip",
            player=player_idx,
            prompt="掷硬币直到出现反面（连续旋转）",
            flip_count=1,
            until_tails=True,
            callback=on_flip_complete,
        )
    )


def _handle_coin_flip_energy_discard(state, params, player_idx, source_slot):
    """Coin flip: heads → discard 1 energy from opponent's Pokemon.
    Used by 粉碎之锤."""
    player = state.get_player(player_idx)
    opponent = state.get_opponent()

    # Collect opponent Pokemon with energy
    energy_targets = []
    for slot_name, poke in opponent.get_all_pokemon():
        if poke and poke.energy_cards:
            energy_targets.append((slot_name, poke, len(poke.energy_cards)))

    if not energy_targets:
        return ActionResult(True, "对手场上没有能量可丢弃。")

    def on_flip_complete(results: list[bool]):
        is_heads = results[0]
        cn = "正面" if is_heads else "反面"
        state._log(f"掷硬币: {cn}!")

        if not is_heads:
            return ActionResult(True, f"硬币: {cn}。没有丢弃能量。")

        # Choose opponent's Pokemon with energy to discard from
        # Auto-select: first Pokemon with energy (usually active)
        target_slot, target_poke, energy_count = energy_targets[0]

        # Discard 1 energy from unified energy_cards
        if target_poke.energy_cards:
            target_poke.energy_cards.pop()

        state._log(f"从{target_poke.card.name}身上丢弃了1个能量。")
        return ActionResult(True, f"粉碎之锤：丢弃了{target_poke.card.name}的1个能量。")

    return ActionResult(
        True, "掷硬币中...",
        pending_action=ActionRequest(
            request_type="coin_flip",
            player=player_idx,
            prompt="掷1次硬币（粉碎之锤）",
            flip_count=1,
            callback=on_flip_complete,
        )
    )


def _handle_ability_discard_revive(state, player, params, player_idx):
    """Ability: if this card is in discard and player has no hand,
    place it on bench and draw 3 cards.
    Used by 帝王拿波 紧急上浮."""
    card_id = params.get("card_id", "")
    registry = CardRegistry()

    # Check: is this card in player's discard?
    target_card = None
    for c in player.discard:
        if c.api_id == card_id:
            target_card = c
            break

    if target_card is None:
        return ActionResult(False, "弃牌区中没有此卡。")

    # Check: no hand
    if len(player.hand) > 0:
        return ActionResult(False, "手牌不为空，无法使用紧急上浮。")

    # Check: bench space available
    bench_slot = player.find_empty_bench_slot()
    if bench_slot is None:
        return ActionResult(False, "备战区已满。")

    # Place on bench
    player.discard.remove(target_card)
    pokemon = player.place_bench(target_card, bench_slot)
    pokemon.placed_this_turn = True
    state._log(f"{player.name}使用紧急上浮将{target_card.name}放置于备战区。")

    # Draw 3 cards
    drawn = player.draw_cards(3)
    state._log(f"{player.name}抽取了{len(drawn)}张卡。")

    return ActionResult(True, f"紧急上浮: {target_card.name}放置于备战区，抽取了{len(drawn)}张。")


def _handle_tool_exp_share(state, player, params, player_idx):
    """学习装置 Exp. Share: When your active Pokemon is KO'd by opponent's attack,
    transfer 1 basic energy from the KO'd Pokemon to the Pokemon holding this tool.
    This is a passive tool — registered but triggered via KO event in action_resolver."""
    return ActionResult(True, "学习装置已装备。击倒时自动转附基本能量。")


def _handle_draw_and_attach_energy(state, player, params, player_idx):
    """Draw 2 cards, then attach up to N Grass energy from hand to 1 bench Pokemon.
    Used by 菜种的活力."""
    energy_count = params.get("energy_count", 2)
    energy_type = params.get("energy_type", "Grass")

    # Step 1: Draw 2 cards
    drawn = player.draw_cards(2)
    drawn_count = len(drawn)
    state._log(f"{player.name}抽取了{drawn_count}张卡。")

    # Step 2: Find Grass energy in hand
    grass_energy_in_hand = [
        c for c in player.hand
        if c.is_basic_energy and energy_type in str(c.provides_energy)
    ]

    if not grass_energy_in_hand:
        return ActionResult(True, f"抽了{drawn_count}张，但手牌中没有G能量可附着。")

    # Find bench Pokemon to attach to
    bench_slots = [
        (i, p) for i, p in enumerate(player.bench) if p is not None
    ]

    if not bench_slots:
        return ActionResult(True, f"抽了{drawn_count}张，但备战区没有宝可梦。")

    max_attach = min(energy_count, len(grass_energy_in_hand))

    if len(bench_slots) == 1 and max_attach <= energy_count:
        # Auto-attach to the only bench Pokemon
        idx, bp = bench_slots[0]
        attached = 0
        for card in grass_energy_in_hand[:max_attach]:
            player.hand.remove(card)
            bp.energy_cards.append(card)
            attached += 1
        state._log(f"将{attached}张G能量附着于备战区{bp.card.name}。")
        return ActionResult(True, f"抽了{drawn_count}张，附着了{attached}张G能量。")

    # Show energy distribution screen
    energy_to_distribute = grass_energy_in_hand[:max_attach]
    targets_info = [
        {"slot": f"bench_{i}", "name": p.card.name, "bench_idx": i}
        for i, p in bench_slots
    ]

    def on_distributed(assignments):
        for ei, tgt_slot in assignments:
            if ei < len(energy_to_distribute):
                card = energy_to_distribute[ei]
                if card in player.hand:
                    player.hand.remove(card)
                    bp = player.get_pokemon(tgt_slot)
                    if bp:
                        bp.energy_cards.append(card)
        state._log(f"将{len(assignments)}张G能量附着于备战区。")

    return ActionResult(True, f"选择最多{max_attach}张G能量分配到备战宝可梦。",
                        pending_action=ActionRequest(
                            request_type="distribute_energy",
                            player=player_idx,
                            prompt=f"分配能量 — 菜种的活力",
                            card_list=energy_to_distribute,
                            target_info=targets_info,
                            distribute_mode="distribute",
                            source_name="菜种的活力",
                            callback=on_distributed,
                        ))
