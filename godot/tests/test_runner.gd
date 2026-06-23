extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	_run_phase_zero_tests()
	_run_phase_one_tests()
	_run_phase_two_tests()
	_run_phase_three_tests()
	_run_phase_four_foundation_tests()
	_run_phase_five_foundation_tests()
	_run_phase_six_foundation_tests()
	_run_visual_upgrade_tests()

	if failures.is_empty():
		print("GODOT_TESTS_OK phase=6")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _run_phase_zero_tests() -> void:
	_check(
		Engine.get_version_info().get("major", 0) == 4
		and Engine.get_version_info().get("minor", 0) == 7,
		"Godot runtime must be 4.7",
	)
	_check(ProjectSettings.get_setting("rendering/renderer/rendering_method") == "gl_compatibility",
		"Compatibility renderer must be enabled")
	_check(ProjectSettings.get_setting("display/window/handheld/orientation") == 0,
		"Android orientation must be landscape")
	_check(ProjectSettings.get_setting("display/window/stretch/aspect") == "expand",
		"Window stretch aspect must support wide mobile displays")
	_check(FileAccess.file_exists("res://scenes/main/main.tscn"), "Main scene is missing")
	_check(FileAccess.file_exists("res://export_presets.cfg"), "Export presets are missing")


func _run_phase_one_tests() -> void:
	var cards := _read_json("res://data/cards.json")
	var decks := _read_json("res://data/decks.json")
	var buckets := _read_json("res://data/card_buckets.json")
	var fixture := _read_json("res://tests/fixtures/data_contract.json")
	var models := _read_json("res://data/ai_models.json")

	_check(cards.size() == 115, "Expected 115 exported cards")
	_check(decks.size() == 8, "Expected 8 exported decks")
	_check(fixture.get("counts", {}).get("effects", 0) == 72, "Expected 72 effect types")
	for deck_key in decks:
		_check(decks[deck_key].get("card_count", 0) == 60, "Deck %s must contain 60 cards" % deck_key)
	_check(models.get("models", {}).size() == 8, "Expected 8 Deep AI model manifest rows")
	_check(models.get("state_numeric_size", 0) == 960, "Deep AI state size mismatch")
	_check(models.get("state_card_slots", 0) == 96, "Deep AI card slot count mismatch")
	_check(models.get("action_numeric_size", 0) == 178, "Deep AI action size mismatch")

	for card_id in fixture.get("card_bucket_samples", {}):
		_check(
			int(buckets.get(card_id, 0)) == int(fixture["card_bucket_samples"][card_id]),
			"Card bucket mismatch for %s" % card_id,
		)

	var random_source := PortableRandomSource.new(int(fixture["portable_rng"]["seed"]))
	for expected in fixture["portable_rng"]["uint32"]:
		_check(random_source.next_u32() == int(expected), "Portable RNG sequence mismatch")

	var source_ref := EntityRef.new("card", 0, "hand", "", 2, "", "svi-chim")
	var target_ref := EntityRef.new("pokemon", 0, "", "bench_0", -1, "", "svi-chim")
	var action := GameAction.new(
		"PLAY_BASIC",
		{"hand_idx": 2, "target": "bench_0"},
		false,
		0,
		source_ref,
		target_ref,
		"action-1",
	)
	var restored_action := GameAction.from_dict(action.to_dict())
	_check(restored_action.to_dict() == action.to_dict(), "GameAction roundtrip failed")

	var request := ChoiceRequest.new(
		"choice:1",
		"select_bench",
		0,
		"选择备战宝可梦",
		[{"option_id": "bench:0", "label": "小火焰猴", "ref": target_ref.to_dict()}],
		1,
		1,
		false,
		false,
		{"revision": 4},
	)
	var restored_request := ChoiceRequest.from_dict(request.to_dict())
	_check(restored_request.to_dict() == request.to_dict(), "ChoiceRequest roundtrip failed")

	var state := GameState.new()
	state.turn_number = 3
	state.phase = "MAIN"
	state.revision = 4
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].hand = ["sv1-ener-2"]
	var restored_state := GameState.from_dict(state.snapshot())
	_check(restored_state.to_dict() == state.to_dict(), "GameState snapshot roundtrip failed")

	_check(
		FileAccess.file_exists("res://assets/cards/card_back.webp"),
		"Card back asset was not exported",
	)
	for card_id in cards:
		var image_path := str(cards[card_id].get("image_path", ""))
		_check(not image_path.is_empty(), "Missing image mapping for %s" % card_id)
		_check(FileAccess.file_exists(image_path), "Missing card image for %s" % card_id)


func _run_phase_two_tests() -> void:
	var fixture := _read_json("res://tests/fixtures/data_contract.json")
	var catalog := CardCatalog.new()
	var engine := GameEngine.new(catalog)
	var effect_types: Array = fixture.get("effect_types", [])
	_check(effect_types.size() == 72, "Expected 72 exported effect type names")
	for effect_type in effect_types:
		_check(
			engine.effect_engine.supports_effect_type(str(effect_type)),
			"Unsupported effect type: %s" % effect_type,
		)
	_run_effect_examples(fixture, catalog, engine)
	_run_python_golden_actions(engine)
	_run_release_deck_playouts(catalog, engine)

	var stack := ResolutionStack.new()
	stack.context = {"finish_attack": true, "actor": 0}
	stack.push_effect({"effect_type": "draw", "params": {"amount": 1}}, 0, "active")
	var restored_stack := ResolutionStack.from_dict(stack.to_dict())
	_check(restored_stack.to_dict() == stack.to_dict(), "ResolutionStack roundtrip failed")

	var hidden_state := GameState.new()
	hidden_state.players[0].hand = ["sv1-104"]
	hidden_state.players[0].deck = ["sv1-ener-5"]
	hidden_state.players[0].prizes = ["sv1-104"]
	hidden_state.players[1].hand = ["sv1-104", "sv1-104"]
	hidden_state.players[1].deck = ["sv1-ener-5", "sv1-ener-5"]
	hidden_state.players[1].prizes = ["sv1-104"]
	var player_view := StateSerializer.for_player(hidden_state, 0)
	_check(player_view["your"].has("hand"), "Own hand must be visible")
	_check(not player_view["your"].has("deck"), "Own deck identities leaked")
	_check(not player_view["your"].has("prizes"), "Own prize identities leaked")
	_check(not player_view["opponent"].has("hand"), "Opponent hand leaked")
	_check(not player_view["opponent"].has("deck"), "Opponent deck leaked")
	_check(not player_view["opponent"].has("prizes"), "Opponent prizes leaked")
	_check(player_view["opponent"]["hand_count"] == 2, "Opponent hand count mismatch")

	var action_state := _battle_state()
	var attach := GameAction.new(
		"ATTACH_ENERGY",
		{"hand_idx": 0, "target_slot": "active"},
		false,
		0,
		EntityRef.new("card", 0, "hand", "", 0, "", "sv1-ener-5"),
		EntityRef.new("pokemon", 0, "", "active", -1, "", "sv1-104"),
		"attach-1",
	)
	var attach_result := engine.apply_action(
		action_state, attach, PortableRandomSource.new(12))
	_check(attach_result.success, "Energy attachment failed: %s" % attach_result.message)
	_check(action_state.players[0].active.energy_card_ids == ["sv1-ener-5"],
		"Energy attachment state mismatch")
	var duplicate_result := engine.apply_action(
		action_state, attach, PortableRandomSource.new(12))
	_check(
		not duplicate_result.success and duplicate_result.error_code == "duplicate_action",
		"Duplicate action ID was not rejected",
	)

	var attack := GameAction.new(
		"DECLARE_ATTACK",
		{"attack_idx": 0},
		true,
		0,
		EntityRef.new("pokemon", 0, "", "active", -1, "", "sv1-104"),
		null,
		"attack-1",
	)
	var attack_result := engine.apply_action(
		action_state, attack, PortableRandomSource.new(13))
	_check(attack_result.success, "Attack failed: %s" % attack_result.message)
	_check(action_state.players[1].active.damage_counters == 1,
		"Attack damage mismatch")
	_check(action_state.active_player_idx == 1 and action_state.turn_number == 3,
		"Attack did not finish the turn atomically")

	var choice_state := _battle_state()
	choice_state.players[0].hand = ["sv1-151"]
	choice_state.players[0].deck = ["sv1-ener-5", "sv1-104"]
	var trainer := GameAction.new(
		"PLAY_TRAINER",
		{"hand_idx": 0},
		false,
		0,
		EntityRef.new("card", 0, "hand", "", 0, "", "sv1-151"),
		null,
		"trainer-1",
	)
	var trainer_result := engine.apply_action(
		choice_state, trainer, PortableRandomSource.new(14))
	_check(trainer_result.success, "Search trainer failed")
	_check(trainer_result.pending_choice != null, "Search trainer did not request a choice")
	if trainer_result.pending_choice:
		var request := trainer_result.pending_choice
		var response := ChoiceResponse.new(request.request_id, [request.options[0]["option_id"]])
		var choice_result := engine.apply_choice(
			choice_state, request, response, PortableRandomSource.new(15))
		_check(choice_result.success, "Search choice failed: %s" % choice_result.message)
		_check(choice_state.players[0].bench_count() == 1,
			"Search destination bench mismatch")

	var cancel_state := _battle_state()
	cancel_state.turn_number = 3
	cancel_state.first_player_idx = 0
	cancel_state.players[0].hand = ["svi-cait", "sv1-ener-5"]
	var cancel_action := GameAction.new(
		"PLAY_TRAINER",
		{"hand_idx": 0},
		false,
		0,
		EntityRef.new("card", 0, "hand", "", 0, "", "svi-cait"),
	)
	var cancel_step := engine.apply_action(
		cancel_state, cancel_action, PortableRandomSource.new(16))
	_check(cancel_step.pending_choice != null, "Cancellable trainer did not request choice")
	if cancel_step.pending_choice:
		var cancelled := engine.apply_choice(
			cancel_state,
			cancel_step.pending_choice,
			ChoiceResponse.new(cancel_step.pending_choice.request_id, [], true),
			PortableRandomSource.new(17),
		)
		_check(cancelled.success, "Trainer cancellation failed")
		_check(cancel_state.players[0].hand == ["svi-cait", "sv1-ener-5"],
			"Trainer cancellation did not restore the pre-action state")

	var self_ko_state := _battle_state()
	self_ko_state.turn_number = 3
	self_ko_state.first_player_idx = 0
	self_ko_state.players[0].active = PokemonState.new("sv2-starm")
	self_ko_state.players[0].active.placed_this_turn = false
	self_ko_state.players[0].bench[0] = PokemonState.new("svi-chim")
	self_ko_state.players[0].bench[0].placed_this_turn = false
	self_ko_state.players[0].hand.clear()
	var ability_name := str(
		catalog.get_card("sv2-starm").get("abilities", [])[0].get("name", ""))
	var self_ko_step := engine.apply_action(
		self_ko_state,
		GameAction.new(
			"USE_ABILITY",
			{"slot": "active", "ability_name": ability_name},
			false,
			0,
			EntityRef.new("pokemon", 0, "", "active", -1, "", "sv2-starm"),
		),
		PortableRandomSource.new(18),
	)
	_check(self_ko_step.pending_choice != null, "Self-KO ability did not request target")
	if self_ko_step.pending_choice:
		var self_ko_request := self_ko_step.pending_choice
		var self_ko_result := engine.apply_choice(
			self_ko_state,
			self_ko_request,
			ChoiceResponse.new(
				self_ko_request.request_id,
				[self_ko_request.options[0]["option_id"]],
			),
			PortableRandomSource.new(19),
		)
		_check(self_ko_result.success, "Self-KO ability choice failed")
		_check(self_ko_state.players[0].active == null,
			"Self-KO source remained in the active slot")
		_check("sv2-starm" in self_ko_state.players[0].discard,
			"Self-KO source was not discarded")
		_check(self_ko_state.players[1].prizes.size() == 0,
			"Opponent did not take a prize for self-KO")
		_check(0 in self_ko_state.pending_promotions,
			"Self-KO did not enqueue promotion")

	var setup_state := GameState.new()
	var deck_keys: Array = catalog.decks.keys()
	var deck_one := catalog.expand_deck(str(deck_keys[0]))
	var deck_two := catalog.expand_deck(str(deck_keys[1]))
	var setup_result := engine.setup_game(
		setup_state, deck_one, deck_two, PortableRandomSource.new(20260620))
	_check(setup_result.success, "Game setup failed: %s" % setup_result.message)
	_check(setup_state.players[0].hand.size() >= 7, "Player one opening hand missing")
	_check(setup_state.players[1].hand.size() >= 7, "Player two opening hand missing")
	_check(_contains_basic(setup_state.players[0].hand, catalog),
		"Player one opening hand has no Basic")
	_check(_contains_basic(setup_state.players[1].hand, catalog),
		"Player two opening hand has no Basic")


func _run_phase_three_tests() -> void:
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	_check(packed != null, "Main UI scene failed to load")
	if packed == null:
		return
	var ui := packed.instantiate()
	root.add_child(ui)
	ui.initialize_ui()
	_check(ui.current_screen == "title", "UI did not open on title screen")
	_check(ui.find_child("TitlePanel", true, false) != null, "Title panel is missing")
	var local_button := ui.find_child("LocalTwoPlayerButton", true, false) as Button
	_check(local_button != null, "Local two-player entry is missing")
	if local_button:
		_check(local_button.custom_minimum_size.y >= 48, "Touch target is below 48 px")
	ui.show_deck_select()
	_check(ui.current_screen == "decks", "Deck selection screen did not open")
	_check(ui.deck_one_option.item_count == 8, "Player one deck list must contain 8 decks")
	_check(ui.deck_two_option.item_count == 8, "Player two deck list must contain 8 decks")
	var started: bool = ui.start_local_match_for_test("fire", "water")
	_check(started, "UI could not start a local match")
	_check(ui.current_screen == "game", "Game screen did not open")
	_check(ui.state != null and ui.state.phase == "SETUP", "Local match is not in setup phase")
	_check(ui.modal_layer.visible, "Hot-seat privacy overlay is missing")
	_check(ui.find_child("BoardPanel", true, false) != null, "Board panel is missing")
	_check(ui.find_child("HandScroll", true, false) != null, "Hand area is missing")
	_check(ui.find_child("ActionList", true, false) != null, "Action list is missing")
	ui._close_modal()
	ui._refresh_game()
	_check(ui.action_list.get_child_count() > 0, "Setup actions were not rendered")
	var setup_actions: Array[GameAction] = ui.engine.legal_actions(ui.state, 0, false)
	var active_action: GameAction
	for candidate in setup_actions:
		if (
			candidate.action == "PLAY_BASIC"
			and candidate.params.get("target", "") == "active"
		):
			active_action = candidate
			break
	_check(active_action != null, "UI setup has no active placement action")
	if active_action:
		ui._execute_action(active_action)
		_check(ui.state.players[0].active != null, "UI action did not mutate rules state")
		_check(ui.action_list.get_child_count() > 0, "UI actions did not refresh")
	_run_local_ui_playout(ui)
	_check(ui.current_screen == "end", "Completed local UI match did not show end screen")
	var title_button := ui.find_child("TitleButton", true, false) as Button
	_check(title_button != null, "Victory screen title return button is missing")
	if title_button:
		title_button.pressed.emit()
		_check(
			ui.current_screen == "title",
			"Victory screen did not return to the title page",
		)
	ui.queue_free()

	var choice_ui := packed.instantiate()
	root.add_child(choice_ui)
	choice_ui.initialize_ui()
	var choice_state := _battle_state()
	choice_state.turn_number = 3
	choice_state.first_player_idx = 0
	choice_state.players[0].hand = ["sv1-151"]
	choice_state.players[0].deck = ["sv1-ener-5", "sv1-104"]
	choice_ui.state = choice_state
	choice_ui.current_view_player = 0
	choice_ui._build_game_screen()
	var trainer := GameAction.new(
		"PLAY_TRAINER",
		{"hand_idx": 0},
		false,
		0,
		EntityRef.new("card", 0, "hand", "", 0, "", "sv1-151"),
	)
	choice_ui._execute_action(trainer)
	_check(choice_ui.modal_layer.visible, "Choice overlay was not displayed")
	_check(choice_ui.active_request != null, "Choice overlay has no request")
	_check(choice_ui.option_buttons.size() > 0, "Choice overlay has no option buttons")
	choice_ui.queue_free()


func _run_phase_four_foundation_tests() -> void:
	var fixture := _read_json("res://tests/fixtures/ai_encoder_golden.json")
	var catalog := CardCatalog.new()
	var encoder := AIActionEncoder.new(catalog)
	var observation: Dictionary = fixture["observation"]
	var encoded_state := encoder.encode_observation(
		observation, str(fixture["deck_key"]))
	_check(
		_deep_equal(encoded_state["numeric"], fixture["expected"]["state_numeric"]),
		"AI state numeric encoder differs from Python",
	)
	_check(
		_deep_equal(encoded_state["card_ids"], fixture["expected"]["state_cards"]),
		"AI state card encoder differs from Python",
	)
	for index in range(fixture["actions"].size()):
		var action := GameAction.from_dict(fixture["actions"][index])
		var encoded := encoder.encode_action(
			observation, action, str(fixture["deck_key"]))
		_check(
			_deep_equal(encoded, fixture["expected"]["actions"][index]),
			"AI action encoder differs at index %d" % index,
		)
	var request := ChoiceRequest.from_dict(fixture["choice"])
	for index in range(request.options.size()):
		var encoded := encoder.encode_choice(
			observation, request, request.options[index], index)
		_check(
			_deep_equal(encoded, fixture["expected"]["choices"][index]),
			"AI choice encoder differs at index %d" % index,
		)

	var action_numeric: Array[float] = []
	var action_cards: Array[int] = []
	for row in fixture["expected"]["actions"]:
		action_numeric.append_array(row["numeric"])
		action_cards.append(int(row["card_id"]))
	var choice_numeric: Array[float] = []
	var choice_cards: Array[int] = []
	for row in fixture["expected"]["choices"]:
		choice_numeric.append_array(row["numeric"])
		choice_cards.append(int(row["card_id"]))
	var runtime := DeepAIRuntime.new()
	_check(runtime.is_available(), "ONNX Runtime GDExtension is unavailable")
	if runtime.is_available():
		for deck_key in [
			"fire", "water", "psychic", "lightning",
			"fighting", "colorless", "dragon", "grass",
		]:
			_check(runtime.load_for_deck(deck_key), (
				"Unable to load %s ONNX model: %s" % [deck_key, runtime.last_error]))
			var backend: Variant = runtime.get_backend()
			if backend == null:
				continue
			var inference: Dictionary = backend.call(
				"infer",
				PackedFloat32Array(fixture["expected"]["state_numeric"]),
				PackedInt64Array(fixture["expected"]["state_cards"]),
				PackedFloat32Array(action_numeric),
				PackedInt64Array(action_cards),
				PackedFloat32Array(choice_numeric),
				PackedInt64Array(choice_cards),
			)
			_check(inference.get("success", false), (
				"Native ONNX inference failed for %s: %s" % [
					deck_key, inference.get("error", "")]))
			_check(
				inference.get("action_logits", []).size() == fixture["actions"].size(),
				"Native ONNX action output size mismatch",
			)
			_check(
				inference.get("choice_logits", []).size() == request.options.size(),
				"Native ONNX choice output size mismatch",
			)
			_check(
				str(backend.call("get_execution_provider")) == "CPUExecutionProvider",
				"Native ONNX provider mismatch",
			)
		runtime.unload()
		var invalid_backend: Variant = ClassDB.instantiate("OnnxInference")
		_check(
			not invalid_backend.call("load_model", "res://data/ai_models/water.onnx", {
				"opset": 17,
				"state_numeric_size": 960,
				"state_card_slots": 96,
				"action_numeric_size": 178,
				"onnx_sha256": "invalid",
			}),
			"Native ONNX loader accepted an invalid SHA-256",
		)

	var state := _battle_state()
	state.active_player_idx = 0
	state.turn_number = 3
	state.phase = "MAIN"
	state.public_deck_keys = ["psychic", "water"]
	var engine := GameEngine.new(catalog)
	var actions := engine.legal_actions(state, 0, false)
	var action_rows: Array = []
	for action in actions:
		action_rows.append(action.to_dict())
	var ai_request := {
		"kind": "action",
		"state": state.snapshot(),
		"actor": 0,
		"revision": state.revision,
		"request_id": "deterministic",
		"mode": "challenge",
		"difficulty": "fast",
		"deck_key": "psychic",
		"seed": 77,
		"simulation_budget": 4,
		"max_depth": 3,
		"deterministic": true,
		"actions": action_rows,
	}
	var worker := NativeChallengeAI.new()
	var first := worker.decide(ai_request, func() -> bool: return false)
	var second := worker.decide(ai_request, func() -> bool: return false)
	_check(first.get("success", false), "Challenge AI did not return an action")
	_check(
		first.get("action", {}) == second.get("action", {}),
		"Challenge AI fixed-seed decision is not reproducible",
	)
	if runtime.is_available() and runtime.load_for_deck("psychic"):
		var deep_request: Dictionary = ai_request.duplicate(true)
		deep_request["mode"] = "deep"
		deep_request["max_depth"] = 1
		var deep_result := worker.decide(
			deep_request,
			func() -> bool: return false,
			runtime.get_backend(),
		)
		_check(deep_result.get("success", false), "Deep AI did not return an action")
		_check(
			int(deep_result.get("simulations", 0)) == 256,
			"Deep AI did not use the fixed 256 simulation budget",
		)
		_check(
			not deep_result.get("deep_fallback", true),
			"Deep AI unexpectedly fell back to Challenge AI",
		)
		runtime.unload()
		var fallback_result := worker.decide(
			deep_request,
			func() -> bool: return false,
			null,
		)
		_check(fallback_result.get("success", false),
			"Deep AI runtime fallback did not return an action")
		_check(
			fallback_result.get("deep_fallback", false)
			and fallback_result.get("fallback_reason", "") == "runtime_unavailable",
			"Deep AI runtime failure did not switch to standard Challenge AI",
		)
	var cancelled_result := worker.decide(
		ai_request,
		func() -> bool: return true,
	)
	_check(
		cancelled_result.get("cancelled", false),
		"Challenge AI search did not honor cancellation",
	)
	var choice_ai_request := {
		"kind": "choice",
		"state": state.snapshot(),
		"choice": request.to_dict(),
		"actor": request.player,
		"revision": state.revision,
		"request_id": "choice-fallback",
		"mode": "deep",
		"deck_key": "psychic",
	}
	var choice_fallback := worker.decide(
		choice_ai_request,
		func() -> bool: return false,
		null,
	)
	_check(
		choice_fallback.get("success", false)
		and choice_fallback.get("deep_fallback", false),
		"Deep AI choice failure did not use Challenge AI fallback",
	)
	var coordinator := AICoordinator.new()
	_check(
		coordinator.start_request(ai_request),
		"Challenge AI background coordinator did not start",
	)
	var background_result: Dictionary = {}
	var poll_count := 0
	while background_result.is_empty() and poll_count < 5000:
		poll_count += 1
		background_result = coordinator.poll_result()
		if background_result.is_empty():
			OS.delay_msec(1)
	_check(background_result.get("success", false), "Background AI did not finish")
	_check(poll_count > 0, "Background AI did not yield to the caller")
	coordinator.cancel_and_wait()

	var packed := load("res://scenes/main/main.tscn") as PackedScene
	var ai_ui := packed.instantiate()
	root.add_child(ai_ui)
	ai_ui.initialize_ui()
	var challenge_button := ai_ui.find_child("ChallengeAIButton", true, false) as Button
	var deep_button := ai_ui.find_child("DeepAIButton", true, false) as Button
	_check(challenge_button != null and not challenge_button.disabled,
		"Challenge AI menu entry is unavailable")
	_check(deep_button != null and not deep_button.disabled,
		"Deep AI menu entry is unavailable")
	ai_ui.show_deck_select("challenge")
	_check(ai_ui.difficulty_option.item_count == 3, "AI difficulty presets are missing")
	_check(
		ai_ui.start_ai_match_for_test(
			"challenge", "fire", "water", "fast", 0, 20260621),
		"Unable to start Challenge AI match",
	)
	_check(ai_ui.current_view_player == 0, "AI match exposed the AI player view")
	_check(ai_ui.state.players[1].name == "Challenge AI", "AI player name mismatch")
	ai_ui._stop_ai()
	ai_ui.queue_free()


func _run_phase_five_foundation_tests() -> void:
	var valid := ProtocolV3.envelope(
		ProtocolV3.ACTION_SUBMIT,
		"room-1",
		1,
		1,
		7,
		"action-1",
		"",
		{"action": {}},
	)
	_check(
		ProtocolV3.validate(valid, "room-1", 1, 0).get("ok", false),
		"Protocol v3 rejected a valid message",
	)
	var wrong_version: Dictionary = valid.duplicate(true)
	wrong_version["protocol_version"] = 2
	_check(
		ProtocolV3.validate(wrong_version).get("code", "") == "protocol_mismatch",
		"Protocol v3 accepted an incompatible client",
	)
	_check(
		ProtocolV3.validate(valid, "room-1", 1, 1).get("code", "") == "stale_sequence",
		"Protocol v3 accepted a duplicate sequence",
	)
	var gap: Dictionary = valid.duplicate(true)
	gap["sequence"] = 3
	_check(
		ProtocolV3.validate(gap, "room-1", 1, 1).get("code", "") == "sequence_gap",
		"Protocol v3 accepted a sequence gap",
	)
	_check(
		ProtocolV3.validate(valid, "room-1", 0, 0).get("code", "") == "wrong_sender",
		"Protocol v3 accepted a forged sender",
	)
	var unknown: Dictionary = valid.duplicate(true)
	unknown["message_type"] = "write_state_directly"
	_check(
		ProtocolV3.validate(unknown).get("code", "") == "unknown_message_type",
		"Protocol v3 accepted an unknown message type",
	)
	var oversized := ProtocolV3.envelope(
		ProtocolV3.PING,
		"room-1",
		1,
		1,
		-1,
		"",
		"",
		{"padding": "x".repeat(ProtocolV3.MAX_MESSAGE_BYTES)},
	)
	_check(
		ProtocolV3.validate(oversized).get("code", "") == "message_too_large",
		"Protocol v3 accepted an oversized payload",
	)

	var session := AuthoritativeSession.new("room-1")
	var started := session.start_match("fire", "water", 20260621, 0)
	_check(started.success, "Authoritative network session did not start")
	var host_view := session.view_for(0)
	var client_view := session.view_for(1)
	_check(
		not host_view["state"]["your"].has("deck")
		and not host_view["state"]["your"].has("prizes"),
		"Network state exposed the host deck or prize identities",
	)
	_check(
		not host_view["state"]["opponent"].has("hand")
		and not client_view["state"]["opponent"].has("hand"),
		"Network state exposed opponent hand identities",
	)
	var restored := StateSerializer.from_player_view(host_view["state"], 0)
	_check(
		restored.players[0].hand == session.state.players[0].hand,
		"Network player view lost the local hand",
	)
	_check(
		restored.players[1].hand.size() == session.state.players[1].hand.size()
		and restored.players[1].hand.all(func(card_id: String) -> bool:
			return card_id.is_empty()),
		"Network player view reconstructed hidden hand identities",
	)
	var legal: Array = host_view["legal_actions"]
	_check(not legal.is_empty(), "Authoritative session produced no setup action")
	if not legal.is_empty():
		var action: Dictionary = legal[0].duplicate(true)
		action["action_id"] = "network-action-1"
		var step := session.submit_action(0, action)
		_check(step.success, "Authoritative session rejected a legal action")
		var duplicate := session.submit_action(0, action)
		_check(
			not duplicate.success and duplicate.error_code == "duplicate_action",
			"Authoritative session accepted a duplicate action ID",
		)
		var forged: Dictionary = legal[0].duplicate(true)
		forged["actor"] = 1
		forged["action_id"] = "forged-action"
		_check(
			session.submit_action(0, forged).error_code == "wrong_actor",
			"Authoritative session accepted an action for another player",
		)

	var attack_controller := NetworkMatchController.new()
	var fake_transport := FakeNetworkTransport.new()
	attack_controller.host = true
	attack_controller.player_idx = 0
	attack_controller.room_id = "room-attack"
	attack_controller.transport = fake_transport
	attack_controller.session = AuthoritativeSession.new("room-attack")
	attack_controller.session.start_match("fire", "water", 99, 0)
	var stale_message := ProtocolV3.envelope(
		ProtocolV3.ACTION_SUBMIT,
		"room-attack",
		1,
		1,
		-1,
		"stale-action",
		"",
		{"action": {
			"action": "END_TURN",
			"params": {},
			"terminal": true,
			"actor": 1,
			"source": null,
			"target": null,
			"action_id": "stale-action",
		}},
	)
	attack_controller._handle_message(stale_message)
	_check(
		not fake_transport.sent_messages.is_empty()
		and fake_transport.sent_messages[0]["payload"].get("code", "")
		== "stale_revision",
		"Host accepted a stale state revision",
	)
	var choice_controller := NetworkMatchController.new()
	var choice_transport := FakeNetworkTransport.new()
	choice_controller.host = true
	choice_controller.player_idx = 0
	choice_controller.room_id = "room-choice"
	choice_controller.transport = choice_transport
	choice_controller.session = AuthoritativeSession.new("room-choice")
	choice_controller.session.start_match("fire", "water", 100, 0)
	var stack := ResolutionStack.new()
	stack.pending_request = ChoiceRequest.new(
		"choice:expected",
		"confirm",
		1,
		"确认",
		[{"option_id": "confirm:yes", "label": "是"}],
		1,
		1,
	)
	choice_controller.session.state.resolution_stack = stack.to_dict()
	var wrong_choice := ProtocolV3.envelope(
		ProtocolV3.CHOICE_SUBMIT,
		"room-choice",
		1,
		1,
		choice_controller.session.state.revision,
		"",
		"choice:forged",
		{"response": {
			"request_id": "choice:expected",
			"option_ids": ["confirm:yes"],
			"cancelled": false,
		}},
	)
	choice_controller._handle_message(wrong_choice)
	_check(
		not choice_transport.sent_messages.is_empty()
		and choice_transport.sent_messages[0]["payload"].get("code", "")
		== "request_id_mismatch",
		"Host accepted a forged request ID",
	)

	var host_transport := EnetTransport.new()
	var client_transport := EnetTransport.new()
	var port := 19000 + int(Time.get_ticks_msec() % 1000)
	_check(host_transport.start_host(port) == OK, "ENet host failed to start")
	_check(
		client_transport.start_client("127.0.0.1", port) == OK,
		"ENet client failed to start",
	)
	var transport_connected := false
	for _poll in range(5000):
		for event in host_transport.poll():
			if event.get("type", "") == "connected":
				transport_connected = true
		client_transport.poll()
		if transport_connected and client_transport.connected_state():
			break
		OS.delay_msec(1)
	_check(
		transport_connected and client_transport.connected_state(),
		"ENet host/client did not connect",
	)
	if transport_connected and client_transport.connected_state():
		var probe := ProtocolV3.envelope(
			ProtocolV3.PING, "room-1", 1, 1)
		_check(client_transport.send(probe), "ENet client failed to send")
		var received := false
		for _poll in range(1000):
			client_transport.poll()
			for event in host_transport.poll():
				if (
					event.get("type", "") == "message"
					and event.get("message", {}).get("message_type", "") == ProtocolV3.PING
				):
					received = true
			if received:
				break
			OS.delay_msec(1)
		_check(received, "ENet host did not receive the protocol packet")
	client_transport.close()
	host_transport.close()

	var host_match := NetworkMatchController.new()
	var client_match := NetworkMatchController.new()
	var match_port := port + 1
	_check(
		host_match.host_lan(match_port, "fire", 20260621) == OK,
		"LAN match host failed to start",
	)
	_check(
		client_match.join_lan("127.0.0.1", match_port, "water") == OK,
		"LAN match client failed to start",
	)
	var host_state_event: Dictionary = {}
	var client_state_event: Dictionary = {}
	for _poll in range(8000):
		for event in host_match.poll():
			if event.get("type", "") in ["error", "connection_failed", "transport_error"]:
				print("HOST_NETWORK_EVENT ", event)
			if event.get("type", "") == "state":
				host_state_event = event
		for event in client_match.poll():
			if event.get("type", "") in ["error", "connection_failed", "transport_error"]:
				print("CLIENT_NETWORK_EVENT ", event)
			if event.get("type", "") == "state":
				client_state_event = event
		if not host_state_event.is_empty() and not client_state_event.is_empty():
			break
		OS.delay_msec(1)
	_check(
		not host_state_event.is_empty() and not client_state_event.is_empty(),
		"LAN controllers did not complete the v3 lobby handshake",
	)
	if not host_state_event.is_empty() and not client_state_event.is_empty():
		var host_match_view: Dictionary = host_state_event["view"]
		var client_match_view: Dictionary = client_state_event["view"]
		_check(
			int(host_match_view["state"]["revision"])
			== int(client_match_view["state"]["revision"]),
			"LAN controllers disagreed on the initial revision",
		)
		var match_actions: Array = host_match_view.get("legal_actions", [])
		_check(not match_actions.is_empty(), "LAN host received no legal setup action")
		if not match_actions.is_empty():
			var match_action := GameAction.from_dict(match_actions[0])
			_check(host_match.submit_action(match_action), "LAN host action was not accepted")
			var updated_client_revision := -1
			for _poll in range(4000):
				host_match.poll()
				for event in client_match.poll():
					if event.get("type", "") == "state":
						updated_client_revision = int(event["view"]["state"]["revision"])
				if updated_client_revision > int(client_match_view["state"]["revision"]):
					break
				OS.delay_msec(1)
			_check(
				updated_client_revision > int(client_match_view["state"]["revision"]),
				"LAN client did not receive the authoritative action result",
			)
	client_match.close()
	host_match.close()

	var packed := load("res://scenes/main/main.tscn") as PackedScene
	var network_ui := packed.instantiate()
	root.add_child(network_ui)
	network_ui.initialize_ui()
	var lan_button := network_ui.find_child("LANButton", true, false) as Button
	var relay_button := network_ui.find_child("RelayButton", true, false) as Button
	_check(lan_button != null and not lan_button.disabled,
		"LAN menu entry is unavailable")
	_check(relay_button != null and not relay_button.disabled,
		"Relay menu entry is unavailable")
	network_ui.show_network_setup("lan")
	_check(
		network_ui.find_child("NetworkConnectButton", true, false) != null,
		"LAN lobby controls were not created",
	)
	network_ui.show_network_setup("relay")
	_check(
		network_ui.find_child("NetworkRoomInput", true, false) != null,
		"Relay room code input was not created",
	)
	network_ui.queue_free()


func _run_phase_six_foundation_tests() -> void:
	_check(AppState.APP_VERSION == "0.3.1", "Stage 6 app version mismatch")
	var settings: Node = root.get_node("AppSettings")
	var texture_cache: Node = root.get_node("CardTextureCache")
	var settings_path := "user://phase6_settings_test.cfg"
	settings.call("reset_defaults")
	settings.call("update", 0.35, true, true, 12, "reduced", "low", 0.4, 0.7)
	settings.set("relay_url", "wss://relay.example.test")
	_check(settings.call("save_settings", settings_path), "Unable to save runtime settings")
	settings.call("reset_defaults")
	_check(settings.call("load_settings", settings_path), "Unable to reload runtime settings")
	_check(is_equal_approx(float(settings.get("master_volume")), 0.35),
		"Master volume setting did not roundtrip")
	_check(bool(settings.get("muted")), "Mute setting did not roundtrip")
	_check(bool(settings.get("reduced_motion")), "Reduced motion setting did not roundtrip")
	_check(is_equal_approx(float(settings.get("music_volume")), 0.4),
		"Music volume setting did not roundtrip")
	_check(is_equal_approx(float(settings.get("sfx_volume")), 0.7),
		"SFX volume setting did not roundtrip")
	_check(str(settings.get("animation_mode")) == "reduced",
		"Animation mode setting did not roundtrip")
	_check(str(settings.get("quality_profile")) == "low",
		"Quality profile setting did not roundtrip")
	_check(int(settings.get("card_cache_size")) == 12,
		"Card cache setting did not roundtrip")
	_check(str(settings.get("relay_url")) == "wss://relay.example.test",
		"Relay URL setting did not roundtrip")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(settings_path))

	var cards := _read_json("res://data/cards.json")
	var image_paths: Array[String] = []
	for card_id in cards:
		var image_path := str(cards[card_id].get("image_path", ""))
		if not image_path.is_empty() and image_path not in image_paths:
			image_paths.append(image_path)
		if image_paths.size() >= 13:
			break
	settings.set("card_cache_size", 12)
	texture_cache.call("clear")


	texture_cache.call("reset_stats")
	for image_path in image_paths:
		_check(texture_cache.call("get_texture", image_path) != null,
			"Unable to load cached card texture: %s" % image_path)
	var cache_stats: Dictionary = texture_cache.call("stats")
	_check(int(cache_stats.get("entries", 0)) <= 12,
		"Card texture cache exceeded its configured limit")
	if not image_paths.is_empty():
		texture_cache.call("get_texture", image_paths[-1])
	var final_cache_stats: Dictionary = texture_cache.call("stats")
	_check(int(final_cache_stats.get("hits", 0)) >= 1,
		"Card texture cache did not record a cache hit")
	texture_cache.call("clear")

	var packed := load("res://scenes/main/main.tscn") as PackedScene
	var release_ui := packed.instantiate()
	root.add_child(release_ui)
	release_ui.initialize_ui()
	var settings_button := release_ui.find_child("SettingsButton", true, false) as Button
	_check(settings_button != null, "Settings entry is missing from the title screen")
	release_ui.show_settings()
	_check(release_ui.find_child("MasterVolumeSlider", true, false) != null,
		"Master volume setting control is missing")
	_check(release_ui.find_child("MutedToggle", true, false) != null,
		"Mute setting control is missing")
	_check(release_ui.find_child("ReducedMotionToggle", true, false) != null,
		"Reduced motion setting control is missing")
	_check(release_ui.find_child("MusicVolumeSlider", true, false) != null,
		"Music volume setting control is missing")
	_check(release_ui.find_child("SFXVolumeSlider", true, false) != null,
		"SFX volume setting control is missing")
	_check(release_ui.find_child("AnimationModeOption", true, false) != null,
		"Animation mode setting control is missing")
	_check(release_ui.find_child("QualityProfileOption", true, false) != null,
		"Quality profile setting control is missing")
	_check(release_ui.find_child("CardCacheOption", true, false) != null,
		"Card texture cache setting control is missing")
	_check(release_ui.find_child("LoadingLayer", true, false) != null,
		"Release loading overlay is missing")
	release_ui._close_modal()
	release_ui.queue_free()

	settings.call("reset_defaults")
	texture_cache.call("clear")


func _run_visual_upgrade_tests() -> void:
	var seeded_state_a := UIPreviewStateFactory.battle_state(77)
	var seeded_state_b := UIPreviewStateFactory.battle_state(77)
	_check(
		seeded_state_a.turn_number == seeded_state_b.turn_number
		and seeded_state_a.players[1].active.damage_counters
		== seeded_state_b.players[1].active.damage_counters
		and seeded_state_a.players[1].deck.size()
		== seeded_state_b.players[1].deck.size(),
		"UI preview state factory is not reproducible for a fixed seed",
	)
	for path in [
		"res://ui/design_tokens.gd",
		"res://ui/game_theme.tres",
		"res://ui/card_view.tscn",
		"res://ui/zone_view.tscn",
		"res://ui/dialogs/settings_panel.tscn",
		"res://ui/dialogs/choice_panel.tscn",
		"res://ui/dialogs/privacy_panel.tscn",
		"res://ui/dialogs/pause_panel.tscn",
		"res://presentation/presentation_event.gd",
		"res://presentation/presentation_director.gd",
		"res://scenes/title/title_page.tscn",
		"res://scenes/decks/deck_select_page.tscn",
		"res://scenes/network/network_lobby_page.tscn",
		"res://scenes/battle/battle_screen.tscn",
		"res://scenes/end/victory_screen.tscn",
		"res://tools/ui_workbench.tscn",
	]:
		_check(FileAccess.file_exists(path), "Visual upgrade asset is missing: %s" % path)

	var main_scene := load("res://scenes/main/main.tscn") as PackedScene
	var main_preview := main_scene.instantiate()
	root.add_child(main_preview)
	var shell_animations := main_preview.find_child(
		"ShellAnimations", true, false
	) as AnimationPlayer
	_check(
		shell_animations != null
		and shell_animations.has_animation("modal_open")
		and shell_animations.has_animation("modal_close"),
		"Main shell does not expose editable modal open and close animations",
	)
	main_preview.free()

	var page_contracts := {
		"res://scenes/title/title_page.tscn": [
			"LocalTwoPlayerButton", "ChallengeAIButton", "SettingsButton",
		],
		"res://scenes/decks/deck_select_page.tscn": [
			"DeckOneOption", "DeckTwoOption", "StartButton",
		],
		"res://scenes/network/network_lobby_page.tscn": [
			"NetworkRoleOption", "NetworkAddressInput", "NetworkConnectButton",
		],
		"res://ui/dialogs/settings_panel.tscn": [
			"MasterVolumeSlider", "AnimationModeOption", "CardCacheOption",
		],
	}
	for scene_path in page_contracts:
		var page_scene := load(scene_path) as PackedScene
		_check(page_scene != null, "Editable page scene failed to load: %s" % scene_path)
		if page_scene == null:
			continue
		var page := page_scene.instantiate()
		root.add_child(page)
		for node_name in page_contracts[scene_path]:
			_check(
				page.find_child(node_name, true, false) != null,
				"Editable page contract is missing %s in %s" % [node_name, scene_path],
			)
		page.queue_free()

	var page_catalog := CardCatalog.new()
	var title_scene := load("res://scenes/title/title_page.tscn") as PackedScene
	var title_page := title_scene.instantiate()
	root.add_child(title_page)
	title_page.configure("Signal Test")
	var title_signals := {}
	title_page.mode_selected.connect(
		func(mode: String) -> void: title_signals["mode"] = mode
	)
	title_page.network_selected.connect(
		func(kind: String) -> void: title_signals["network"] = kind
	)
	title_page.settings_requested.connect(
		func() -> void: title_signals["settings"] = true
	)
	(title_page.find_child("LocalTwoPlayerButton", true, false) as Button).pressed.emit()
	(title_page.find_child("LANButton", true, false) as Button).pressed.emit()
	(title_page.find_child("SettingsButton", true, false) as Button).pressed.emit()
	_check(title_signals.get("mode", "") == "local",
		"Title page mode signal did not carry the selected mode")
	_check(title_signals.get("network", "") == "lan",
		"Title page network signal did not carry the transport kind")
	_check(bool(title_signals.get("settings", false)),
		"Title page settings signal was not emitted")
	title_page.queue_free()

	var deck_scene := load(
		"res://scenes/decks/deck_select_page.tscn"
	) as PackedScene
	var deck_page := deck_scene.instantiate()
	root.add_child(deck_page)
	deck_page.configure(page_catalog, "challenge")
	var deck_signal := {}
	deck_page.start_requested.connect(func(
		mode: String,
		first_key: String,
		second_key: String,
		difficulty: String,
		forced_first: int,
	) -> void:
		deck_signal.merge({
			"mode": mode,
			"first": first_key,
			"second": second_key,
			"difficulty": difficulty,
			"forced_first": forced_first,
		}, true)
	)
	(deck_page.find_child("StartButton", true, false) as Button).pressed.emit()
	_check(deck_signal.get("mode", "") == "challenge",
		"Deck page start signal did not carry the game mode")
	_check(not str(deck_signal.get("first", "")).is_empty(),
		"Deck page start signal omitted the first deck")
	_check(not str(deck_signal.get("second", "")).is_empty(),
		"Deck page start signal omitted the second deck")
	_check(deck_signal.get("difficulty", "") == "standard",
		"Deck page start signal omitted the selected difficulty")
	deck_page.queue_free()

	var network_scene := load(
		"res://scenes/network/network_lobby_page.tscn"
	) as PackedScene
	var network_page := network_scene.instantiate()
	root.add_child(network_page)
	network_page.configure(page_catalog, "relay", "wss://relay.example.test")
	network_page.role_option.select(1)
	network_page.refresh_fields(1)
	network_page.room_input.text = "ROOM42"
	var network_signal := {}
	network_page.connect_requested.connect(func(
		kind: String,
		role: String,
		address: String,
		port: int,
		room_code: String,
		deck_key: String,
	) -> void:
		network_signal.merge({
			"kind": kind,
			"role": role,
			"address": address,
			"port": port,
			"room": room_code,
			"deck": deck_key,
		}, true)
	)
	(network_page.find_child(
		"NetworkConnectButton", true, false
	) as Button).pressed.emit()
	_check(network_signal.get("kind", "") == "relay",
		"Network page signal did not carry the transport kind")
	_check(network_signal.get("role", "") == "client",
		"Network page signal did not carry the selected role")
	_check(network_signal.get("room", "") == "ROOM42",
		"Network page signal did not carry the room code")
	_check(not str(network_signal.get("deck", "")).is_empty(),
		"Network page signal omitted the selected deck")
	network_page.queue_free()

	var settings_scene := load(
		"res://ui/dialogs/settings_panel.tscn"
	) as PackedScene
	var settings_panel := settings_scene.instantiate()
	root.add_child(settings_panel)
	settings_panel.configure()
	settings_panel.master_volume_slider.value = 0.45
	settings_panel.muted_toggle.button_pressed = true
	var settings_signal := {}
	settings_panel.save_requested.connect(
		func(values: Dictionary) -> void: settings_signal.merge(values, true)
	)
	settings_panel.request_save()
	_check(
		is_equal_approx(float(settings_signal.get("master_volume", -1.0)), 0.45),
		"Settings panel save signal omitted the master volume",
	)
	_check(bool(settings_signal.get("muted", false)),
		"Settings panel save signal omitted the mute state")
	settings_panel.queue_free()

	var workbench_scene := load("res://tools/ui_workbench.tscn") as PackedScene
	_check(workbench_scene != null, "UI Workbench scene failed to load")
	if workbench_scene:
		var workbench := workbench_scene.instantiate()
		root.add_child(workbench)
		_check(
			workbench.find_child("PreviewHost", true, false) != null,
			"UI Workbench preview host is missing",
		)
		workbench.call("trigger_presentation", "victory")
		_check(
			workbench.find_child("VictoryScreen", true, false) != null,
			"UI Workbench victory trigger did not open the victory preview",
		)
		workbench.queue_free()

	var normalized := PresentationEvent.normalize({
		"event_type": "cards_drawn",
		"actor": 0,
		"visibility": "owner",
		"card_id": "sv1-104",
		"data": {
			"player": 0,
			"count": 1,
			"card_ids": ["sv1-104"],
		},
	}, 7, 0, 0)
	_check(str(normalized.get("event_id", "")).begins_with("presentation:7:0"),
		"Presentation event IDs are not deterministic")
	var owner_event := PresentationEvent.for_player(normalized, 0)
	var opponent_event := PresentationEvent.for_player(normalized, 1)
	_check(owner_event.get("card_id", "") == "sv1-104",
		"Presentation event hid the owner's drawn card")
	_check(opponent_event.get("card_id", "") == "",
		"Presentation event leaked an opponent drawn card")
	_check(opponent_event.get("data", {}).get("card_ids", []).is_empty(),
		"Presentation event leaked hidden card IDs")
	var legacy_draw := PresentationEvent.normalize({
		"event_type": "cards_drawn",
		"data": {"player": 0, "cards": ["sv1-104"]},
	}, 8, 0, 0)
	_check(legacy_draw.get("visibility", "") == PresentationEvent.OWNER,
		"Legacy draw events are not owner-only")
	_check(
		PresentationEvent.for_player(legacy_draw, 1).get("data", {}).get(
			"cards", []).is_empty(),
		"Legacy draw event leaked the opponent's card identity",
	)

	var packed := load("res://scenes/battle/battle_screen.tscn") as PackedScene
	_check(packed != null, "Battle screen scene failed to load")
	if packed:
		var battle := packed.instantiate()
		root.add_child(battle)
		battle.initialize_ui()
		var state := _battle_state()
		state.players[0].hand = [
			"sv1-104", "sv1-ener-5", "sv1-151", "sv1-189",
		]
		var engine := GameEngine.new(CardCatalog.new())
		var rows: Array[Dictionary] = []
		for action in engine.legal_actions(state, 0, true):
			rows.append({"action": action, "label": action.action})
		battle.update_view(state, 0, rows, "", false, "local")
		_check(
			battle.own_active != null
			and battle.own_active.card_id == state.players[0].active.card_id,
			"Battle screen did not bind the public active card",
		)
		_check(battle.hand_views.size() == 4,
			"Battle screen did not create stable hand card views")
		_check(battle.zones.size() == 7,
			"Battle screen does not expose every required tabletop zone")
		_check(battle.phase_advance_button != null,
			"Battle screen is missing the dedicated phase advance button")
		_check(not battle.quick_actions.is_visible_in_tree(),
			"Legacy right-side card action list is still visible")
		var first_hand: Variant = battle.hand_views[0]
		_check(first_hand.catalog == battle.catalog,
			"Battle cards do not reuse the shared card catalog")
		battle.update_view(state, 0, rows, "hand:3", false, "local")
		var trainer_view: Variant = battle.hand_views[3]
		_check(not trainer_view._pending_action_rows.is_empty(),
			"Direct trainer action was not placed on the selected card")
		battle.update_view(state, 0, rows, "", false, "local")
		first_hand.configure_target(0, "active")
		_check(first_hand._can_drop_data(Vector2.ZERO, {
			"kind": "hand_card",
			"hand_index": 0,
			"card_id": "sv1-104",
		}), "Card drag data is not accepted by a configured target")
		first_hand.set_targetable(true)
		var card_animation := first_hand.get_node(
			"AnimationPlayer"
		) as AnimationPlayer
		_check(
			card_animation.current_animation == "target_pulse",
			"Legal target highlight is not driven by AnimationPlayer",
		)
		first_hand.set_targetable(false)
		var node_count_before := battle.find_children("*", "", true, false).size()
		for _index in range(80):
			battle.update_view(state, 0, rows, "", false, "local")
		var node_count_after := battle.find_children("*", "", true, false).size()
		_check(node_count_after == node_count_before,
			"Repeated battle refreshes created persistent UI nodes")
		for _index in range(30):
			battle.effects.burst(Vector2(100, 100), Color.WHITE, "stress")
		_check(battle.effects.particles.size() <= 220,
			"Battle particles exceeded the Android safety cap")
		for _index in range(18):
			battle._on_card_motion_requested({
				"event_type": "cards_drawn",
				"actor": 0,
				"card_id": "sv1-104",
				"source": {"player": 0, "zone": "deck"},
				"target": {"player": 0, "zone": "hand"},
				"amount": 1,
			}, 0.5)
		_check(battle._active_flyers.size() <= 12,
			"Flying card animations exceeded the Android safety cap")
		battle._clear_transient_visuals()
		battle.free()

	var status_card_scene := load("res://ui/card_view.tscn") as PackedScene
	var status_card: Variant = status_card_scene.instantiate()
	var status_row := status_card.find_child(
		"StatusRow", true, false
	) as HBoxContainer
	status_card.status_row = status_row
	var status_pokemon := PokemonState.new("sv1-104")
	status_pokemon.status_conditions = ["POISONED"]
	status_card.pokemon = status_pokemon
	status_card._refresh_statuses()
	_check(
		status_row != null and status_row.get_child_count() == 1,
		"Card status badge was not created",
	)
	status_card.pokemon = null
	status_card._refresh_statuses()
	_check(
		status_row != null and status_row.get_child_count() == 0,
		"Reused card view retained stale status badges after becoming empty",
	)
	status_card.free()

	var runtime_settings: Node = root.get_node("AppSettings")
	_check(str(runtime_settings.get("animation_mode")) in [
		"cinematic", "standard", "fast", "reduced",
	],
		"Animation mode setting is invalid")
	_check(str(runtime_settings.call("resolved_quality_profile")) in [
		"high", "medium", "low",
	],
		"Quality profile did not resolve to a runtime tier")
	_check(int(runtime_settings.call("target_fps")) in [30, 60],
		"Performance profile returned an unsupported FPS target")


func _run_local_ui_playout(ui: Node) -> void:
	var action_count := 0
	while ui.state.winner < 0 and action_count < 1200:
		action_count += 1
		if ui.modal_layer.visible and ui.active_request == null:
			ui._close_modal()
		var actor: int = ui.state.active_player_idx
		if not ui.state.pending_promotions.is_empty():
			actor = int(ui.state.pending_promotions[0])
		elif ui.state.phase == "SETUP":
			actor = 0 if not ui.state.setup_ready[0] else 1
		ui.current_view_player = actor
		ui._refresh_game()
		var actions: Array[GameAction] = ui.engine.legal_actions(
			ui.state, actor, true)
		_check(not actions.is_empty(), (
			"Local UI playout has no legal action; phase=%s actor=%d active=%d "
			+ "ready=%s pending=%s stack=%s revision=%d"
		) % [
			ui.state.phase,
			actor,
			ui.state.active_player_idx,
			JSON.stringify(ui.state.setup_ready),
			JSON.stringify(ui.state.pending_promotions),
			JSON.stringify(ui.state.resolution_stack),
			ui.state.revision,
		])
		if actions.is_empty():
			break
		var previous_revision: int = ui.state.revision
		var step: StepResult = ui._execute_action(_playout_action(actions))
		_check(step.success, "Local UI action failed: %s" % step.message)
		if not step.success:
			break
		_check(
			ui.state.revision > previous_revision,
			"Local UI action did not advance state revision",
		)
		if ui.state.revision <= previous_revision:
			break
		var choice_guard := 0
		while ui.active_request != null and choice_guard < 32:
			choice_guard += 1
			var request: ChoiceRequest = ui.active_request
			ui.selected_choice_ids.clear()
			for choice_index in range(request.min_select):
				if request.options.is_empty():
					break
				var option_index: int = (
					choice_index % request.options.size()
					if request.allow_duplicates
					else min(choice_index, request.options.size() - 1)
				)
				ui.selected_choice_ids.append(str(
					request.options[option_index]["option_id"]))
			ui._confirm_choice()
		_check(choice_guard < 32, "Local UI choice chain exceeded guard")
	_check(action_count < 1200, "Local UI playout exceeded action guard")
	_check(ui.state.winner >= 0, "Local UI playout did not terminate")


func _battle_state() -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.turn_number = 2
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[0].active.placed_this_turn = false
	state.players[0].hand = ["sv1-ener-5"]
	state.players[0].deck = ["sv1-ener-5", "sv1-ener-5"]
	state.players[0].prizes = ["sv1-ener-5"]
	state.players[1].active = PokemonState.new("sv1-104")
	state.players[1].active.placed_this_turn = false
	state.players[1].deck = ["sv1-ener-5", "sv1-ener-5"]
	state.players[1].prizes = ["sv1-ener-5"]
	return state


func _contains_basic(card_ids: Array[String], catalog: CardCatalog) -> bool:
	for card_id in card_ids:
		if catalog.is_basic_pokemon(card_id):
			return true
	return false


func _run_effect_examples(
	fixture: Dictionary,
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	var examples: Dictionary = fixture.get("effect_examples", {})
	_check(examples.size() == 72, "Expected one real example for every effect type")
	for effect_type in examples:
		var state := _effect_state()
		var stack := ResolutionStack.new()
		stack.push_effect(Dictionary(examples[effect_type]), 0, "active")
		var step := engine.effect_engine.resolve(
			state, stack, PortableRandomSource.new(20260620))
		_check(
			step.error_code not in ["unknown_effect", "unknown_continuation"],
			"Effect dispatch failed for %s: %s" % [effect_type, step.message],
		)
		var guard := 0
		while step.success and step.pending_choice and guard < 32:
			guard += 1
			var request := step.pending_choice
			var option_ids: Array[String] = []
			for index in range(request.min_select):
				if request.options.is_empty():
					break
				var option_index: int = (
					index % request.options.size()
					if request.allow_duplicates
					else min(index, request.options.size() - 1)
				)
				option_ids.append(str(request.options[option_index]["option_id"]))
			step = engine.effect_engine.apply_choice(
				state,
				ResolutionStack.from_dict(state.resolution_stack),
				ChoiceResponse.new(request.request_id, option_ids),
				PortableRandomSource.new(20260620 + guard),
			)
			_check(
				step.error_code not in ["unknown_effect", "unknown_continuation"],
				"Effect continuation failed for %s: %s" % [effect_type, step.message],
			)
		_check(guard < 32, "Effect choice chain exceeded guard for %s" % effect_type)
		if step.pending_choice:
			var saved := ResolutionStack.from_dict(state.resolution_stack)
			_check(
				saved.to_dict() == ResolutionStack.from_dict(saved.to_dict()).to_dict(),
				"Pending effect stack is not serializable for %s" % effect_type,
			)


func _effect_state() -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.turn_number = 3
	state.first_player_idx = 0
	state.active_player_idx = 0
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.damage_counters = 2
	state.players[0].active.energy_card_ids = ["sv1-ener-5", "sv1-ener-6"]
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[0].bench[0].placed_this_turn = false
	state.players[0].bench[1] = PokemonState.new("svf-rio")
	state.players[0].bench[1].placed_this_turn = false
	state.players[0].hand = [
		"sv1-ener-1", "sv1-ener-2", "sv1-ener-5", "svf-potion",
		"sv1-151", "svg2-tort", "svf-luca",
	]
	state.players[0].deck = [
		"sv1-104", "svi-chim", "svf-rio", "sv1-150", "sv1-201",
		"sv1-ener-1", "sv1-ener-2", "sv1-ener-3", "sv1-ener-4",
		"sv1-ener-5", "sv1-ener-6", "sv1-ener-8",
		"sv1-104", "svi-chim", "svf-rio", "sv1-150", "sv1-201",
		"sv1-ener-1", "sv1-ener-2", "sv1-ener-5",
	]
	state.players[0].discard = [
		"sv1-104", "svi-chim", "svf-rio", "sv1-ener-1",
		"sv1-ener-2", "sv1-ener-5",
	]
	state.players[0].prizes = ["sv1-ener-5", "sv1-ener-5", "sv1-ener-5"]
	state.players[1].active = PokemonState.new("sv1-104")
	state.players[1].active.placed_this_turn = false
	state.players[1].active.damage_counters = 1
	state.players[1].active.energy_card_ids = ["sv1-ener-5"]
	state.players[1].bench[0] = PokemonState.new("svi-chim")
	state.players[1].bench[0].placed_this_turn = false
	state.players[1].hand = ["sv1-ener-5", "sv1-104", "svf-potion"]
	state.players[1].deck = [
		"sv1-104", "svi-chim", "sv1-ener-1", "sv1-ener-2",
		"sv1-ener-3", "sv1-ener-4", "sv1-ener-5", "sv1-ener-6",
	]
	state.players[1].discard = ["sv1-104", "sv1-ener-5"]
	state.players[1].prizes = ["sv1-ener-5", "sv1-ener-5", "sv1-ener-5"]
	return state


func _run_python_golden_actions(engine: GameEngine) -> void:
	var fixture := _read_json("res://tests/fixtures/rules_golden.json")
	var cases: Dictionary = fixture.get("cases", {})
	_check(cases.size() == 3, "Expected three Python golden action cases")
	for case_name in cases:
		var row: Dictionary = cases[case_name]
		var state := GameState.from_dict(row["initial_state"])
		var action_index := 0
		for action_value in row.get("actions", []):
			var action_row: Dictionary = action_value
			var result := engine.apply_action(
				state,
				GameAction.new(
					str(action_row["action"]),
					Dictionary(action_row.get("params", {})),
					false,
					int(action_row.get("actor", -1)),
				),
				PortableRandomSource.new(700 + action_index),
			)
			_check(
				result.success,
				"Golden action %s[%d] failed: %s" % [
					case_name, action_index, result.message],
			)
			action_index += 1
		_check(
			_deep_equal(_rule_summary(state), row["expected"]),
			"Python/Godot rule mismatch for %s\nexpected=%s\nactual=%s" % [
				case_name,
				JSON.stringify(row["expected"]),
				JSON.stringify(_rule_summary(state)),
			],
		)


func _rule_summary(state: GameState) -> Dictionary:
	var payload := state.to_dict()
	payload.erase("action_log")
	payload.erase("resolution_stack")
	payload.erase("setup_ready")
	payload.erase("processed_action_ids")
	payload.erase("revision")
	return payload


func _deep_equal(left: Variant, right: Variant) -> bool:
	if (
		(left is int or left is float)
		and (right is int or right is float)
	):
		return is_equal_approx(float(left), float(right))
	if left is Dictionary and right is Dictionary:
		if left.size() != right.size():
			return false
		for key in left:
			if not right.has(key) or not _deep_equal(left[key], right[key]):
				return false
		return true
	if left is Array and right is Array:
		if left.size() != right.size():
			return false
		for index in range(left.size()):
			if not _deep_equal(left[index], right[index]):
				return false
		return true
	return left == right


func _run_release_deck_playouts(
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	var deck_keys: Array = catalog.decks.keys()
	deck_keys.sort()
	for index in range(deck_keys.size()):
		var first_key := str(deck_keys[index])
		var second_key := str(deck_keys[(index + 1) % deck_keys.size()])
		var state := GameState.new()
		var rng := PortableRandomSource.new(9000 + index)
		var setup := engine.setup_game(
			state,
			catalog.expand_deck(first_key),
			catalog.expand_deck(second_key),
			rng,
		)
		_check(setup.success, "Playout setup failed for %s vs %s" % [
			first_key, second_key])
		if not setup.success:
			continue
		for actor in [0, 1]:
			var setup_actions := engine.legal_actions(state, actor, false)
			var active_action: GameAction
			for candidate in setup_actions:
				if (
					candidate.action == "PLAY_BASIC"
					and candidate.params.get("target", "") == "active"
				):
					active_action = candidate
					break
			_check(active_action != null, "No setup Basic for %s" % first_key)
			if active_action:
				var placed := engine.apply_action(state, active_action, rng)
				_check(placed.success, "Setup placement failed: %s" % placed.message)
				var ready := engine.apply_action(
					state, GameAction.new("SETUP_DONE", {}, true, actor), rng)
				_check(ready.success, "Setup completion failed: %s" % ready.message)

		var action_count := 0
		while state.winner < 0 and action_count < 1200:
			action_count += 1
			var actions := engine.legal_actions(
				state,
				int(state.pending_promotions[0])
				if not state.pending_promotions.is_empty()
				else state.active_player_idx,
				true,
			)
			_check(not actions.is_empty(), (
				"No legal action during %s vs %s; phase=%s active=%d pending=%s stack=%s"
				% [
					first_key,
					second_key,
					state.phase,
					state.active_player_idx,
					JSON.stringify(state.pending_promotions),
					JSON.stringify(state.resolution_stack),
				]
			))
			if actions.is_empty():
				break
			var selected := _playout_action(actions)
			var step := engine.apply_action(state, selected, rng)
			_check(step.success, "Illegal enumerated action %s: %s" % [
				selected.action, step.message])
			if not step.success:
				break
			var choice_guard := 0
			while step.pending_choice and choice_guard < 32:
				choice_guard += 1
				var request := step.pending_choice
				var ids: Array[String] = []
				for choice_index in range(request.min_select):
					if request.options.is_empty():
						break
					var option_index: int = (
						choice_index % request.options.size()
						if request.allow_duplicates
						else min(choice_index, request.options.size() - 1)
					)
					ids.append(str(request.options[option_index]["option_id"]))
				step = engine.apply_choice(
					state,
					request,
					ChoiceResponse.new(request.request_id, ids),
					rng,
				)
				_check(step.success, "Playout choice failed: %s" % step.message)
				if not step.success:
					break
			_check(choice_guard < 32, "Playout choice chain exceeded guard")
		_check(state.winner >= 0, "Playout did not terminate: %s vs %s" % [
			first_key, second_key])


func _playout_action(actions: Array[GameAction]) -> GameAction:
	var priorities := [
		"PROMOTE",
		"PLAY_BASIC",
		"EVOLVE",
		"ATTACH_ENERGY",
		"USE_ABILITY",
		"PLAY_TRAINER",
		"USE_STADIUM",
		"RETREAT",
		"DECLARE_ATTACK",
		"END_TURN",
	]
	for action_name in priorities:
		for action in actions:
			if action.action == action_name:
				return action
	return actions[0]


func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_check(false, "Unable to open %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		_check(false, "Invalid dictionary JSON in %s" % path)
		return {}
	return parsed


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
