class_name VMLookTopCommands
extends RefCounted

var catalog: CardCatalog
var energy_commands: VMEnergyCommands


func _init(p_catalog: CardCatalog, p_energy_commands: VMEnergyCommands) -> void:
	catalog = p_catalog
	energy_commands = p_energy_commands


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"look_top_attach_energy": Callable(self, "cmd_look_top_attach_energy"),
		"look_top_deck": Callable(self, "cmd_look_top_deck"),
	}
	for op in registrations:
		interpreter.register_command_handler(str(op), registrations[op])


func cmd_look_top_attach_energy(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return look_top_attach_request(state, stack, rng, player_idx, args, events)


func cmd_look_top_deck(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	return look_top_request(state, stack, rng, player_idx, args, events)


func look_top_request(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	player_idx: int,
	params: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var count: int = min(int(params.get("count", 1)), player.deck.size())
	var top_cards: Array[String] = []
	for offset in range(count):
		top_cards.append(player.deck[player.deck.size() - 1 - offset])
	var options: Array[Dictionary] = []
	var filter_type := str(params.get("filter", "any"))
	for position in range(top_cards.size()):
		var card_id := top_cards[position]
		if catalog.filter_cards([card_id], filter_type).is_empty():
			continue
		var deck_index := player.deck.size() - 1 - position
		options.append({
			"option_id": "card:deck:%d:%s" % [deck_index, card_id],
			"label": catalog.card_name(card_id),
			"ref": EntityRef.new(
				"card", player_idx, "deck", "", deck_index, "", card_id).to_dict(),
			"value": {"index": deck_index, "card_id": card_id},
		})
	var take: int = min(int(params.get("take", 1)), options.size())
	if options.is_empty() or take <= 0:
		complete_unselected_look_top(
			state,
			rng,
			player_idx,
			top_cards,
			str(params.get("destination", "hand")),
			bool(params.get("rest_bottom", false)),
			bool(params.get("shuffle_rest", false)),
			events,
		)
		return VMResult.ok("查看的卡中没有符合条件的卡。")
	stack.push_continuation("look_top", {
		"player_idx": player_idx,
		"top_cards": top_cards,
		"destination": str(params.get("destination", "hand")),
		"rest_bottom": bool(params.get("rest_bottom", false)),
		"shuffle_rest": bool(params.get("shuffle_rest", false)),
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "look_top"),
		"look_top",
		player_idx,
		"选择查看到的卡。",
		options,
		0,
		take,
		false,
		true,
		{
			"domain": "effect",
			"purpose": "look_top",
			"revision": state.revision,
			"revealed_card_ids": top_cards.duplicate(),
			"source_player": player_idx,
			"source_zone": "deck",
		},
	)
	return VMResult.ok()


func look_top_attach_request(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	player_idx: int,
	params: Dictionary,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	var count: int = min(int(params.get("count", 5)), player.deck.size())
	var take := int(params.get("take", 99))
	var filter_type := str(params.get("filter", "basic_energy"))
	var options: Array[Dictionary] = []
	var top_indices: Array[int] = []
	var top_card_ids: Array[String] = []
	for offset in range(count):
		var deck_index := player.deck.size() - 1 - offset
		top_indices.append(deck_index)
		var card_id := player.deck[deck_index]
		top_card_ids.append(card_id)
		if not energy_commands.energy_matches(card_id, filter_type):
			continue
		options.append({
			"option_id": "card:deck:%d:%s" % [deck_index, card_id],
			"label": catalog.card_name(card_id),
			"ref": EntityRef.new("card", player_idx, "deck", "", deck_index, "", card_id).to_dict(),
			"value": {"index": deck_index, "card_id": card_id},
		})
	if options.is_empty():
		events.append(VMZoneHelpers.cards_selected_event(
			player_idx, "deck", "field", [], 0))
		VMZoneHelpers.shuffle_deck(state, rng, player_idx, events)
		return VMResult.ok("查看的卡中没有可附着的能量。")
	stack.push_continuation("look_top_attach_energy", {
		"player_idx": player_idx,
		"top_indices": top_indices,
		"top_card_ids": top_card_ids,
	})
	stack.pending_request = ChoiceRequest.new(
		stack.next_request_id(state, player_idx, "look_top_attach_energy"),
		"look_top_attach_energy",
		player_idx,
		"选择任意数量的基本能量。",
		options,
		0,
		min(take, options.size()),
		false,
		true,
		{
			"domain": "effect",
			"purpose": "look_top_attach_energy",
			"revision": state.revision,
			"revealed_card_ids": top_card_ids.duplicate(),
			"source_player": player_idx,
			"source_zone": "deck",
		},
	)
	return VMResult.ok()


func complete_unselected_look_top(
	state: GameState,
	rng: PortableRandomSource,
	player_idx: int,
	top_cards: Array[String],
	destination: String,
	rest_bottom: bool,
	shuffle_rest: bool,
	events: Array[Dictionary],
) -> void:
	var player := state.get_player(player_idx)
	events.append(VMZoneHelpers.cards_selected_event(
		player_idx, "deck", destination, [], 0))
	if shuffle_rest:
		VMZoneHelpers.shuffle_deck(state, rng, player_idx, events)
		return
	if not rest_bottom:
		return
	for _card_id in top_cards:
		player.deck.pop_back()
	for card_id in top_cards:
		player.deck.push_front(card_id)
