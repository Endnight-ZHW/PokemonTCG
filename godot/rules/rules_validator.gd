class_name RulesValidator
extends RefCounted

const MAX_BENCH_SIZE := 5

var catalog: CardCatalog


func _init(p_catalog: CardCatalog) -> void:
	catalog = p_catalog


func can_play_basic(state: GameState, player_idx: int, card_id: String, target: String) -> String:
	if state.phase not in ["SETUP", "MAIN"]:
		return "只能在准备阶段或主要阶段打出基础宝可梦。"
	if not catalog.is_basic_pokemon(card_id):
		return "%s不是基础宝可梦。" % catalog.card_name(card_id)
	if state.phase == "SETUP":
		if player_idx != state.setup_actor_idx:
			return "尚未轮到该玩家放置宝可梦。"
		if state.setup_stage == GameState.SETUP_BONUS_PLACEMENT:
			if target == "active":
				return "再战奖励抽到的基础宝可梦只能放入备战区。"
			if card_id not in state.setup_bonus_card_ids[player_idx]:
				return "只能放置再战奖励抽到的基础宝可梦。"
		elif state.setup_stage != GameState.SETUP_INITIAL_PLACEMENT:
			return "当前准备阶段不能放置宝可梦。"
	var player := state.get_player(player_idx)
	if target == "active":
		if state.phase != "SETUP":
			return "主要阶段不能从手牌将基础宝可梦放到战斗区。"
		if player.active != null:
			return "战斗区已有宝可梦。"
	elif target.begins_with("bench_"):
		var index := target.trim_prefix("bench_").to_int()
		if index < 0 or index >= MAX_BENCH_SIZE:
			return "无效的备战区位置。"
		if player.bench[index] != null:
			return "该备战区位置已被占用。"
	else:
		return "无效的目标。"
	return ""


func can_evolve(state: GameState, player_idx: int, slot: String, card_id: String) -> String:
	if state.phase != "MAIN":
		return "只能在主要阶段进行进化。"
	if not catalog.is_pokemon(card_id):
		return "进化卡不是宝可梦卡。"
	var target := state.get_player(player_idx).get_pokemon(slot)
	if target == null:
		return "目标位置没有宝可梦。"
	var card := catalog.get_card(card_id)
	if str(card.get("evolves_from", "")).to_lower() != catalog.card_name(target.card_id).to_lower():
		return "进化来源不匹配。"
	if state.is_player_first_turn(player_idx):
		return "第一回合不能进化。"
	if target.placed_this_turn:
		return "当回合上场的宝可梦不能进化。"
	if not target.can_evolve_this_turn:
		return "这只宝可梦本回合已经进化过了。"
	return ""


func can_attach_energy(state: GameState, player_idx: int, card_id: String, slot: String) -> String:
	if state.phase != "MAIN":
		return "只能在主要阶段附着能量。"
	if not catalog.is_energy(card_id):
		return "该卡不是能量卡。"
	var player := state.get_player(player_idx)
	if player.energy_attached_this_turn:
		return "本回合已经附着过能量了。"
	if player.get_pokemon(slot) == null:
		return "目标位置没有宝可梦。"
	return ""


func can_play_trainer(state: GameState, player_idx: int, card_id: String, target_slot: String = "") -> String:
	if state.phase != "MAIN":
		return "只能在主要阶段使用训练家卡。"
	var player := state.get_player(player_idx)
	if catalog.is_supporter(card_id):
		if player.supporter_played_this_turn:
			return "本回合已经使用过支援者。"
		if state.is_first_turn():
			return "先攻玩家的第一回合不能使用支援者。"
	elif catalog.is_stadium(card_id):
		if player.stadium_played_this_turn:
			return "本回合已经打出过竞技场。"
		if (
			not state.stadium_card_id.is_empty()
			and catalog.card_name(state.stadium_card_id) == catalog.card_name(card_id)
		):
			return "不能打出与场上同名的竞技场。"
	elif catalog.is_tool(card_id):
		var target := player.get_pokemon(target_slot)
		if target == null:
			return "道具目标不存在。"
		if not target.attached_tool_id.is_empty():
			return "目标已经附有道具。"
	return ""


func can_use_ability(state: GameState, player_idx: int, slot: String, ability_name: String) -> String:
	if state.phase != "MAIN":
		return "只能在主要阶段使用特性。"
	var player := state.get_player(player_idx)
	if slot.begins_with("discard_"):
		var discard_index := slot.trim_prefix("discard_").to_int()
		if discard_index < 0 or discard_index >= player.discard.size():
			return "弃牌区来源已不存在。"
		var card_id := str(player.discard[discard_index])
		if not player.hand.is_empty() or player.find_empty_bench_slot() < 0:
			return "紧急上浮条件不满足。"
		for ability_value in catalog.get_card(card_id).get("abilities", []):
			var ability: Dictionary = ability_value
			if str(ability.get("name", "")).to_lower() != ability_name.to_lower():
				continue
			for effect_value in VMRuntimeEffects.strict_ability_effects(ability):
				if str(Dictionary(effect_value).get("op", "")) == "discard_then_revive":
					return ""
		return "该特性不能从弃牌区发动。"
	var pokemon := player.get_pokemon(slot)
	if pokemon == null:
		return "目标位置没有宝可梦。"
	for ability in catalog.get_card(pokemon.card_id).get("abilities", []):
		if str(ability.get("name", "")).to_lower() != ability_name.to_lower():
			continue
		var trigger := str(ability.get("trigger", ""))
		if trigger in ["passive", "on_enter_play", "on_damaged"]:
			return "该特性不能手动发动。"
		if trigger != "repeatable" and ability_name in pokemon.used_abilities:
			return "本回合已经使用过该特性。"
		return ""
	return "没有找到该特性。"


func can_retreat(
	state: GameState,
	player_idx: int,
	bench_idx: int,
	energy_indices: Array,
) -> String:
	if state.phase != "MAIN":
		return "只能在主要阶段撤退。"
	var player := state.get_player(player_idx)
	if player.retreated_this_turn:
		return "本回合已经撤退过了。"
	if player.active == null:
		return "没有战斗宝可梦。"
	if "ASLEEP" in player.active.status_conditions or "PARALYZED" in player.active.status_conditions:
		return "当前状态不能撤退。"
	if bench_idx < 0 or bench_idx >= player.bench.size() or player.bench[bench_idx] == null:
		return "无效的备战目标。"
	var retreat_cost := effective_retreat_cost(state, player)
	var paid := 0
	var seen: Dictionary = {}
	for raw_index in energy_indices:
		var index := int(raw_index)
		if index < 0 or index >= player.active.energy_card_ids.size() or seen.has(index):
			return "撤退费用包含无效能量。"
		seen[index] = true
		paid += EnergyView.units_provided_by_card(
			player.active.energy_card_ids, index, catalog)
	if paid < retreat_cost:
		return "所选能量不足以支付撤退费用。"
	for raw_index in energy_indices:
		var index := int(raw_index)
		var units := EnergyView.units_provided_by_card(
			player.active.energy_card_ids, index, catalog)
		if paid - units >= retreat_cost:
			return "撤退费用不能包含多余能量。"
	return ""


func can_attack(state: GameState, player_idx: int, attack_idx: int) -> String:
	if state.phase != "MAIN":
		return "只能在主要阶段攻击。"
	if state.is_first_turn():
		return "先攻玩家第一回合不能攻击。"
	var active := state.get_player(player_idx).active
	if active == null:
		return "没有战斗宝可梦。"
	if "ASLEEP" in active.status_conditions or "PARALYZED" in active.status_conditions or active.attack_locked:
		return "当前状态不能攻击。"
	var attacks: Array = catalog.get_card(active.card_id).get("attacks", [])
	if attack_idx < 0 or attack_idx >= attacks.size():
		return "无效的攻击序号。"
	var attack: Dictionary = attacks[attack_idx]
	if active.attack_locked_names.has("__all__"):
		return "这只宝可梦无法使用招式。"
	if active.attack_locked_names.has(attack.get("name", "")):
		return "该招式不能连续使用。"
	if not active.has_enough_energy(attack.get("cost", []), catalog):
		return "能量不足。"
	return ""


func effective_retreat_cost(state: GameState, player: PlayerState) -> int:
	return VMRetreatModifierHooks.effective_retreat_cost(state, catalog, player)


func check_winner(state: GameState) -> int:
	var result := evaluate_result(state)
	return int(result.get("winner", -1)) if str(result.get("status", "")) == GameState.RESULT_WIN else -1


func evaluate_result(state: GameState) -> Dictionary:
	# Every independent condition is retained in the public result. If both
	# players satisfy the same number of conditions, the official result is a
	# draw; the engine must not manufacture a winner from turn order.
	var conditions: Array = [[], []]
	if state.players[0].prizes.is_empty():
		conditions[0].append("prizes_empty")
	if state.players[1].prizes.is_empty():
		conditions[1].append("prizes_empty")
	if not state.players[1].has_any_pokemon_in_play():
		conditions[0].append("opponent_has_no_pokemon")
	if not state.players[0].has_any_pokemon_in_play():
		conditions[1].append("opponent_has_no_pokemon")
	var scores: Array[int] = [conditions[0].size(), conditions[1].size()]
	if scores[0] == 0 and scores[1] == 0:
		return {
			"status": GameState.RESULT_ONGOING,
			"winner": -1,
			"conditions": conditions,
		}
	if scores[0] != scores[1]:
		return {
			"status": GameState.RESULT_WIN,
			"winner": 0 if scores[0] > scores[1] else 1,
			"conditions": conditions,
		}
	return {
		"status": GameState.RESULT_DRAW,
		"winner": -1,
		"conditions": conditions,
	}
