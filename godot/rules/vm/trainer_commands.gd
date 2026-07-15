class_name VMTrainerCommands
extends RefCounted

var catalog: CardCatalog


func _init(p_catalog: CardCatalog) -> void:
	catalog = p_catalog


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"discard_cards": Callable(self, "cmd_discard_cards"),
		"discard_then_draw_cards": Callable(self, "cmd_discard_then_draw_cards"),
		"hand_to_bottom_draw_until": Callable(self, "cmd_hand_to_bottom_draw_until"),
		"hand_to_bottom_then_draw": Callable(self, "cmd_hand_to_bottom_then_draw"),
		"recover_clara": Callable(self, "cmd_recover_clara"),
		"search_cards": Callable(self, "cmd_search_cards"),
		"search_item_and_tool": Callable(self, "cmd_search_item_and_tool"),
		"shuffle_from_discard_to_deck": Callable(self, "cmd_shuffle_from_discard_to_deck"),
		"trekking_shoes": Callable(self, "cmd_trekking_shoes"),
		"zinnia_resolve": Callable(self, "cmd_zinnia_resolve"),
	}
	for op in registrations:
		interpreter.register_command_handler(str(op), registrations[op])


func cmd_discard_cards(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	var discard_zone := str(args.get("from", args.get("from_zone", "hand")))
	var discard_source: Array[String] = VMZoneHelpers.zone(state.get_player(player_idx), discard_zone)
	var discard_amount := int(args.get("amount", 1))
	if discard_source.size() < discard_amount:
		return {
			"success": false,
			"message": "手牌不足，无法支付丢弃代价。",
			"error_code": "cost_not_payable",
		}
	if discard_amount <= 0:
		return {
			"success": false,
			"message": "没有可丢弃的卡。",
			"error_code": "effect_failed",
		}
	return VMChoiceRequests.request_cards(
		catalog,
		state, stack, player_idx, discard_zone, discard_source, "discard_cards",
		{"player_idx": player_idx, "zone": discard_zone},
		discard_amount, discard_amount, "选择要丢弃的卡。")


func cmd_discard_then_draw_cards(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var draw_amount := int(args.get("draw_amount", args.get("draw", 0)))
	if bool(args.get("discard_hand", false)):
		var discard_draw_player := state.get_player(player_idx)
		var discarded_cards := discard_draw_player.hand.duplicate()
		var discarded_count := discard_draw_player.discard_entire_hand()
		if discarded_count > 0:
			events.append(VMZoneHelpers.discard_event(
				player_idx,
				"hand",
				discarded_cards,
				discarded_count,
				range(discarded_count),
			))
		return VMZoneHelpers.draw_available(state, player_idx, draw_amount, events)
	var select_discard_amount := int(args.get("discard_amount", args.get("amount", 1)))
	return VMChoiceRequests.request_cards(
		catalog,
		state, stack, player_idx, "hand", state.get_player(player_idx).hand,
		"discard_then_draw",
		{"player_idx": player_idx, "draw_amount": draw_amount},
		select_discard_amount, select_discard_amount, "选择要丢弃的手牌。")


func cmd_hand_to_bottom_draw_until(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	if player.hand.is_empty():
		return {
			"success": false,
			"message": "没有其他手牌可以放回牌库底。",
			"error_code": "effect_failed",
		}
	return VMChoiceRequests.request_cards(
		catalog,
		state, stack, player_idx, "hand", player.hand, "houb",
		{"player_idx": player_idx, "target": int(args.get("target_hand_size", 5))},
		1, 1, "选择1张手牌放回牌库底。")


func cmd_hand_to_bottom_then_draw(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	_args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return hand_to_bottom_then_draw_request(state, stack, player_idx)


func cmd_recover_clara(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return recover_from_discard_request(
		state, stack, player_idx, args.duplicate(true), "clara")


func cmd_search_cards(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return search_request(state, stack, rng, player_idx, args, events)


func cmd_search_item_and_tool(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	_args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return arven_request(state, stack, rng, player_idx, events)


func cmd_shuffle_from_discard_to_deck(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return recover_from_discard_request(
		state, stack, player_idx, args.duplicate(true), "shuffle_to_deck")


func cmd_trekking_shoes(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	_args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return trekking_shoes_request(state, stack, player_idx)


func cmd_zinnia_resolve(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	_args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return zinnia_resolve_request(state, stack, player_idx, events)


func hand_to_bottom_then_draw_request(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
) -> Dictionary:
	var player := state.get_player(player_idx)
	if player.hand.is_empty():
		return VMResult.ok("手牌为空，无需操作。")
	return VMChoiceRequests.request_cards(
		catalog,
		state, stack, player_idx, "hand", player.hand, "hand_bottom_draw",
		{"player_idx": player_idx},
		0, player.hand.size(), "选择任意张手牌放回牌库底。", true)


func zinnia_resolve_request(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	if player.hand.size() < 2:
		return VMResult.fail("手牌不足2张。")
	var opponent := state.get_player(1 - player_idx)
	var draw_amount := opponent.bench_count() + (1 if opponent.active else 0)
	if player.hand.size() == 2:
		var discarded_cards := player.hand.duplicate()
		var discarded_count := player.discard_entire_hand()
		if discarded_count > 0:
			events.append(VMZoneHelpers.discard_event(
				player_idx,
				"hand",
				discarded_cards,
				discarded_count,
				range(discarded_count),
			))
		return VMZoneHelpers.draw_available(state, player_idx, draw_amount, events)
	return VMChoiceRequests.request_cards(
		catalog,
		state, stack, player_idx, "hand", player.hand, "zinnia",
		{"player_idx": player_idx, "draw_amount": draw_amount},
		2, 2, "选择2张手牌丢弃。")


func recover_from_discard_request(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	params: Dictionary,
	mode: String,
) -> Dictionary:
	var player := state.get_player(player_idx)
	if mode == "clara":
		var clara_available: Array[String] = []
		for card_id in player.discard:
			if catalog.is_pokemon(card_id) or catalog.is_basic_energy(card_id):
				clara_available.append(card_id)
		if clara_available.is_empty():
			return VMResult.ok("弃牌区没有可回收的卡。")
		var pokemon_count := int(params.get("pokemon_count", 2))
		var energy_count := int(params.get("energy_count", 2))
		return VMChoiceRequests.request_cards(
			catalog,
			state, stack, player_idx, "discard", clara_available, "clara",
			{
				"player_idx": player_idx,
				"pokemon_count": pokemon_count,
				"energy_count": energy_count,
			},
			0, min(clara_available.size(), pokemon_count + energy_count),
			"选择弃牌区中的宝可梦和基本能量。", true)

	var available := catalog.filter_cards(
		player.discard,
		str(params.get("filter", "any")),
	)
	if available.is_empty():
		return VMResult.fail("弃牌区没有符合条件的卡，卡牌保留在手牌中。", "no_legal_target")
	var max_select: int = min(int(params.get("count", 3)), available.size())
	return VMChoiceRequests.request_cards(
		catalog,
		state, stack, player_idx, "discard", available, "shuffle_from_discard",
		{"player_idx": player_idx},
		min(1, max_select), max_select,
		"选择要洗回牌库的卡。", true)


func arven_request(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	player_idx: int,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var available: Array[String] = []
	for card_id in player.deck:
		if catalog.is_item(card_id) or catalog.is_tool(card_id):
			available.append(card_id)
	if available.is_empty():
		complete_empty_deck_search(state, rng, player_idx, "hand", events)
		return VMResult.ok("牌库中没有物品卡或宝可梦道具卡。")
	return VMChoiceRequests.request_cards(
		catalog,
		state, stack, player_idx, "deck", available, "arven",
		{"player_idx": player_idx},
		1, min(2, available.size()),
		"选择1张物品和1张宝可梦道具。")


func trekking_shoes_request(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
) -> Dictionary:
	var player := state.get_player(player_idx)
	if player.deck.is_empty():
		return VMResult.ok("牌库为空。")
	var top_card_id := player.deck[-1]
	return VMChoiceRequests.confirm_request(
		state, stack, player_idx, "trekking_shoes",
		{"player_idx": player_idx, "card_id": top_card_id},
		"牌库顶是「%s」。是否将其加入手牌？\n（选「否」将丢弃此卡并抽1张）" % catalog.card_name(top_card_id),
		{
			"top_card_id": top_card_id,
			"revealed_card_ids": [top_card_id],
		})


func conditional_search_request(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	player_idx: int,
	params: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var count := int(params.get("default_count", 1))
	if (
		player_idx != state.first_player_idx
		and player_idx == state.active_player_idx
		and state.is_player_first_turn(player_idx)
	):
		count = int(params.get("max_count", count))
	return search_request(state, stack, rng, player_idx, {
		"from_zone": "deck",
		"filter": params.get("filter", "pokemon"),
		"destination": "hand",
		"count": count,
		"min_select": 0 if count == int(params.get("max_count", count)) else 1,
	}, events)


func search_request(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	player_idx: int,
	params: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var zone := str(params.get("from_zone", "deck"))
	var source: Array[String] = player.deck if zone == "deck" else player.discard
	var available := catalog.filter_cards(
		source,
		str(params.get("filter", "any")),
		str(params.get("filter_name", "")),
	)
	if available.is_empty():
		if zone == "deck":
			complete_empty_deck_search(
				state, rng, player_idx, str(params.get("destination", "hand")), events)
		return VMResult.ok("没有符合条件的卡。")
	var requested_count := int(params.get("count", 1))
	if requested_count <= 0:
		if zone == "deck":
			complete_empty_deck_search(
				state, rng, player_idx, str(params.get("destination", "hand")), events)
		return VMResult.ok("未选择卡牌。")
	var min_select: int = min(
		int(params.get("min_select", min(1, requested_count))),
		min(requested_count, available.size())
	)
	return VMChoiceRequests.request_cards(
		catalog,
		state, stack, player_idx, zone, available, "search_move",
		{
			"player_idx": player_idx,
			"source_zone": zone,
			"destination": str(params.get("destination", "hand")),
			"shuffle": zone == "deck",
		},
		min_select,
		min(requested_count, available.size()),
		"选择符合条件的卡。",
		min_select <= 0)


func complete_empty_deck_search(
	state: GameState,
	rng: PortableRandomSource,
	player_idx: int,
	destination: String,
	events: Array[Dictionary],
) -> void:
	events.append(VMZoneHelpers.cards_selected_event(
		player_idx,
		"deck",
		destination,
		[],
		0,
	))
	VMZoneHelpers.shuffle_deck(state, rng, player_idx, events)
