class_name VMLookTopContinuations
extends RefCounted

var catalog: CardCatalog


func _init(p_catalog: CardCatalog) -> void:
	catalog = p_catalog


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"look_top": Callable(self, "continue_look_top"),
		"look_top_attach_energy": Callable(self, "continue_look_top_attach_energy"),
		"look_top_attach_target": Callable(self, "continue_look_top_attach_target"),
		"trekking_shoes": Callable(self, "continue_trekking_shoes"),
	}
	for operation in registrations:
		interpreter.register_continuation(str(operation), registrations[operation])


func continue_look_top(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return resolve_look_top(state, stack, rng, data, selected, events)


func continue_look_top_attach_energy(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return resolve_look_top_attach_energy(state, stack, rng, data, selected, events)


func continue_look_top_attach_target(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return resolve_look_top_attach_target(state, data, selected, events)


func continue_trekking_shoes(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(int(data["player_idx"]))
	var keep := not selected.is_empty() and bool(selected[0].get("value", false))
	if player.deck.is_empty():
		return VMResult.ok()
	var expected_top := str(data.get("card_id", ""))
	if not expected_top.is_empty() and str(player.deck[-1]) != expected_top:
		return VMResult.fail("牌库顶卡已变化，无法继续结算。", "stale_choice")
	var top: String = player.deck.pop_back()
	if keep:
		player.hand.append(top)
	else:
		player.discard.append(top)
		VMZoneHelpers.draw_available(state, int(data["player_idx"]), 1, events)
	return VMResult.ok()


func resolve_look_top(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(int(data["player_idx"]))
	var source_indices := VMZoneHelpers.selected_source_indices(selected)
	var selected_cards: Array[String] = VMZoneHelpers.remove_selected_from_zone(
		player, "deck", selected, false)
	var top_cards: Array = data["top_cards"]
	var remaining: Array[String] = []
	for card_value in top_cards:
		var card_id := str(card_value)
		var index := player.deck.find(card_id)
		if index >= 0:
			player.deck.remove_at(index)
			remaining.append(card_id)
	var destination := str(data["destination"])
	var hand_start := player.hand.size()
	if destination == "bench_energy":
		if bool(data["shuffle_rest"]):
			player.deck.append_array(remaining)
			rng.shuffle(player.deck)
			events.append({"event_type": "deck_shuffled", "data": {
				"player": int(data["player_idx"]),
			}})
		elif bool(data["rest_bottom"]):
			for card_id in remaining:
				player.deck.push_front(card_id)
		else:
			player.deck.append_array(remaining)
		if selected_cards.is_empty():
			events.append(VMZoneHelpers.cards_selected_event(
				int(data["player_idx"]),
				"deck",
				"choice",
				[],
				0,
			))
			return VMResult.ok("未选择能量。")
		var options: Array[Dictionary] = []
		for index in range(player.bench.size()):
			var pokemon: PokemonState = player.bench[index]
			if pokemon == null:
				continue
			var card_data := catalog.get_card(pokemon.card_id)
			if not ("Lightning" in card_data.get("energy_types", [])):
				continue
			var slot := "bench_%d" % index
			options.append({
				"option_id": "pokemon:%d:%s:%s" % [int(data["player_idx"]), slot, pokemon.card_id],
				"label": catalog.card_name(pokemon.card_id),
				"ref": EntityRef.new("pokemon", int(data["player_idx"]), "", slot, -1, "", pokemon.card_id).to_dict(),
				"value": {"slot": slot, "card_id": pokemon.card_id},
			})
		if options.is_empty():
			player.deck.append_array(selected_cards)
			rng.shuffle(player.deck)
			events.append({"event_type": "deck_shuffled", "data": {
				"player": int(data["player_idx"]),
			}})
			return VMResult.ok("没有备战雷宝可梦。")
		if options.size() == 1:
			return attach_selected_energy_to_slot(
				state,
				int(data["player_idx"]),
				selected_cards,
				str(options[0].get("value", {}).get("slot", "")),
				events,
				source_indices,
			)
		stack.push_continuation("detached_energy_distribution", {
			"player_idx": int(data["player_idx"]),
			"card_ids": selected_cards,
			"source_indices": source_indices,
			"max_per_target": 99,
		})
		stack.pending_request = ChoiceRequest.new(
			stack.next_request_id(state, int(data["player_idx"]), "detached_energy_distribution"),
			"distribute_energy",
			int(data["player_idx"]),
			"为电气发生器选择附着目标。",
			options,
			selected_cards.size(),
			selected_cards.size(),
			true,
			false,
			{"revision": state.revision, "max_per_target": 99},
		)
		events.append(VMZoneHelpers.cards_selected_event(
			int(data["player_idx"]),
			"deck",
			"choice",
			selected_cards,
			-1,
			source_indices,
		))
		return VMResult.ok()
	else:
		player.hand.append_array(selected_cards)
	if bool(data["shuffle_rest"]):
		player.deck.append_array(remaining)
		rng.shuffle(player.deck)
		events.append({"event_type": "deck_shuffled", "data": {
			"player": int(data["player_idx"]),
		}})
	elif bool(data["rest_bottom"]):
		for card_id in remaining:
			player.deck.push_front(card_id)
	else:
		player.deck.append_array(remaining)
	events.append(VMZoneHelpers.cards_selected_event(
		int(data["player_idx"]),
		"deck",
		"hand",
		selected_cards,
		-1,
		source_indices,
		range(hand_start, hand_start + selected_cards.size()),
	))
	return VMResult.ok()


func resolve_look_top_attach_energy(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data["player_idx"])
	var player := state.get_player(player_idx)
	var selected_indices: Dictionary = {}
	for option in selected:
		selected_indices[int(option.get("value", {}).get("index", -1))] = true
	var indices: Array = data.get("top_indices", [])
	indices.sort()
	indices.reverse()
	var selected_cards: Array[String] = []
	var selected_deck_indices: Array[int] = []
	var remaining: Array[String] = []
	for raw_index in indices:
		var deck_index := int(raw_index)
		if deck_index < 0 or deck_index >= player.deck.size():
			continue
		var card_id: String = player.deck.pop_at(deck_index)
		if selected_indices.has(deck_index):
			selected_cards.append(card_id)
			selected_deck_indices.append(deck_index)
		else:
			remaining.append(card_id)
	player.deck.append_array(remaining)
	rng.shuffle(player.deck)
	events.append({"event_type": "deck_shuffled", "data": {"player": player_idx}})
	if selected_cards.is_empty():
		return VMResult.ok("未选择能量。")
	var options: Array[Dictionary] = []
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null:
			continue
		var slot := str(row["slot"])
		options.append({
			"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
			"label": catalog.card_name(pokemon.card_id),
			"ref": EntityRef.new("pokemon", player_idx, "", slot, -1, "", pokemon.card_id).to_dict(),
			"value": {"slot": slot, "card_id": pokemon.card_id},
		})
	if options.is_empty():
		return VMResult.fail("没有附能目标。")
	if options.size() == 1:
		return attach_selected_energy_to_slot(
			state,
			player_idx,
			selected_cards,
			str(options[0].get("value", {}).get("slot", "")),
			events,
			selected_deck_indices,
		)
	stack.push_continuation("look_top_attach_target", {
		"player_idx": player_idx,
		"card_ids": selected_cards,
		"source_indices": selected_deck_indices,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "look_top_attach_target"),
		"select_energy_target",
		player_idx,
		"选择1只宝可梦附着能量。",
		options,
		1,
		1,
		false,
		false,
		{"revision": state.revision},
	)
	return VMResult.ok()


func resolve_look_top_attach_target(
	state: GameState,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return VMResult.fail("没有选择附能目标。")
	return attach_selected_energy_to_slot(
		state,
		int(data["player_idx"]),
		Array(data["card_ids"]),
		str(selected[0].get("value", {}).get("slot", "")),
		events,
		Array(data.get("source_indices", [])),
	)


func attach_selected_energy_to_slot(
	state: GameState,
	player_idx: int,
	card_ids: Array,
	target_slot: String,
	events: Array[Dictionary],
	source_indices: Array = [],
) -> Dictionary:
	var target := state.get_player(player_idx).get_pokemon(target_slot)
	if target == null:
		return VMResult.fail("附能目标不存在。")
	for index in range(card_ids.size()):
		var card_value: Variant = card_ids[index]
		var card_id := str(card_value)
		var source_index := (
			int(source_indices[index]) if index < source_indices.size() else -1
		)
		var target_index := target.energy_card_ids.size()
		target.energy_card_ids.append(card_id)
		events.append({
			"event_type": "energy_attached",
			"actor": player_idx,
			"card_id": card_id,
			"source": {
				"player": player_idx,
				"zone": "deck",
				"index": source_index,
			},
			"target": {
				"player": player_idx,
				"slot": target_slot,
				"index": target_index,
			},
			"data": {
				"player": player_idx,
				"slot": target_slot,
				"card_id": card_id,
				"source_zone": "deck",
				"source_index": source_index,
				"target_index": target_index,
			},
		})
	return VMResult.ok("附着了%d张能量。" % card_ids.size())
