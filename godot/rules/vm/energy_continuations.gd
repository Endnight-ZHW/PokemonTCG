class_name VMEnergyContinuations
extends RefCounted

var energy_commands: VMEnergyCommands
var trigger_commands: VMTriggerCommands


func _init(p_energy_commands: VMEnergyCommands, p_trigger_commands: VMTriggerCommands) -> void:
	energy_commands = p_energy_commands
	trigger_commands = p_trigger_commands


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"energy_attach_target": Callable(self, "continue_energy_attach_target"),
		"energy_attach_distribution": Callable(self, "continue_energy_attach_distribution"),
		"energy_relocate_source": Callable(self, "continue_energy_relocate_source"),
		"energy_relocate_target": Callable(self, "continue_energy_relocate_target"),
		"energy_relocate_distribution": Callable(self, "continue_energy_relocate_distribution"),
		"detached_energy_distribution": Callable(self, "continue_detached_energy_distribution"),
	}
	for operation in registrations:
		interpreter.register_continuation(str(operation), registrations[operation])


func continue_energy_attach_target(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return VMResult.ok("未选择附能目标。")
	return energy_commands.attach_cards(
		state,
		int(data["player_idx"]),
		str(data["source_zone"]),
		Array(data["card_ids"]),
		str(selected[0].get("value", {}).get("slot", "")),
		events,
		rng,
		stack)


func continue_energy_attach_distribution(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(int(data["player_idx"]))
	var zone := str(data["source_zone"])
	var source: Array[String] = VMZoneHelpers.zone(player, zone)
	var cards: Array = data["card_ids"]
	var max_per_target := int(data.get("max_per_target", 99))
	var forced_slot := ""
	if bool(data.get("same_target", false)) and not selected.is_empty():
		forced_slot = str(selected[0].get("value", {}).get("slot", ""))
	var per_target: Dictionary = {}
	for index in range(min(cards.size(), selected.size())):
		var energy_id := str(cards[index])
		var source_index := source.find(energy_id)
		var target_slot := str(selected[index].get("value", {}).get("slot", ""))
		if not forced_slot.is_empty():
			target_slot = forced_slot
		if int(per_target.get(target_slot, 0)) >= max_per_target:
			continue
		var target := player.get_pokemon(target_slot)
		if source_index >= 0 and target:
			source.remove_at(source_index)
			target.energy_card_ids.append(energy_id)
			per_target[target_slot] = int(per_target.get(target_slot, 0)) + 1
			events.append({
				"event_type": "energy_attached",
				"actor": int(data["player_idx"]),
				"card_id": energy_id,
				"source": {
					"player": int(data["player_idx"]),
					"zone": zone,
					"index": source_index,
				},
				"target": {
					"player": int(data["player_idx"]),
					"slot": target_slot,
				},
				"data": {
					"player": int(data["player_idx"]),
					"slot": target_slot,
					"card_id": energy_id,
					"source_zone": zone,
					"source_index": source_index,
				},
			})
			var trigger_commands_to_resolve: Array[Dictionary] = []
			trigger_commands.collect_on_attach_commands(
				energy_id,
				int(data["player_idx"]),
				target_slot,
				zone,
				trigger_commands_to_resolve,
			)
			var trigger_result := trigger_commands.resolve_commands(
				state,
				int(data["player_idx"]),
				trigger_commands_to_resolve,
				events,
				stack,
			)
			if not bool(trigger_result.get("success", false)):
				return trigger_result
	if zone == "deck":
		rng.shuffle(player.deck)
		events.append({"event_type": "deck_shuffled", "data": {
			"player": int(data["player_idx"]),
		}})
	return VMResult.ok()


func continue_energy_relocate_source(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	_events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return VMResult.fail("没有选择能量来源。")
	return energy_commands.request_relocation_targets(
		state,
		stack,
		int(data["player_idx"]),
		str(selected[0].get("value", {}).get("slot", "")),
		int(data["amount"]),
		str(data.get("energy_type", "any")),
		int(data.get("min_select", -1)),
		bool(data.get("same_target", false)),
	)


func continue_energy_relocate_target(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	_events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return VMResult.ok("未选择能量目标。")
	var player := state.get_player(int(data["player_idx"]))
	var source := player.get_pokemon(str(data["source_slot"]))
	var target := player.get_pokemon(str(selected[0].get("value", {}).get("slot", "")))
	if source == null or target == null:
		return VMResult.fail("能量转移目标无效。")
	var moved_ids: Array = data.get("card_ids", [])
	var amount: int = min(int(data["amount"]), moved_ids.size())
	for index in range(amount):
		var energy_id := str(moved_ids[index])
		var source_index := source.energy_card_ids.find(energy_id)
		if source_index >= 0:
			source.energy_card_ids.remove_at(source_index)
			target.energy_card_ids.append(energy_id)
	return VMResult.ok()


func continue_energy_relocate_distribution(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	_events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(int(data["player_idx"]))
	var source := player.get_pokemon(str(data["source_slot"]))
	if source == null:
		return VMResult.fail("能量来源已失效。")
	var moved_ids: Array = data.get("card_ids", [])
	var move_count: int = min(
		int(data["amount"]),
		min(moved_ids.size(), selected.size()),
	)
	var forced_slot := ""
	if bool(data.get("same_target", false)) and not selected.is_empty():
		forced_slot = str(selected[0].get("value", {}).get("slot", ""))
	for index in range(move_count):
		var target_slot := str(selected[index].get("value", {}).get("slot", ""))
		if not forced_slot.is_empty():
			target_slot = forced_slot
		var target := player.get_pokemon(target_slot)
		if target:
			var energy_id := str(moved_ids[index])
			var source_index := source.energy_card_ids.find(energy_id)
			if source_index >= 0:
				source.energy_card_ids.remove_at(source_index)
				target.energy_card_ids.append(energy_id)
	return VMResult.ok()


func continue_detached_energy_distribution(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return resolve_detached_energy_distribution(state, data, selected, events)


func resolve_detached_energy_distribution(
	state: GameState,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data["player_idx"])
	var player := state.get_player(player_idx)
	var card_ids: Array = data.get("card_ids", [])
	var max_per_target := int(data.get("max_per_target", 99))
	var per_target: Dictionary = {}
	for index in range(min(card_ids.size(), selected.size())):
		var target_slot := str(selected[index].get("value", {}).get("slot", ""))
		if int(per_target.get(target_slot, 0)) >= max_per_target:
			continue
		var target := player.get_pokemon(target_slot)
		if target == null:
			continue
		var card_id := str(card_ids[index])
		target.energy_card_ids.append(card_id)
		per_target[target_slot] = int(per_target.get(target_slot, 0)) + 1
		events.append({
			"event_type": "energy_attached",
			"actor": player_idx,
			"card_id": card_id,
			"source": {"player": player_idx, "zone": "deck", "index": -1},
			"target": {"player": player_idx, "slot": target_slot},
			"data": {
				"player": player_idx,
				"slot": target_slot,
				"card_id": card_id,
				"source_zone": "deck",
				"source_index": -1,
			},
		})
	return VMResult.ok()
