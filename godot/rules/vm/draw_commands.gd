class_name VMDrawCommands
extends RefCounted


func register(interpreter: VMInterpreter) -> void:
	var registrations := {
		"draw_cards": Callable(self, "cmd_draw_cards"),
		"draw_until": Callable(self, "cmd_draw_until"),
		"draw_until_more_than_opponent": Callable(self, "cmd_draw_until_more_than_opponent"),
		"judge": Callable(self, "cmd_judge"),
		"shuffle_then_draw_cards": Callable(self, "cmd_shuffle_then_draw_cards"),
	}
	for op in registrations:
		interpreter.register_command_handler(str(op), registrations[op])


func cmd_draw_cards(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var draw_player_idx := (
		1 - player_idx
		if str(args.get("player", "self")) == "opponent"
		else player_idx
	)
	return draw_available(state, draw_player_idx, int(args.get("amount", 1)), events)


func cmd_draw_until(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var to_draw: int = max(
		0,
		int(args.get("target_hand_size", 5)) - state.get_player(player_idx).hand.size(),
	)
	return draw_available(state, player_idx, to_draw, events)


func cmd_draw_until_more_than_opponent(
	state: GameState,
	_stack: ResolutionStack,
	_rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var margin := int(args.get("margin", 1))
	var to_draw: int = max(
		0,
		state.get_player(1 - player_idx).hand.size()
		+ margin
		- state.get_player(player_idx).hand.size(),
	)
	return draw_available(state, player_idx, to_draw, events)


func cmd_judge(
	state: GameState,
	_stack: ResolutionStack,
	rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	_player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	for player_idx in [0, 1]:
		var player := state.get_player(player_idx)
		if player.hand.is_empty():
			continue
		player.deck.append_array(player.hand)
		player.hand.clear()
		rng.shuffle(player.deck)
		events.append({"event_type": "deck_shuffled", "data": {"player": player_idx}})
		draw_available(state, player_idx, int(args.get("draw", args.get("amount", 4))), events)
	return VMResult.ok()


func cmd_shuffle_then_draw_cards(
	state: GameState,
	_stack: ResolutionStack,
	rng: PortableRandomSource,
	args: Dictionary,
	_branches: Dictionary,
	player_idx: int,
	_source_slot: String,
	events: Array[Dictionary],
) -> Dictionary:
	var player := state.get_player(player_idx)
	if bool(args.get("shuffle_hand", false)):
		player.deck.append_array(player.hand)
		player.hand.clear()
		rng.shuffle(player.deck)
		events.append({"event_type": "deck_shuffled", "data": {"player": player_idx}})
	return draw_available(state, player_idx, int(args.get("draw", args.get("amount", 5))), events)


func draw_available(
	state: GameState,
	player_idx: int,
	amount: int,
	events: Array[Dictionary],
) -> Dictionary:
	return VMZoneHelpers.draw_available(state, player_idx, amount, events)
