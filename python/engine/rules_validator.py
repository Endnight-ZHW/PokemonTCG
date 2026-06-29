"""Rules validator - checks if actions are legal under PTCG rules."""
from typing import Optional, Tuple
from engine.enums import TurnPhase, PlayerAction, StatusType
from engine.game_state import GameState
from engine.player_state import PlayerState, PokemonInPlay
from engine.rules_constants import DECK_SIZE, MAX_BENCH_SIZE, MAX_COPIES_PER_CARD
from engine.effects.availability import effect_params
from engine.effects.runtime_effects import strict_trainer_runtime_effects as trainer_runtime_effects
from data.card_models import Card


def parse_bench_idx(value) -> Tuple[bool, int]:
    """Safely parse a bench index from a string or int.

    Returns (ok, idx) where ok is False if the input is malformed or out of
    range, and idx is the parsed integer (only meaningful when ok=True).
    """
    if isinstance(value, int):
        idx = value
    elif isinstance(value, str):
        try:
            idx = int(value)
        except (ValueError, TypeError):
            return False, -1
    else:
        return False, -1
    if not (0 <= idx < MAX_BENCH_SIZE):
        return False, -1
    return True, idx


def parse_slot(slot: str) -> Tuple[bool, str, int]:
    """Safely parse a slot string like 'active' or 'bench_2'.

    Returns (ok, slot_type, bench_idx) where:
      - slot_type is 'active' or 'bench'
      - bench_idx is the integer index (only valid when slot_type=='bench')
    """
    if not isinstance(slot, str):
        return False, "", -1
    if slot == "active":
        return True, "active", -1
    if slot.startswith("bench_"):
        parts = slot.split("_", 1)
        if len(parts) != 2:
            return False, "", -1
        try:
            idx = int(parts[1])
        except (ValueError, TypeError):
            return False, "", -1
        if not (0 <= idx < MAX_BENCH_SIZE):
            return False, "", -1
        return True, "bench", idx
    return False, "", -1


def check_bench_bounds(bench_idx: int) -> Tuple[bool, str]:
    """Check that a bench index is within valid range."""
    if not (0 <= bench_idx < MAX_BENCH_SIZE):
        return False, f"无效的备战区位置: {bench_idx}（有效范围 0-{MAX_BENCH_SIZE - 1}）。"
    return True, ""


def _attached_tool_allows_first_turn_evolution(target) -> bool:
    if not target.attached_tool:
        return False
    return any(
        effect_params(effect).get("effect") == "can_evolve_on_first_turn"
        for effect in trainer_runtime_effects(target.attached_tool)
    )


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
        try:
            idx = int(target.split("_")[1])
        except (ValueError, IndexError):
            return False, f"无效的备战区位置: {target}。"
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

    allows_first_turn_evo = _attached_tool_allows_first_turn_evolution(target)

    if state.is_player_first_turn(player_idx) and not allows_first_turn_evo:
        return False, "First-turn evolution is not allowed."

    if target.placed_this_turn:
        allows_first_turn_evo = _attached_tool_allows_first_turn_evolution(target)
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


def energy_card_units(card: Card, pokemon=None) -> int:
    """Return how many retreat-payment energy units one attached card provides."""
    provided = list(getattr(card, "provides_energy", []) or [])
    return max(1, len(provided)) if getattr(card, "is_energy", False) else 0


def attached_energy_units(pokemon) -> int:
    if pokemon is None:
        return 0
    return sum(energy_card_units(card, pokemon) for card in pokemon.energy_cards)


def can_retreat(state: GameState, player_idx: int,
                bench_idx: int, energy_indices: list[int] | tuple[int, ...] | None = None
                ) -> tuple[bool, str]:
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

    ok, msg = check_bench_bounds(bench_idx)
    if not ok:
        return False, msg

    target = player.bench[bench_idx]
    if target is None:
        return False, f"备战区位置{bench_idx}没有宝可梦。"

    retreat_cost = effective_retreat_cost(state, player)
    available_units = attached_energy_units(player.active)
    if available_units < retreat_cost:
        return False, (f"需要{retreat_cost}个能量才能撤退，"
                       f"当前只能提供{available_units}个。")

    if energy_indices is not None:
        indices = list(energy_indices)
        if len(indices) != len(set(indices)):
            return False, "撤退费用不能重复选择同一张能量卡。"
        if any(not isinstance(index, int) or not (0 <= index < len(player.active.energy_cards))
               for index in indices):
            return False, "撤退费用包含无效的能量卡。"
        paid_units = sum(
            energy_card_units(player.active.energy_cards[index], player.active)
            for index in indices
        )
        if paid_units < retreat_cost:
            return False, f"所选能量只能提供{paid_units}个，无法支付{retreat_cost}点撤退费用。"
        for index in indices:
            if paid_units - energy_card_units(player.active.energy_cards[index], player.active) >= retreat_cost:
                return False, "撤退费用不能包含多余的能量卡。"

    return True, ""


def can_declare_attack(state: GameState, player_idx: int,
                       attack_idx: int) -> tuple[bool, str]:
    """Check if the Active Pokemon can declare an attack."""
    if state.phase != TurnPhase.MAIN:
        return False, "只能在主要阶段进行攻击。"

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
    if attack.damage <= 0:
        from engine.effects.availability import attack_has_legal_target
        if not attack_has_legal_target(state, player_idx, attack, "active"):
            return False, "没有合法目标，不能使用该招式。"

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
    if trigger not in ("", "on_turn", "repeatable"):
        return False, f"特性'{ability_name}'不能在主要阶段手动发动。"
    if trigger != "repeatable" and ability.name in pokemon.used_abilities:
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


def effective_retreat_cost(state, player) -> int:
    """Calculate the effective retreat cost of the active Pokemon,
    accounting for abilities (薄雾飘浮) and stadiums (Beach Court)."""
    from engine.effects.retreat_modifier_hooks import effective_retreat_cost as _effective_retreat_cost

    return _effective_retreat_cost(state, player)


# Backward-compatible private name used by older UI/action code.
_get_effective_retreat_cost = effective_retreat_cost
