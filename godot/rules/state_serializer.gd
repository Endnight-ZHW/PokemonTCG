class_name StateSerializer
extends RefCounted


static func for_player(state: GameState, player_idx: int) -> Dictionary:
	var own := _player_payload(state.players[player_idx], true)
	var opponent := _player_payload(state.players[1 - player_idx], false)
	return {
		"phase": state.phase,
		"turn_number": state.turn_number,
		"active_player_idx": state.active_player_idx,
		"first_player_idx": state.first_player_idx,
		"revision": state.revision,
		"stadium_card_id": state.stadium_card_id,
		"winner": state.winner,
		"public_deck_keys": state.public_deck_keys.duplicate(),
		"apply_type_matchups": state.apply_type_matchups,
		"action_log": state.action_log.duplicate(),
		"mulligan_count": state.mulligan_count.duplicate(),
		"extra_draws": state.extra_draws.duplicate(),
		"setup_ready": state.setup_ready.duplicate(),
		"pending_promotions": state.pending_promotions.duplicate(),
		"your": own,
		"opponent": opponent,
	}


static func _player_payload(player: PlayerState, show_hand: bool) -> Dictionary:
	var payload := player.to_dict()
	payload["hand_count"] = player.hand.size()
	payload["deck_count"] = player.deck.size()
	payload["prize_count"] = player.prizes.size()
	payload.erase("deck")
	payload.erase("prizes")
	if not show_hand:
		payload.erase("hand")
	return payload


static func from_player_view(payload: Dictionary, player_idx: int) -> GameState:
	var result := GameState.new()
	result.phase = str(payload.get("phase", "SETUP"))
	result.turn_number = int(payload.get("turn_number", 0))
	result.active_player_idx = int(payload.get("active_player_idx", 0))
	result.first_player_idx = int(payload.get("first_player_idx", 0))
	result.revision = int(payload.get("revision", 0))
	result.stadium_card_id = str(payload.get("stadium_card_id", ""))
	result.winner = int(payload.get("winner", -1))
	result.apply_type_matchups = bool(payload.get("apply_type_matchups", false))
	result.action_log.assign(payload.get("action_log", []))
	result.pending_promotions.assign(payload.get("pending_promotions", []))
	result.mulligan_count.assign(payload.get("mulligan_count", [0, 0]))
	result.extra_draws.assign(payload.get("extra_draws", [0, 0]))
	result.setup_ready.assign(payload.get("setup_ready", [false, false]))
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
	result.resize(maxi(0, count))
	result.fill("")
	return result
