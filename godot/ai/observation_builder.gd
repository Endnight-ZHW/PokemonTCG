class_name AIObservationBuilder
extends RefCounted


static func build(state: GameState, perspective: int) -> Dictionary:
	var own := state.get_player(perspective)
	var opponent := state.get_player(1 - perspective)
	var setup_board_hidden: bool = (
		state.phase == "SETUP"
		and state.setup_stage != GameState.SETUP_COMPLETE
	)
	var board: Array = []
	for player_idx in [0, 1]:
		var player := state.get_player(player_idx)
		for row in player.get_all_pokemon():
			var pokemon: PokemonState = row["pokemon"]
			if pokemon == null:
				board.append([player_idx, str(row["slot"]), "", 0, [], [], ""])
				continue
			var hide_identity: bool = setup_board_hidden and player_idx != perspective
			board.append([
				player_idx,
				str(row["slot"]),
				"" if hide_identity else pokemon.card_id,
				0 if hide_identity else pokemon.damage_counters,
				[] if hide_identity else pokemon.energy_card_ids.duplicate(),
				[] if hide_identity else pokemon.status_conditions.duplicate(),
				"" if hide_identity else pokemon.attached_tool_id,
			])
	return {
		"perspective": perspective,
		"turn_number": state.turn_number,
		"phase": state.phase,
		"active_player": state.active_player_idx,
		"winner": state.winner,
		"own_hand": own.hand.duplicate(),
		"own_discard": own.discard.duplicate(),
		"own_deck_count": own.deck.size(),
		"own_prize_count": own.prizes.size(),
		"opponent_hand_count": opponent.hand.size(),
		"opponent_discard": opponent.discard.duplicate(),
		"opponent_deck_count": opponent.deck.size(),
		"opponent_prize_count": opponent.prizes.size(),
		"board": board,
		"stadium_id": state.stadium_card_id,
		"public_deck_keys": state.public_deck_keys.duplicate(),
		"apply_type_matchups": state.apply_type_matchups,
	}


static func determinize(
	snapshot: Dictionary,
	perspective: int,
	determinize_seed: int,
	catalog: CardCatalog,
) -> GameState:
	return _determinize_mutable(
		GameState.from_dict(snapshot), perspective, determinize_seed, catalog)


static func determinize_state(
	base_state: GameState,
	perspective: int,
	determinize_seed: int,
	catalog: CardCatalog,
) -> GameState:
	return _determinize_mutable(base_state.clone_state(), perspective, determinize_seed, catalog)


static func _determinize_mutable(
	state: GameState,
	perspective: int,
	determinize_seed: int,
	catalog: CardCatalog,
) -> GameState:
	# AI challenge never uses the optional global type matchup rule.  Keep
	# determinized legacy/encoder states aligned with the authoritative AI mode.
	state.set_type_matchups_enabled(false)
	var rng := PortableRandomSource.new(determinize_seed)
	var setup_board_hidden: bool = (
		state.phase == "SETUP"
		and state.setup_stage != GameState.SETUP_COMPLETE
	)
	if setup_board_hidden:
		_mask_setup_board_identity(state.get_player(1 - perspective))
	var own := state.get_player(perspective)
	var own_unknown := _deck_unknown_pool(
		state, perspective, catalog, own.hand, own.deck + own.prizes)
	var own_hidden_count := own.deck.size() + own.prizes.size()
	while own_unknown.size() < own_hidden_count:
		own_unknown.append("sv1-ener-1")
	own_unknown.resize(own_hidden_count)
	rng.shuffle(own_unknown)
	var own_deck_count := own.deck.size()
	own.deck.assign(own_unknown.slice(0, own_deck_count))
	own.prizes.assign(own_unknown.slice(own_deck_count))

	var opponent_idx := 1 - perspective
	var opponent := state.get_player(opponent_idx)
	var hidden_count := (
		opponent.hand.size() + opponent.deck.size() + opponent.prizes.size()
	)
	var deck_key := (
		state.public_deck_keys[opponent_idx]
		if opponent_idx < state.public_deck_keys.size()
		else ""
	)
	var pool := _deck_unknown_pool(
		state,
		opponent_idx,
		catalog,
		[],
		opponent.hand + opponent.deck + opponent.prizes,
	)
	while pool.size() < hidden_count:
		pool.append("" if setup_board_hidden else "sv1-ener-1")
	pool.resize(hidden_count)
	rng.shuffle(pool)
	var hand_count := opponent.hand.size()
	var deck_count := opponent.deck.size()
	opponent.hand.assign(pool.slice(0, hand_count))
	opponent.deck.assign(pool.slice(hand_count, hand_count + deck_count))
	opponent.prizes.assign(pool.slice(hand_count + deck_count))
	return state


static func _deck_unknown_pool(
	state: GameState,
	player_idx: int,
	catalog: CardCatalog,
	extra_visible_cards: Array,
	fallback_hidden_cards: Array,
) -> Array[String]:
	var deck_key := (
		state.public_deck_keys[player_idx]
		if player_idx >= 0 and player_idx < state.public_deck_keys.size()
		else ""
	)
	var pool: Array[String] = catalog.expand_deck(deck_key)
	if pool.is_empty():
		for value in fallback_hidden_cards:
			var fallback_id := str(value)
			if not fallback_id.begins_with("__hidden_"):
				pool.append(fallback_id)
		return pool
	var player := state.get_player(player_idx)
	var visible_cards: Array = player.discard.duplicate()
	visible_cards.append_array(extra_visible_cards)
	for row in player.get_all_pokemon():
		var pokemon: PokemonState = row["pokemon"]
		if pokemon == null or pokemon.card_id.is_empty():
			continue
		visible_cards.append(pokemon.card_id)
		visible_cards.append_array(pokemon.evolution_stack_ids)
		visible_cards.append_array(pokemon.energy_card_ids)
		if not pokemon.attached_tool_id.is_empty():
			visible_cards.append(pokemon.attached_tool_id)
	for value in visible_cards:
		var card_id := str(value)
		var index := pool.find(card_id)
		if index >= 0:
			pool.remove_at(index)
	return pool


static func _mask_setup_board_identity(player: PlayerState) -> void:
	if player.active != null:
		player.active = PokemonState.new("")
	for index in range(player.bench.size()):
		if player.bench[index] is PokemonState:
			player.bench[index] = PokemonState.new("")
