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
	_check_prefetch_privacy(state)
	_check_event_batch_ownership(view)
	print("VIEW_MODEL_OWNERSHIP_OK")
	quit(0)


func _check_prefetch_privacy(state: GameState) -> void:
	state.players[0].hand = ["own-visible"]
	state.players[1].hand = ["opponent-secret"]
	state.players[0].deck = ["deck-secret"]
	state.players[1].prizes = ["prize-secret"]
	state.players[1].active = PokemonState.new("setup-secret")
	state.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	# Borrowed captures can contain full state; the art collector must still enforce privacy.
	var view := BattleViewModel.capture(state, 0, [], "", false, "local")
	var ids := view.visible_card_ids()
	assert("own-visible" in ids)
	for secret in ["opponent-secret", "deck-secret", "prize-secret", "setup-secret"]:
		assert(secret not in ids, "Hidden identity crossed the prefetch boundary: " + secret)
	ids.clear()
	assert("own-visible" in view.visible_card_ids(), "Art collector exposes mutable snapshot arrays")
	state.setup_stage = GameState.SETUP_COMPLETE
	view = BattleViewModel.capture(state, 0, [], "", false, "local")
	assert("setup-secret" in view.visible_card_ids(), "Public board art is missing after setup")


func _check_event_batch_ownership(view: BattleViewModel) -> void:
	var raw := [{"event_type": "cards_drawn", "actor": 0,
		"data": {"player": 0, "cards": ["own-visible"], "purpose": "turn_draw", "turn": 2}},
		{"event_type": "turn_start", "actor": 0, "data": {"turn": 2}},
		{"event_type": "cards_drawn", "actor": 1,
		"data": {"player": 1, "cards": ["opponent-secret"]}}]
	var request := BattleTransitionRequest.create(view, raw)
	assert(request.events[0].event_type == "turn_start", "Turn draw precedes its announcement")
	assert(request.events[1].data.card_ids == ["own-visible"])
	assert(request.events[2].data.card_ids.is_empty(), "Hidden draw reached presentation workers")
	assert(raw[2].data.cards == ["opponent-secret"], "Filtering mutated authoritative events")
	raw[0].data.cards.clear()
	assert(request.events[1].data.card_ids == ["own-visible"], "Queued events alias their caller")
	assert(not PresentationEvent.is_supported_event_type("card_discarded"))
	assert(not PresentationEvent.is_supported_event_type("knockout_effect_applied"))
