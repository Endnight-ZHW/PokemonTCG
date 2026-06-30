class_name VMTrainerContinuations
extends RefCounted

var catalog: CardCatalog


func _init(p_catalog: CardCatalog) -> void:
	catalog = p_catalog


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"search_move": Callable(self, "continue_search_move"),
		"discard_then_draw": Callable(self, "continue_discard_then_draw"),
		"discard_cards": Callable(self, "continue_discard_cards"),
		"hand_bottom_draw": Callable(self, "continue_hand_bottom_draw"),
		"houb": Callable(self, "continue_houb"),
		"zinnia": Callable(self, "continue_zinnia"),
		"shuffle_from_discard": Callable(self, "continue_shuffle_from_discard"),
		"clara": Callable(self, "continue_clara"),
		"arven": Callable(self, "continue_arven"),
	}
	for operation in registrations:
		interpreter.register_continuation(str(operation), registrations[operation])


func continue_search_move(
	state: GameState,
	_stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	return VMZoneHelpers.move_selected_cards(state, rng, data, selected, events)


func continue_discard_then_draw(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data["player_idx"])
	var discarded: Array[String] = VMZoneHelpers.remove_selected_from_zone(
		state.get_player(player_idx), "hand", selected, true)
	events.append(VMZoneHelpers.discard_event(player_idx, "hand", discarded, discarded.size()))
	return VMZoneHelpers.draw_available(state, player_idx, int(data["draw_amount"]), events)


func continue_discard_cards(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data["player_idx"])
	var zone := str(data["zone"])
	var discarded: Array[String] = VMZoneHelpers.remove_selected_from_zone(
		state.get_player(player_idx), zone, selected, true)
	events.append(VMZoneHelpers.discard_event(player_idx, zone, discarded, discarded.size()))
	return VMResult.ok()


func continue_hand_bottom_draw(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(int(data["player_idx"]))
	var moved: Array[String] = VMZoneHelpers.remove_selected_from_zone(player, "hand", selected, false)
	for card_id in moved:
		player.deck.push_front(card_id)
	return VMZoneHelpers.draw_available(state, int(data["player_idx"]), moved.size(), events)


func continue_houb(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(int(data["player_idx"]))
	var bottom: Array[String] = VMZoneHelpers.remove_selected_from_zone(player, "hand", selected, false)
	for card_id in bottom:
		player.deck.push_front(card_id)
	return VMZoneHelpers.draw_available(
		state, int(data["player_idx"]),
		max(0, int(data["target"]) - player.hand.size()), events)


func continue_zinnia(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(int(data["player_idx"]))
	var discarded: Array[String] = VMZoneHelpers.remove_selected_from_zone(player, "hand", selected, true)
	events.append(VMZoneHelpers.discard_event(
		int(data["player_idx"]), "hand", discarded, discarded.size()))
	return VMZoneHelpers.draw_available(
		state, int(data["player_idx"]), int(data["draw_amount"]), events)


func continue_shuffle_from_discard(
	state: GameState,
	_stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player_idx := int(data["player_idx"])
	var player := state.get_player(player_idx)
	if selected.is_empty():
		return VMResult.fail("至少选择1张卡。", "choice_count")
	var shuffled: Array[String] = VMZoneHelpers.remove_selected_from_zone(player, "discard", selected, false)
	if shuffled.is_empty():
		return VMResult.fail("没有可洗回牌库的卡。", "choice_count")
	player.deck.append_array(shuffled)
	rng.shuffle(player.deck)
	events.append({
		"event_type": "card_moved",
		"actor": player_idx,
		"source": {"player": player_idx, "zone": "discard"},
		"target": {"player": player_idx, "zone": "deck"},
		"amount": shuffled.size(),
		"data": {
			"player": player_idx,
			"source_zone": "discard",
			"target_zone": "deck",
			"card_ids": shuffled.duplicate(),
			"count": shuffled.size(),
		},
	})
	events.append({"event_type": "deck_shuffled", "data": {
		"player": player_idx,
	}})
	state.log_action("%s将%d张卡从弃牌区洗回牌库。" % [player.name, shuffled.size()])
	return VMResult.ok("将%d张卡洗回牌库。" % shuffled.size())


func continue_clara(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	_events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(int(data["player_idx"]))
	var pokemon_left := int(data["pokemon_count"])
	var energy_left := int(data["energy_count"])
	var accepted: Array[Dictionary] = []
	for option in selected:
		var card_id := str(option.get("value", {}).get("card_id", ""))
		if catalog.is_pokemon(card_id) and pokemon_left > 0:
			accepted.append(option)
			pokemon_left -= 1
		elif catalog.is_basic_energy(card_id) and energy_left > 0:
			accepted.append(option)
			energy_left -= 1
	var recovered: Array[String] = VMZoneHelpers.remove_selected_from_zone(player, "discard", accepted, false)
	player.hand.append_array(recovered)
	return VMResult.ok()


func continue_arven(
	state: GameState,
	_stack: ResolutionStack,
	rng: PortableRandomSource,
	data: Dictionary,
	selected: Array[Dictionary],
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(int(data["player_idx"]))
	var item_taken := false
	var tool_taken := false
	var accepted: Array[Dictionary] = []
	for option in selected:
		var card_id := str(option.get("value", {}).get("card_id", ""))
		if catalog.is_item(card_id) and not item_taken:
			accepted.append(option)
			item_taken = true
		elif catalog.is_tool(card_id) and not tool_taken:
			accepted.append(option)
			tool_taken = true
	var cards: Array[String] = VMZoneHelpers.remove_selected_from_zone(player, "deck", accepted, false)
	player.hand.append_array(cards)
	rng.shuffle(player.deck)
	events.append({"event_type": "deck_shuffled", "data": {
		"player": int(data["player_idx"]),
	}})
	return VMResult.ok()
