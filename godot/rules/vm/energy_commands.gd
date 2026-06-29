class_name VMEnergyCommands
extends RefCounted

var catalog: CardCatalog
var trigger_commands: VMTriggerCommands


func _init(p_catalog: CardCatalog, p_trigger_commands: VMTriggerCommands) -> void:
	catalog = p_catalog
	trigger_commands = p_trigger_commands


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"attach_energy": Callable(self, "cmd_attach_energy"),
		"attach_energy_from_discard": Callable(self, "cmd_attach_energy_from_discard"),
		"discard_energy": Callable(self, "cmd_discard_energy"),
		"draw_and_attach_energy": Callable(self, "cmd_draw_and_attach_energy"),
		"relocate_energy": Callable(self, "cmd_relocate_energy"),
	}
	for op in registrations:
		interpreter.register_command_handler(str(op), registrations[op])


func cmd_attach_energy(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return energy_attach(state, stack, player_idx, source_slot, args)


func cmd_attach_energy_from_discard(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return attach_from_discard(state, stack, player_idx, source_slot, args)


func cmd_discard_energy(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return discard_energy(state, player_idx, source_slot, args)


func cmd_draw_and_attach_energy(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	VMZoneHelpers.draw_available(state, player_idx, 2, events)
	return attach_from_hand_to_bench(
		state,
		stack,
		player_idx,
		int(args.get("energy_count", 2)),
		str(args.get("energy_type", "Grass")),
		int(args.get("min_select", int(args.get("energy_count", 2)))),
	)


func cmd_relocate_energy(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return energy_relocate_request(state, stack, player_idx, args)


func energy_attach(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var zone := str(params.get("from_zone", "deck"))
	var source: Array[String] = player.deck if zone == "deck" else player.hand
	var filter := str(params.get("filter", "any")).to_lower()
	var matching: Array[String] = []
	for card_id in source:
		if energy_matches(card_id, filter):
			matching.append(card_id)
	var amount := int(params.get("amount", 1))
	var base_amount := amount
	var bonus_applied := false
	if state.active_player_idx != state.first_player_idx and state.is_player_first_turn(player_idx):
		amount = max(amount, int(params.get("going_second_bonus", amount)))
		bonus_applied = amount > base_amount
	if matching.is_empty():
		return VMResult.ok("没有符合条件的能量。")
	var optional_count := bool(params.has("min_select") or params.get("optional", false) or bonus_applied)
	var min_select := int(params.get("min_select", 0 if optional_count else -1))
	var target_spec := str(params.get("to", "self"))
	var target_slots: Array[String] = []
	if target_spec == "self":
		target_slots.append(source_slot)
	elif target_spec == "self_basic":
		for row in player.get_all_pokemon():
			var pokemon: PokemonState = row["pokemon"]
			if pokemon and catalog.is_basic_pokemon(pokemon.card_id):
				target_slots.append(str(row["slot"]))
	elif target_spec == "bench":
		for index in range(player.bench.size()):
			if player.bench[index]:
				target_slots.append("bench_%d" % index)
	else:
		for row in player.get_all_pokemon():
			if row["pokemon"]:
				target_slots.append(str(row["slot"]))
	return request_energy_target(
		state, stack, player_idx, zone, matching.slice(0, min(amount, matching.size())),
		target_slots, int(params.get("max_per_target", 99)),
		min_select,
		min(amount, matching.size()) if optional_count else -1,
		target_spec in ["self_basic", "any"])


func attach_from_discard(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var energy_type := str(params.get("energy_type", "any")).to_lower()
	var target_pokemon_type := str(params.get("target_pokemon_type", ""))
	var matching: Array[String] = []
	for card_id in player.discard:
		if not catalog.is_basic_energy(card_id):
			continue
		if energy_type in ["any", "basic", "basic_energy"]:
			matching.append(card_id)
		else:
			for provided in catalog.provides_energy(card_id):
				if str(provided).to_lower() == energy_type:
					matching.append(card_id)
					break
	if matching.is_empty():
		return VMResult.ok("弃牌区没有符合条件的能量。")
	var amount: int = min(int(params.get("amount", 1)), matching.size())
	var optional_count := bool(params.has("min_select") or params.get("optional", false))
	var min_select := int(params.get("min_select", 0 if optional_count else -1))
	var slots: Array[String] = []
	match str(params.get("target", "self")):
		"self":
			var source_pokemon := player.get_pokemon(source_slot)
			if source_pokemon and pokemon_matches_type(source_pokemon, target_pokemon_type):
				slots.append(source_slot)
		"bench":
			for index in range(player.bench.size()):
				if player.bench[index] and pokemon_matches_type(player.bench[index], target_pokemon_type):
					slots.append("bench_%d" % index)
		_:
			for row in player.get_all_pokemon():
				if row["pokemon"] and pokemon_matches_type(row["pokemon"], target_pokemon_type):
					slots.append(str(row["slot"]))
	return request_energy_target(
		state, stack, player_idx, "discard",
		matching.slice(0, amount),
		slots,
		99,
		min_select,
		amount if optional_count else -1,
		str(params.get("target", "self")) == "self_or_bench")


func pokemon_matches_type(pokemon: PokemonState, target_type: String) -> bool:
	if target_type.is_empty():
		return true
	var normalized := target_type.to_lower()
	for card_type in catalog.get_card(pokemon.card_id).get("energy_types", []):
		if str(card_type).to_lower() == normalized:
			return true
	return false


func request_energy_target(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_zone: String,
	card_ids: Array,
	target_slots: Array[String],
	max_per_target: int = 99,
	min_select: int = -1,
	max_select: int = -1,
	same_target: bool = false,
) -> Dictionary:
	if target_slots.is_empty():
		return VMResult.ok("没有附能目标。")
	var capped_card_ids := card_ids.duplicate()
	var target_capacity: int = max(0, target_slots.size() * max_per_target)
	if capped_card_ids.size() > target_capacity:
		capped_card_ids = capped_card_ids.slice(0, target_capacity)
	if capped_card_ids.is_empty():
		return VMResult.ok("没有可附着的能量。")
	var options: Array[Dictionary] = []
	for slot in target_slots:
		var pokemon := state.get_player(player_idx).get_pokemon(slot)
		if pokemon:
			options.append({
				"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"value": {"slot": slot, "card_id": pokemon.card_id},
			})
	var operation := (
		"energy_attach_distribution"
		if capped_card_ids.size() > 1
		else "energy_attach_target"
	)
	var request_min := capped_card_ids.size() if capped_card_ids.size() > 1 else 1
	var request_max := request_min
	if max_select >= 0:
		request_max = min(max_select, capped_card_ids.size())
		request_min = min(request_max, max(0, min_select))
	stack.push_continuation(operation, {
		"player_idx": player_idx,
		"source_zone": source_zone,
		"card_ids": capped_card_ids,
		"max_per_target": max_per_target,
		"same_target": same_target,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, operation),
		"distribute_energy" if capped_card_ids.size() > 1 else "select_energy_target",
		player_idx,
		"为每张能量选择附着目标。" if capped_card_ids.size() > 1 else "选择附着能量的宝可梦。",
		options,
		request_min,
		request_max,
		capped_card_ids.size() > 1,
		request_min <= 0,
		{"revision": state.revision, "max_per_target": max_per_target},
	)
	return VMResult.ok()


func attach_cards(
	state: GameState,
	player_idx: int,
	source_zone: String,
	card_ids: Array,
	target_slot: String,
	events: Array[Dictionary],
	rng: PortableRandomSource,
	active_stack: ResolutionStack = null,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var source: Array[String] = VMZoneHelpers.zone(player, source_zone)
	var target := player.get_pokemon(target_slot)
	if target == null:
		return VMResult.fail("附能目标不存在。")
	for card_value in card_ids:
		var card_id := str(card_value)
		var index := source.find(card_id)
		if index >= 0:
			source.remove_at(index)
			target.energy_card_ids.append(card_id)
			events.append({
				"event_type": "energy_attached",
				"actor": player_idx,
				"card_id": card_id,
				"source": {
					"player": player_idx,
					"zone": source_zone,
					"index": index,
				},
				"target": {"player": player_idx, "slot": target_slot},
				"data": {
					"player": player_idx,
					"slot": target_slot,
					"card_id": card_id,
					"source_zone": source_zone,
					"source_index": index,
				},
			})
			var trigger_commands_to_resolve: Array[Dictionary] = []
			trigger_commands.collect_on_attach_commands(
				card_id,
				player_idx,
				target_slot,
				source_zone,
				trigger_commands_to_resolve,
			)
			var trigger_result := trigger_commands.resolve_commands(
				state,
				player_idx,
				trigger_commands_to_resolve,
				events,
				active_stack,
			)
			if not bool(trigger_result.get("success", false)):
				return trigger_result
	if source_zone == "deck":
		rng.shuffle(player.deck)
		events.append({"event_type": "deck_shuffled", "data": {"player": player_idx}})
	return VMResult.ok()


func energy_relocate_request(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var energy_type := str(params.get("energy_type", params.get("filter", "any")))
	var source_options: Array[Dictionary] = []
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		var slot := str(row["slot"])
		if (
			pokemon
			and matching_energy_ids(pokemon.energy_card_ids, energy_type).size() > 0
			and (not bool(params.get("from_self", false)) or slot == "active")
		):
			source_options.append({
				"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"value": {"slot": slot, "card_id": pokemon.card_id},
			})
	if source_options.is_empty():
		return VMResult.ok("场上没有可移动的能量。")
	if source_options.size() == 1:
		return request_relocation_targets(
			state,
			stack,
			player_idx,
			str(source_options[0].get("value", {}).get("slot", "")),
			int(params.get("amount", 1)),
			energy_type,
			int(params.get("min_select", -1)),
			bool(params.get("same_target", false)),
		)
	stack.push_continuation("energy_relocate_source", {
		"player_idx": player_idx,
		"amount": int(params.get("amount", 1)),
		"energy_type": energy_type,
		"min_select": int(params.get("min_select", -1)),
		"same_target": bool(params.get("same_target", false)),
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "energy_relocate_source"),
		"select_energy_source",
		player_idx,
		"选择能量来源宝可梦。",
		source_options,
		1,
		1,
	)
	return VMResult.ok()


func request_relocation_targets(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	source_slot: String,
	amount: int,
	energy_type: String = "any",
	min_select: int = -1,
	same_target: bool = false,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var source := player.get_pokemon(source_slot)
	if source == null:
		return VMResult.ok("能量来源没有可移动的能量。")
	var matching_energy := matching_energy_ids(source.energy_card_ids, energy_type)
	if matching_energy.is_empty():
		return VMResult.ok("能量来源没有可移动的能量。")
	var options: Array[Dictionary] = []
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		var slot := str(row["slot"])
		if pokemon and slot != source_slot:
			options.append({
				"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"value": {"slot": slot, "card_id": pokemon.card_id},
			})
	if options.is_empty():
		return VMResult.ok("没有能量转移目标。")
	var move_count: int = min(amount, matching_energy.size())
	var request_min := move_count if move_count > 1 else 1
	var request_max := request_min
	if min_select >= 0:
		request_min = min(move_count, max(0, min_select))
		request_max = move_count
	var operation := (
		"energy_relocate_distribution"
		if move_count > 1
		else "energy_relocate_target"
	)
	stack.push_continuation(operation, {
		"player_idx": player_idx,
		"source_slot": source_slot,
		"amount": move_count,
		"energy_type": energy_type,
		"card_ids": matching_energy.slice(0, move_count),
		"same_target": same_target,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, operation),
		"distribute_energy" if move_count > 1 else "select_energy_target",
		player_idx,
		"为每张能量选择转移目标。" if move_count > 1 else "选择能量转移目标。",
		options,
		request_min,
		request_max,
		move_count > 1,
		request_min <= 0,
	)
	return VMResult.ok()


func attach_from_hand_to_bench(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	amount: int,
	energy_type: String,
	min_select: int = -1,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var matching: Array[String] = []
	for card_id in player.hand:
		if catalog.is_basic_energy(card_id) and energy_type in catalog.provides_energy(card_id):
			matching.append(card_id)
	var slots: Array[String] = []
	for index in range(player.bench.size()):
		if player.bench[index]:
			slots.append("bench_%d" % index)
	if matching.is_empty() or slots.is_empty():
		return VMResult.ok()
	return request_energy_target(
		state, stack, player_idx, "hand",
		matching.slice(0, min(amount, matching.size())), slots, 99,
		min_select,
		min(amount, matching.size()) if min_select >= 0 else -1,
		true)


func energy_matches(card_id: String, energy_type: String) -> bool:
	var normalized := energy_type.to_lower()
	if not catalog.is_energy(card_id):
		return false
	if normalized in ["any", "energy", ""]:
		return true
	if normalized in ["basic", "basic_energy"]:
		return catalog.is_basic_energy(card_id)
	for provided in catalog.provides_energy(card_id):
		if str(provided).to_lower() == normalized:
			return true
	return false


func discard_energy(
	state: GameState,
	player_idx: int,
	source_slot: String,
	params: Dictionary,
) -> Dictionary:
	var from_opponent := str(params.get("from", "self")) != "self"
	var owner_idx := 1 - player_idx if from_opponent else player_idx
	var owner := state.get_player(owner_idx)
	var source := owner.active if from_opponent else owner.get_pokemon(source_slot)
	if source == null:
		return VMResult.fail("没有能量来源。")
	if from_opponent and source.all_prevented_next_turn:
		source.all_prevented_next_turn = false
		return VMResult.ok("能量丢弃效果被免疫。")
	var filter_type := str(params.get("filter", params.get("energy_type", "any"))).to_lower()
	var kept_energy: Array[String] = []
	var discarded_energy := 0
	for energy_value in source.energy_card_ids:
		var energy_id := str(energy_value)
		var matches := energy_matches(energy_id, filter_type)
		if matches and discarded_energy < int(params.get("amount", 1)):
			owner.discard.append(energy_id)
			discarded_energy += 1
		else:
			kept_energy.append(energy_id)
	source.energy_card_ids = kept_energy
	return VMResult.ok("丢弃了%d张能量。" % discarded_energy)


func matching_energy_ids(card_ids: Array, energy_type: String) -> Array[String]:
	var result: Array[String] = []
	for card_value in card_ids:
		var card_id := str(card_value)
		if energy_matches(card_id, energy_type):
			result.append(card_id)
	return result
