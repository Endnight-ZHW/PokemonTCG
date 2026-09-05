extends SceneTree

func _initialize() -> void:
	var state := UIPreviewStateFactory.battle_state()
	state.players[1].hand = ["sv1-ener-3"]
	var view := BattleViewModel.capture_player_view(state, 0, [], "", false, "local")
	var captured := view.state_for_render()
	assert(captured.players[1].hand == [""], "Opponent hand crossed the render boundary")
	assert(captured.players[0].deck[0] == "", "Deck order crossed the render boundary")
	var original_hand := captured.players[0].hand.duplicate()
	state.players[0].hand.clear()
	state.players[0].active.damage_counters += 5
	assert(view.state_for_render().players[0].hand == original_hand, "Queued view aliases live state")
	assert(view.state_for_render().players[0].active.damage_counters == captured.players[0].active.damage_counters,
		"Queued Pokemon aliases live state")
	captured.players[0].hand.clear()
	captured.players[0].active.energy_card_ids.clear()
	assert(view.state_for_render().players[0].hand == original_hand, "Render consumer mutated the queued view")
	assert(not view.state_for_render().players[0].active.energy_card_ids.is_empty(), "Render Pokemon aliases queued state")
	var borrowed := BattleViewModel.capture(state, 0, [], "", false, "local")
	state.players[0].active.damage_counters += 7
	assert(borrowed.state_for_render().players[0].active.damage_counters != state.players[0].active.damage_counters,
		"Borrowed capture stopped owning a snapshot")
	print("VIEW_MODEL_OWNERSHIP_OK")
	quit(0)
