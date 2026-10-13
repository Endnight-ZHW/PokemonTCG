extends SceneTree

var failures: Array[String] = []

func check(value: bool, message: String) -> void:
	if not value:
		failures.append(message)
		push_error(message)

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var catalog := CardCatalog.shared()
	var controller := NetworkMatchController.new()
	var definition := {"name": "private name", "profile": "casual60", "cards": [
		{"card_id": "csv5-014", "count": 4}, {"card_id": "sv1-ener-2", "count": 56}]}
	var payload := {"deck_key": "custom", "deck_definition": definition, "deck_digest": DeckLibrary.deck_digest(definition),
		"rules_version": AppState.RULES_SCHEMA_VERSION, "action_version": AppState.ACTION_SCHEMA_VERSION,
		"rules_profile_id": GameState.RULES_PROFILE_ID, "rules_options": {"apply_type_matchups": false},
		"core_fingerprint": controller._core_fingerprint()}
	var received := controller._receive_selection(payload)
	check(not received.is_empty() and received.definition.name == "自定义卡组", "Host rejected valid unimported custom deck")
	for bad_kind in ["size", "unknown", "count", "digest", "preset"]:
		var bad := payload.duplicate(true)
		match bad_kind:
			"size": bad.deck_definition.cards[1].count = 55
			"unknown": bad.deck_definition.cards[0].card_id = "unknown-card"
			"count": bad.deck_definition.cards[0].count = 4.5
			"preset": bad.deck_key = "fire"
		bad.deck_digest = "0".repeat(64) if bad_kind == "digest" else DeckLibrary.deck_digest(bad.deck_definition)
		check(controller._receive_selection(bad).is_empty(), "Host accepted invalid deck: " + bad_kind)
	controller.host = true
	controller.player_idx = 0
	controller.room_id = "custom-resume"
	controller.transport = FakeNetworkTransport.new()
	controller.session = AuthoritativeSession.new(controller.room_id)
	var own := controller._freeze_selection("fire")
	check(controller.session.start_frozen_match(own,received,1234,0).success, "Frozen custom network match failed")
	controller.remote_deck_key = "custom"
	controller.remote_deck_digest = received.digest
	controller.connection_phase = NetworkMatchController.ConnectionPhase.LOBBY
	var replacement := payload.duplicate(true)
	replacement.resume = true
	replacement.deck_definition.cards[0].card_id = "csv5-046"
	replacement.deck_digest = DeckLibrary.deck_digest(replacement.deck_definition)
	controller._handle_host_message({},ProtocolV7.DECK_SELECT,replacement)
	check(controller.transport.sent_messages.back().payload.get("code") == "resume_mismatch", "Reconnect allowed changing cards")
	var bad_fingerprint := payload.duplicate(true)
	bad_fingerprint.core_fingerprint = "0".repeat(64)
	controller._handle_host_message({},ProtocolV7.DECK_SELECT,bad_fingerprint)
	check(controller.transport.sent_messages.back().payload.get("code") == "schema_mismatch", "Mismatched card pool accepted")
	var resume := payload.duplicate(true)
	resume.resume = true
	controller._handle_host_message({},ProtocolV7.DECK_SELECT,resume)
	check(controller.connection_phase == NetworkMatchController.ConnectionPhase.PLAYING, "Original frozen custom deck could not resume")
	var old := ProtocolV7.envelope(ProtocolV7.PING,"old",0,1)
	old.protocol_version = 6
	check(ProtocolV7.validate(old).get("code") == "protocol_mismatch", "Protocol 6 was accepted")
	for viewer in [0,1]:
		var view := JSON.stringify(controller.session.view_for(viewer))
		check("private name" not in view and "deck_definition" not in view and "deck_digest" not in view, "Network view leaked custom definition")
	controller.close()
	var state := GameState.new()
	state.phase = "MAIN"
	state.turn_number = 3
	state.setup_stage = GameState.SETUP_COMPLETE
	state.public_deck_keys = ["fire","custom"]
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[1].active = PokemonState.new("csv5-014")
	state.players[0].hand.assign(["sv1-ener-2", "sv1-150"])
	for player in state.players:
		player.deck.assign(catalog.expand_deck("fire").slice(0,20))
		player.prizes.assign(["sv1-ener-2", "sv1-ener-2", "sv1-ener-2", "sv1-ener-2", "sv1-ener-2", "sv1-ener-2"])
	state.players[1].hand.assign(["csv5-075","csv5-119"])
	var native_a: Variant = ClassDB.instantiate("NativeRulesSession")
	var native_b: Variant = ClassDB.instantiate("NativeRulesSession")
	for native in [native_a,native_b]: check(native.set_catalog(catalog.native_rules_catalog()), "Privacy catalog rejected")
	check(native_a.load_scenario(state.snapshot(),719,{"private_deck_definitions":[{},definition]}).success, "Privacy first scenario rejected")
	state.players[1].hand.assign(["csv5-014","csv5-128"])
	state.players[1].deck.reverse()
	state.players[1].deck[0] = "csv5-129"
	state.players[1].prizes[0] = "csv5-001"
	check(native_b.load_scenario(state.snapshot(),719,{"private_deck_definitions":[{},replacement.deck_definition]}).success, "Privacy second scenario rejected")
	var observation_a: Dictionary = native_a.ai_observation_for(0)
	var observation_b: Dictionary = native_b.ai_observation_for(0)
	check(observation_a == observation_b, "Hidden deck/hand/order changed AI observation")
	var query := LegalActionQueryResult.from_dict(native_a.legal_actions(0))
	var actions: Array = []
	for candidate in query.concrete_actions(): actions.append(candidate.to_dict())
	var request := {"kind":"action","state":observation_a,"actor":0,"revision":0,"request_id":"privacy", "deck_key":"fire",
		"mode":"challenge","match_instance_id":"privacy-fixed", "seed":71,"deterministic":true,"internal_evaluation_smoke":true,"actions":actions}
	var decision_a := ChallengeAIClient.new().decide(request,Callable())
	request.state = observation_b
	var decision_b := ChallengeAIClient.new().decide(request,Callable())
	check(decision_a.get("success",false) and decision_b.get("success",false), "Unknown deck AI failed: " + str(decision_a.get("error")))
	check(decision_a.get("action") == decision_b.get("action"), "Hidden cards changed deterministic AI decision")
	if failures.is_empty(): print("CUSTOM_DECK_PRIVACY_CONTRACT_OK")
	quit(0 if failures.is_empty() else 1)
