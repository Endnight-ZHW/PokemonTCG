"""Draw and hand-management effect handlers."""
from engine.enums import TurnPhase
from engine.game_state import GameState, ActionResult, ActionRequest


def _handle_draw(state, player, params):
    amount = params.get("amount", 1)
    target_player = params.get("player", "self")
    actual_player = player if target_player == "self" else state.get_opponent()

    from engine.enums import TurnPhase
    from engine.rules_validator import check_win_condition

    # PTCG rule: if a player cannot draw because their deck is empty, they lose
    if len(actual_player.deck) < amount:
        loser_idx = 0 if actual_player == state.p1 else 1
        winner_idx = 1 - loser_idx
        state.winner = winner_idx
        state.phase = TurnPhase.GAME_OVER
        state._log(f"{actual_player.name}无法抽牌（卡组不足{amount}张）！"
                   f"{state.get_player(winner_idx).name}获胜！")
        return ActionResult(True, f"{actual_player.name}卡组耗尽，游戏结束。")

    drawn = actual_player.draw_cards(amount)
    state._log(f"{actual_player.name}抽取了{len(drawn)}张卡。")
    return ActionResult(True, f"抽取了{len(drawn)}张卡。", cards_drawn=drawn)


def _handle_draw_until(state, player, params):
    """Draw cards until hand has at least target_hand_size cards.
    (e.g. Radiant Charizard: draw until hand has 5 cards)."""
    target = params.get("target_hand_size", 5)
    current = len(player.hand)
    to_draw = max(0, target - current)

    if to_draw == 0:
        state._log(f"{player.name}的手牌已有{current}张，无需抽取。")
        return ActionResult(True, f"Hand already has {current} cards.")

    drawn = player.draw_cards(to_draw)
    state._log(f"{player.name}抽取了{len(drawn)}张卡，现在手牌有{len(player.hand)}张。")
    return ActionResult(True, f"Drew {len(drawn)} cards to reach {target}.")


def _handle_discard_draw(state, player, params):
    """Discard hand and draw N cards (e.g. Professor's Research)."""
    discard_hand = params.get("discard_hand", False)
    draw_amount = params.get("draw", 7)

    if discard_hand:
        player.discard_entire_hand()

    drawn = player.draw_cards(draw_amount)

    player_name = player.name
    state._log(f"{player_name}丢弃了手牌并抽取了{len(drawn)}张卡。")
    return ActionResult(True, f"Discarded and drew {len(drawn)}.")


def _handle_shuffle_draw(state, player, params):
    """Shuffle own hand into deck, then draw N cards (self only)."""
    shuffle_hand = params.get("shuffle_hand", False)
    draw_amount = params.get("draw", 5)

    if shuffle_hand:
        hand_size = len(player.hand)
        for card in player.hand[:]:
            player.deck.append(card)
        player.hand.clear()
        player.shuffle_deck()
        state._log(f"{player.name}将{hand_size}张手牌洗回牌库。")

    drawn = player.draw_cards(draw_amount)
    state._log(f"{player.name}抽取了{len(drawn)}张卡。")
    return ActionResult(True, f"洗回手牌并抽取了{len(drawn)}张卡。")


def _handle_discard_then_draw(state, player, player_idx, params):
    """Discard 1 card from hand (player chooses), then draw N.
    Used by 月石 循环抽取."""
    discard_amount = params.get("discard_amount", 1)
    draw_amount = params.get("draw_amount", 3)

    if len(player.hand) == 0:
        return ActionResult(True, "手牌为空，无需操作。")

    if len(player.hand) == 1:
        # Auto-discard the only card
        player.discard_entire_hand()
        state._log(f"{player.name}丢弃了最后1张手牌。")
        drawn = player.draw_cards(draw_amount)
        state._log(f"抽取了{len(drawn)}张卡。")
        return ActionResult(True, f"丢弃1张手牌并抽取了{len(drawn)}张。")

    def discard_callback(selected_cards):
        count = 0
        for card in selected_cards[:discard_amount]:
            if card in player.hand:
                player.hand.remove(card)
                player.discard.append(card)
                count += 1
        state._log(f"{player.name}丢弃了{count}张手牌。")
        drawn = player.draw_cards(draw_amount)
        state._log(f"抽取了{len(drawn)}张卡。")

    return ActionResult(True, f"选择{discard_amount}张手牌丢弃。",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=player_idx,
                            prompt=f"选择{discard_amount}张手牌丢弃（月石 循环抽取）",
                            min_select=1,
                            max_select=discard_amount,
                            from_zone="hand",
                            card_list=list(player.hand),
                            callback=discard_callback,
                        ))


def _handle_hand_to_bottom_draw(state, player, params):
    """Choose any number of cards from hand, put on bottom of deck, draw that many.
    Used by 嘉德丽雅."""
    if len(player.hand) == 0:
        return ActionResult(True, "手牌为空，无需操作。")

    # Let player choose cards to put back
    def caitlin_callback(selected_cards):
        count = len(selected_cards)
        # Remove selected from hand
        for card in selected_cards:
            if card in player.hand:
                player.hand.remove(card)
                player.deck.insert(0, card)  # bottom of deck
        state._log(f"{player.name}将{count}张手牌放回牌库底。")
        drawn = player.draw_cards(count)
        state._log(f"{player.name}抽取了{len(drawn)}张卡。")

    caitlin_player_idx = 0 if player is state.p1 else 1
    return ActionResult(True, f"选择任意张手牌放回牌库底。",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=caitlin_player_idx,
                            prompt="选择任意张手牌放回牌库底（嘉德丽雅）",
                            min_select=0,
                            max_select=len(player.hand),
                            from_zone="hand",
                            card_list=list(player.hand),
                            callback=caitlin_callback,
                        ))


def _handle_iono(state, player_idx, params):
    """Iono: Both players shuffle their hands into their decks,
    then each draws cards equal to their remaining prize cards."""
    results = []

    for pi in [0, 1]:
        p = state.get_player(pi)
        hand_size = len(p.hand)
        if hand_size == 0:
            continue
        # Shuffle hand back into deck
        for card in p.hand[:]:
            p.deck.append(card)
        p.hand.clear()
        p.shuffle_deck()
        # Draw = number of remaining prizes
        draw_count = len(p.prizes)
        drawn = p.draw_cards(draw_count)
        state._log(f"{p.name}将{hand_size}张手牌洗回牌库，抽取了{len(drawn)}张卡。")
        results.append(drawn)

    return ActionResult(True, f"Iono: both players shuffled and drew.")


def _handle_judge(state, player_idx, params):
    """Judge: Both players shuffle their hands into their decks,
    then each draws N cards."""
    draw_amount = params.get("draw", 4)

    for pi in [0, 1]:
        p = state.get_player(pi)
        hand_size = len(p.hand)
        if hand_size == 0:
            continue
        for card in p.hand[:]:
            p.deck.append(card)
        p.hand.clear()
        p.shuffle_deck()
        drawn = p.draw_cards(draw_amount)
        state._log(f"{p.name}将{hand_size}张手牌洗回牌库，抽取了{len(drawn)}张卡。")

    return ActionResult(True, f"Judge: both players shuffled and drew {draw_amount}.")


def _handle_houb(state, player, params):
    """凰檗: choose 1 card from hand, put to bottom of deck, then draw until hand = 5.
    Cannot be used if hand only has this 1 card."""
    target = params.get("target_hand_size", 5)

    if len(player.hand) <= 1:
        return ActionResult(False, "手牌仅有1张，无法使用凰檗（需要至少有1张其他手牌）。")

    if len(player.hand) == 2:
        # Auto: put the other card to bottom, draw to 5
        # Find the card that's NOT 凰檗 (this should be called after the card is discarded from hand)
        other = player.hand[0]  # After playing 凰檗, the remaining card is at position 0
        player.hand.remove(other)
        player.deck.append(other)  # Put to bottom
        to_draw = max(0, target - len(player.hand))
        drawn = player.draw_cards(to_draw)
        state._log(f"{player.name}将1张手牌放回牌库底，抽取了{len(drawn)}张。")
        return ActionResult(True, f"抽取了{len(drawn)}张卡，现在手牌{len(player.hand)}张。")

    # Player chooses which card to put to bottom
    def houb_callback(selected_cards):
        if selected_cards:
            card = selected_cards[0]
            if card in player.hand:
                player.hand.remove(card)
                player.deck.append(card)  # Put to bottom of deck
        to_draw = max(0, target - len(player.hand))
        drawn = player.draw_cards(to_draw)
        state._log(f"{player.name}将1张手牌放回牌库底，抽取了{len(drawn)}张。")

    # Exclude the 凰檗 card itself from choices (it was already discarded)
    houb_player_idx = 0 if player is state.p1 else 1
    return ActionResult(True, "选择1张手牌放回牌库底部（凰檗）。",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=houb_player_idx,
                            prompt="选择1张手牌放回牌库底部，然后抽到5张（凰檗）",
                            min_select=1,
                            max_select=1,
                            from_zone="hand",
                            card_list=list(player.hand),
                            callback=houb_callback,
                        ))


def _handle_shuffle_from_discard(state, player, player_idx, params):
    """Shuffle cards from discard back into deck (e.g., Super Rod, Pal Pad).
    Returns an ActionRequest so the player picks which cards."""
    count = params.get("count", 3)
    filter_type = params.get("filter", "any")

    # Build filter
    def matches(card):
        if filter_type == "supporter":
            return card.is_trainer_supporter
        if filter_type == "basic_energy":
            return card.is_basic_energy
        if filter_type == "pokemon_and_energy":
            return card.is_pokemon or card.is_basic_energy
        return True  # "any"

    available = [c for c in player.discard if matches(c)]
    if not available:
        return ActionResult(False, "弃牌区没有符合条件的卡，卡牌保留在手牌中。")

    # Callback after player picks
    def shuffle_callback(selected_cards):
        if not selected_cards:
            state._log(f"{player.name}没有从弃牌区选择卡牌。")
            return
        for card in selected_cards:
            if card in player.discard:
                player.discard.remove(card)
                player.deck.append(card)
        player.shuffle_deck()
        state._log(f"{player.name}将{len(selected_cards)}张卡从弃牌区洗回牌库。")

    zone_name = "弃牌区"
    return ActionResult(True, f"Choose up to {count} cards from discard.",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=player_idx,
                            prompt=f"从{zone_name}选择最多{count}张卡",
                            min_select=0,
                            max_select=count,
                            from_zone="discard",
                            card_list=available,
                            callback=shuffle_callback,
                        ))


def _handle_draw_until_more(state, player, params):
    """Draw cards until hand size > opponent's hand size by 1.
    Used by 贝里菈."""
    opponent = state.get_opponent()
    target = len(opponent.hand) + 1
    current = len(player.hand)
    to_draw = max(0, target - current)

    if to_draw == 0:
        state._log(f"{player.name}的手牌已有{current}张（比对手的{len(opponent.hand)}张多1张或以上），无需抽取。")
        return ActionResult(True, f"Hand already has {current} cards.")

    drawn = player.draw_cards(to_draw)
    state._log(f"{player.name}抽取了{len(drawn)}张卡（目标比对手多1张，抽了{to_draw}张）。")
    return ActionResult(True, f"抽取了{len(drawn)}张卡。")
