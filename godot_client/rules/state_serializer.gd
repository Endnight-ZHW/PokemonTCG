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
		"apply_type_matchups": state.apply_type_matchups,
		"action_log": state.action_log.duplicate(),
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
