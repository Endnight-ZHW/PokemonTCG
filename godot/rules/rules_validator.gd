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
		if state.stadium_card_id == card_id:
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
	var pokemon := state.get_player(player_idx).get_pokemon(slot)
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
		paid += max(1, catalog.provides_energy(player.active.energy_card_ids[index]).size())
	if paid < retreat_cost:
		return "所选能量不足以支付撤退费用。"
	for raw_index in energy_indices:
		var index := int(raw_index)
		var units: int = max(1, catalog.provides_energy(player.active.energy_card_ids[index]).size())
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
	if active.attack_locked_names.has(attack.get("name", "")):
		return "该招式不能连续使用。"
	if not active.has_enough_energy(attack.get("cost", []), catalog):
		return "能量不足。"
	return ""


func effective_retreat_cost(state: GameState, player: PlayerState) -> int:
	if player.active == null:
		return 0
	var cost := int(catalog.get_card(player.active.card_id).get("retreat_cost", 0))
	for ability in catalog.get_card(player.active.card_id).get("abilities", []):
		for effect in ability.get("effects", []):
			if effect.get("effect_type", "") != "conditional_zero_retreat":
				continue
			var required := str(effect.get("params", {}).get("energy_type", "")).to_lower()
			for energy_id in player.active.energy_card_ids:
				for provided in catalog.provides_energy(energy_id):
					if provided.to_lower() == required:
						return 0
	if not state.stadium_card_id.is_empty() and catalog.is_basic_pokemon(player.active.card_id):
		for effect in catalog.get_card(state.stadium_card_id).get("trainer_effects", []):
			if effect.get("params", {}).get("effect", "") == "reduce_retreat_cost_basics":
				cost = max(0, cost - 1)
	return cost


func check_winner(state: GameState) -> int:
	if state.players[0].prizes.is_empty():
		return 0
	if state.players[1].prizes.is_empty():
		return 1
	if not state.players[0].has_any_pokemon_in_play():
		return 1
	if not state.players[1].has_any_pokemon_in_play():
		return 0
	return -1
