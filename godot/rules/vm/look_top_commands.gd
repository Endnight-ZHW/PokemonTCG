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
	_events: Array[Dictionary],
) -> Dictionary:
	return look_top_attach_request(state, stack, rng, player_idx, args)


func cmd_look_top_deck(
	state: GameState,
	stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	_events: Array[Dictionary],
) -> Dictionary:
	return look_top_request(state, stack, player_idx, args)


func look_top_request(
	state: GameState,
	stack: ResolutionStack,
	player_idx: int,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var count: int = min(int(params.get("count", 1)), player.deck.size())
	var top_cards: Array[String] = []
	for offset in range(count):
		top_cards.append(player.deck[player.deck.size() - 1 - offset])
	var available := catalog.filter_cards(top_cards, str(params.get("filter", "any")))
	var take: int = min(int(params.get("take", 1)), available.size())
	if available.is_empty():
		return VMResult.ok("查看的卡中没有符合条件的卡。")
	return VMChoiceRequests.request_cards(
		catalog,
		state, stack, player_idx, "deck", available, "look_top",
		{
			"player_idx": player_idx,
			"top_cards": top_cards,
			"destination": str(params.get("destination", "hand")),
			"rest_bottom": bool(params.get("rest_bottom", false)),
			"shuffle_rest": bool(params.get("shuffle_rest", false)),
		},
		0, take, "选择查看到的卡。", true)


func look_top_attach_request(
	state: GameState,
	stack: ResolutionStack,
	rng: PortableRandomSource,
	player_idx: int,
	params: Dictionary,
) -> Dictionary:
	var player := state.get_player(player_idx)
	var count: int = min(int(params.get("count", 5)), player.deck.size())
	var take := int(params.get("take", 99))
	var filter_type := str(params.get("filter", "basic_energy"))
	var options: Array[Dictionary] = []
	var top_indices: Array[int] = []
	for offset in range(count):
		var deck_index := player.deck.size() - 1 - offset
		top_indices.append(deck_index)
		var card_id := player.deck[deck_index]
		if not energy_commands.energy_matches(card_id, filter_type):
			continue
		options.append({
			"option_id": "card:deck:%d:%s" % [deck_index, card_id],
			"label": catalog.card_name(card_id),
			"ref": EntityRef.new("card", player_idx, "deck", "", deck_index, "", card_id).to_dict(),
			"value": {"index": deck_index, "card_id": card_id},
		})
	if options.is_empty():
		rng.shuffle(player.deck)
		return VMResult.ok("查看的卡中没有可附着的能量。")
	stack.push_continuation("look_top_attach_energy", {
		"player_idx": player_idx,
		"top_indices": top_indices,
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
		{"revision": state.revision},
	)
	return VMResult.ok()
