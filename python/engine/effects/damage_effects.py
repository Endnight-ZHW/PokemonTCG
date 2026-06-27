"""Damage-related effect handlers."""
import random
from engine.rules_constants import DAMAGE_PER_COUNTER
from engine.enums import TurnPhase
from engine.game_state import GameState, ActionResult, ActionRequest
from engine.actions import PokemonRef, resolve_pokemon_ref
from engine.commands.damage_pipeline import resolve_damage as event_damage_pipeline


def _discard_pokemon_for_effect(state: GameState, player_idx: int, slot: str):
    """Discard a Pokemon from play and unregister its event modifiers."""
    player = state.get_player(player_idx)
    pokemon = player.get_pokemon(slot)
    if pokemon is None:
        return None
    try:
        from engine.commands.modifier_registration import unregister_pokemon_modifiers

        unregister_pokemon_modifiers(
            pokemon.card.api_id,
            slot,
            event_bus=state.event_bus,
        )
    except Exception:
        pass
    state.discard_pokemon(player_idx, slot)
    return pokemon


def _award_prizes_for_effect_ko(state: GameState, knocked_player_idx: int, pokemon) -> None:
    prize_taker_idx = 1 - knocked_player_idx
    prize_taker = state.get_player(prize_taker_idx)
    for _ in range(getattr(pokemon.card, "prize_value", 1)):
        if prize_taker.prizes:
            prize_taker.take_prize()
            state._log(
                f"{prize_taker.name}获得了奖品卡！"
                f"（剩余{len(prize_taker.prizes)}张）"
            )


def _set_promotion_or_game_over(state: GameState, player_idx: int) -> None:
    player = state.get_player(player_idx)
    opponent = state.get_player(1 - player_idx)
    if player.active is not None:
        return
    if not player.has_any_pokemon_in_play():
        state.winner = 1 - player_idx
        state.phase = TurnPhase.GAME_OVER
        state._log(f"{opponent.name}获胜——对手场上没有宝可梦了！")
        return
    state.pending_promotion_player = player_idx


def _handle_effect_ko_if_needed(
    state: GameState,
    player_idx: int,
    slot: str,
    pokemon,
    ko_slots: list[str],
) -> None:
    if pokemon is None or not pokemon.is_knocked_out:
        return
    knocked = _discard_pokemon_for_effect(state, player_idx, slot)
    if knocked is None:
        return
    ko_slots.append(f"p{player_idx}_{slot}")
    state._log(f"{state.get_player(player_idx).name}的{knocked.card.name}被击倒了！")
    _award_prizes_for_effect_ko(state, player_idx, knocked)
    from engine.rules_validator import check_win_condition

    winner = check_win_condition(state)
    if winner is not None:
        state.winner = winner
        state.phase = TurnPhase.GAME_OVER
        state._log(f"{state.get_player(winner).name}获胜！")
        return
    if slot == "active":
        state.pending_promotion_player = player_idx


def _check_effect_damage_prevented(defender, state) -> bool:
    """Check if damage from attack effects should be prevented.
    Returns True if damage should be skipped.
    Checks both damage_prevented_next_turn (full damage prevention) and
    all_prevented_next_turn (effect-only prevention from 七夕青鸟ex 光之波動).
    Consumes the relevant immunity flag."""
    if getattr(defender, 'damage_prevented_next_turn', False):
        defender.damage_prevented_next_turn = False
        # Also consume all_prevented if both were set (prevent_all)
        if getattr(defender, 'all_prevented_next_turn', False):
            defender.all_prevented_next_turn = False
        state._log(f"{defender.card.name}免疫了伤害！")
        return True
    if getattr(defender, 'all_prevented_next_turn', False):
        defender.all_prevented_next_turn = False
        state._log(f"{defender.card.name}免疫了附加效果伤害！")
        return True
    return False


def _handle_damage(state, player, opponent, params, source_slot):
    amount = params.get("amount", 0)
    target_str = params.get("target", "opponent_active")

    if target_str == "opponent_active" and opponent.active:
        defender = opponent.active
        damage = amount
        if _check_effect_damage_prevented(defender, state):
            return ActionResult(True, "伤害被免疫。")

        defender.damage_counters += damage // DAMAGE_PER_COUNTER
        msg = f"对{defender.card.name}造成{damage}点伤害。"
        state._log(msg)
        return ActionResult(True, msg, damage_dealt=damage)
    elif target_str == "self" and player.active:
        player.active.damage_counters += amount // DAMAGE_PER_COUNTER
        state._log(f"{player.active.card.name}自身受到{amount}点伤害。")
        return ActionResult(True, f"自身伤害: {amount}")

    return ActionResult(True, f"伤害: {amount}")


def _count_attached_energy_of_type(pokemon, energy_type: str) -> int:
    if pokemon is None:
        return 0
    energy_type = str(energy_type or "").lower()
    return sum(
        1
        for card in pokemon.energy_cards
        if any(str(provided).lower() == energy_type for provided in card.provides_energy)
    )


def _handle_attack_damage_formula(state, player, opponent, params, source_slot):
    """Primary attack damage formula that still uses the normal damage pipeline."""
    attacker = player.get_pokemon(source_slot) or player.active
    defender = opponent.active
    if attacker is None or defender is None:
        return ActionResult(False, "没有目标。")

    total = int(params.get("base", 0) or 0)
    per_own_bench = int(params.get("per_own_bench", 0) or 0)
    if per_own_bench:
        bench_count = sum(1 for poke in player.bench if poke is not None)
        total += bench_count * per_own_bench

    energy_type = params.get("per_self_energy_type")
    if energy_type:
        per_energy = int(params.get("per_energy", 0) or 0)
        energy_count = _count_attached_energy_of_type(attacker, str(energy_type))
        total += energy_count * per_energy

    per_self_damage_counter = int(params.get("per_self_damage_counter", 0) or 0)
    if per_self_damage_counter:
        total += attacker.damage_counters * per_self_damage_counter

    condition_bonus = params.get("condition_bonus") or {}
    if isinstance(condition_bonus, dict):
        condition = str(condition_bonus.get("condition", "") or "")
        applies = False
        if condition == "ko_by_attack_last_turn":
            applies = player.was_ko_by_attack
        elif condition == "own_bench_damaged":
            applies = any(
                poke is not None and poke.damage_counters > 0
                for poke in player.bench
            )
        elif condition == "opponent_active_evolved":
            applies = defender is not None and not defender.card.is_basic_pokemon
        elif condition == "opponent_active_damaged":
            applies = defender is not None and defender.damage_counters > 0
        elif condition == "own_hand_empty":
            applies = len(player.hand) == 0

        if applies:
            total += int(condition_bonus.get("bonus", 0) or 0)
            if condition == "ko_by_attack_last_turn" and bool(condition_bonus.get("consume", True)):
                player.was_ko_by_attack = False

    ignore_defender_effects = bool(params.get("ignore_defender_effects", False))
    if not ignore_defender_effects and _check_effect_damage_prevented(defender, state):
        return ActionResult(True, "伤害被免疫。")

    attacker_type = attacker.card.energy_types[0] if attacker.card.energy_types else "Colorless"
    final_damage, mod_logs = event_damage_pipeline(
        state,
        attacker,
        defender,
        total,
        attacker_type,
        piercing=bool(params.get("piercing", False)),
        ignore_defender_effects=ignore_defender_effects,
    )
    for log_msg in mod_logs:
        state._log(log_msg)

    defender.damage_counters += final_damage // DAMAGE_PER_COUNTER
    state._log(f"对{defender.card.name}造成{final_damage}点伤害。")
    return ActionResult(True, f"伤害: {final_damage}", damage_dealt=final_damage)


def _check_bench_protection(target_state) -> bool:
    """Check if a player has bench protection from an ability (e.g. Manaphy's 波之幕)."""
    all_pokemon = [target_state.active] if target_state.active else []
    all_pokemon.extend(p for p in target_state.bench if p is not None)
    for poke in all_pokemon:
        for ab in (poke.card.abilities or []):
            text = ab.text if hasattr(ab, 'text') else ''
            if '备战宝可梦不会受到' in text:
                return True
    return False


def _handle_bench_damage(state, player, opponent, params):
    amount = params.get("amount", 0)
    count = params.get("count", 1)
    target_player = params.get("player", "opponent")
    choose_targets = params.get("choose_targets", True)

    target_state = opponent if target_player == "opponent" else state.get_player(0 if target_player == "self" else 1)

    # Check for bench protection ability (e.g. Manaphy 波之幕)
    if _check_bench_protection(target_state):
        state._log(f"{target_state.name}的备战宝可梦受到特性保护，不会受到伤害。")
        return ActionResult(True, "Bench protected by ability.")

    bench_indices = [i for i, p in enumerate(target_state.bench)
                     if p is not None and not p.damage_prevented_next_turn
                     and not getattr(p, 'all_prevented_next_turn', False)]

    if not bench_indices:
        state._log(f"{target_state.name}的备战区没有可攻击的宝可梦。")
        return ActionResult(True, "No bench targets.")

    actual_count = min(count, len(bench_indices))

    # Auto-apply if only one target or player choice disabled
    if not choose_targets or len(bench_indices) == 1:
        counters = amount // DAMAGE_PER_COUNTER
        hits = 0
        for idx in bench_indices:
            if hits >= actual_count:
                break
            target_state.bench[idx].damage_counters += counters
            hits += 1
        state._log(f"对{target_state.name}的备战区造成了{hits}次{amount}点伤害。")
        return ActionResult(True, f"Bench damage dealt to {hits} Pokemon.")

    # Let player choose which bench Pokemon to hit
    def bench_damage_callback(selected_indices):
        counters = amount // DAMAGE_PER_COUNTER
        hits = 0
        for idx in selected_indices[:actual_count]:
            if idx < len(target_state.bench) and target_state.bench[idx]:
                target_state.bench[idx].damage_counters += counters
                hits += 1
        state._log(f"对{target_state.name}的备战区造成了{hits}次{amount}点伤害。")

    bench_player_idx = 0 if player is state.p1 else 1
    return ActionResult(True, f"选择{actual_count}个备战宝可梦作为目标。",
                        pending_action=ActionRequest(
                            request_type="select_bench_targets",
                            player=bench_player_idx,
                            prompt=f"选择{actual_count}个对手备战宝可梦作为目标。",
                            min_select=actual_count,
                            max_select=actual_count,
                            target_player=target_player,
                            bench_indices=bench_indices,
                            callback=bench_damage_callback,
                        ))


def _handle_damage_counter_self(state, player, params, source_slot):
    amount = params.get("amount", 0)
    player_idx = 0 if state.p1 is player else 1
    target = player.get_pokemon(source_slot)
    ko_slots: list[str] = []
    if target:
        target.damage_counters += amount // DAMAGE_PER_COUNTER
        state._log(f"{target.card.name}对自己放置了{amount}点伤害。")
        _handle_effect_ko_if_needed(state, player_idx, source_slot, target, ko_slots)
    return ActionResult(True, f"Self damage counters: {amount}.", pokemon_ko=ko_slots)


def _handle_damage_per_prize(state, player, opponent, params):
    """Damage that scales with opponent's prize cards taken.
    Used by Charizard ex Burning Darkness: 180 + 30 per prize taken."""
    base_damage = params.get("base", 0)
    per_prize = params.get("per_prize", 30)
    prizes_taken = 6 - len(opponent.prizes)
    total = base_damage + per_prize * prizes_taken

    if opponent.active:
        defender = opponent.active
        if _check_effect_damage_prevented(defender, state):
            return ActionResult(True, "伤害被免疫。")
        counters = total // DAMAGE_PER_COUNTER
        defender.damage_counters += counters
        state._log(f"对{defender.card.name}造成{total}点伤害（基础{base_damage}+{per_prize}×{prizes_taken}张奖品卡）。")
        return ActionResult(True, f"伤害: {total}", damage_dealt=total)
    return ActionResult(False, "没有目标。")


def _handle_damage_per_energy(state, player, opponent, params):
    """Damage that scales with energy attached to target Pokemon.
    Used by Magnezone ex Energy Crush: 50× per energy on all opponent's Pokemon."""
    base_damage = params.get("base", 0)
    per_energy = params.get("per_energy", 0)
    target_str = params.get("target", "opponent_active")
    count_from = params.get("count_from", "self")

    # Count energy
    energy_count = 0
    if count_from == "self":
        source = player.active
        if source:
            energy_count = len(source.energy_cards)
    elif count_from == "opponent_active":
        if opponent.active:
            energy_count = len(opponent.active.energy_cards)
    elif count_from == "all_opponent":
        for p in [opponent.active] + [b for b in opponent.bench if b is not None]:
            if p:
                energy_count += len(p.energy_cards)

    total = base_damage + per_energy * energy_count

    if target_str == "opponent_active" and opponent.active:
        defender = opponent.active
        if _check_effect_damage_prevented(defender, state):
            return ActionResult(True, "伤害被免疫。")
        counters = total // DAMAGE_PER_COUNTER
        defender.damage_counters += counters
        state._log(f"对{defender.card.name}造成{total}点伤害。")
        return ActionResult(True, f"伤害: {total}", damage_dealt=total)
    return ActionResult(False, "没有目标。")


def _handle_any_pokemon_damage(state, player, opponent, params):
    """Damage to any ONE of the opponent's Pokemon (active or bench).
    If targeting bench, weakness/resistance is not calculated."""
    amount = params.get("amount", 0)
    piercing_on_bench = params.get("piercing_on_bench", False)

    # Collect all valid targets (opponent active + benched Pokemon)
    targets = []
    if opponent.active:
        targets.append(("active", opponent.active))
    for i, p in enumerate(opponent.bench):
        if p is not None:
            targets.append((f"bench_{i}", p))

    if not targets:
        return ActionResult(True, "对手场上没有宝可梦。")

    if len(targets) == 1:
        # Auto-select the only target
        slot_name, target_poke = targets[0]
        if _check_effect_damage_prevented(target_poke, state):
            return ActionResult(True, "伤害被免疫。")
        counters = amount // DAMAGE_PER_COUNTER
        target_poke.damage_counters += counters
        state._log(f"对{target_poke.card.name}造成了{amount}点伤害。")
        return ActionResult(True, f"对{target_poke.card.name}造成{amount}点伤害。", damage_dealt=amount)

    # Let player choose target
    def any_damage_callback(selected_cards):
        for card in selected_cards:
            if isinstance(card, PokemonRef):
                selected_pokemon = resolve_pokemon_ref(state, card)
                for slot_name, target_poke in targets:
                    if target_poke is selected_pokemon:
                        if not _check_effect_damage_prevented(target_poke, state):
                            counters = amount // DAMAGE_PER_COUNTER
                            target_poke.damage_counters += counters
                            state._log(f"对{target_poke.card.name}造成了{amount}点伤害。")
                        return
            for slot_name, target_poke in targets:
                if target_poke.card.api_id == card.api_id:
                    if _check_effect_damage_prevented(target_poke, state):
                        break
                    counters = amount // DAMAGE_PER_COUNTER
                    target_poke.damage_counters += counters
                    state._log(f"对{target_poke.card.name}造成了{amount}点伤害。")
                    break
            break

    target_cards = [t[1].card for t in targets]
    any_dmg_player_idx = 0 if player is state.p1 else 1

    return ActionResult(True, f"选择1只对手的宝可梦作为目标。",
                        pending_action=ActionRequest(
                            request_type="search_deck",
                            player=any_dmg_player_idx,
                            prompt=f"选择1只对手的宝可梦，造成{amount}点伤害",
                            min_select=1,
                            max_select=1,
                            from_zone="board",
                            target_player="opponent",
                            card_list=target_cards,
                            callback=any_damage_callback,
                        ))


def _handle_conditional_damage_bonus(state, player, opponent, params):
    """Apply bonus damage if a condition is met."""
    bonus = params.get("bonus", 0)
    condition = params.get("condition", "")

    if condition == "opponent_active_damaged" and opponent.active:
        if opponent.active.damage_counters > 0:
            if _check_effect_damage_prevented(opponent.active, state):
                return ActionResult(True, "追加伤害被免疫。")
            counters = bonus // DAMAGE_PER_COUNTER
            opponent.active.damage_counters += counters
            state._log(f"追加造成{bonus}点伤害！（激流斩条件触发）")
            return ActionResult(True, f"追加{bonus}点伤害。", damage_dealt=bonus)

    if condition == "ko_by_attack_last_turn":
        if player.was_ko_by_attack:
            player.was_ko_by_attack = False
            if opponent.active:
                if _check_effect_damage_prevented(opponent.active, state):
                    return ActionResult(True, "追加伤害被免疫。")
                counters = bonus // DAMAGE_PER_COUNTER
                opponent.active.damage_counters += counters
                state._log(f"追加造成{bonus}点伤害！（嫉妒业火条件触发）")
                return ActionResult(True, f"追加{bonus}点伤害。", damage_dealt=bonus)
        else:
            state._log("上个对手回合没有宝可梦因招式伤害昏厥，嫉妒业火追加伤害不触发。")

    if condition == "opponent_active_evolved" and opponent.active:
        # 摔角鹰人 挥落: if opponent active is evolved +30
        if not opponent.active.card.is_basic_pokemon:
            if _check_effect_damage_prevented(opponent.active, state):
                return ActionResult(True, "追加伤害被免疫。")
            counters = bonus // DAMAGE_PER_COUNTER
            opponent.active.damage_counters += counters
            state._log(f"追加造成{bonus}点伤害！（对手为进化宝可梦）")
            return ActionResult(True, f"追加{bonus}点伤害。", damage_dealt=bonus)
        else:
            state._log("对手战斗宝可梦不是进化宝可梦，挥落追加伤害不触发。")

    if condition == "field_energy_ge_5":
        # 克雷色利亚 光子镭射: 己方场上能量≥5时+90
        total_energy = 0
        for slot_name, poke in player.get_all_pokemon():
            if poke:
                total_energy += len(poke.energy_cards)
        if total_energy >= 5:
            if opponent.active:
                if _check_effect_damage_prevented(opponent.active, state):
                    return ActionResult(True, "追加伤害被免疫。")
                counters = bonus // DAMAGE_PER_COUNTER
                opponent.active.damage_counters += counters
                state._log(f"追加造成{bonus}点伤害！（场上能量{total_energy}≥5）")
                return ActionResult(True, f"追加{bonus}点伤害。", damage_dealt=bonus)
        else:
            state._log(f"场上能量{total_energy}不足5个，光子镭射追加伤害不触发。")

    return ActionResult(True, "无追加伤害。")


def _handle_damage_plus_bench(state, player, opponent, params):
    """Damage = base + own_bench_count × per_bench."""
    base = params.get("base", 0)
    per_bench = params.get("per_bench", 0)
    count_own_bench = params.get("count_own_bench", True)

    bench_count = 0
    if count_own_bench:
        bench_count = sum(1 for p in player.bench if p is not None)

    total = base + bench_count * per_bench

    if opponent.active:
        defender = opponent.active
        if _check_effect_damage_prevented(defender, state):
            return ActionResult(True, "伤害被免疫。")
        counters = total // DAMAGE_PER_COUNTER
        defender.damage_counters += counters
        state._log(f"对{defender.card.name}造成{total}点伤害（基础{base}+备战{bench_count}只×{per_bench}）。")
        return ActionResult(True, f"伤害: {total}", damage_dealt=total)
    return ActionResult(False, "没有目标。")


def _handle_place_counters_and_self_ko(state, player_idx, opponent, params, source_slot):
    """Place damage counters on any opponent's Pokemon, then discard this Pokemon."""
    counters = params.get("counters", 2)
    target = params.get("target", "opponent_any")

    player = state.get_player(player_idx)
    ko_slots: list[str] = []

    # Collect all opponent's Pokemon as targets
    targets = []
    if opponent.active:
        targets.append(("active", opponent.active))
    for i, p in enumerate(opponent.bench):
        if p is not None:
            targets.append((f"bench_{i}", p))

    if not targets:
        return ActionResult(True, "对手场上没有宝可梦。")

    def _do_mystic_comet(slot_name, target_poke):
        # Place damage counters
        target_poke.damage_counters += counters
        state._log(f"在{target_poke.card.name}身上放置了{counters}个伤害指示物。")
        _handle_effect_ko_if_needed(state, 1 - player_idx, slot_name, target_poke, ko_slots)
        if state.phase == TurnPhase.GAME_OVER:
            return

        # Then self KO: discard this Pokemon and all attachments
        source = _discard_pokemon_for_effect(state, player_idx, source_slot)
        if source:
            state._log(f"{source.card.name}被放置于弃牌区。")
            if source_slot == "active":
                _set_promotion_or_game_over(state, player_idx)

    if len(targets) == 1:
        _do_mystic_comet(*targets[0])
    else:
        # Let player choose
        def comet_callback(selected_cards):
            for card in selected_cards:
                if isinstance(card, PokemonRef):
                    selected_pokemon = resolve_pokemon_ref(state, card)
                    for slot_name, target_poke in targets:
                        if target_poke is selected_pokemon:
                            _do_mystic_comet(slot_name, target_poke)
                            return ActionResult(
                                True,
                                "神秘彗星结算完毕。",
                                pokemon_ko=list(ko_slots),
                            )
                for slot_name, target_poke in targets:
                    if target_poke.card.api_id == card.api_id:
                        _do_mystic_comet(slot_name, target_poke)
                        return ActionResult(True, "神秘彗星结算完毕。", pokemon_ko=list(ko_slots))
                break
            return ActionResult(True, "神秘彗星没有选择目标。")

        target_cards = [t[1].card for t in targets]

        return ActionResult(True, "选择1只对手的宝可梦放置伤害指示物。",
                            pending_action=ActionRequest(
                                request_type="search_deck",
                                player=player_idx,
                                prompt="选择1只对手的宝可梦，放置2个伤害指示物",
                                min_select=1,
                                max_select=1,
                                from_zone="board",
                                target_player="opponent",
                                card_list=target_cards,
                                callback=comet_callback,
                            ))

    return ActionResult(True, "神秘彗星结算完毕。", pokemon_ko=list(ko_slots))


def _handle_mill_and_damage_per_energy(state, player, opponent, params):
    """Mill top N cards of own deck. Deal X * (number of energy cards found) damage.
    Energy cards go to discard, rest go back to deck and shuffle.
    Used by 烈焰猴 螺旋业火."""
    mill_count = params.get("mill_count", 5)
    damage_per = params.get("damage_per", 80)

    milled = []
    for _ in range(min(mill_count, len(player.deck))):
        milled.append(player.deck.pop())

    energy_cards = [c for c in milled if c.is_energy]
    non_energy = [c for c in milled if not c.is_energy]

    # Energy cards go to discard
    for c in energy_cards:
        player.discard.append(c)

    # Non-energy cards go back to deck
    for c in non_energy:
        player.deck.append(c)
    player.shuffle_deck()

    energy_count = len(energy_cards)
    total_damage = damage_per * energy_count

    state._log(f"翻开了{len(milled)}张卡，其中{energy_count}张能量卡。")

    if total_damage > 0 and opponent.active:
        defender = opponent.active
        if _check_effect_damage_prevented(defender, state):
            return ActionResult(True, "伤害被免疫。")
        counters = total_damage // DAMAGE_PER_COUNTER
        defender.damage_counters += counters
        state._log(f"对{defender.card.name}造成{total_damage}点伤害！")
        return ActionResult(True, f"螺旋业火: {total_damage}伤害。", damage_dealt=total_damage)

    return ActionResult(True, "螺旋业火: 无能量卡，造成0伤害。")


def _handle_damage_per_self_energy(state, player, opponent, params):
    """Damage = base + number of specific energy attached to self * per_energy.
    Used by 炎帝 火焰之球."""
    base = params.get("base", 60)
    per_energy = params.get("per_energy", 20)
    energy_filter = params.get("energy_filter", "fire")

    source = player.active
    if not source:
        return ActionResult(False, "没有宝可梦。")

    matching = sum(1 for c in source.energy_cards
                   if energy_filter == "any" or
                   any(et.lower() == energy_filter.lower() for et in c.provides_energy))
    total = base + per_energy * matching

    if opponent.active:
        defender = opponent.active
        if _check_effect_damage_prevented(defender, state):
            return ActionResult(True, "伤害被免疫。")
        counters = total // DAMAGE_PER_COUNTER
        defender.damage_counters += counters
        state._log(f"对{defender.card.name}造成{total}点伤害（基础{base}+{per_energy}×{matching}张火能量）。")
        return ActionResult(True, f"伤害: {total}", damage_dealt=total)
    return ActionResult(False, "没有目标。")


def _handle_damage_per_hand_size(state, player, opponent, params):
    """Damage = player's hand size × per. Used by 双尾怪手 长手抛掷, 爱管侍 妙手强念."""
    per = params.get("per", 20)
    hand_size = len(player.hand)
    total = per * hand_size

    if total > 0 and opponent.active:
        defender = opponent.active
        if _check_effect_damage_prevented(defender, state):
            return ActionResult(True, "伤害被免疫。")
        counters = total // DAMAGE_PER_COUNTER
        defender.damage_counters += counters
        state._log(f"造成{total}点伤害（手牌{hand_size}张×{per}）。")
        return ActionResult(True, f"伤害: {total}", damage_dealt=total)

    state._log("手牌为0张，造成0点伤害。")
    return ActionResult(True, "手牌为0张，造成0点伤害。")


def _handle_damage_per_discard_psychic(state, player, opponent, params):
    """Damage = base + count of Psychic Pokemon in discard × per_card.
    Used by 墓扬犬 扫墓."""
    base = params.get("base", 80)
    per_card = params.get("per_card", 10)

    # Count Psychic-type Pokemon in discard
    psychic_count = sum(
        1 for c in player.discard
        if c.is_pokemon and c.energy_types and "Psychic" in c.energy_types
    )
    total = base + per_card * psychic_count

    if opponent.active:
        defender = opponent.active
        if _check_effect_damage_prevented(defender, state):
            return ActionResult(True, "伤害被免疫。")
        counters = total // DAMAGE_PER_COUNTER
        defender.damage_counters += counters
        state._log(f"对{defender.card.name}造成{total}点伤害（基础{base}+弃牌区{psychic_count}只超宝可梦×{per_card}）。")
        return ActionResult(True, f"扫墓: {total}伤害。", damage_dealt=total)

    return ActionResult(False, "没有目标。")


def _handle_discard_hand_conditional_bonus(state, player, opponent, params, source_slot):
    """Discard entire hand. If discarded >= threshold, deal bonus damage.
    Used by 藏饱栗鼠 倾倒一空."""
    threshold = params.get("threshold", 5)
    base_damage = params.get("base_damage", 60)
    bonus = params.get("bonus", 150)

    hand_size = len(player.hand)
    player.discard_entire_hand()
    state._log(f"{player.name}将{hand_size}张手牌全部丢弃。")

    total = base_damage
    if hand_size >= threshold:
        total += bonus
        state._log(f"丢弃了{hand_size}张（≥{threshold}张），追加{bonus}点伤害！")

    if opponent.active:
        defender = opponent.active
        if _check_effect_damage_prevented(defender, state):
            return ActionResult(True, "伤害被免疫。")
        counters = total // DAMAGE_PER_COUNTER
        defender.damage_counters += counters
        state._log(f"对{defender.card.name}造成{total}点伤害。")
        return ActionResult(True, f"倾倒一空: {total}伤害。", damage_dealt=total)

    return ActionResult(True, f"倾倒一空: {total}伤害。")


def _handle_coin_flip_triple(state, player, opponent, params):
    """Flip N coins, deal heads_count × damage_per_head.
    Used by 天然雀 三连突刺."""
    flips = params.get("flips", 3)
    damage_per_head = params.get("damage_per_head", 10)

    def on_flip_complete(results: list[bool]):
        heads = sum(1 for r in results if r)
        total = damage_per_head * heads
        state._log(f"掷了{flips}次硬币，{heads}次正面！造成{total}点伤害。")

        if total > 0 and opponent.active:
            defender = opponent.active
            if _check_effect_damage_prevented(defender, state):
                return ActionResult(True, "伤害被免疫。")
            counters = total // DAMAGE_PER_COUNTER
            defender.damage_counters += counters
            return ActionResult(True, f"三连突刺: {total}伤害。", damage_dealt=total)

        return ActionResult(True, f"三连突刺: 0伤害。")

    return ActionResult(
        True, f"掷{flips}次硬币中...",
        pending_action=ActionRequest(
            request_type="coin_flip",
            player=state.active_player_idx,
            prompt=f"掷{flips}次硬币",
            flip_count=flips,
            callback=on_flip_complete,
        )
    )


def _handle_coin_flip_double_ko(state, player, opponent, player_idx, source_slot):
    """大树切割: flip 2 coins. If both heads, KO opponent's active Pokemon."""

    def on_flip_complete(results: list[bool]):
        coin1 = "正面" if results[0] else "反面"
        coin2 = "正面" if results[1] else "反面"
        state._log(f"大树切割掷硬币: {coin1}, {coin2}!")

        if results[0] and results[1]:
            if opponent.active:
                if _check_effect_damage_prevented(opponent.active, state):
                    return ActionResult(True, "击倒效果被免疫。")
                remaining = opponent.active.current_hp
                counters = max(1, (remaining + 9) // DAMAGE_PER_COUNTER)
                opponent.active.damage_counters += counters
                state._log(f"{opponent.active.card.name}被大树切割击倒！")
                return ActionResult(True, f"{opponent.active.card.name}被击倒！", pokemon_ko=[f"opponent_active"])
            return ActionResult(True, "没有对手宝可梦。")
        else:
            state._log("大树切割失败。")
            return ActionResult(True, "大树切割失败。")

    return ActionResult(
        True, "掷2次硬币中...",
        pending_action=ActionRequest(
            request_type="coin_flip",
            player=player_idx,
            prompt="掷2次硬币",
            flip_count=2,
            callback=on_flip_complete,
        )
    )


def _handle_discard_fighting_energy_damage(state, player, opponent, params):
    """连续波导弹: discard all Fighting energy from self, deal base + per_energy * count damage.
    Damage is applied directly to opponent active."""
    base = params.get("base", 10)
    per_energy = params.get("per_energy", 60)

    source = player.active
    if source is None:
        return ActionResult(False, "没有战斗宝可梦。")

    # Count and discard Fighting energy from unified energy_cards
    fighting_count = 0
    kept_energy = []
    for c in source.energy_cards:
        if hasattr(c, 'provides_energy') and \
           any(et.lower() == 'fighting' for et in c.provides_energy):
            player.discard.append(c)
            fighting_count += 1
        else:
            kept_energy.append(c)
    source.energy_cards = kept_energy

    total_damage = base + per_energy * fighting_count
    state._log(f"丢弃了{fighting_count}个斗能量，造成{total_damage}点伤害。")

    if opponent.active and total_damage > 0:
        if _check_effect_damage_prevented(opponent.active, state):
            return ActionResult(True, "伤害被免疫。")
        counters = total_damage // DAMAGE_PER_COUNTER
        opponent.active.damage_counters += counters
        return ActionResult(True, f"连续波导弹造成{total_damage}点伤害。", damage_dealt=total_damage)

    return ActionResult(True, f"丢弃了{fighting_count}个斗能量。")


def _handle_damage_per_self_damage(state, player, opponent, params):
    """Damage = base + self_damage_counters × per_counter.
    Used by 老翁龙 逆鳞: 60 + self damage counters × 10."""
    base = params.get("base", 60)
    per_counter = params.get("per_counter", 10)

    source = player.active
    if source:
        bonus = source.damage_counters * per_counter
        total = base + bonus

        if opponent.active:
            defender = opponent.active
            if _check_effect_damage_prevented(defender, state):
                return ActionResult(True, "伤害被免疫。")
            counters = total // DAMAGE_PER_COUNTER
            defender.damage_counters += counters
            state._log(f"对{defender.card.name}造成{total}点伤害。"
                      f"（基础{base}+伤害指示物{source.damage_counters}个×{per_counter}）")
            return ActionResult(True, f"伤害: {total}", damage_dealt=total)
    return ActionResult(False, "没有目标。")


def _handle_damage_self_penalty(state, player, opponent, params):
    """Damage = base - self_damage_counters × per_counter. Minimum 0.
    Used by 浩大鲸 扫除冲撞: 200 - self damage counters × 20."""
    base = params.get("base", 200)
    per_counter = params.get("per_counter", 20)
    per_counter_in_dmg = per_counter // DAMAGE_PER_COUNTER

    source = player.active
    if source:
        penalty = source.damage_counters * per_counter
        total = max(0, base - penalty)

        if opponent.active:
            defender = opponent.active
            if _check_effect_damage_prevented(defender, state):
                return ActionResult(True, "伤害被免疫。")
            counters = total // DAMAGE_PER_COUNTER
            defender.damage_counters += counters
            state._log(f"对{defender.card.name}造成{total}点伤害。"
                      f"（{base}−伤害指示物{source.damage_counters}个×{per_counter}）")
            return ActionResult(True, f"伤害: {total}", damage_dealt=total)
    return ActionResult(False, "没有目标。")


def _handle_conditional_damage_heal(state, player, opponent, params):
    """Damage with bonus if this Pokemon was healed this turn.
    Used by 大奶罐 活泼冲撞: 60 + 90 if healed this turn."""
    base = params.get("base", 60)
    bonus = params.get("bonus", 90)
    healed_flag = getattr(player, 'healed_this_turn', False)

    total = base + (bonus if healed_flag else 0)

    if opponent.active:
        defender = opponent.active
        if _check_effect_damage_prevented(defender, state):
            return ActionResult(True, "伤害被免疫。")
        counters = total // DAMAGE_PER_COUNTER
        defender.damage_counters += counters
        heal_msg = "（本回合回复过HP，追加90伤害！）" if healed_flag else ""
        state._log(f"对{defender.card.name}造成{total}点伤害。{heal_msg}")
        return ActionResult(True, f"伤害: {total}", damage_dealt=total)

    return ActionResult(False, "没有目标。")


def _handle_damage_per_evolved(state, player, opponent, params):
    """Damage = per_evolved × number of evolved Pokemon on your field.
    Used by 土台龟 进化压制: 50 × evolved Pokemon count on your field."""
    per_evolved = params.get("per_evolved", 50)

    evolved_count = 0
    for slot_name, poke in player.get_all_pokemon():
        if poke and poke.card and not poke.card.is_basic_pokemon:
            evolved_count += 1

    total = per_evolved * evolved_count

    if opponent.active:
        defender = opponent.active
        if total > 0:
            if _check_effect_damage_prevented(defender, state):
                return ActionResult(True, "伤害被免疫。")
            counters = total // DAMAGE_PER_COUNTER
            defender.damage_counters += counters
            state._log(f"对{defender.card.name}造成{total}点伤害。"
                      f"（{per_evolved}×{evolved_count}只进化宝可梦）")
            return ActionResult(True, f"伤害: {total}", damage_dealt=total)
        else:
            state._log("场上没有进化宝可梦，进化压制造成0点伤害。")
            return ActionResult(True, "进化压制造成0点伤害。")

    return ActionResult(False, "没有目标。")


def _handle_damage_per_self_energy_type(state, player, opponent, params):
    """Damage = base + per_energy × number of specific-type energy attached to self.
    Used by 萨戮德 反复鞭挞: 60 + G energy count × 20."""
    base = params.get("base", 60)
    per_energy = params.get("per_energy", 20)
    energy_type = params.get("energy_type", "Grass")

    source = player.active
    if source:
        type_energy_count = sum(1 for c in source.energy_cards
                                if any(et.lower() == energy_type.lower()
                                       for et in c.provides_energy))

        total = base + per_energy * type_energy_count

        if opponent.active:
            defender = opponent.active
            if _check_effect_damage_prevented(defender, state):
                return ActionResult(True, "伤害被免疫。")
            counters = total // DAMAGE_PER_COUNTER
            defender.damage_counters += counters
            state._log(f"对{defender.card.name}造成{total}点伤害。"
                      f"（{base}+{per_energy}×{type_energy_count}个{energy_type}能量）")
            return ActionResult(True, f"伤害: {total}", damage_dealt=total)

    return ActionResult(False, "没有目标。")


def _handle_damage_and_self_heal(state, player, opponent, params):
    """Deal damage AND heal self.
    Used by 蘑蘑菇 吸取: 10 damage + heal 10 from self."""
    damage = params.get("damage", 10)
    heal = params.get("heal", 10)

    source = player.active

    # Deal damage
    if opponent.active and damage > 0:
        if _check_effect_damage_prevented(opponent.active, state):
            pass  # damage prevented, continue to heal
        else:
            counters = damage // DAMAGE_PER_COUNTER
            opponent.active.damage_counters += counters
            state._log(f"对{opponent.active.card.name}造成{damage}点伤害。")

    # Heal self
    if source and heal > 0:
        heal_counters = heal // DAMAGE_PER_COUNTER
        if source.damage_counters > 0:
            actual = min(source.damage_counters, heal_counters)
            source.damage_counters -= actual
            state._log(f"{source.card.name}回复了{actual * DAMAGE_PER_COUNTER}点HP。")
            # Track heal for 大奶罐 活泼冲撞
            player.healed_this_turn = True

    return ActionResult(True, f"造成{damage}点伤害并回复{heal}点HP。", damage_dealt=damage)
