class_name VMLookTopContinuations
extends RefCounted

var catalog: CardCatalog


func _init(p_catalog: CardCatalog) -> void:
	catalog = p_catalog


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"look_top": Callable(self, "continue_look_top"),
		"look_top_bench_energy_distribution": Callable(
			self, "continue_look_top_bench_energy_distribution"),
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


func continue_look_top_bench_energy_distribution(
	state: GameState,
	_stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return resolve_look_top_bench_energy_distribution(
		state, rng, data, selected, events)


func continue_look_top_attach_target(
	state: GameState,
	_stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return resolve_look_top_attach_target(state, rng, data, selected, events)


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
	var player_idx := int(data["player_idx"])
	var source_index := player.deck.size() - 1
	var top: String = player.deck.pop_back()
	if keep:
		var target_index := player.hand.size()
		player.hand.append(top)
		events.append(VMZoneHelpers.card_moved_event(
			player_idx,
			[top],
			{"player": player_idx, "zone": "deck", "index": source_index},
			{"player": player_idx, "zone": "hand", "index": target_index},
			"owner",
		))
	else:
		var discard_index := player.discard.size()
		player.discard.append(top)
		events.append(VMZoneHelpers.discard_event(
			player_idx,
			"deck",
			[top],
			1,
			[source_index],
			"",
			discard_index,
		))
		VMZoneHelpers.draw_available(state, player_idx, 1, events)
	return VMResult.ok()


func resolve_look_top(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data["player_idx"])
	var player := state.get_player(player_idx)
	var top_cards := string_array(data.get("top_cards", []))
	var position_result := selected_top_positions(player, top_cards, selected)
	if not bool(position_result.get("success", false)):
		return VMResult.fail(
			str(position_result.get("message", "牌库顶卡已变化，无法继续结算。")),
			"stale_choice",
		)
	var positions: Array[int] = position_result.get("positions", [])
	var partition := partition_top_cards(player.deck.size(), top_cards, positions)
	var selected_cards: Array[String] = partition["selected_cards"]
	var source_indices: Array[int] = partition["source_indices"]
	var remaining: Array[String] = partition["remaining"]
	var destination := str(data["destination"])
	var rest_bottom := bool(data.get("rest_bottom", false))
	var shuffle_rest := bool(data.get("shuffle_rest", false))

	if destination == "bench_energy":
		var options := lightning_bench_options(state, player_idx)
		if selected_cards.is_empty() or options.is_empty():
			var pop_result := pop_expected_top_cards(player, top_cards)
			if not bool(pop_result.get("success", false)):
				return VMResult.fail(str(pop_result.get("message", "")), "stale_choice")
			events.append(VMZoneHelpers.cards_selected_event(
				player_idx, "deck", "choice", [], 0))
			restore_top_cards(
				state, rng, player_idx, top_cards, rest_bottom, shuffle_rest, events)
			return VMResult.ok(
				"未选择能量。" if selected_cards.is_empty() else "没有备战雷宝可梦。")

		events.append(VMZoneHelpers.cards_selected_event(
			player_idx,
			"deck",
			"choice",
			selected_cards,
			-1,
			source_indices,
		))
		if options.size() > 1:
			stack.push_continuation("look_top_bench_energy_distribution", {
				"player_idx": player_idx,
				"top_card_ids": top_cards,
				"selected_top_positions": positions,
				"rest_bottom": rest_bottom,
				"shuffle_rest": shuffle_rest,
				"max_per_target": 99,
			})
			stack.pending_request = ChoiceRequest.new(
				stack.next_request_id(
					state, player_idx, "look_top_bench_energy_distribution"),
				"distribute_energy",
				player_idx,
				"为电气发生器选择附着目标。",
				options,
				selected_cards.size(),
				selected_cards.size(),
				true,
				false,
				{
					"revision": state.revision,
					"purpose": "detached_energy_distribution",
					"card_ids": selected_cards.duplicate(),
					"source_player": player_idx,
					"source_zone": "deck",
					"same_source": true,
					"same_target": false,
					"max_per_target": 99,
				},
			)
			return VMResult.ok()

		var pop_result := pop_expected_top_cards(player, top_cards)
		if not bool(pop_result.get("success", false)):
			return VMResult.fail(str(pop_result.get("message", "")), "stale_choice")
		var attach_result := attach_selected_energy_to_slot(
			state,
			player_idx,
			selected_cards,
			str(options[0].get("value", {}).get("slot", "")),
			events,
			source_indices,
		)
		if not bool(attach_result.get("success", false)):
			return attach_result
		restore_top_cards(
			state, rng, player_idx, remaining, rest_bottom, shuffle_rest, events)
		return attach_result

	var pop_result := pop_expected_top_cards(player, top_cards)
	if not bool(pop_result.get("success", false)):
		return VMResult.fail(str(pop_result.get("message", "")), "stale_choice")
	var hand_start := player.hand.size()
	player.hand.append_array(selected_cards)
	events.append(VMZoneHelpers.cards_selected_event(
		player_idx,
		"deck",
		"hand",
		selected_cards,
		-1,
		source_indices,
		range(hand_start, hand_start + selected_cards.size()),
	))
	restore_top_cards(
		state, rng, player_idx, remaining, rest_bottom, shuffle_rest, events)
	return VMResult.ok()


func resolve_look_top_bench_energy_distribution(
	state: GameState,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data["player_idx"])
	var player := state.get_player(player_idx)
	var top_cards := string_array(data.get("top_card_ids", []))
	var positions := int_array(data.get("selected_top_positions", []))
	var partition := partition_top_cards(player.deck.size(), top_cards, positions)
	var selected_cards: Array[String] = partition["selected_cards"]
	var source_indices: Array[int] = partition["source_indices"]
	if selected.size() != selected_cards.size():
		return VMResult.fail("附能目标数量无效。")
	var target_slots: Array[String] = []
	var per_target: Dictionary = {}
	var max_per_target := int(data.get("max_per_target", 99))
	for option in selected:
		var target_slot := str(option.get("value", {}).get("slot", ""))
		var target := player.get_pokemon(target_slot)
		if (
			target == null
			or not target_slot.begins_with("bench_")
			or not ("Lightning" in catalog.get_card(target.card_id).get("energy_types", []))
			or int(per_target.get(target_slot, 0)) >= max_per_target
		):
			return VMResult.fail("附能目标已失效。", "stale_choice")
		per_target[target_slot] = int(per_target.get(target_slot, 0)) + 1
		target_slots.append(target_slot)
	var pop_result := pop_expected_top_cards(player, top_cards)
	if not bool(pop_result.get("success", false)):
		return VMResult.fail(str(pop_result.get("message", "")), "stale_choice")
	for index in range(selected_cards.size()):
		var attach_result := attach_selected_energy_to_slot(
			state,
			player_idx,
			[selected_cards[index]],
			target_slots[index],
			events,
			[source_indices[index]],
		)
		if not bool(attach_result.get("success", false)):
			return attach_result
	restore_top_cards(
		state,
		rng,
		player_idx,
		partition["remaining"],
		bool(data.get("rest_bottom", false)),
		bool(data.get("shuffle_rest", false)),
		events,
	)
	return VMResult.ok("附着了%d张能量。" % selected_cards.size())


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
	var top_cards := string_array(data.get("top_card_ids", []))
	if top_cards.is_empty():
		var legacy_indices := int_array(data.get("top_indices", []))
		legacy_indices.sort()
		legacy_indices.reverse()
		for deck_index in legacy_indices:
			if deck_index >= 0 and deck_index < player.deck.size():
				top_cards.append(str(player.deck[deck_index]))
	var position_result := selected_top_positions(player, top_cards, selected)
	if not bool(position_result.get("success", false)):
		return VMResult.fail(
			str(position_result.get("message", "牌库顶卡已变化，无法继续结算。")),
			"stale_choice",
		)
	var positions: Array[int] = position_result.get("positions", [])
	var partition := partition_top_cards(player.deck.size(), top_cards, positions)
	var selected_cards: Array[String] = partition["selected_cards"]
	var selected_deck_indices: Array[int] = partition["source_indices"]
	if selected_cards.is_empty():
		var pop_result := pop_expected_top_cards(player, top_cards)
		if not bool(pop_result.get("success", false)):
			return VMResult.fail(str(pop_result.get("message", "")), "stale_choice")
		events.append(VMZoneHelpers.cards_selected_event(
			player_idx, "deck", "field", [], 0))
		restore_top_cards(
			state, rng, player_idx, partition["remaining"], false, true, events)
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
			"ref": EntityRef.new(
				"pokemon", player_idx, "field", slot, -1, "", pokemon.card_id).to_dict(),
			"value": {"slot": slot, "card_id": pokemon.card_id},
		})
	if options.is_empty():
		var pop_result := pop_expected_top_cards(player, top_cards)
		if not bool(pop_result.get("success", false)):
			return VMResult.fail(str(pop_result.get("message", "")), "stale_choice")
		events.append(VMZoneHelpers.cards_selected_event(
			player_idx, "deck", "field", [], 0))
		restore_top_cards(state, rng, player_idx, top_cards, false, true, events)
		return VMResult.ok("没有附能目标。")
	events.append(VMZoneHelpers.cards_selected_event(
		player_idx,
		"deck",
		"field",
		selected_cards,
		-1,
		selected_deck_indices,
	))
	if options.size() == 1:
		var pop_result := pop_expected_top_cards(player, top_cards)
		if not bool(pop_result.get("success", false)):
			return VMResult.fail(str(pop_result.get("message", "")), "stale_choice")
		var attach_result := attach_selected_energy_to_slot(
			state,
			player_idx,
			selected_cards,
			str(options[0].get("value", {}).get("slot", "")),
			events,
			selected_deck_indices,
		)
		if not bool(attach_result.get("success", false)):
			return attach_result
		restore_top_cards(
			state, rng, player_idx, partition["remaining"], false, true, events)
		return attach_result
	stack.push_continuation("look_top_attach_target", {
		"player_idx": player_idx,
		"top_card_ids": top_cards,
		"selected_top_positions": positions,
		"selection_event_emitted": true,
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
		{
			"revision": state.revision,
			"purpose": "look_top_attach_target",
			"card_ids": selected_cards.duplicate(),
			"source_player": player_idx,
			"source_zone": "deck",
			"same_source": true,
			"same_target": true,
			"max_per_target": selected_cards.size(),
		},
	)
	return VMResult.ok()


func resolve_look_top_attach_target(
	state: GameState,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	if selected.is_empty():
		return VMResult.fail("没有选择附能目标。")
	var player_idx := int(data["player_idx"])
	# Backward compatibility for a pending choice created before deck shuffling
	# was deferred to this continuation.
	if not data.has("top_card_ids"):
		return attach_selected_energy_to_slot(
			state,
			player_idx,
			Array(data.get("card_ids", [])),
			str(selected[0].get("value", {}).get("slot", "")),
			events,
			Array(data.get("source_indices", [])),
		)
	var player := state.get_player(player_idx)
	var target_slot := str(selected[0].get("value", {}).get("slot", ""))
	if player.get_pokemon(target_slot) == null:
		return VMResult.fail("附能目标已失效。", "stale_choice")
	var top_cards := string_array(data.get("top_card_ids", []))
	var positions := int_array(data.get("selected_top_positions", []))
	var partition := partition_top_cards(player.deck.size(), top_cards, positions)
	var pop_result := pop_expected_top_cards(player, top_cards)
	if not bool(pop_result.get("success", false)):
		return VMResult.fail(str(pop_result.get("message", "")), "stale_choice")
	var selected_cards: Array[String] = partition["selected_cards"]
	var source_indices: Array[int] = partition["source_indices"]
	if not bool(data.get("selection_event_emitted", false)):
		events.append(VMZoneHelpers.cards_selected_event(
			player_idx,
			"deck",
			"field",
			selected_cards,
			-1,
			source_indices,
		))
	var attach_result := attach_selected_energy_to_slot(
		state,
		player_idx,
		selected_cards,
		target_slot,
		events,
		source_indices,
	)
	if not bool(attach_result.get("success", false)):
		return attach_result
	restore_top_cards(
		state, rng, player_idx, partition["remaining"], false, true, events)
	return attach_result


func lightning_bench_options(state: GameState, player_idx: int) -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	var player := state.get_player(player_idx)
	for index in range(player.bench.size()):
		var pokemon: PokemonState = player.bench[index]
		if pokemon == null:
			continue
		if not ("Lightning" in catalog.get_card(pokemon.card_id).get("energy_types", [])):
			continue
		var slot := "bench_%d" % index
		options.append({
			"option_id": "pokemon:%d:%s:%s" % [player_idx, slot, pokemon.card_id],
			"label": catalog.card_name(pokemon.card_id),
			"ref": EntityRef.new(
				"pokemon", player_idx, "field", slot, -1, "", pokemon.card_id).to_dict(),
			"value": {"slot": slot, "card_id": pokemon.card_id},
		})
	return options


static func selected_top_positions(
	player: PlayerState,
	top_cards: Array[String],
	selected: Array[Dictionary],
) -> Dictionary:
	var peek_result := peek_expected_top_cards(player, top_cards)
	if not bool(peek_result.get("success", false)):
		return peek_result
	var positions: Array[int] = []
	var seen: Dictionary = {}
	for option in selected:
		var source_index := int(option.get("value", {}).get("index", -1))
		var card_id := str(option.get("value", {}).get("card_id", ""))
		var position := player.deck.size() - 1 - source_index
		if (
			position < 0
			or position >= top_cards.size()
			or seen.has(position)
			or top_cards[position] != card_id
		):
			return {
				"success": false,
				"message": "牌库顶卡已变化，无法继续结算。",
			}
		seen[position] = true
		positions.append(position)
	positions.sort()
	return {"success": true, "positions": positions}


static func partition_top_cards(
	deck_size: int,
	top_cards: Array[String],
	selected_positions: Array[int],
) -> Dictionary:
	var selected_set: Dictionary = {}
	for position in selected_positions:
		selected_set[position] = true
	var selected_cards: Array[String] = []
	var source_indices: Array[int] = []
	var remaining: Array[String] = []
	for position in range(top_cards.size()):
		var card_id := top_cards[position]
		if selected_set.has(position):
			selected_cards.append(card_id)
			source_indices.append(deck_size - 1 - position)
		else:
			remaining.append(card_id)
	return {
		"selected_cards": selected_cards,
		"source_indices": source_indices,
		"remaining": remaining,
	}


static func peek_expected_top_cards(
	player: PlayerState,
	top_cards: Array[String],
) -> Dictionary:
	if player.deck.size() < top_cards.size():
		return {
			"success": false,
			"message": "牌库顶卡已变化，无法继续结算。",
		}
	for position in range(top_cards.size()):
		if str(player.deck[player.deck.size() - 1 - position]) != top_cards[position]:
			return {
				"success": false,
				"message": "牌库顶卡已变化，无法继续结算。",
			}
	return {"success": true}


static func pop_expected_top_cards(
	player: PlayerState,
	top_cards: Array[String],
) -> Dictionary:
	var peek_result := peek_expected_top_cards(player, top_cards)
	if not bool(peek_result.get("success", false)):
		return peek_result
	for _card_id in top_cards:
		player.deck.pop_back()
	return {"success": true}


static func restore_top_cards(
	state: GameState,
	rng: PortableRandomSource,
	player_idx: int,
	remaining: Array[String],
	rest_bottom: bool,
	shuffle_rest: bool,
	events: Array[Dictionary],
) -> void:
	var player := state.get_player(player_idx)
	if shuffle_rest:
		player.deck.append_array(remaining)
		VMZoneHelpers.shuffle_deck(state, rng, player_idx, events)
		return
	if rest_bottom:
		for card_id in remaining:
			player.deck.push_front(card_id)
		return
	var restored := remaining.duplicate()
	restored.reverse()
	player.deck.append_array(restored)


static func string_array(values: Variant) -> Array[String]:
	var result: Array[String] = []
	if values is Array:
		for value in values:
			result.append(str(value))
	return result


static func int_array(values: Variant) -> Array[int]:
	var result: Array[int] = []
	if values is Array:
		for value in values:
			result.append(int(value))
	return result


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
