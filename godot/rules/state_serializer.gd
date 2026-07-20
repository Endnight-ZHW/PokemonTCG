class_name StateSerializer
extends RefCounted


static func for_player(state: GameState, player_idx: int) -> Dictionary:
	var setup_hidden := state.setup_stage != GameState.SETUP_COMPLETE
	var own := _player_payload(state.players[player_idx], true, false)
	var opponent := _player_payload(state.players[1 - player_idx], false, setup_hidden)
	return {
		"phase": state.phase,
		"turn_number": state.turn_number,
		"active_player_idx": state.active_player_idx,
		"first_player_idx": state.first_player_idx,
		"revision": state.revision,
		"stadium_card_id": state.stadium_card_id,
		"stadium_owner_idx": state.stadium_owner_idx,
		"winner": state.winner,
		"result_status": state.result_status,
		"result_reason": state.result_reason,
		"result_conditions": state.result_conditions.duplicate(true),
		"public_deck_keys": state.public_deck_keys.duplicate(),
		"apply_type_matchups": state.apply_type_matchups,
		"rules_profile_id": state.rules_profile_id,
		"rules_options": state.rules_options.merged(
			{"apply_type_matchups": state.apply_type_matchups}, true),
		"action_log": state.action_log.duplicate(),
		"mulligan_count": state.mulligan_count.duplicate(),
		"extra_draws": state.extra_draws.duplicate(),
		"setup_ready": state.setup_ready.duplicate(),
		"setup_stage": state.setup_stage,
		"setup_actor_idx": state.setup_actor_idx,
		"opening_coin_winner_idx": state.opening_coin_winner_idx,
		"mulligan_bonus_max": state.mulligan_bonus_max,
		"pending_promotions": state.pending_promotions.duplicate(),
		"turn_fact_book": state.turn_fact_book.duplicate(true),
		"your": own,
		"opponent": opponent,
	}


static func _player_payload(
	player: PlayerState,
	show_hand: bool,
	hide_setup_board: bool = false,
) -> Dictionary:
	var payload := player.to_dict()
	payload["hand_count"] = player.hand.size()
	payload["deck_count"] = player.deck.size()
	payload["prize_count"] = player.prizes.size()
	payload.erase("deck")
	payload.erase("prizes")
	if not show_hand:
		payload.erase("hand")
	if hide_setup_board:
		payload["active"] = {"hidden": true} if player.active != null else null
		var hidden_bench: Array = []
		for pokemon in player.bench:
			hidden_bench.append({"hidden": true} if pokemon is PokemonState else null)
		payload["bench"] = hidden_bench
	return payload


static func from_player_view(payload: Dictionary, player_idx: int) -> GameState:
	var result := GameState.new()
	result.phase = str(payload.get("phase", "SETUP"))
	result.turn_number = int(payload.get("turn_number", 0))
	result.active_player_idx = int(payload.get("active_player_idx", 0))
	result.first_player_idx = int(payload.get("first_player_idx", 0))
	result.revision = int(payload.get("revision", 0))
	result.stadium_card_id = str(payload.get("stadium_card_id", ""))
	result.stadium_owner_idx = int(payload.get("stadium_owner_idx", -1))
	result.winner = int(payload.get("winner", -1))
	result.result_status = str(payload.get(
		"result_status", GameState.RESULT_WIN if result.winner >= 0 else GameState.RESULT_ONGOING))
	result.result_reason = str(payload.get("result_reason", ""))
	result.result_conditions = Array(payload.get("result_conditions", [[], []])).duplicate(true)
	result.rules_profile_id = str(payload.get("rules_profile_id", GameState.RULES_PROFILE_ID))
	result.rules_options = Dictionary(payload.get("rules_options", {})).duplicate(true)
	result.apply_type_matchups = bool(result.rules_options.get(
		"apply_type_matchups", payload.get("apply_type_matchups", false)))
	result.rules_options["apply_type_matchups"] = result.apply_type_matchups
	result.action_log.assign(payload.get("action_log", []))
	result.pending_promotions.assign(payload.get("pending_promotions", []))
	result.turn_fact_book = Dictionary(payload.get("turn_fact_book", {
		"current_turn": {"knockouts": []},
		"previous_turn": {"knockouts": []},
	})).duplicate(true)
	result.mulligan_count.assign(payload.get("mulligan_count", [0, 0]))
	result.extra_draws.assign(payload.get("extra_draws", [0, 0]))
	result.setup_ready.assign(payload.get("setup_ready", [false, false]))
	result.setup_stage = str(payload.get("setup_stage", GameState.SETUP_INITIAL_PLACEMENT))
	result.setup_actor_idx = int(payload.get("setup_actor_idx", result.first_player_idx))
	result.opening_coin_winner_idx = int(payload.get(
		"opening_coin_winner_idx", result.first_player_idx))
	result.mulligan_bonus_max = int(payload.get("mulligan_bonus_max", 0))
	result.public_deck_keys.assign(payload.get("public_deck_keys", ["", ""]))
	var own := _player_from_payload(payload.get("your", {}), true)
	var opponent := _player_from_payload(payload.get("opponent", {}), false)
	result.players[0] = own if player_idx == 0 else opponent
	result.players[1] = opponent if player_idx == 0 else own
	return result


static func _player_from_payload(payload: Dictionary, show_hand: bool) -> PlayerState:
	var row := payload.duplicate(true)
	row["deck"] = _hidden_cards(int(payload.get("deck_count", 0)))
	row["prizes"] = _hidden_cards(int(payload.get("prize_count", 0)))
	if not show_hand:
		row["hand"] = _hidden_cards(int(payload.get("hand_count", 0)))
	return PlayerState.from_dict(row)


static func _hidden_cards(count: int) -> Array[String]:
	var result: Array[String] = []
	# ProtocolV6 rejects out-of-range counts before deserialization. Keep this
	# defensive cap so direct callers can never allocate from an untrusted count.
	result.resize(clampi(count, 0, ProtocolV6.MAX_DECK_CARDS))
	result.fill("")
	return result
