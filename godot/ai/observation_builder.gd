class_name AIObservationBuilder
extends RefCounted


static func build(state: GameState, perspective: int) -> Dictionary:
	var own := state.get_player(perspective)
	var opponent := state.get_player(1 - perspective)
	var board: Array = []
	for player_idx in [0, 1]:
		var player := state.get_player(player_idx)
		for row in player.get_all_pokemon():
			var pokemon: PokemonState = row["pokemon"]
			if pokemon == null:
				board.append([player_idx, str(row["slot"]), "", 0, [], [], ""])
				continue
			board.append([
				player_idx,
				str(row["slot"]),
				pokemon.card_id,
				pokemon.damage_counters,
				pokemon.energy_card_ids.duplicate(),
				pokemon.status_conditions.duplicate(),
				pokemon.attached_tool_id,
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
	seed: int,
	catalog: CardCatalog,
) -> GameState:
	var state := GameState.from_dict(snapshot)
	var rng := PortableRandomSource.new(seed)
	var own := state.get_player(perspective)
	var own_unknown: Array = own.deck.duplicate()
	own_unknown.append_array(own.prizes)
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
	var pool: Array[String] = catalog.expand_deck(deck_key)
	if not pool.is_empty():
		var visible := opponent.discard.duplicate()
		for row in opponent.get_all_pokemon():
			var pokemon: PokemonState = row["pokemon"]
			if pokemon == null:
				continue
			visible.append(pokemon.card_id)
			visible.append_array(pokemon.evolution_stack_ids)
			visible.append_array(pokemon.energy_card_ids)
			if not pokemon.attached_tool_id.is_empty():
				visible.append(pokemon.attached_tool_id)
		for card_id in visible:
			var index := pool.find(card_id)
			if index >= 0:
				pool.remove_at(index)
	else:
		pool.assign(opponent.hand + opponent.deck + opponent.prizes)
	while pool.size() < hidden_count:
		pool.append("sv1-ener-1")
	pool.resize(hidden_count)
	rng.shuffle(pool)
	var hand_count := opponent.hand.size()
	var deck_count := opponent.deck.size()
	opponent.hand.assign(pool.slice(0, hand_count))
	opponent.deck.assign(pool.slice(hand_count, hand_count + deck_count))
	opponent.prizes.assign(pool.slice(hand_count + deck_count))
	return state
