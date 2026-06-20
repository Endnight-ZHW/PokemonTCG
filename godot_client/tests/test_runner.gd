extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	_run_phase_zero_tests()
	_run_phase_one_tests()
	_run_phase_two_tests()
	_run_phase_three_tests()

	if failures.is_empty():
		print("GODOT_TESTS_OK phase=3")
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
	ui._show_deck_select()
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
