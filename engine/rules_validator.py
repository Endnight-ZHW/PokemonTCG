"""Rules validator - checks if actions are legal under PTCG rules."""
from typing import Optional
from engine.enums import TurnPhase, PlayerAction, StatusType
from engine.game_state import GameState
from engine.player_state import PlayerState, PokemonInPlay
from engine.rules_constants import DECK_SIZE, MAX_BENCH_SIZE, MAX_COPIES_PER_CARD
from data.card_models import Card


def can_play_basic(state: GameState, player_idx: int, card: Card,
                   target: str) -> tuple[bool, str]:
    """Check if a Basic Pokemon can be played to a slot."""
    if state.phase not in (TurnPhase.SETUP, TurnPhase.MAIN):
        return False, "只能在准备阶段或主要阶段打出基础宝可梦。"

    if not card.is_basic_pokemon:
        return False, f"{card.name}不是基础宝可梦。"

    player = state.get_player(player_idx)

    if target == "active":
        if state.phase != TurnPhase.SETUP:
            return False, "主要阶段不能从手牌将基础宝可梦放到战斗区。"
        if player.active is not None:
            return False, "战斗区已有宝可梦。"
    elif target.startswith("bench_"):
        idx = int(target.split("_")[1])
        if not (0 <= idx < MAX_BENCH_SIZE):
            return False, f"无效的备战区位置: {idx}。"
        if not player.bench_has_space():
            return False, f"备战区已满（最多{MAX_BENCH_SIZE}只）。"
        if player.bench[idx] is not None:
            return False, f"备战区位置{idx}已被占用。"
    else:
        return False, f"无效的目标: {target}。"

    return True, ""


def can_evolve(state: GameState, player_idx: int, slot: str,
               evolution_card: Card) -> tuple[bool, str]:
    """Check if a Pokemon can be evolved."""
    if state.phase != TurnPhase.MAIN:
        return False, "只能在主要阶段进行进化。"

    if not evolution_card.is_pokemon:
        return False, "进化卡不是宝可梦卡。"

    player = state.get_player(player_idx)
    target = player.get_pokemon(slot)
    if target is None:
        return False, f"位置{slot}没有宝可梦。"

    if evolution_card.evolves_from.lower() != target.card.name.lower():
        return False, (f"{evolution_card.name}是从{evolution_card.evolves_from}"
                       f"进化而来，不是{target.card.name}。")

    allows_first_turn_evo = False
    if target.attached_tool and hasattr(target.attached_tool, 'trainer_effects'):
        for eff in target.attached_tool.trainer_effects:
            if eff.params.get("effect") == "can_evolve_on_first_turn":
                allows_first_turn_evo = True
                break

    if state.is_player_first_turn(player_idx) and not allows_first_turn_evo:
        return False, "First-turn evolution is not allowed."

    if target.placed_this_turn:
        allows_first_turn_evo = False
        if target.attached_tool and hasattr(target.attached_tool, 'trainer_effects'):
            for eff in target.attached_tool.trainer_effects:
                if eff.params.get("effect") == "can_evolve_on_first_turn":
                    allows_first_turn_evo = True
                    break
        if not allows_first_turn_evo:
            return False, "当回合上场的宝可梦不能进化。"

    if not target.can_evolve_this_turn:
        return False, "这只宝可梦本回合已经进化过了。"

    if player_idx != state.active_player_idx:
        return False, "不能在对手的回合进化。"

    return True, ""


def can_attach_energy(state: GameState, player_idx: int, energy_card: Card,
                      target_slot: str) -> tuple[bool, str]:
    """Check if energy can be attached."""
    if state.phase != TurnPhase.MAIN:
        return False, "只能在主要阶段附着能量。"

    if not energy_card.is_energy:
        return False, f"{energy_card.name}不是能量卡。"

    player = state.get_player(player_idx)

    if player.energy_attached_this_turn:
        return False, "本回合已经附着过能量了。"

    target = player.get_pokemon(target_slot)
    if target is None:
        return False, f"位置{target_slot}没有宝可梦。"

    return True, ""


def can_play_supporter(state: GameState, player_idx: int) -> tuple[bool, str]:
    """Check if a Supporter can be played."""
    if state.phase != TurnPhase.MAIN:
        return False, "只能在主要阶段使用支援者。"

    player = state.get_player(player_idx)

    if player.supporter_played_this_turn:
        return False, "本回合已经使用过支援者了。"

    if state.is_first_turn():
        return False, "先攻玩家的第一回合不能使用支援者。"

    return True, ""


def can_play_item(state: GameState, player_idx: int) -> tuple[bool, str]:
    """Check if an Item card can be played."""
    if state.phase != TurnPhase.MAIN:
        return False, "只能在主要阶段使用物品卡。"
    return True, ""


def can_play_stadium(state: GameState, player_idx: int,
                     stadium_card: Card | None = None) -> tuple[bool, str]:
    """Check if a Stadium card can be played."""
    if state.phase != TurnPhase.MAIN:
        return False, "只能在主要阶段使用竞技场卡。"
    player = state.get_player(player_idx)
    if player.stadium_played_this_turn:
        return False, "You can play only 1 Stadium card during your turn."
    if stadium_card is not None and state.stadium_card is not None:
        same_id = getattr(state.stadium_card, "api_id", None) == getattr(stadium_card, "api_id", None)
        same_name = state.stadium_card.name.lower() == stadium_card.name.lower()
        if same_id or same_name:
            return False, "不能打出与场上同名的竞技场卡。"
    return True, ""


def can_play_tool(state: GameState, player_idx: int, target_slot: str) -> tuple[bool, str]:
    """Check if a Tool can be attached."""
    if state.phase != TurnPhase.MAIN:
        return False, "只能在主要阶段附着道具。"

    player = state.get_player(player_idx)
    target = player.get_pokemon(target_slot)
    if target is None:
        return False, f"位置{target_slot}没有宝可梦。"

    if target.attached_tool is not None:
        return False, f"{target.card.name}已经附有道具了。"

    return True, ""


def can_retreat(state: GameState, player_idx: int,
                bench_idx: int) -> tuple[bool, str]:
    """Check if Active Pokemon can retreat."""
    if state.phase != TurnPhase.MAIN:
        return False, "只能在主要阶段进行撤退。"

    player = state.get_player(player_idx)

    if player.retreated_this_turn:
        return False, "本回合已经撤退过了。"

    if player.active is None:
        return False, "没有战斗宝可梦可以撤退。"

    if not player.active.can_retreat():
        conditions = [c.name for c in player.active.status_conditions]
        status_cn = {"POISONED": "中毒", "BURNED": "灼伤", "ASLEEP": "睡眠",
                     "PARALYZED": "麻痹", "CONFUSED": "混乱"}
        cn = [status_cn.get(c, c) for c in conditions]
        return False, f"在{', '.join(cn)}状态下不能撤退。"

    target = player.bench[bench_idx]
    if target is None:
        return False, f"备战区位置{bench_idx}没有宝可梦。"

    retreat_cost = _get_effective_retreat_cost(state, player)

    if len(player.active.energy_cards) < retreat_cost:
        return False, (f"需要{retreat_cost}个能量才能撤退，"
                       f"当前只有{len(player.active.energy_cards)}个。")

    return True, ""


def can_declare_attack(state: GameState, player_idx: int,
                       attack_idx: int) -> tuple[bool, str]:
    """Check if the Active Pokemon can declare an attack."""
    if state.phase != TurnPhase.ATTACK:
        if state.phase != TurnPhase.MAIN:
            return False, "只能在主要阶段或攻击阶段进行攻击。"

    player = state.get_player(player_idx)

    if player.active is None:
        return False, "没有战斗宝可梦。"

    if state.is_first_turn():
        return False, "先攻玩家的第一回合不能攻击。"

    if not (0 <= attack_idx < len(player.active.card.attacks)):
        return False, f"无效的攻击序号: {attack_idx}。"

    if not player.active.can_attack():
        if player.active.attack_locked:
            return False, "这只宝可梦因冻结效果无法使用招式。"
        conditions = [c.name for c in player.active.status_conditions]
        status_cn = {"POISONED": "中毒", "BURNED": "灼伤", "ASLEEP": "睡眠",
                     "PARALYZED": "麻痹", "CONFUSED": "混乱"}
        cn = [status_cn.get(c, c) for c in conditions]
        return False, f"在{', '.join(cn)}状态下不能攻击。"

    attack = player.active.card.attacks[attack_idx]
    if attack.name in player.active.attack_locked_names:
        return False, f"这只宝可梦在上个回合使用了「{attack.name}」，无法连续使用。"
    if not player.active.has_enough_energy(attack.cost):
        return False, f"能量不足以使用{attack.name}。需要: {attack.cost}。"

    return True, ""


def can_use_ability(state: GameState, player_idx: int,
                    slot: str, ability_name: str) -> tuple[bool, str]:
    """Check if an ability can be used."""
    if state.phase != TurnPhase.MAIN:
        return False, "只能在主要阶段使用特性。"

    player = state.get_player(player_idx)
    pokemon = player.get_pokemon(slot)
    if pokemon is None:
        return False, f"位置{slot}没有宝可梦。"

    ability = None
    for ab in pokemon.card.abilities:
        if ab.name.lower() == ability_name.lower():
            ability = ab
            break

    if ability is None:
        return False, f"{pokemon.card.name}没有名为'{ability_name}'的特性。"

    trigger = getattr(ability, "trigger", "")
    if trigger in ("passive", "on_enter_play", "on_damaged"):
        return False, f"特性'{ability_name}'不是可手动发动的特性。"
    if trigger not in ("", "on_turn"):
        return False, f"特性'{ability_name}'不能在主要阶段手动发动。"
    if ability.name in pokemon.used_abilities:
        return False, f"本回合已经使用过特性'{ability_name}'。"

    return True, ""


def check_win_condition(state: GameState) -> int | None:
    """Check if any player has won. Returns winning player_idx or None."""
    if len(state.p1.prizes) == 0:
        return 0
    if len(state.p2.prizes) == 0:
        return 1

    if not state.p1.has_any_pokemon_in_play():
        return 1
    if not state.p2.has_any_pokemon_in_play():
        return 0

    return None


def is_ace_spec(card: Card) -> bool:
    """Check if a card is an ACE SPEC."""
    return "ACE SPEC" in card.subtypes or "ACE SPEC" in card.rules


def is_radiant(card: Card) -> bool:
    """Check if a card is a Radiant Pokemon."""
    return "Radiant" in card.subtypes or "Radiant" in card.name


def validate_deck(deck: list[Card], deck_name: str = "") -> tuple[bool, str]:
    """Validate a deck against PTCG construction rules.
    Returns (is_valid, error_message)."""
    label = f"「{deck_name}」" if deck_name else "卡组"

    if len(deck) != DECK_SIZE:
        return False, f"{label}必须有{DECK_SIZE}张卡，当前有{len(deck)}张。"

    name_counts: dict[str, int] = {}
    for card in deck:
        if card.is_basic_energy:
            continue  # Basic Energy cards are exempt from the 4-copy rule
        name_key = card.name.lower()
        name_counts[name_key] = name_counts.get(name_key, 0) + 1
    for name, count in name_counts.items():
        if count > MAX_COPIES_PER_CARD:
            return False, (
                f"{label}中「{name}」有{count}张，"
                f"超过同名卡最多{MAX_COPIES_PER_CARD}张的限制。"
            )

    ace_spec_count = sum(1 for c in deck if is_ace_spec(c))
    if ace_spec_count > 1:
        return False, f"{label}中有{ace_spec_count}张ACE SPEC卡，最多只能有1张。"

    radiant_count = sum(1 for c in deck if is_radiant(c))
    if radiant_count > 1:
        return False, f"{label}中有{radiant_count}张光辉宝可梦，最多只能有1张。"

    return True, ""


def _get_effective_retreat_cost(state, player) -> int:
    """Calculate the effective retreat cost of the active Pokemon,
    accounting for abilities (薄雾飘浮) and stadiums (Beach Court)."""
    from engine.player_state import PlayerState
    active = player.active
    if active is None:
        return 0

    retreat_cost = active.card.retreat_cost

    # 拉帝亚斯 薄雾飘浮: 0 retreat if specific energy type attached
    for ab in (active.card.abilities or []):
        for eff in (ab.effects or []):
            if eff.effect_type == "conditional_zero_retreat":
                energy_type = eff.params.get("energy_type", "")
                if any(any(et.lower() == energy_type.lower() for et in c.provides_energy)
                       for c in active.energy_cards):
                    return 0

    # Beach Court stadium: basic Pokemon retreat cost -1
    if state.stadium_card:
        for eff in state.stadium_card.trainer_effects:
            if eff.effect_type == "stadium" and eff.params.get("effect") == "reduce_retreat_cost_basics":
                if active.card.is_basic_pokemon:
                    retreat_cost = max(0, retreat_cost - 1)
                break

    return retreat_cost
