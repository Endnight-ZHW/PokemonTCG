class_name VMBoardContinuations
extends RefCounted

var catalog: CardCatalog
var board_commands: VMBoardCommands
var coin_commands: VMCoinCommands
var combat_damage: VMCombatDamage


func _init(
	p_catalog: CardCatalog,
	p_board_commands: VMBoardCommands,
	p_coin_commands: VMCoinCommands,
	p_combat_damage: VMCombatDamage,
) -> void:
	catalog = p_catalog
	board_commands = p_board_commands
	coin_commands = p_coin_commands
	combat_damage = p_combat_damage


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"switch": Callable(self, "continue_switch"),
		"confirm_switch": Callable(self, "continue_confirm_switch"),
		"coin": Callable(self, "continue_coin"),
		"damage_target": Callable(self, "continue_damage_target"),
		"evolve_skip_stage": Callable(self, "continue_evolve_skip_stage"),
		"bench_damage_target": Callable(self, "continue_bench_damage_target"),
		"place_counters_self_ko": Callable(self, "continue_place_counters_self_ko"),
		"heal_target": Callable(self, "continue_heal_target"),
		"discard_attachment": Callable(self, "continue_discard_attachment"),
	}
	for operation in registrations:
		interpreter.register_continuation(str(operation), registrations[operation])


func continue_switch(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var target_player := state.get_player(int(data["target_player"]))
	if selected.is_empty():
		return VMResult.ok()
	var slot := str(selected[0].get("value", {}).get("slot", ""))
	target_player.switch_active_to_bench(slot.trim_prefix("bench_").to_int())
	events.append({"event_type": "switched", "data": {
		"player": int(data["target_player"]),
		"slot": slot,
	}})
	return VMResult.ok()


func continue_confirm_switch(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	_events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty() or selected[0].get("value", false) == false:
		return VMResult.ok()
	return board_commands.switch_request(
		state, stack, int(data["chooser"]), int(data["target_player"]), false, false)


func continue_coin(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	_selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return coin_commands.resolve_coin(state, stack, data, events)


func continue_damage_target(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return combat_damage.selected_target_damage(
		state, selected, int(data["target_player"]), int(data["amount"]), events)


func continue_evolve_skip_stage(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return resolve_evolve_skip_stage(state, data, selected, events)


func continue_bench_damage_target(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return combat_damage.selected_bench_damage(
		state, selected, int(data["target_player"]), int(data["amount"]), events)


func continue_place_counters_self_ko(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return VMResult.fail("没有选择目标。")
	var target_slot := str(selected[0].get("value", {}).get("slot", ""))
	var target := state.get_player(int(data["target_player"])).get_pokemon(target_slot)
	if target:
		var counter_count := int(data["counters"])
		target.damage_counters += counter_count
		events.append({
			"event_type": "damage_counters_placed",
			"actor": int(data.get("source_player", data["target_player"])),
			"target": {
				"player": int(data["target_player"]),
				"slot": target_slot,
			},
			"amount": counter_count * 10,
			"data": {
				"player": int(data["target_player"]),
				"slot": target_slot,
				"count": counter_count,
				"counter_count": counter_count,
			},
		})
	var source_player := int(data["source_player"])
	var source_slot := str(data["source_slot"])
	var source_state := state.get_player(source_player)
	if source_state.get_pokemon(source_slot):
		var discard_start := source_state.discard.size()
		state.discard_pokemon(source_player, source_slot)
		var discarded_cards: Array[String] = []
		for index in range(discard_start, source_state.discard.size()):
			discarded_cards.append(source_state.discard[index])
		if not discarded_cards.is_empty():
			events.append(VMZoneHelpers.discard_event(
				source_player,
				"",
				discarded_cards,
				discarded_cards.size(),
				range(discarded_cards.size()),
				source_slot,
				discard_start,
			))
	if (
		source_slot == "active"
		and source_state.active == null
		and source_state.bench_count() > 0
		and source_player not in state.pending_promotions
	):
		state.pending_promotions.append(source_player)
	elif not source_state.has_any_pokemon_in_play():
		state.winner = 1 - source_player
		state.phase = "GAME_OVER"
	return VMResult.ok()


func resolve_evolve_skip_stage(
	state: GameState,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return VMResult.fail("没有选择神奇糖果进化目标。", "choice_count")
	var player_idx := int(data.get("player_idx", state.active_player_idx))
	if state.is_player_first_turn(player_idx):
		return VMResult.fail("第一回合不能使用神奇糖果。", "illegal_evolution")
	var value: Dictionary = selected[0].get("value", {})
	var slot := str(value.get("slot", ""))
	var hand_index := int(value.get("hand_index", -1))
	var stage2_id := str(value.get("card_id", ""))
	var base_card_id := str(value.get("base_card_id", ""))
	var player := state.get_player(player_idx)
	if hand_index < 0 or hand_index >= player.hand.size():
		return VMResult.fail("进化卡已不在手牌中。", "stale_choice")
	if str(player.hand[hand_index]) != stage2_id:
		return VMResult.fail("进化卡已变化。", "stale_choice")
	var target := player.get_pokemon(slot)
	if target == null:
		return VMResult.fail("进化目标已不存在。", "stale_choice")
	if target.card_id != base_card_id:
		return VMResult.fail("进化目标已变化。", "stale_choice")
	if not catalog.is_basic_pokemon(target.card_id):
		return VMResult.fail("神奇糖果只能选择基础宝可梦。", "illegal_evolution")
	if target.placed_this_turn or not target.can_evolve_this_turn:
		return VMResult.fail("这只宝可梦本回合不能进化。", "illegal_evolution")
	if not catalog.is_stage2(stage2_id):
		return VMResult.fail("选择的卡不是2阶进化宝可梦。", "illegal_evolution")
	if not board_commands.stage2_can_evolve_from_basic(stage2_id, target.card_id):
		return VMResult.fail("进化来源不匹配。", "illegal_evolution")
	player.hand.remove_at(hand_index)
	target.evolution_stack_ids.append(target.card_id)
	target.card_id = stage2_id
	target.status_conditions.clear()
	target.can_evolve_this_turn = false
	events.append({
		"event_type": "pokemon_evolved",
		"actor": player_idx,
		"card_id": stage2_id,
		"source": {"player": player_idx, "zone": "hand", "index": hand_index},
		"target": {"player": player_idx, "slot": slot},
		"data": {
			"player": player_idx,
			"slot": slot,
			"card_id": stage2_id,
			"source_zone": "hand",
			"source_index": hand_index,
		},
	})
	state.log_action("%s使用神奇糖果将%s进化为%s。" % [
		player.name,
		catalog.card_name(base_card_id),
		catalog.card_name(stage2_id),
	])
	return VMResult.ok("神奇糖果进化完成。")


func continue_heal_target(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return VMResult.fail("没有选择回复目标。")
	return combat_damage.heal_pokemon(
		state, int(data["player_idx"]),
		str(selected[0].get("value", {}).get("slot", "")),
		int(data["amount"]), events)


func continue_discard_attachment(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return resolve_discard_attachment(state, data, selected, events)


func resolve_discard_attachment(
	state: GameState,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return VMResult.fail("没有选择要丢弃的能量。")
	var value: Dictionary = selected[0].get("value", {})
	var target_player := int(value.get("player", -1))
	var target_slot := str(value.get("slot", ""))
	var energy_index := int(value.get("index", -1))
	var card_id := str(value.get("card_id", ""))
	if target_player < 0:
		return VMResult.fail("能量引用无效。")
	var target := state.get_player(target_player).get_pokemon(target_slot)
	if (
		target == null
		or energy_index < 0
		or energy_index >= target.energy_card_ids.size()
		or str(target.energy_card_ids[energy_index]) != card_id
	):
		return VMResult.fail("选择的能量已不存在。")
	state.get_player(target_player).discard.append(target.energy_card_ids.pop_at(energy_index))
	events.append({
		"event_type": "cards_discarded",
		"actor": int(data.get("player_idx", state.active_player_idx)),
		"card_id": card_id,
		"source": {
			"player": target_player,
			"slot": target_slot,
			"attachment_type": "energy",
			"index": energy_index,
		},
		"target": {"player": target_player, "zone": "discard"},
		"amount": 1,
		"data": {
			"player": target_player,
			"slot": target_slot,
			"source_slot": target_slot,
			"source_index": energy_index,
			"source_indices": [energy_index],
			"count": 1,
			"card_id": card_id,
			"card_ids": [card_id],
		},
	})
	return VMResult.ok()
