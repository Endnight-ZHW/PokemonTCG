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
	_check(not bool(ProjectSettings.get_setting(
		"gui/theme/default_font_multichannel_signed_distance_field", false)),
		"Default font MSDF must stay disabled for Android Compatibility text")
	_check(FileAccess.file_exists("res://scenes/main/main.tscn"), "Main scene is missing")
	_check(FileAccess.file_exists("res://export_presets.cfg"), "Export presets are missing")


func _run_phase_one_tests() -> void:
	var cards := _read_json("res://data/cards.json")
	var decks := _read_json("res://data/decks.json")
	var buckets := _read_json("res://data/card_buckets.json")
	var fixture := _read_json("res://tests/fixtures/data_contract.json")
	var models := _read_json("res://data/ai_models.json")

	_check(cards.size() == 137, "Expected 137 exported cards")
	_check(decks.size() == 10, "Expected 10 exported decks")
	_check(fixture.get("counts", {}).get("effects", 0) == 78, "Expected 78 effect types")
	for deck_key in decks:
		_check(decks[deck_key].get("card_count", 0) == 60, "Deck %s must contain 60 cards" % deck_key)
	_check(models.get("models", {}).size() == 8, "Expected 8 Deep AI model manifest rows")
	_check(models.get("state_numeric_size", 0) == 960, "Deep AI state size mismatch")
	_check(models.get("state_card_slots", 0) == 96, "Deep AI card slot count mismatch")
	_check(models.get("action_numeric_size", 0) == 178, "Deep AI action size mismatch")
	_check_release_effects_have_compiled_ir(cards)

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
	_check(effect_types.size() == 78, "Expected 78 exported effect type names")
	for effect_type in effect_types:
		_check(
			engine.effect_engine.supports_effect_type(str(effect_type)),
			"Unsupported effect type: %s" % effect_type,
		)
	var compiled_examples: Dictionary = fixture.get("compiled_effect_examples", {})
	_check(compiled_examples.size() == 78, "Expected one compiled example for every effect type")
	for effect_type in compiled_examples:
		_check(
			engine.effect_engine.supports_command_spec(Dictionary(compiled_examples[effect_type])),
			"Unsupported compiled effect spec: %s" % effect_type,
		)
	var raw_examples: Dictionary = fixture.get("effect_examples", {})
	_check(raw_examples.size() == 78, "Expected one raw metadata example for every effect type")
	for effect_type in raw_examples:
		var raw_effect := Dictionary(raw_examples[effect_type])
		_check(
			str(raw_effect.get("effect_type", "")) == str(effect_type),
			"Raw effect metadata key mismatch for %s" % effect_type,
		)
		_check(
			not engine.effect_engine.supports_command_spec(raw_effect),
			"Raw effect metadata must not be accepted as a VM command: %s" % effect_type,
		)
	var explicit_marker_ops := {
		"apply_outgoing_damage_reduction": "apply_outgoing_damage_reduction",
		"attack_lock_basic": "apply_attack_lock_basic",
		"dazzling_beam": "apply_dazzling_beam",
		"prevent_all": "prevent_all",
		"prevent_damage": "prevent_damage",
		"prevent_effects": "prevent_effects",
		"self_attack_lock": "apply_self_attack_lock",
	}
	for effect_type in explicit_marker_ops:
		var spec := Dictionary(compiled_examples.get(effect_type, {}))
		_check(
			str(spec.get("op", "")) == str(explicit_marker_ops[effect_type]),
			"Immediate marker effect did not compile to explicit op: %s" % effect_type,
		)
		_check(
			not Dictionary(spec.get("args", {})).has("effect_type"),
			"Immediate marker op still carries legacy effect_type args: %s" % effect_type,
		)
	var explicit_formula_ops := {
		"damage_per_discard_psychic": "deal_damage_per_discard_psychic",
		"damage_per_energy": "deal_damage_per_energy",
		"damage_per_evolved": "deal_damage_per_evolved",
		"damage_per_hand_size": "deal_damage_per_hand_size",
		"damage_per_self_damage": "deal_damage_per_self_damage",
		"damage_per_self_energy": "deal_damage_per_self_energy",
		"damage_per_self_energy_type": "deal_damage_per_self_energy_type",
		"damage_plus_bench": "deal_damage_plus_bench",
	}
	for effect_type in explicit_formula_ops:
		var spec := Dictionary(compiled_examples.get(effect_type, {}))
		_check(
			str(spec.get("op", "")) == str(explicit_formula_ops[effect_type]),
			"Damage formula effect did not compile to explicit op: %s" % effect_type,
		)
		_check(
			not Dictionary(spec.get("args", {})).has("effect_type"),
			"Damage formula op still carries legacy effect_type args: %s" % effect_type,
		)
	var wrapper_ops_without_effect_type := {
		"clara": "recover_clara",
		"coin_flip_double_ko": "flip_coin_then_ko",
		"coin_flip_energy_discard": "flip_coin_then_discard_energy",
		"coin_flip_triple": "flip_coin_repeat_damage",
		"coin_flip_until_tails": "flip_until_tails",
		"shuffle_from_discard": "shuffle_from_discard_to_deck",
		"switch_opponent": "switch_pokemon",
		"switch_self": "switch_pokemon",
		"tool": "register_tool_modifier",
	}
	for effect_type in wrapper_ops_without_effect_type:
		var spec := Dictionary(compiled_examples.get(effect_type, {}))
		_check(
			str(spec.get("op", "")) == str(wrapper_ops_without_effect_type[effect_type]),
			"Wrapper effect did not compile to expected op: %s" % effect_type,
		)
		_check(
			not Dictionary(spec.get("args", {})).has("effect_type"),
			"Wrapper op still carries legacy effect_type args: %s" % effect_type,
		)
	_check(
		str(Dictionary(compiled_examples["switch_self"]).get("args", {}).get("target", "")) == "self",
		"switch_self compiled IR must carry explicit target",
	)
	_check(
		str(Dictionary(compiled_examples["switch_opponent"]).get("args", {}).get("target", "")) == "opponent",
		"switch_opponent compiled IR must carry explicit target",
	)
	var explicit_modifier_ops := {
		"aura_damage_boost": "register_aura_damage_boost",
		"aura_damage_reduction": "register_aura_damage_reduction",
		"conditional_hp_boost": "register_conditional_hp_boost",
		"conditional_zero_retreat": "register_conditional_zero_retreat",
		"reactive_thorns": "register_reactive_thorns",
		"tool_exp_share": "register_tool_exp_share",
	}
	for effect_type in explicit_modifier_ops:
		var spec := Dictionary(compiled_examples.get(effect_type, {}))
		_check(
			str(spec.get("op", "")) == str(explicit_modifier_ops[effect_type]),
			"Modifier effect did not compile to explicit registration op: %s" % effect_type,
		)
		_check(
			not Dictionary(spec.get("args", {})).has("effect_type"),
			"Modifier registration op still carries legacy effect_type args: %s" % effect_type,
		)
	for effect_type in compiled_examples:
		var spec := Dictionary(compiled_examples[effect_type])
		_check(
			not Dictionary(spec.get("args", {})).has("effect_type"),
			"Compiled release IR still carries legacy effect_type args: %s" % effect_type,
		)
	_check(
		not engine.effect_engine.supports_command_spec({
			"op": "legacy_effect",
			"args": {"effect_type": "draw", "amount": 1},
			"branches": {},
		}),
		"Unknown compiled VM op must not be accepted through legacy effect_type fallback",
	)
	var retired_vm_ops := [
		"deal_damage_formula",
		"recover_from_discard",
		"register_modifier",
		"register_trigger",
	]
	for op in retired_vm_ops:
		_check(
			not engine.effect_engine.supports_command_spec({
				"op": op,
				"args": {},
				"branches": {},
			}),
			"Retired VM op must not be accepted: %s" % op,
		)
	_check(
		not engine.effect_engine.supports_command_spec({
			"op": "deal_damage",
			"args": {"effect_type": "damage", "amount": 10},
			"branches": {},
		}),
		"Native VM op must not accept legacy effect_type args",
	)
	_run_compiled_effect_examples(fixture, catalog, engine)
	_run_native_command_spec_tests(engine)
	_run_compiled_runtime_dispatch_tests(engine)
	_run_python_golden_actions(engine)
	_run_release_deck_playouts(catalog, engine)
	_run_steel_rules_tests(catalog, engine)
	_run_darkness_rules_tests(catalog, engine)
	_run_turn_state_regression_tests(catalog, engine)
	_run_card_effect_accuracy_tests(engine)

	var stack := ResolutionStack.new()
	stack.context = {"finish_attack": true, "actor": 0}
	stack.push_effect({"op": "draw_cards", "args": {"amount": 1}, "branches": {}}, 0, "active")
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


func _check_release_effects_have_compiled_ir(cards: Dictionary) -> void:
	for card_id in cards:
		var card: Dictionary = cards[card_id]
		var trainer_effects := _variant_array(card.get("trainer_effects", []))
		var compiled_trainer := _variant_array(card.get("compiled_trainer_effects", []))
		if not trainer_effects.is_empty():
			_check(
				trainer_effects.size() == compiled_trainer.size(),
				"Trainer %s has raw effects without matching compiled IR" % card_id,
			)
		var abilities := _variant_array(card.get("abilities", []))
		for ability_index in range(abilities.size()):
			var ability: Dictionary = abilities[ability_index]
			var ability_effects := _variant_array(ability.get("effects", []))
			var compiled_ability := _variant_array(ability.get("compiled_effects", []))
			if not ability_effects.is_empty():
				_check(
					ability_effects.size() == compiled_ability.size(),
					"Ability %s[%d] has raw effects without matching compiled IR" % [card_id, ability_index],
				)
		var attacks := _variant_array(card.get("attacks", []))
		for attack_index in range(attacks.size()):
			var attack: Dictionary = attacks[attack_index]
			var attack_effects := _variant_array(attack.get("effects", []))
			var compiled_attack := _variant_array(attack.get("compiled_effects", []))
			if not attack_effects.is_empty():
				_check(
					attack_effects.size() == compiled_attack.size(),
					"Attack %s[%d] has raw effects without matching compiled IR" % [card_id, attack_index],
				)


func _variant_array(value: Variant) -> Array:
	var result: Array = []
	if value is Array:
		result = value
	return result


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
	_check(ui.deck_one_option.item_count == 10, "Player one deck list must contain 10 decks")
	_check(ui.deck_two_option.item_count == 10, "Player two deck list must contain 10 decks")
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
	_run_ai_strength_regression_tests(catalog, engine, worker)

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
	_check(not ai_ui.modal_layer.visible,
		"Challenge AI match opened the local privacy overlay")
	_check(ai_ui.state.players[1].name == "Challenge AI", "AI player name mismatch")
	var fallback_state := _battle_state()
	fallback_state.phase = "MAIN"
	fallback_state.turn_number = 4
	fallback_state.first_player_idx = 0
	fallback_state.active_player_idx = 1
	fallback_state.revision = 77
	ai_ui.state = fallback_state
	ai_ui.rng = PortableRandomSource.new(20260627)
	ai_ui.ai_thinking = true
	ai_ui.active_ai_request_id = "ai-failure-test"
	ai_ui._refresh_game()
	ai_ui._apply_ai_result({
		"success": false,
		"error": "forced_failure",
		"request_id": "ai-failure-test",
		"revision": fallback_state.revision,
	})
	_check(not ai_ui.ai_thinking, "AI failure fallback left the UI thinking")
	_check(
		ai_ui.state.active_player_idx == 0,
		"AI failure fallback did not advance to the human turn",
	)
	_check(
		ai_ui.state.revision > 77,
		"AI failure fallback did not apply a legal fallback action",
	)
	ai_ui._stop_ai()
	_check(
		ai_ui.start_ai_match_for_test(
			"challenge", "fire", "water", "fast", 0),
		"Unable to start Challenge AI match with automatic seed",
	)
	var automatic_seed_a := int(ai_ui.last_match_seed)
	ai_ui._stop_ai()
	_check(
		ai_ui.start_ai_match_for_test(
			"challenge", "fire", "water", "fast", 0),
		"Unable to restart Challenge AI match with automatic seed",
	)
	var automatic_seed_b := int(ai_ui.last_match_seed)
	_check(
		automatic_seed_a != automatic_seed_b,
		"Challenge AI matches reused a fixed automatic match seed",
	)
	ai_ui._stop_ai()
	_check(
		ai_ui.start_ai_match_for_test(
			"deep", "fire", "water", "fast", 0, 20260621),
		"Unable to start Deep AI match",
	)
	_check(ai_ui.current_view_player == 0, "Deep AI match exposed the AI player view")
	_check(not ai_ui.modal_layer.visible,
		"Deep AI match opened the local privacy overlay")
	ai_ui._stop_ai()
	ai_ui.queue_free()


func _run_ai_strength_regression_tests(
	catalog: CardCatalog,
	_engine: GameEngine,
	worker: NativeChallengeAI,
) -> void:
	var ko_state := GameState.new()
	ko_state.phase = "MAIN"
	ko_state.turn_number = 5
	ko_state.first_player_idx = 1
	ko_state.active_player_idx = 0
	ko_state.public_deck_keys = ["lightning", "water"]
	ko_state.players[0].active = PokemonState.new("svl-zera")
	ko_state.players[0].active.placed_this_turn = false
	ko_state.players[0].active.energy_card_ids = ["sv1-ener-4", "sv1-ener-4"]
	ko_state.players[0].prizes = [
		"sv1-ener-4", "sv1-ener-4", "sv1-ener-4",
		"sv1-ener-4", "sv1-ener-4", "sv1-ener-4",
	]
	ko_state.players[1].active = PokemonState.new("sv2-delib")
	ko_state.players[1].active.placed_this_turn = false
	ko_state.players[1].prizes = [
		"sv1-ener-3", "sv1-ener-3", "sv1-ener-3",
		"sv1-ener-3", "sv1-ener-3", "sv1-ener-3",
	]
	var ko_action := _ai_decision_for_actions(worker, ko_state, 0, "lightning", [
		GameAction.new("END_TURN", {}, true, 0),
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
	], "ko-before-pass")
	_check(
		ko_action != null and ko_action.action == "DECLARE_ATTACK",
		"AI fallback did not take an immediate KO before ending turn",
	)

	var energy_state := GameState.new()
	energy_state.phase = "MAIN"
	energy_state.turn_number = 5
	energy_state.first_player_idx = 0
	energy_state.active_player_idx = 1
	energy_state.public_deck_keys = ["dragon", "lightning"]
	energy_state.players[0].active = PokemonState.new("svg-dram")
	energy_state.players[0].active.placed_this_turn = false
	energy_state.players[1].active = PokemonState.new("svl-pikaex")
	energy_state.players[1].active.placed_this_turn = false
	energy_state.players[1].active.energy_card_ids = ["sv1-ener-4"]
	energy_state.players[1].hand = ["sv1-ener-4"]
	var energy_action := _ai_decision_for_actions(worker, energy_state, 1, "lightning", [
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 1),
		GameAction.new("ATTACH_ENERGY", {"hand_idx": 0, "target_slot": "active"}, false, 1),
		GameAction.new("END_TURN", {}, true, 1),
	], "weak-attack-before-energy")
	_check(
		energy_action != null
		and energy_action.action == "ATTACH_ENERGY"
		and str(energy_action.params.get("target_slot", "")) == "active",
		"AI fallback did not delay a weak attack for obvious core energy",
	)

	var draw_state := GameState.new()
	draw_state.phase = "MAIN"
	draw_state.turn_number = 5
	draw_state.first_player_idx = 0
	draw_state.active_player_idx = 1
	draw_state.public_deck_keys = ["dragon", "psychic"]
	draw_state.players[0].active = PokemonState.new("svg-dram")
	draw_state.players[0].active.placed_this_turn = false
	draw_state.players[1].active = PokemonState.new("sv1-104")
	draw_state.players[1].active.placed_this_turn = false
	draw_state.players[1].active.energy_card_ids = ["sv1-ener-5"]
	draw_state.players[1].hand = ["sv1-180"]
	draw_state.players[1].deck = [
		"sv1-ener-5", "sv1-ener-5", "sv1-ener-5", "sv1-ener-5",
		"sv1-ener-5", "sv1-ener-5", "sv1-ener-5", "sv1-ener-5",
	]
	var draw_action := _ai_decision_for_actions(worker, draw_state, 1, "psychic", [
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 1),
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 1),
		GameAction.new("END_TURN", {}, true, 1),
	], "weak-attack-before-draw")
	_check(
		draw_action != null and draw_action.action == "PLAY_TRAINER",
		"AI fallback did not use a productive draw trainer before weak attack",
	)

	var major_draw_state := GameState.new()
	major_draw_state.phase = "MAIN"
	major_draw_state.turn_number = 5
	major_draw_state.first_player_idx = 0
	major_draw_state.active_player_idx = 1
	major_draw_state.public_deck_keys = ["dragon", "psychic"]
	major_draw_state.players[0].active = PokemonState.new("svg-dram")
	major_draw_state.players[0].active.placed_this_turn = false
	major_draw_state.players[1].active = PokemonState.new("sv1-104")
	major_draw_state.players[1].active.placed_this_turn = false
	major_draw_state.players[1].hand = ["sv1-ener-5", "sv1-189"]
	major_draw_state.players[1].deck = [
		"sv1-180", "sv1-180", "sv1-180", "sv1-180", "sv1-180",
		"sv1-180", "sv1-180", "sv1-180", "sv1-180", "sv1-180",
	]
	var major_draw_action := _ai_decision_for_actions(worker, major_draw_state, 1, "psychic", [
		GameAction.new("PLAY_TRAINER", {"hand_idx": 1}, false, 1),
		GameAction.new("ATTACH_ENERGY", {"hand_idx": 0, "target_slot": "active"}, false, 1),
		GameAction.new("END_TURN", {}, true, 1),
	], "major-draw-before-energy")
	_check(
		major_draw_action != null and major_draw_action.action == "ATTACH_ENERGY",
		"AI fallback did not spend obvious energy before a major hand refresh",
	)

	var ability_state := GameState.new()
	ability_state.phase = "MAIN"
	ability_state.turn_number = 5
	ability_state.first_player_idx = 0
	ability_state.active_player_idx = 1
	ability_state.public_deck_keys = ["dragon", "psychic"]
	ability_state.players[0].active = PokemonState.new("svg-dram")
	ability_state.players[0].active.placed_this_turn = false
	ability_state.players[1].active = PokemonState.new("sv1-106")
	ability_state.players[1].active.placed_this_turn = false
	ability_state.players[1].bench[0] = PokemonState.new("sv1-108")
	ability_state.players[1].bench[0].placed_this_turn = false
	ability_state.players[1].bench[1] = PokemonState.new("sv1-111")
	ability_state.players[1].bench[1].placed_this_turn = false
	ability_state.players[1].hand = ["sv1-ener-5"]
	ability_state.players[1].deck = [
		"sv1-180", "sv1-180", "sv1-180",
		"sv1-180", "sv1-180", "sv1-180",
	]
	var ability_name := str(catalog.get_card("sv1-108").get("abilities", [])[0].get("name", ""))
	var ability_action := _ai_decision_for_actions(worker, ability_state, 1, "psychic", [
		GameAction.new("END_TURN", {}, true, 1),
		GameAction.new("USE_ABILITY", {"slot": "bench_0", "ability_name": ability_name}, false, 1),
	], "ability-before-pass")
	_check(
		ability_action != null and ability_action.action == "USE_ABILITY",
		"AI fallback did not use a productive ability before ending turn",
	)

	var context_state := GameState.new()
	context_state.public_deck_keys = ["lightning", "psychic"]
	context_state.phase = "MAIN"
	context_state.turn_number = 5
	context_state.active_player_idx = 1
	context_state.players[1].active = PokemonState.new("sv1-104")
	context_state.players[1].hand = ["sv1-ener-5"]
	var context_action := GameAction.new(
		"ATTACH_ENERGY", {"hand_idx": 0, "target_slot": "active"}, false, 1)
	var public_deck_key := worker._deck_key_for_actor(context_state, 1, "lightning")
	_check(public_deck_key == "psychic", "AI rollout deck context ignored public deck keys")
	_check(
		worker._action_score(context_state, 1, context_action, public_deck_key, catalog)
		> worker._action_score(context_state, 1, context_action, "lightning", catalog),
		"AI action scoring did not benefit from the current actor deck profile",
	)


func _ai_decision_for_actions(
	worker: NativeChallengeAI,
	state: GameState,
	actor: int,
	deck_key: String,
	actions: Array,
	request_id: String,
) -> GameAction:
	var rows: Array = []
	for action in actions:
		rows.append(action.to_dict())
	var result := worker.decide({
		"kind": "action",
		"state": state.snapshot(),
		"actor": actor,
		"revision": state.revision,
		"request_id": request_id,
		"mode": "challenge",
		"difficulty": "fast",
		"deck_key": deck_key,
		"seed": 20260626,
		"simulation_budget": 0,
		"seconds": 0.0,
		"max_depth": 1,
		"deterministic": true,
		"actions": rows,
	}, func() -> bool: return false)
	_check(result.get("success", false), "AI strength decision failed: %s" % result.get("error", "unknown"))
	if not result.get("success", false):
		return null
	return GameAction.from_dict(result["action"])


func _run_phase_five_foundation_tests() -> void:
	var seed_controller := NetworkMatchController.new()
	var network_seed_a := int(seed_controller._resolved_match_seed(-1))
	var network_seed_b := int(seed_controller._resolved_match_seed(-1))
	_check(
		network_seed_a != network_seed_b,
		"Network hosted matches reused a fixed automatic match seed",
	)
	_check(
		seed_controller._resolved_match_seed(20260621) == 20260621,
		"Explicit network match seed was not preserved",
	)

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
	var main_scene := load("res://scenes/main/main.tscn") as PackedScene
	for view_row in [
		{"view": host_view, "player": 0, "label": "host"},
		{"view": client_view, "player": 1, "label": "client"},
	]:
		var network_view_ui := main_scene.instantiate()
		root.add_child(network_view_ui)
		network_view_ui.initialize_ui()
		network_view_ui._apply_network_view(view_row["view"], int(view_row["player"]))
		_check(not network_view_ui.modal_layer.visible,
			"Network %s view opened the local privacy overlay" % view_row["label"])
		network_view_ui.queue_free()
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
			"HelpButton",
		],
		"res://scenes/decks/deck_select_page.tscn": [
			"DeckOneOption", "DeckTwoOption", "DeckOneDetailsButton",
			"DeckTwoDetailsButton", "StartButton",
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
	title_page.help_requested.connect(
		func() -> void: title_signals["help"] = true
	)
	(title_page.find_child("LocalTwoPlayerButton", true, false) as Button).pressed.emit()
	(title_page.find_child("LANButton", true, false) as Button).pressed.emit()
	(title_page.find_child("SettingsButton", true, false) as Button).pressed.emit()
	(title_page.find_child("HelpButton", true, false) as Button).pressed.emit()
	_check(title_signals.get("mode", "") == "local",
		"Title page mode signal did not carry the selected mode")
	_check(title_signals.get("network", "") == "lan",
		"Title page network signal did not carry the transport kind")
	_check(bool(title_signals.get("settings", false)),
		"Title page settings signal was not emitted")
	_check(bool(title_signals.get("help", false)),
		"Title page help signal was not emitted")
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
	deck_page.deck_details_requested.connect(
		func(deck_key: String) -> void: deck_signal["details"] = deck_key
	)
	(deck_page.find_child("StartButton", true, false) as Button).pressed.emit()
	(deck_page.find_child("DeckOneDetailsButton", true, false) as Button).pressed.emit()
	_check(deck_signal.get("mode", "") == "challenge",
		"Deck page start signal did not carry the game mode")
	_check(not str(deck_signal.get("first", "")).is_empty(),
		"Deck page start signal omitted the first deck")
	_check(not str(deck_signal.get("second", "")).is_empty(),
		"Deck page start signal omitted the second deck")
	_check(deck_signal.get("difficulty", "") == "standard",
		"Deck page start signal omitted the selected difficulty")
	_check(not str(deck_signal.get("details", "")).is_empty(),
		"Deck page details signal omitted the selected deck")
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

	var modal_ui := main_scene.instantiate()
	root.add_child(modal_ui)
	modal_ui.initialize_ui()
	modal_ui._show_help()
	_check(modal_ui.modal_layer.visible,
		"Help modal did not open from the main shell")
	_check(is_equal_approx(float(modal_ui.modal_shade.color.a), 0.86),
		"Title help modal did not use the default translucent shade")
	var help_labels: Array[Node] = modal_ui.modal_body.find_children(
		"*", "Label", true, false)
	var help_body_has_outline := false
	var help_body_has_fullwidth_semicolon := false
	for node in help_labels:
		var help_label := node as Label
		if help_label == null:
			continue
		help_body_has_outline = (
			help_body_has_outline
			or help_label.get_theme_constant("outline_size") != 0
		)
		help_body_has_fullwidth_semicolon = (
			help_body_has_fullwidth_semicolon
			or str(help_label.text).contains("；")
		)
	_check(not help_body_has_outline,
		"Help modal body labels inherited the global outline")
	_check(not help_body_has_fullwidth_semicolon,
		"Help modal body still contains Android-unsafe fullwidth semicolons")
	modal_ui._close_modal()
	var distribute_request := ChoiceRequest.new(
		"choice:test:energy",
		"distribute_energy",
		0,
		"为每张能量选择附着目标。",
		[
			{
				"option_id": "pokemon:0:active:sv1-104",
				"label": "墓仔狗",
				"value": {"slot": "active", "card_id": "sv1-104"},
			},
		],
		2,
		2,
		true,
	)
	modal_ui.show_choice(distribute_request)
	modal_ui._toggle_choice("pokemon:0:active:sv1-104")
	modal_ui._toggle_choice("pokemon:0:active:sv1-104")
	_check(modal_ui.selected_choice_ids == [
		"pokemon:0:active:sv1-104",
		"pokemon:0:active:sv1-104",
	], "Energy distribution choice did not preserve repeated option IDs")
	modal_ui.queue_free()

	var privacy_ui := main_scene.instantiate()
	root.add_child(privacy_ui)
	privacy_ui.initialize_ui()
	_check(
		privacy_ui.start_local_match_for_test("fire", "water", 20260621),
		"Unable to start local match for privacy modal test",
	)
	_check(privacy_ui.modal_layer.visible,
		"Local match did not open the privacy pass overlay")
	_check(float(privacy_ui.modal_shade.color.a) >= 0.99,
		"Local privacy pass overlay did not use an opaque shade")
	privacy_ui._finish_modal_close(privacy_ui._modal_generation)
	privacy_ui._refresh_game()
	privacy_ui.battle_screen.show_card_detail("sv1-104")
	_check(privacy_ui.battle_screen.detail_panel.visible,
		"Battle card detail did not open for the close control test")
	_check(privacy_ui.battle_screen.detail_close_button != null
		and privacy_ui.battle_screen.detail_close_button.visible,
		"Battle card detail close button was not shown")
	privacy_ui.battle_screen.detail_close_button.pressed.emit()
	_check(not privacy_ui.battle_screen.detail_panel.visible,
		"Battle card detail close button did not hide the detail panel")
	privacy_ui.battle_screen.show_card_detail("sv1-104")
	privacy_ui._show_pause_overlay()
	_check(privacy_ui.modal_layer.z_index > privacy_ui.battle_screen.z_index + 20,
		"Pause menu modal layer can be drawn under battle overlay panels")
	_check(not privacy_ui.battle_screen.detail_panel.visible,
		"Pause menu left the battle card detail overlay visible")
	_check(float(privacy_ui.modal_shade.color.a) >= 0.99,
		"Pause menu did not use an opaque privacy shade")
	privacy_ui._finish_modal_close(privacy_ui._modal_generation)
	privacy_ui.show_title()
	privacy_ui._show_help()
	_check(is_equal_approx(float(privacy_ui.modal_shade.color.a), 0.86),
		"Title help modal retained an opaque in-game shade")
	privacy_ui.queue_free()

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
		workbench.call("show_preview", "help")
		_check(
			str(workbench.preview_caption.text).contains("帮助面板"),
			"UI Workbench help preview did not open",
		)
		workbench.call("show_preview", "deck_detail")
		_check(
			str(workbench.preview_caption.text).contains("牌组详情"),
			"UI Workbench deck detail preview did not open",
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
	var legacy_multi_draw := PresentationEvent.normalize({
		"event_type": "cards_drawn",
		"data": {"player": 0, "cards": ["sv1-104", "sv1-151", "sv1-153"]},
	}, 8, 0, 1)
	_check(legacy_draw.get("visibility", "") == PresentationEvent.OWNER,
		"Legacy draw events are not owner-only")
	_check(int(legacy_multi_draw.get("amount", 0)) == 3,
		"Legacy multi-card draw event did not derive the card amount")
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
		state.players[0].active.energy_card_ids.assign([
			"sv1-ener-5", "sv1-ener-5", "svi-mirc",
		])
		state.players[0].active.attached_tool_id = "sv1-202"
		state.players[0].active.damage_counters = 2
		state.players[0].active.status_conditions.assign(["POISONED"])
		state.players[0].discard = ["sv1-180", "sv1-189"]
		state.players[0].prizes = ["sv1-151", "sv1-153"]
		state.players[1].hand = [
			"sv1-104", "sv1-151", "sv1-153", "sv1-189", "svf-potion", "sv1-ener-5",
		]
		state.players[1].deck = []
		for _index in range(43):
			state.players[1].deck.append("")
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
		var active_hp := battle.own_active.find_child(
			"HPPill", true, false
		) as Label
		var active_damage := battle.own_active.find_child(
			"DamageBadge", true, false
		) as Label
		var active_energy := battle.own_active.find_child(
			"EnergyRow", true, false
		) as HBoxContainer
		var active_tool := battle.own_active.find_child(
			"ToolBadge", true, false
		) as Label
		_check(
			active_hp != null and active_hp.visible and active_hp.text == "HP100",
			"Active Pokemon HP pill did not show current boosted HP",
		)
		_check(
			active_damage != null and active_damage.visible and active_damage.text == "20",
			"Active Pokemon damage badge did not show damage counters",
		)
		_check(
			active_energy != null and active_energy.visible
			and active_energy.get_child_count() >= 2,
			"Active Pokemon energy row did not render grouped energy badges",
		)
		_check(
			active_tool != null and active_tool.visible,
			"Active Pokemon tool badge was not rendered",
		)
		_check(
			battle.own_active.status_row.get_child_count() == 1,
			"Active Pokemon status badge was not rendered",
		)
		_check(battle.hand_views.size() == 4,
			"Battle screen did not create stable hand card views")
		_check(
			battle.find_child("OpponentHandSurface", true, false) != null,
			"Battle screen is missing the opponent hand surface",
		)
		_check(battle.opponent_hand_views.size() == 6,
			"Battle screen did not create opponent hand card-back views")
		for opponent_hand_view in battle.opponent_hand_views:
			var hidden_view := opponent_hand_view as CardView
			_check(
				hidden_view.is_hidden_card
				and hidden_view.card_id.is_empty()
				and hidden_view.hand_index == -1,
				"Opponent hand view leaked card identity or became interactive",
			)
			var hidden_hp := hidden_view.find_child("HPPill", true, false) as Label
			var hidden_energy := hidden_view.find_child(
				"EnergyRow", true, false
			) as HBoxContainer
			_check(
				(hidden_hp == null or not hidden_hp.visible)
				and (hidden_energy == null or not hidden_energy.visible),
				"Hidden opponent hand card exposed battle info overlays",
			)
		_check(battle.zones.size() == 7,
			"Battle screen does not expose every required tabletop zone")
		_check(
			(battle.zones["opponent_deck"] as ZoneView).stack_visual_mode == "deck"
			and (battle.zones["own_deck"] as ZoneView).stack_visual_mode == "deck"
			and (battle.zones["own_prizes"] as ZoneView).stack_visual_mode == "prizes",
			"Battle zones did not enable deck/prize stack visuals",
		)
		_check(battle.phase_advance_button != null,
			"Battle screen is missing the dedicated phase advance button")
		_check(
			battle.find_child("QuickActions", true, false) == null,
			"Legacy quick action node still exists in the battle scene",
		)
		_check(
			battle.action_panel != null and not battle.action_panel.visible,
			"All-actions fallback drawer should start hidden",
		)
		_check(
			battle.all_actions_button != null and not battle.all_actions_button.disabled,
			"Battle screen is missing the all-actions HUD button",
		)
		if battle.all_actions_button:
			battle.all_actions_button.pressed.emit()
		_check(
			battle.action_panel != null and battle.action_panel.visible,
			"All-actions fallback drawer did not open from the HUD button",
		)
		_check(
			battle.action_list != null and battle.action_list.get_child_count() > 0,
			"All-actions fallback drawer did not render legal actions",
		)
		if battle.all_actions_toggle:
			battle.all_actions_toggle.pressed.emit()
		_check(
			battle.action_panel != null and not battle.action_panel.visible,
			"All-actions fallback drawer did not close from its collapse button",
		)
		battle.update_view(state, 0, rows, "", true, "challenge")
		var ai_chip := battle.find_child("AIThinkingChip", true, false) as Label
		var ai_status := battle.find_child("AIThinkingStatus", true, false) as Label
		_check(
			ai_status != null
			and ai_status.visible
			and ai_status.text.contains("思考中"),
			"AI thinking tabletop status was not visible during AI turn",
		)
		_check(
			ai_chip == null or not ai_chip.visible,
			"AI thinking status remained in the header instead of the tabletop",
		)
		_check(
			battle.ai_thinking_overlay != null
			and battle.ai_thinking_overlay.visible,
			"AI thinking board overlay was not visible during AI turn",
		)
		_check(
			battle.phase_advance_button != null and battle.phase_advance_button.disabled,
			"AI thinking state did not disable the phase action button",
		)
		if battle.all_actions_button:
			battle.all_actions_button.pressed.emit()
		var disabled_action_buttons: bool = (
			battle.action_list != null and battle.action_list.get_child_count() > 0
		)
		if battle.action_list:
			for child in battle.action_list.get_children():
				var action_button := child as Button
				if action_button:
					disabled_action_buttons = disabled_action_buttons and action_button.disabled
		_check(
			disabled_action_buttons,
			"AI thinking state did not disable rendered action buttons",
		)
		_check(
			not battle.input_blocker.visible,
			"AI thinking state reused the presentation input blocker",
		)
		_check(
			not battle.own_active.is_presentation_hidden()
			and not battle.opponent_active.is_presentation_hidden(),
			"AI thinking state hid battlefield Pokemon",
		)
		var ai_node_count_before := battle.find_children("*", "", true, false).size()
		for _index in range(12):
			battle.update_view(state, 0, rows, "", true, "challenge")
		var ai_node_count_after := battle.find_children("*", "", true, false).size()
		_check(
			ai_node_count_after == ai_node_count_before,
			"Repeated AI thinking refreshes created persistent UI nodes",
		)
		var ai_settings_node: Node = root.get_node("AppSettings")
		var ai_previous_animation_mode := str(ai_settings_node.get("animation_mode"))
		ai_settings_node.call(
			"update",
			float(ai_settings_node.get("master_volume")),
			bool(ai_settings_node.get("muted")),
			true,
			int(ai_settings_node.get("card_cache_size")),
			"reduced",
		)
		battle.update_view(state, 0, rows, "", true, "challenge")
		_check(
			battle.ai_thinking_overlay != null
			and battle.ai_thinking_overlay.visible
			and not battle.ai_thinking_overlay.is_animating(),
			"Reduced motion AI thinking overlay kept running animation",
		)
		ai_settings_node.call(
			"update",
			float(ai_settings_node.get("master_volume")),
			bool(ai_settings_node.get("muted")),
			ai_previous_animation_mode == "reduced",
			int(ai_settings_node.get("card_cache_size")),
			ai_previous_animation_mode,
		)
		if battle.all_actions_toggle:
			battle.all_actions_toggle.pressed.emit()
		battle.update_view(state, 0, rows, "", false, "challenge")
		_check(
			ai_status != null
			and not ai_status.visible
			and battle.ai_thinking_overlay != null
			and not battle.ai_thinking_overlay.visible
			and not battle.ai_thinking_overlay.is_animating(),
			"AI thinking indicator did not hide cleanly after the turn ended",
		)
		var discard_context: Dictionary = (
			battle.zones["own_discard"] as ZoneView
		).inspect_context
		_check(discard_context.get("card_ids", []) == ["sv1-180", "sv1-189"],
			"Discard zone inspector did not expose public discard cards")
		var prize_context: Dictionary = (
			battle.zones["own_prizes"] as ZoneView
		).inspect_context
		_check(bool(prize_context.get("hidden", false)),
			"Prize zone inspector is not marked hidden")
		_check(Array(prize_context.get("card_ids", [])).is_empty(),
			"Prize zone inspector leaked hidden prize card IDs")
		var opponent_draw_event := {
			"event_type": "cards_drawn",
			"actor": 1,
			"visibility": "owner",
			"card_id": "sv1-151",
			"source": {"player": 1, "zone": "deck"},
			"target": {"player": 1, "zone": "hand"},
			"data": {
				"player": 1,
				"count": 1,
				"card_ids": ["sv1-151"],
			},
		}
		var normalized_opponent_draw := PresentationEvent.normalize(
			opponent_draw_event, 40, 1, 0)
		var opponent_target_points: Array[Vector2] = battle._target_points_for_event(
			{"player": 1, "zone": "hand"},
			[],
			1,
			battle.resolve_endpoint_center({"player": 1, "zone": "hand"}),
			normalized_opponent_draw,
		)
		var opponent_target_view: Variant = battle.opponent_hand_views[-1]
		var opponent_target_expected: Vector2 = battle._effects_local(
			opponent_target_view.global_center())
		_check(
			opponent_target_points.size() == 1
			and opponent_target_points[0].distance_to(opponent_target_expected) < 0.01,
			"Opponent draw animation did not land on the visible opponent hand backs",
		)
		_check(
			opponent_target_points[0].distance_to(battle._own_hand_center()) > 120.0,
			"Opponent draw animation still targeted the local hand area",
		)
		_check(
			battle._motion_card_hidden_from_view(
				"sv1-151",
				{"player": 1, "zone": "deck"},
				{"player": 1, "zone": "hand"},
			),
			"Opponent hidden-zone card motion would reveal card identity",
		)
		_check(
			not battle._motion_card_hidden_from_view(
				"sv1-151",
				{"player": 0, "zone": "deck"},
				{"player": 0, "zone": "hand"},
			),
			"Local owner draw animation was incorrectly forced to card back",
		)
		var inspected_card := {}
		battle.inspect_card_requested.connect(
			func(context: Dictionary) -> void: inspected_card.merge(context, true)
		)
		battle._on_detail_requested("sv1-104")
		var inspected_pokemon := inspected_card.get("pokemon") as PokemonState
		_check(inspected_pokemon != null and inspected_pokemon.attached_tool_id == "sv1-202",
			"Card inspector context did not include attached cards")
		var first_hand: Variant = battle.hand_views[0]
		_check(first_hand.catalog == battle.catalog,
			"Battle cards do not reuse the shared card catalog")
		battle.update_view(state, 0, rows, "hand:3", false, "local")
		var trainer_view: Variant = battle.hand_views[3]
		_check(not trainer_view._pending_action_rows.is_empty(),
			"Direct trainer action was not placed on the selected card")
		battle.update_view(state, 0, rows, "", false, "local")
		var fallback_start := Vector2(321, 654)
		var non_first_expected: Vector2 = (
			battle._effects_local(battle.hand_views[1].global_center())
		)
		var non_first_starts: Array[Vector2] = battle._discard_hand_start_points(
			["sv1-ener-5"], 1, fallback_start)
		_check(
			non_first_starts.size() == 1
			and non_first_starts[0].distance_to(non_first_expected) < 0.01,
			"Discard animation did not start from the matching non-first hand card",
		)
		state.players[0].hand = [
			"sv1-104", "sv1-ener-5", "sv1-104", "sv1-189",
		]
		battle.update_view(state, 0, rows, "", false, "local")
		var duplicate_expected_a: Vector2 = (
			battle._effects_local(battle.hand_views[0].global_center())
		)
		var duplicate_expected_b: Vector2 = (
			battle._effects_local(battle.hand_views[2].global_center())
		)
		var duplicate_starts: Array[Vector2] = battle._discard_hand_start_points(
			["sv1-104", "sv1-104"], 2, fallback_start)
		_check(
			duplicate_starts.size() == 2
			and duplicate_starts[0].distance_to(duplicate_expected_a) < 0.01
			and duplicate_starts[1].distance_to(duplicate_expected_b) < 0.01,
			"Discard animation did not consume duplicate hand-card starts in order",
		)
		var missing_starts: Array[Vector2] = battle._discard_hand_start_points(
			["missing-card"], 1, fallback_start)
		_check(
			missing_starts.size() == 1 and missing_starts[0] == fallback_start,
			"Discard animation did not fall back when a card identity is absent",
		)
		var anonymous_starts: Array[Vector2] = battle._discard_hand_start_points(
			[], 2, fallback_start)
		_check(
			anonymous_starts.size() == 2
			and anonymous_starts[0] == fallback_start
			and anonymous_starts[1] == fallback_start,
			"Discard animation did not fall back for anonymous discard events",
		)
		state.players[0].hand = ["sv1-104", "sv1-ener-5"]
		state.players[0].deck = ["sv1-151"]
		battle.update_view(state, 0, rows, "", false, "local")
		var draw_snapshot: Dictionary = battle.capture_presentation_snapshot()
		state.players[0].deck.clear()
		state.players[0].hand.append("sv1-151")
		battle.update_view(state, 0, rows, "", false, "local")
		var draw_event := {
			"event_type": "cards_drawn",
			"actor": 0,
			"visibility": "owner",
			"card_id": "sv1-151",
			"source": {"player": 0, "zone": "deck"},
			"target": {"player": 0, "zone": "hand"},
			"data": {
				"player": 0,
				"count": 1,
				"card_ids": ["sv1-151"],
			},
		}
		battle.play_presentation([draw_event], 41, 0, draw_snapshot)
		var drawn_view: Variant = battle.hand_views[2]
		_check(
			drawn_view.is_presentation_hidden(),
			"Draw animation exposed the new hand card before landing",
		)
		var normalized_draw := PresentationEvent.normalize(draw_event, 41, 0, 0)
		var draw_target_points: Array[Vector2] = battle._target_points_for_event(
			{"player": 0, "zone": "hand"},
			["sv1-151"],
			1,
			Vector2.ZERO,
			normalized_draw,
		)
		_check(
			draw_target_points.size() == 1
			and draw_target_points[0].distance_to(
				battle._effects_local(drawn_view.global_center())) < 0.01,
			"Draw animation did not land on the actual final hand-card position",
		)
		battle._on_presentation_event_finished(normalized_draw)
		_check(
			not drawn_view.is_presentation_hidden(),
			"Draw animation did not reveal the hand card after landing",
		)
		battle.director.clear_for_resync()
		battle._clear_transient_visuals()

		state.players[0].hand = ["sv1-180", "sv1-104"]
		state.players[0].deck = ["sv1-151", "sv1-153", "sv1-ener-5", "sv1-ener-6"]
		state.players[0].discard.clear()
		state.players[0].supporter_played_this_turn = false
		battle.update_view(state, 0, rows, "", false, "local")
		var nemona_snapshot: Dictionary = battle.capture_presentation_snapshot()
		var nemona_step := engine.apply_action(
			state,
			GameAction.new(
				"PLAY_TRAINER",
				{"hand_idx": 0},
				false,
				0,
				EntityRef.new("card", 0, "hand", "", 0, "", "sv1-180"),
			),
			PortableRandomSource.new(20260625),
		)
		_check(nemona_step.success,
			"Nemona trainer action failed in the UI presentation regression")
		battle.update_view(state, 0, rows, "", false, "local")
		var nemona_events: Array[Dictionary] = PresentationEvent.normalize_all(
			nemona_step.events,
			state.revision,
			0,
		)
		battle._stage_presentation_targets(nemona_events, nemona_snapshot)
		var nemona_draw_event := {}
		for event in nemona_events:
			if str(event.get("event_type", "")) == "cards_drawn":
				nemona_draw_event = event
				break
		var nemona_targets: Array = battle._presentation_event_hand_targets.get(
			str(nemona_draw_event.get("event_id", "")),
			[],
		)
		_check(int(nemona_draw_event.get("amount", 0)) == 3,
			"Nemona draw event did not keep the three-card amount")
		_check(nemona_targets.size() == 3,
			"Nemona draw did not target all three newly drawn hand cards")
		for target_value in nemona_targets:
			var target_card := target_value as CardView
			_check(
				target_card != null and target_card.is_presentation_hidden(),
				"Nemona drawn card target was not masked before the animation landed",
			)
		battle._on_presentation_event_finished(nemona_draw_event)
		for target_value in nemona_targets:
			var target_card := target_value as CardView
			_check(
				target_card != null and not target_card.is_presentation_hidden(),
				"Nemona drawn card target was not revealed after the animation landed",
			)
		battle.director.clear_for_resync()
		battle._clear_transient_visuals()

		state.players[0].hand = ["sv1-104", "sv1-ener-5"]
		state.players[0].deck = ["sv1-104"]
		state.players[0].discard.clear()
		battle.update_view(state, 0, rows, "", false, "local")
		var same_id_snapshot: Dictionary = battle.capture_presentation_snapshot()
		state.players[0].hand = ["sv1-ener-5", "sv1-104"]
		state.players[0].deck.clear()
		state.players[0].discard = ["sv1-104"]
		battle.update_view(state, 0, rows, "", false, "local")
		var same_id_discard_event := {
			"event_type": "cards_discarded",
			"actor": 0,
			"source": {"player": 0, "zone": "hand", "index": 0},
			"target": {"player": 0, "zone": "discard"},
			"amount": 1,
			"data": {
				"player": 0,
				"count": 1,
				"card_ids": ["sv1-104"],
			},
		}
		var same_id_draw_event := {
			"event_type": "cards_drawn",
			"actor": 0,
			"visibility": "owner",
			"card_id": "sv1-104",
			"source": {"player": 0, "zone": "deck"},
			"target": {"player": 0, "zone": "hand"},
			"amount": 1,
			"data": {
				"player": 0,
				"count": 1,
				"card_ids": ["sv1-104"],
			},
		}
		var same_id_events: Array[Dictionary] = PresentationEvent.normalize_all(
			[same_id_discard_event, same_id_draw_event],
			48,
			0,
		)
		battle._stage_presentation_targets(same_id_events, same_id_snapshot)
		var same_id_draw := same_id_events[1]
		var same_id_targets: Array = battle._presentation_event_hand_targets.get(
			str(same_id_draw.get("event_id", "")),
			[],
		)
		_check(
			same_id_targets.size() == 1
			and same_id_targets[0] == battle.hand_views[1],
			"Discard-then-draw with the same card ID did not target the newly drawn hand card",
		)
		_check(
			(battle.hand_views[1] as CardView).is_presentation_hidden(),
			"Discard-then-draw same-ID target was not masked before the draw landed",
		)
		var same_id_finish_points: Array[Vector2] = battle._target_points_for_event(
			{"player": 0, "zone": "hand"},
			["sv1-104"],
			1,
			Vector2.ZERO,
			same_id_draw,
		)
		_check(
			same_id_finish_points.size() == 1
			and same_id_finish_points[0].distance_to(
				battle._effects_local(battle.hand_views[1].global_center())) < 0.01,
			"Discard-then-draw same-ID animation did not land on the new hand card",
		)
		battle._on_presentation_event_finished(same_id_draw)
		_check(
			not (battle.hand_views[1] as CardView).is_presentation_hidden(),
			"Discard-then-draw same-ID target did not reveal after landing",
		)
		battle.director.clear_for_resync()
		battle._clear_transient_visuals()

		state.players[0].hand = ["sv1-104", "sv1-ener-5", "sv1-104"]
		state.players[0].discard.clear()
		battle.update_view(state, 0, rows, "", false, "local")
		var discard_snapshot: Dictionary = battle.capture_presentation_snapshot()
		var discard_expected: Vector2 = (
			battle._effects_local(battle.hand_views[1].global_center())
		)
		state.players[0].hand = ["sv1-104", "sv1-104"]
		state.players[0].discard = ["sv1-ener-5"]
		battle.update_view(state, 0, rows, "", false, "local")
		battle._presentation_snapshot = discard_snapshot
		var snapshot_discard_starts: Array[Vector2] = (
			battle._source_points_for_event(
				{"player": 0, "zone": "hand"},
				["sv1-ener-5"],
				1,
				fallback_start,
			)
		)
		_check(
			snapshot_discard_starts.size() == 1
			and snapshot_discard_starts[0].distance_to(discard_expected) < 0.01,
			"Discard animation did not use the pre-refresh hand snapshot",
		)

		state.players[0].hand = ["svi-chim", "sv1-ener-5"]
		state.players[0].bench[0] = null
		battle.update_view(state, 0, rows, "", false, "local")
		var play_snapshot: Dictionary = battle.capture_presentation_snapshot()
		var play_start_expected: Vector2 = (
			battle._effects_local(battle.hand_views[0].global_center())
		)
		state.players[0].hand = ["sv1-ener-5"]
		state.players[0].bench[0] = PokemonState.new("svi-chim")
		battle.update_view(state, 0, rows, "", false, "local")
		var play_event := {
			"event_type": "pokemon_played",
			"actor": 0,
			"card_id": "svi-chim",
			"source": {"player": 0, "zone": "hand", "index": 0},
			"target": {"player": 0, "slot": "bench_0"},
			"data": {
				"player": 0,
				"slot": "bench_0",
				"card_id": "svi-chim",
			},
		}
		battle.play_presentation([play_event], 42, 0, play_snapshot)
		var played_slot: Variant = battle.get_slot_view(0, "bench_0")
		_check(
			played_slot.is_presentation_hidden(),
			"Played Pokemon target slot was visible before the card landed",
		)
		var play_starts: Array[Vector2] = battle._source_points_for_event(
			{"player": 0, "zone": "hand", "index": 0},
			["svi-chim"],
			1,
			fallback_start,
		)
		_check(
			play_starts.size() == 1
			and play_starts[0].distance_to(play_start_expected) < 0.01,
			"Played Pokemon did not fly from its old hand-card position",
		)
		var normalized_play := PresentationEvent.normalize(play_event, 42, 0, 0)
		battle._on_presentation_event_finished(normalized_play)
		_check(
			not played_slot.is_presentation_hidden(),
			"Played Pokemon target slot did not reveal after landing",
		)
		battle.director.clear_for_resync()
		battle._clear_transient_visuals()

		state.players[0].active = PokemonState.new("sv1-104")
		state.players[0].active.placed_this_turn = false
		state.players[0].active.energy_card_ids.clear()
		state.players[0].hand = ["sv1-ener-5"]
		battle.update_view(state, 0, rows, "", false, "local")
		var energy_snapshot: Dictionary = battle.capture_presentation_snapshot()
		var energy_snapshot_row: Dictionary = energy_snapshot.get("slots", {}).get(
			"0:active",
			{},
		)
		_check(
			str(energy_snapshot_row.get("card_id", "")) == "sv1-104"
			and not bool(energy_snapshot_row.get("empty", true)),
			"Energy presentation snapshot did not capture the old active slot: %s" % JSON.stringify(energy_snapshot_row),
		)
		var energy_start_expected: Vector2 = (
			battle._effects_local(battle.hand_views[0].global_center())
		)
		state.players[0].hand.clear()
		state.players[0].active.energy_card_ids.append("sv1-ener-5")
		battle.update_view(state, 0, rows, "", false, "local")
		var energy_event := {
			"event_type": "energy_attached",
			"actor": 0,
			"card_id": "sv1-ener-5",
			"source": {"player": 0, "zone": "hand", "index": 0},
			"target": {"player": 0, "slot": "active"},
			"data": {
				"player": 0,
				"slot": "active",
				"card_id": "sv1-ener-5",
				"source_zone": "hand",
				"source_index": 0,
			},
		}
		battle.play_presentation([energy_event], 45, 0, energy_snapshot)
		var energy_slot: Variant = battle.get_slot_view(0, "active")
		_check(
			not energy_slot.is_presentation_hidden(),
			"Energy attachment hid the target Pokemon during presentation",
		)
		var normalized_energy := PresentationEvent.normalize(energy_event, 45, 0, 0)
		var energy_event_id := str(normalized_energy.get("event_id", ""))
		var energy_covers: Array = battle._presentation_covers.get(
			energy_event_id,
			[],
		)
		_check(
			energy_covers.size() == 1,
			"Energy attachment did not stage an old-slot presentation cover",
		)
		var energy_starts: Array[Vector2] = battle._source_points_for_event(
			{"player": 0, "zone": "hand", "index": 0},
			["sv1-ener-5"],
			1,
			fallback_start,
		)
		_check(
			energy_starts.size() == 1
			and energy_starts[0].distance_to(energy_start_expected) < 0.01,
			"Energy attachment did not fly from its previous hand position",
		)
		battle._on_presentation_event_finished(normalized_energy)
		_check(
			not battle._presentation_covers.has(energy_event_id),
			"Energy attachment cover was not released after presentation",
		)
		_check(
			not energy_slot.is_presentation_hidden(),
			"Energy attachment left the target Pokemon hidden after landing",
		)
		battle.director.clear_for_resync()
		battle._clear_transient_visuals()

		state.players[0].active = PokemonState.new("svi-chim")
		state.players[0].active.placed_this_turn = false
		state.players[0].hand = ["svi-monf"]
		battle.update_view(state, 0, rows, "", false, "local")
		var evolve_snapshot: Dictionary = battle.capture_presentation_snapshot()
		var evolve_snapshot_row: Dictionary = evolve_snapshot.get("slots", {}).get(
			"0:active",
			{},
		)
		_check(
			str(evolve_snapshot_row.get("card_id", "")) == "svi-chim"
			and not bool(evolve_snapshot_row.get("empty", true)),
			"Evolution presentation snapshot did not capture the old active slot: %s" % JSON.stringify(evolve_snapshot_row),
		)
		state.players[0].hand.clear()
		state.players[0].active.evolution_stack_ids.append("svi-chim")
		state.players[0].active.card_id = "svi-monf"
		battle.update_view(state, 0, rows, "", false, "local")
		var evolve_event := {
			"event_type": "pokemon_evolved",
			"actor": 0,
			"card_id": "svi-monf",
			"source": {"player": 0, "zone": "hand", "index": 0},
			"target": {"player": 0, "slot": "active"},
			"data": {
				"player": 0,
				"slot": "active",
				"card_id": "svi-monf",
				"source_zone": "hand",
				"source_index": 0,
			},
		}
		battle.play_presentation([evolve_event], 46, 0, evolve_snapshot)
		var evolved_slot: Variant = battle.get_slot_view(0, "active")
		_check(
			not evolved_slot.is_presentation_hidden(),
			"Evolution hid the target Pokemon during presentation",
		)
		_check(
			evolved_slot.card_id == "svi-monf",
			"Evolution target did not keep the post-refresh evolved Pokemon visible",
		)
		var normalized_evolve := PresentationEvent.normalize(evolve_event, 46, 0, 0)
		var evolve_event_id := str(normalized_evolve.get("event_id", ""))
		var evolve_covers: Array = battle._presentation_covers.get(
			evolve_event_id,
			[],
		)
		_check(
			evolve_covers.size() == 1,
			"Evolution did not stage an old-Pokemon presentation cover",
		)
		battle._on_presentation_event_finished(normalized_evolve)
		_check(
			not battle._presentation_covers.has(evolve_event_id),
			"Evolution cover was not released after presentation",
		)
		battle.director.clear_for_resync()
		battle._clear_transient_visuals()

		var legacy_energy_event := PresentationEvent.normalize({
			"event_type": "energy_attached",
			"data": {
				"player": 0,
				"slot": "active",
				"card_id": "sv1-ener-5",
			},
		}, 47, 0, 0)
		var legacy_source: Dictionary = legacy_energy_event.get("source", {})
		var legacy_target: Dictionary = legacy_energy_event.get("target", {})
		_check(
			str(legacy_target.get("slot", "")) == "active"
			and str(legacy_source.get("slot", "")).is_empty(),
			"Legacy data-only energy event did not normalize to a target-only slot",
		)

		state.players[0].hand = ["sv1-189"]
		state.stadium_card_id = ""
		battle.update_view(state, 0, rows, "", false, "local")
		var stadium_snapshot: Dictionary = battle.capture_presentation_snapshot()
		state.players[0].hand.clear()
		state.stadium_card_id = "sv1-189"
		battle.update_view(state, 0, rows, "", false, "local")
		var stadium_event := {
			"event_type": "stadium_changed",
			"actor": 0,
			"card_id": "sv1-189",
			"source": {"player": 0, "zone": "hand", "index": 0},
			"target": {"player": 0, "zone": "stadium"},
			"data": {"player": 0, "card_id": "sv1-189"},
		}
		battle.play_presentation([stadium_event], 43, 0, stadium_snapshot)
		var stadium_zone: Variant = battle.zones["stadium"]
		_check(
			stadium_zone.is_presentation_hidden(),
			"Stadium zone exposed the new card before landing",
		)
		battle._on_presentation_event_finished(
			PresentationEvent.normalize(stadium_event, 43, 0, 0))
		_check(
			not stadium_zone.is_presentation_hidden(),
			"Stadium zone did not reveal after the card landed",
		)
		battle.director.clear_for_resync()
		battle._clear_transient_visuals()

		var settings_node: Node = root.get_node("AppSettings")
		var previous_animation_mode := str(settings_node.get("animation_mode"))
		settings_node.call(
			"update",
			float(settings_node.get("master_volume")),
			bool(settings_node.get("muted")),
			true,
			int(settings_node.get("card_cache_size")),
			"reduced",
		)
		state.players[0].hand = ["sv1-104"]
		state.players[0].deck = ["sv1-151"]
		battle.update_view(state, 0, rows, "", false, "local")
		var reduced_snapshot: Dictionary = battle.capture_presentation_snapshot()
		state.players[0].deck.clear()
		state.players[0].hand.append("sv1-151")
		battle.update_view(state, 0, rows, "", false, "local")
		battle.play_presentation([draw_event], 44, 0, reduced_snapshot)
		var reduced_drawn: Variant = battle.hand_views[1]
		_check(
			reduced_drawn.is_presentation_hidden(),
			"Reduced motion draw exposed the new hand card before reveal",
		)
		battle._on_presentation_event_finished(
			PresentationEvent.normalize(draw_event, 44, 0, 0))
		_check(
			not reduced_drawn.is_presentation_hidden(),
			"Reduced motion draw did not reveal the hand card",
		)
		battle.director.clear_for_resync()
		battle._clear_transient_visuals()
		settings_node.call(
			"update",
			float(settings_node.get("master_volume")),
			bool(settings_node.get("muted")),
			previous_animation_mode == "reduced",
			int(settings_node.get("card_cache_size")),
			previous_animation_mode,
		)
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
	status_pokemon.status_conditions.assign(["POISONED"])
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
		var step: StepResult = ui._execute_action(_playout_action(actions, ui.state, ui.catalog))
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


func _run_compiled_effect_examples(
	fixture: Dictionary,
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	var examples: Dictionary = fixture.get("compiled_effect_examples", {})
	_check(examples.size() == 78, "Expected one compiled example for every effect type")
	for effect_type in examples:
		var state := _effect_state()
		var stack := ResolutionStack.new()
		stack.push_effect(Dictionary(examples[effect_type]), 0, "active")
		var step := engine.effect_engine.resolve(
			state, stack, PortableRandomSource.new(20260620))
		_check(
			step.error_code not in [
				"missing_vm_op",
				"unknown_continuation",
				"unknown_effect",
				"unsupported_vm_op",
			],
			"Compiled effect dispatch failed for %s: %s" % [effect_type, step.message],
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
				step.error_code not in [
					"missing_vm_op",
					"unknown_continuation",
					"unknown_effect",
					"unsupported_vm_op",
				],
				"Compiled effect continuation failed for %s: %s" % [effect_type, step.message],
			)
		_check(guard < 32, "Compiled effect choice chain exceeded guard for %s" % effect_type)
		if step.pending_choice:
			var saved := ResolutionStack.from_dict(state.resolution_stack)
			_check(
				saved.to_dict() == ResolutionStack.from_dict(saved.to_dict()).to_dict(),
				"Pending compiled effect stack is not serializable for %s" % effect_type,
			)


func _run_native_command_spec_tests(engine: GameEngine) -> void:
	var state := _effect_state()
	state.players[0].deck = ["sv1-ener-2"]
	var stack := ResolutionStack.new()
	stack.push_effect({"op": "draw_cards", "args": {"amount": 1}, "branches": {}}, 0, "active")
	var step := engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260621))
	_check(step.success, "Native draw_cards command spec failed: %s" % step.message)
	_check(state.players[0].hand.has("sv1-ener-2"), "Native draw_cards did not draw a card")

	state = _effect_state()
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "legacy_effect",
		"args": {"effect_type": "draw", "amount": 1},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026062101))
	_check(
		not step.success and step.error_code == "unsupported_vm_op",
		"Unknown compiled VM op was dispatched through legacy effect fallback",
	)

	state = _effect_state()
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage",
		"args": {"effect_type": "damage", "amount": 20},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026062103))
	_check(
		not step.success and step.error_code == "legacy_effect_type_arg",
		"Native VM op accepted legacy effect_type args at runtime",
	)

	state = _effect_state()
	stack = ResolutionStack.new()
	stack.push_effect({"effect_type": "draw", "params": {"amount": 1}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026062102))
	_check(
		not step.success and step.error_code == "missing_vm_op",
		"Raw effect dict was accepted as a VM stack command",
	)

	state = _effect_state()
	stack = ResolutionStack.new()
	stack.push_effect({"op": "deal_damage", "args": {"amount": 20}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260622))
	_check(step.success, "Native deal_damage command spec failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 3, "Native deal_damage did not damage opponent active")

	state = _effect_state()
	stack = ResolutionStack.new()
	stack.push_effect({"op": "apply_status", "args": {"status": "asleep"}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260623))
	_check(step.success, "Native apply_status command spec failed: %s" % step.message)
	_check("ASLEEP" in state.players[1].active.status_conditions, "Native apply_status did not apply status")

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].deck = ["sv1-ener-2", "sv1-ener-2"]
	stack = ResolutionStack.new()
	stack.push_effect({"op": "draw_until", "args": {"target_hand_size": 2}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260624))
	_check(step.success, "Native draw_until command spec failed: %s" % step.message)
	_check(state.players[0].hand.size() == 2, "Native draw_until did not draw to target hand size")

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-1"]
	state.players[1].hand = ["sv1-ener-2", "sv1-ener-3", "sv1-ener-4"]
	state.players[0].deck = ["sv1-ener-5", "sv1-ener-6", "sv1-ener-7"]
	stack = ResolutionStack.new()
	stack.push_effect({"op": "draw_until_more_than_opponent", "args": {}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606241))
	_check(step.success, "Native draw_until_more_than_opponent command spec failed: %s" % step.message)
	_check(state.players[0].hand.size() == 4,
		"Native draw_until_more_than_opponent did not draw above opponent hand size")

	state = _effect_state()
	stack = ResolutionStack.new()
	stack.push_effect({"op": "heal_all", "args": {"amount": 20}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260625))
	_check(step.success, "Native heal_all command spec failed: %s" % step.message)
	_check(state.players[0].active.damage_counters == 0, "Native heal_all did not heal active Pokemon")

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].deck = ["sv1-ener-2"]
	state.players[0].active.damage_counters = 4
	state.players[0].bench[0].damage_counters = 5
	stack = ResolutionStack.new()
	stack.push_effect({"op": "draw_cards", "args": {"amount": 1}, "branches": {}}, 0, "active")
	stack.push_effect({"op": "choose_heal_damage", "args": {"amount": 30}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606251))
	_check(step.success and step.pending_choice != null,
		"Native choose_heal_damage command spec did not pause for choice")
	var heal_option := _choice_id_for_slot(step.pending_choice, "bench_0")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [heal_option]),
		PortableRandomSource.new(202606252),
	)
	_check(step.success, "Native choose_heal_damage command spec failed to resume: %s" % step.message)
	_check(state.players[0].active.damage_counters == 4,
		"Native choose_heal_damage healed the wrong Pokemon")
	_check(state.players[0].bench[0].damage_counters == 2,
		"Native choose_heal_damage did not heal selected Pokemon")
	_check(state.players[0].hand == ["sv1-ener-2"],
		"Native choose_heal_damage did not resume remaining command")

	state = _effect_state()
	state.players[0].was_ko_by_attack = true
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "conditional_status",
		"args": {"status": "paralyzed", "condition": "ko_by_attack_last_turn"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260626))
	_check(step.success, "Native conditional_status command spec failed: %s" % step.message)
	_check("PARALYZED" in state.players[1].active.status_conditions, "Native conditional_status did not apply status")

	state = _effect_state()
	state.turn_number = 7
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "apply_dazzling_beam",
		"args": {"target": "opponent_active"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606261))
	_check(step.success, "Native apply_dazzling_beam command spec failed: %s" % step.message)
	_check(state.players[1].active.dazzled,
		"Native dazzling_beam did not set dazzled marker")

	state.players[1].active.dazzled = false
	state.players[1].active.all_prevented_next_turn = true
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "apply_dazzling_beam",
		"args": {"target": "opponent_active"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606262))
	_check(step.success, "Native dazzling_beam immunity branch failed: %s" % step.message)
	_check(not state.players[1].active.dazzled,
		"Native dazzling_beam ignored effect immunity")
	_check(not state.players[1].active.all_prevented_next_turn,
		"Native dazzling_beam did not consume effect immunity")

	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "apply_attack_lock_basic",
		"args": {"target": "opponent_active"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606263))
	_check(step.success, "Native apply_attack_lock_basic command spec failed: %s" % step.message)
	_check(state.players[1].active.attack_locked,
		"Native attack_lock_basic did not lock basic active")

	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "apply_outgoing_damage_reduction",
		"args": {
			"target": "opponent_active",
			"amount": 50,
		},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606264))
	_check(step.success, "Native apply_outgoing_damage_reduction command spec failed: %s" % step.message)
	_check(state.players[1].active.outgoing_damage_reduction_next_turn == 50,
		"Native apply_outgoing_damage_reduction did not set reduction marker")

	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "apply_self_attack_lock",
		"args": {"attack_name": "漆黑之刃"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606265))
	_check(step.success, "Native apply_self_attack_lock command spec failed: %s" % step.message)
	_check(int(state.players[0].active.attack_locked_names.get("漆黑之刃", -1)) == 7,
		"Native self_attack_lock did not store the attack lock turn")

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-5"])
	state.players[1].active = PokemonState.new("sv2-delib")
	state.players[1].active.placed_this_turn = false
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "register_aura_damage_reduction",
		"args": {"reduction": 20},
		"branches": {},
	}, 1, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026062651))
	_check(step.success, "Native register_aura_damage_reduction failed: %s" % step.message)
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(2026062652),
	)
	_check(step.success, "Native aura_damage_reduction attack failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 0,
		"Native aura_damage_reduction modifier did not reduce attack damage to zero")

	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.placed_this_turn = false
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	_set_energy_cards(state.players[0].active, ["sv1-ener-2"])
	state.players[1].active = PokemonState.new("svd-seviper")
	state.players[1].active.placed_this_turn = false
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "register_aura_damage_boost",
		"args": {
			"amount": 30,
			"attacker_subtype": "Basic",
			"defender_type": "Darkness",
		},
		"branches": {},
	}, 0, "bench_0")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026062653))
	_check(step.success, "Native register_aura_damage_boost failed: %s" % step.message)
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(2026062654),
	)
	_check(step.success, "Native aura_damage_boost attack failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 6,
		"Native aura_damage_boost modifier did not boost attack damage")

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-5"])
	state.players[1].active = PokemonState.new("sv2-delib")
	state.players[1].active.placed_this_turn = false
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "register_reactive_thorns",
		"args": {
			"filter_names": ["信使鸟"],
			"per_pokemon": 1,
		},
		"branches": {},
	}, 1, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026062655))
	_check(step.success, "Native register_reactive_thorns failed: %s" % step.message)
	_check(state.players[1].active.modifiers.size() == 1,
		"Native reactive_thorns register_trigger did not store a VM modifier")
	var reactive_modifier := Dictionary(state.players[1].active.modifiers[0])
	_check(
		str(reactive_modifier.get("modifier_kind", "")) == "reactive_thorns"
		and not reactive_modifier.has("effect_type"),
		"Native modifier row must store modifier_kind instead of effect_type",
	)
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(2026062656),
	)
	_check(step.success, "Native reactive_thorns attack failed: %s" % step.message)
	_check(
		state.players[0].active != null and state.players[0].active.damage_counters == 1,
		"Native reactive_thorns trigger did not place counters on attacker; counters=%s" % [
			str(state.players[0].active.damage_counters if state.players[0].active else -1)
		],
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-5"])
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "register_conditional_zero_retreat",
		"args": {"energy_type": "psychic"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026062657))
	_check(step.success, "Native register_conditional_zero_retreat failed: %s" % step.message)
	_check(engine.validator.effective_retreat_cost(state, state.players[0]) == 0,
		"Native conditional_zero_retreat modifier did not set retreat cost to zero")

	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-8", "sv1-ener-8", "sv1-ener-8"])
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "register_conditional_hp_boost",
		"args": {
			"energy_type": "Metal",
			"threshold": 3,
			"amount": 100,
		},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026062658))
	_check(step.success, "Native register_conditional_hp_boost failed: %s" % step.message)
	_check(state.players[0].active.current_hp(engine.catalog) == 150,
		"Native conditional_hp_boost modifier did not increase HP")
	var hp_snapshot := GameState.from_dict(state.snapshot())
	_check(hp_snapshot.players[0].active.current_hp(engine.catalog) == 150,
		"Native conditional_hp_boost modifier was not preserved in snapshot")

	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-2"])
	state.players[1].active = PokemonState.new("sv2-delib")
	state.players[1].active.placed_this_turn = false
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "register_tool_modifier",
		"args": {"effect": "damage_boost_10"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026062659))
	_check(step.success, "Native register_tool_modifier failed: %s" % step.message)
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(2026062660),
	)
	_check(step.success, "Native tool modifier attack failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 4,
		"Native register_tool_modifier damage boost did not apply")

	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.damage_counters = 99
	_set_energy_cards(state.players[0].active, ["sv1-ener-2"])
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "register_tool_exp_share",
		"args": {},
		"branches": {},
	}, 0, "bench_0")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026062661))
	_check(step.success, "Native register_tool_exp_share failed: %s" % step.message)
	var ko_events: Array[Dictionary] = []
	engine._resolve_knockouts(state, 1, ko_events, true)
	_check(
		state.players[0].active == null
		and state.players[0].bench[0].energy_card_ids == ["sv1-ener-2"]
		and "sv1-ener-2" not in state.players[0].discard,
		"Native tool_exp_share modifier did not move basic energy before KO discard",
	)

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].deck = ["sv1-ener-2"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "flip_coin",
		"args": {},
		"branches": {
			"on_heads": [{"op": "draw_cards", "args": {"amount": 1}, "branches": {}}],
			"on_tails": [{"op": "draw_cards", "args": {"amount": 1}, "branches": {}}],
		},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260627))
	_check(step.success and step.pending_choice != null, "Native flip_coin command spec did not pause for choice")
	var coin_stack := ResolutionStack.from_dict(state.resolution_stack)
	var coin_frame := Dictionary(coin_stack.frames[coin_stack.frames.size() - 1])
	var coin_data := Dictionary(coin_frame.get("data", {}))
	_check(
		str(coin_data.get("coin_kind", "")) == "branch"
		and not coin_data.has("effect_type"),
		"Native flip_coin continuation must store coin_kind instead of effect_type",
	)
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, []),
		PortableRandomSource.new(20260628),
	)
	_check(step.success, "Native flip_coin command spec failed to resume: %s" % step.message)
	_check(state.players[0].hand.size() == 1, "Native flip_coin branch did not resolve after choice")

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].deck = ["sv1-ener-2"]
	stack = ResolutionStack.new()
	stack.push_effect({"op": "draw_cards", "args": {"amount": 1}, "branches": {}}, 0, "active")
	stack.push_effect({
		"op": "switch_pokemon",
		"args": {"target": "self"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260629))
	_check(step.success and step.pending_choice != null,
		"Native switch_pokemon command spec did not pause for choice")
	var switch_option := _choice_id_for_slot(step.pending_choice, "bench_1")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [switch_option]),
		PortableRandomSource.new(20260630),
	)
	_check(step.success, "Native switch_pokemon command spec failed to resume: %s" % step.message)
	_check(state.players[0].active.card_id == "svf-rio", "Native switch_pokemon did not switch active Pokemon")
	_check(state.players[0].hand.size() == 1, "Native switch_pokemon did not resume remaining command")

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2"]
	state.players[0].deck = ["sv1-ener-3", "sv1-ener-4"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "shuffle_then_draw_cards",
		"args": {"shuffle_hand": true, "draw": 2},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606301))
	_check(step.success, "Native shuffle_then_draw_cards command spec failed: %s" % step.message)
	var shuffle_draw_cards := state.players[0].hand.duplicate()
	shuffle_draw_cards.append_array(state.players[0].deck)
	shuffle_draw_cards.sort()
	_check(
		state.players[0].hand.size() == 2
		and state.players[0].deck.size() == 2
		and shuffle_draw_cards == ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3", "sv1-ener-4"],
		"Native shuffle_then_draw_cards did not preserve hand/deck cards",
	)

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-1"]
	state.players[0].deck = ["sv1-ener-2"]
	state.players[1].hand = []
	state.players[1].deck = ["sv1-ener-3"]
	stack = ResolutionStack.new()
	stack.push_effect({"op": "judge", "args": {"draw": 1}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606302))
	_check(step.success, "Native judge command spec failed: %s" % step.message)
	var judge_cards := state.players[0].hand.duplicate()
	judge_cards.append_array(state.players[0].deck)
	judge_cards.sort()
	_check(
		state.players[0].hand.size() == 1
		and state.players[0].deck.size() == 1
		and judge_cards == ["sv1-ener-1", "sv1-ener-2"],
		"Native judge did not preserve shuffled player's cards",
	)
	_check(
		state.players[1].hand.is_empty()
		and state.players[1].deck == ["sv1-ener-3"],
		"Native judge did not skip empty-hand player",
	)

	state = _effect_state()
	state.players[0].deck = ["sv1-ener-2"]
	state.players[0].discard = ["sv1-104", "sv1-ener-1", "svf-potion"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "shuffle_from_discard_to_deck",
		"args": {"filter": "pokemon_and_energy", "count": 2},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606303))
	_check(step.success and step.pending_choice != null,
		"Native recover_from_discard shuffle path did not pause for choice")
	var recover_shuffle_options: Array[String] = [
		str(step.pending_choice.options[0]["option_id"]),
		str(step.pending_choice.options[1]["option_id"]),
	]
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, recover_shuffle_options),
		PortableRandomSource.new(202606304),
	)
	_check(step.success, "Native recover_from_discard shuffle path failed: %s" % step.message)
	var recovered_deck := state.players[0].deck.duplicate()
	recovered_deck.sort()
	_check(
		state.players[0].discard == ["svf-potion"]
		and recovered_deck == ["sv1-104", "sv1-ener-1", "sv1-ener-2"],
		"Native recover_from_discard did not shuffle selected discard cards into deck",
	)

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].discard = ["sv1-104", "sv1-ener-1", "svf-potion"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "recover_clara",
		"args": {"pokemon_count": 1, "energy_count": 1},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606305))
	_check(step.success and step.pending_choice != null,
		"Native recover_from_discard clara path did not pause for choice")
	var clara_options: Array[String] = [
		str(step.pending_choice.options[0]["option_id"]),
		str(step.pending_choice.options[1]["option_id"]),
	]
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, clara_options),
		PortableRandomSource.new(202606306),
	)
	_check(step.success, "Native recover_from_discard clara path failed: %s" % step.message)
	_check(
		state.players[0].hand == ["sv1-104", "sv1-ener-1"]
		and state.players[0].discard == ["svf-potion"],
		"Native recover_from_discard clara path did not recover selected cards to hand",
	)

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2"]
	state.players[0].deck = ["sv1-ener-3", "sv1-ener-4"]
	stack = ResolutionStack.new()
	stack.push_effect({"op": "hand_to_bottom_then_draw", "args": {}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606307))
	_check(step.success and step.pending_choice != null,
		"Native hand_to_bottom_then_draw did not pause for choice")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(202606308),
	)
	_check(step.success, "Native hand_to_bottom_then_draw failed: %s" % step.message)
	_check(
		state.players[0].hand == ["sv1-ener-2", "sv1-ener-4"]
		and state.players[0].deck == ["sv1-ener-1", "sv1-ener-3"],
		"Native hand_to_bottom_then_draw did not bottom selected card and draw",
	)

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3"]
	state.players[0].deck = ["sv1-ener-4", "sv1-ener-5"]
	state.players[0].discard = []
	state.players[1].active = PokemonState.new("sv2-delib")
	state.players[1].bench[0] = PokemonState.new("sv1-104")
	state.players[1].bench[1] = null
	stack = ResolutionStack.new()
	stack.push_effect({"op": "zinnia_resolve", "args": {}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606309))
	_check(step.success and step.pending_choice != null,
		"Native zinnia_resolve did not pause for discard choice")
	var zinnia_options: Array[String] = [
		str(step.pending_choice.options[0]["option_id"]),
		str(step.pending_choice.options[1]["option_id"]),
	]
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, zinnia_options),
		PortableRandomSource.new(202606310),
	)
	_check(step.success, "Native zinnia_resolve failed: %s" % step.message)
	var zinnia_discard := state.players[0].discard.duplicate()
	zinnia_discard.sort()
	_check(
		zinnia_discard == ["sv1-ener-1", "sv1-ener-2"]
		and state.players[0].hand == ["sv1-ener-3", "sv1-ener-5", "sv1-ener-4"],
		"Native zinnia_resolve did not discard and draw expected cards",
	)

	state = _effect_state()
	state.players[0].deck = ["sv1-ener-1", "sv1-104", "sv1-ener-2"]
	state.players[0].bench[0] = null
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "search_cards",
		"args": {
			"from_zone": "deck",
			"filter": "basic_pokemon",
			"destination": "bench",
			"count": 1,
		},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606311))
	_check(step.success and step.pending_choice != null,
		"Native search_cards deck path did not pause for choice")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(202606312),
	)
	_check(step.success, "Native search_cards deck path failed: %s" % step.message)
	var search_deck_remaining := state.players[0].deck.duplicate()
	search_deck_remaining.sort()
	_check(
		state.players[0].bench[0] != null
		and state.players[0].bench[0].card_id == "sv1-104"
		and search_deck_remaining == ["sv1-ener-1", "sv1-ener-2"],
		"Native search_cards deck path did not bench selected Pokemon",
	)

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].discard = ["sv1-ener-1", "svf-potion"]
	state.players[0].deck = ["sv1-ener-2"]
	stack = ResolutionStack.new()
	stack.push_effect({"op": "draw_cards", "args": {"amount": 1}, "branches": {}}, 0, "active")
	stack.push_effect({
		"op": "search_cards",
		"args": {
			"from_zone": "discard",
			"filter": "basic_energy",
			"destination": "hand",
			"count": 1,
			"min_select": 0,
		},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606313))
	_check(step.success and step.pending_choice != null,
		"Native search_cards discard path did not pause for choice")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(202606314),
	)
	_check(step.success, "Native search_cards discard path failed: %s" % step.message)
	_check(
		state.players[0].hand == ["sv1-ener-1", "sv1-ener-2"]
		and state.players[0].discard == ["svf-potion"],
		"Native search_cards discard path did not move card and resume draw",
	)

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].deck = ["sv1-ener-1", "svf-potion", "svl-vitb"]
	stack = ResolutionStack.new()
	stack.push_effect({"op": "search_item_and_tool", "args": {}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606315))
	_check(step.success and step.pending_choice != null,
		"Native search_item_and_tool did not pause for choice")
	var arven_options: Array[String] = [
		str(step.pending_choice.options[0]["option_id"]),
		str(step.pending_choice.options[1]["option_id"]),
	]
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, arven_options),
		PortableRandomSource.new(202606316),
	)
	_check(step.success, "Native search_item_and_tool failed: %s" % step.message)
	_check(
		state.players[0].hand == ["svf-potion", "svl-vitb"]
		and state.players[0].deck == ["sv1-ener-1"],
		"Native search_item_and_tool did not move item and tool to hand",
	)

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].deck = ["sv1-ener-1", "svf-potion"]
	state.players[0].discard = []
	stack = ResolutionStack.new()
	stack.push_effect({"op": "trekking_shoes", "args": {}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606317))
	_check(step.success and step.pending_choice != null,
		"Native trekking_shoes did not pause for confirm choice")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, ["confirm:no"]),
		PortableRandomSource.new(202606318),
	)
	_check(step.success, "Native trekking_shoes failed: %s" % step.message)
	_check(
		state.players[0].hand == ["sv1-ener-1"]
		and state.players[0].discard == ["svf-potion"],
		"Native trekking_shoes did not discard top and draw next card",
	)

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "flip_coin_repeat_damage",
		"args": {"flips": 3, "damage_per_head": 10},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606319))
	_check(step.success and step.pending_choice != null,
		"Native flip_coin_repeat_damage did not create coin request")
	var repeat_results: Array = step.pending_choice.metadata.get("predetermined_flips", [])
	var repeat_heads := 0
	for result in repeat_results:
		if bool(result):
			repeat_heads += 1
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, []),
		PortableRandomSource.new(202606320),
	)
	_check(step.success, "Native flip_coin_repeat_damage failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == repeat_heads,
		"Native flip_coin_repeat_damage produced damage inconsistent with flips")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "flip_until_tails",
		"args": {"per_head": 20},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606321))
	_check(step.success and step.pending_choice != null,
		"Native flip_until_tails did not create coin request")
	var until_results: Array = step.pending_choice.metadata.get("predetermined_flips", [])
	var until_heads := 0
	for result in until_results:
		if bool(result):
			until_heads += 1
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, []),
		PortableRandomSource.new(202606322),
	)
	_check(step.success, "Native flip_until_tails failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == until_heads * 2,
		"Native flip_until_tails produced damage inconsistent with flips")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.push_effect({"op": "flip_coin_then_ko", "args": {}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606323))
	_check(step.success and step.pending_choice != null,
		"Native flip_coin_then_ko did not create coin request")
	var ko_results: Array = step.pending_choice.metadata.get("predetermined_flips", [])
	var should_ko := ko_results.size() >= 2 and bool(ko_results[0]) and bool(ko_results[1])
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, []),
		PortableRandomSource.new(202606324),
	)
	_check(step.success, "Native flip_coin_then_ko failed: %s" % step.message)
	_check(state.players[1].active.is_knocked_out(engine.catalog) == should_ko,
		"Native flip_coin_then_ko result did not match predetermined flips")

	state = _effect_state()
	state.first_player_idx = 0
	state.active_player_idx = 1
	state.turn_number = 2
	state.players[1].hand = []
	state.players[1].deck = ["svg2-zaru", "sv1-104", "svg2-tort"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "conditional_search",
		"args": {"filter": "grass_pokemon", "max_count": 3, "default_count": 1},
		"branches": {},
	}, 1, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606325))
	_check(step.success and step.pending_choice != null,
		"Native conditional_search did not pause for choice")
	_check(step.pending_choice.min_select == 0 and step.pending_choice.max_select == 2,
		"Native conditional_search did not expose optional second-turn search bounds")
	var conditional_options: Array[String] = []
	for option in step.pending_choice.options:
		conditional_options.append(str(option["option_id"]))
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, conditional_options),
		PortableRandomSource.new(202606326),
	)
	_check(step.success, "Native conditional_search failed: %s" % step.message)
	_check(
		state.players[1].hand == ["svg2-zaru", "svg2-tort"]
		and state.players[1].deck == ["sv1-104"],
		"Native conditional_search did not move selected Grass Pokemon",
	)

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].deck = ["svf-potion", "sv1-ener-1"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "look_top_deck",
		"args": {
			"count": 2,
			"take": 1,
			"filter": "energy",
			"destination": "hand",
			"rest_bottom": true,
		},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063261))
	_check(step.success and step.pending_choice != null,
		"Native look_top_deck did not pause for hand choice")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(2026063262),
	)
	_check(step.success, "Native look_top_deck hand choice failed: %s" % step.message)
	_check(
		state.players[0].hand == ["sv1-ener-1"]
		and state.players[0].deck == ["svf-potion"],
		"Native look_top_deck did not move selected top card to hand",
	)

	state = _effect_state()
	state.players[0].bench[0] = PokemonState.new("svl-pikaex")
	state.players[0].deck = ["svf-potion", "sv1-ener-4"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "look_top_deck",
		"args": {
			"count": 2,
			"take": 1,
			"filter": "lightning_energy",
			"destination": "bench_energy",
			"shuffle_rest": true,
			"min_select": 0,
		},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063263))
	_check(step.success and step.pending_choice != null,
		"Native look_top_deck did not pause for bench-energy choice")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(2026063264),
	)
	_check(step.success, "Native look_top_deck bench-energy choice failed: %s" % step.message)
	_check(
		state.players[0].bench[0].energy_card_ids == ["sv1-ener-4"]
		and state.players[0].deck == ["svf-potion"],
		"Native look_top_deck did not attach Lightning energy to the only bench target",
	)

	state = _effect_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].deck = ["svf-potion", "sv1-ener-1", "sv1-ener-2"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "look_top_attach_energy",
		"args": {"count": 3, "take": 2, "filter": "basic_energy"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063265))
	_check(step.success and step.pending_choice != null,
		"Native look_top_attach_energy did not pause for energy choice")
	var top_energy_ids: Array[String] = []
	for option in step.pending_choice.options:
		top_energy_ids.append(str(option["option_id"]))
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, top_energy_ids),
		PortableRandomSource.new(2026063266),
	)
	_check(step.success and step.pending_choice != null,
		"Native look_top_attach_energy did not continue to target choice")
	var attach_target_id := ""
	for option_value in step.pending_choice.options:
		var option: Dictionary = option_value
		if str(option.get("value", {}).get("slot", "")) == "bench_0":
			attach_target_id = str(option.get("option_id", ""))
			break
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [attach_target_id]),
		PortableRandomSource.new(2026063267),
	)
	_check(step.success, "Native look_top_attach_energy target choice failed: %s" % step.message)
	_check(
		state.players[0].bench[0].energy_card_ids == ["sv1-ener-2", "sv1-ener-1"]
		and state.players[0].deck == ["svf-potion"],
		"Native look_top_attach_energy did not attach selected top energies",
	)

	state = _effect_state()
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].hand = ["sv1-ener-1"]
	state.players[0].deck = ["sv1-ener-1"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "draw_and_attach_energy",
		"args": {"energy_count": 2, "energy_type": "Grass", "min_select": 0},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063268))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.min_select == 0
		and step.pending_choice.max_select == 2,
		"Native draw_and_attach_energy did not expose optional energy distribution",
	)
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(2026063269),
	)
	_check(step.success, "Native draw_and_attach_energy choice failed: %s" % step.message)
	_check(
		state.players[0].bench[0].energy_card_ids.size() == 1
		and state.players[0].hand.size() == 1,
		"Native draw_and_attach_energy did not allow attaching fewer than max",
	)

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3"]
	state.players[0].deck = ["sv1-104"]
	state.players[0].discard = []
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "conditional",
		"args": {},
		"branches": {
			"cost": [{
				"op": "discard_cards",
				"args": {"amount": 2, "from": "hand"},
				"branches": {},
			}],
			"on_pay": [{
				"op": "search_cards",
				"args": {
					"from_zone": "deck",
					"filter": "pokemon",
					"destination": "hand",
					"count": 1,
				},
				"branches": {},
			}],
		},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063270))
	_check(step.success and step.pending_choice != null,
		"Native conditional did not pause for cost choice")
	var discard_ids: Array[String] = []
	for index in range(2):
		discard_ids.append(str(step.pending_choice.options[index]["option_id"]))
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, discard_ids),
		PortableRandomSource.new(2026063271),
	)
	_check(step.success and step.pending_choice != null,
		"Native conditional did not continue to on_pay search")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(2026063272),
	)
	_check(step.success, "Native conditional search branch failed: %s" % step.message)
	_check(
		state.players[0].discard.size() == 2
		and "sv1-ener-1" in state.players[0].discard
		and "sv1-ener-2" in state.players[0].discard
		and state.players[0].hand == ["sv1-ener-3", "sv1-104"],
		"Native conditional did not resolve cost before on_pay branch",
	)

	state = _effect_state()
	state.players[0].was_ko_by_attack = true
	state.players[0].deck = ["sv1-ener-1"]
	state.players[0].hand = []
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "conditional",
		"args": {"condition": "ko_by_attack_last_turn"},
		"branches": {
			"on_pay": [{
				"op": "draw_cards",
				"args": {"amount": 1},
				"branches": {},
			}],
		},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063273))
	_check(step.success, "Native conditional ko condition failed: %s" % step.message)
	_check(
		not state.players[0].was_ko_by_attack
		and state.players[0].hand == ["sv1-ener-1"],
		"Native conditional did not consume ko marker and resolve branch",
	)

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3"]
	state.players[0].deck = ["sv1-ener-4", "sv1-ener-5", "sv1-ener-6"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "hand_to_bottom_draw_until",
		"args": {"target_hand_size": 5},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063274))
	_check(step.success and step.pending_choice != null,
		"Native hand_to_bottom_draw_until did not pause for hand choice")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(2026063275),
	)
	_check(step.success, "Native hand_to_bottom_draw_until choice failed: %s" % step.message)
	_check(
		state.players[0].hand == ["sv1-ener-2", "sv1-ener-3", "sv1-ener-6", "sv1-ener-5", "sv1-ener-4"]
		and state.players[0].deck == ["sv1-ener-1"],
		"Native hand_to_bottom_draw_until did not put selected card on deck bottom",
	)

	state = _effect_state()
	state.players[0].active.energy_card_ids = []
	state.players[0].deck = ["sv1-ener-1", "sv1-ener-6"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "attach_energy",
		"args": {"amount": 1, "from_zone": "deck", "filter": "fighting", "to": "self"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063276))
	_check(step.success and step.pending_choice != null,
		"Native attach_energy self did not request target")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(2026063277),
	)
	_check(step.success, "Native attach_energy self choice failed: %s" % step.message)
	_check(
		state.players[0].active.energy_card_ids == ["sv1-ener-6"]
		and state.players[0].deck == ["sv1-ener-1"],
		"Native attach_energy self did not attach Fighting energy from deck",
	)

	state = _effect_state()
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[1] = PokemonState.new("svf-rio")
	state.players[0].hand = ["sv1-ener-4"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "attach_energy",
		"args": {"amount": 1, "from_zone": "hand", "filter": "lightning", "to": "bench", "optional": true},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063278))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.min_select == 0,
		"Native attach_energy optional bench did not expose optional target choice",
	)
	var bench_zero_attach := ""
	for option_value in step.pending_choice.options:
		var option: Dictionary = option_value
		if str(option.get("value", {}).get("slot", "")) == "bench_0":
			bench_zero_attach = str(option.get("option_id", ""))
			break
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [bench_zero_attach]),
		PortableRandomSource.new(2026063279),
	)
	_check(step.success, "Native attach_energy optional bench choice failed: %s" % step.message)
	_check(
		state.players[0].bench[0].energy_card_ids == ["sv1-ener-4"]
		and state.players[0].hand.is_empty(),
		"Native attach_energy optional bench did not attach hand energy",
	)

	state = _effect_state()
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[1] = PokemonState.new("svf-rio")
	state.players[0].deck = ["sv1-ener-1", "sv1-ener-2"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "attach_energy",
		"args": {
			"amount": 2,
			"from_zone": "deck",
			"filter": "basic_energy",
			"to": "bench",
			"max_per_target": 1,
			"min_select": 0,
		},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063280))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.request_type == "distribute_energy"
		and step.pending_choice.min_select == 0,
		"Native attach_energy bench distribution did not expose optional distribution",
	)
	var bench_distribution_ids: Array[String] = []
	for option in step.pending_choice.options:
		bench_distribution_ids.append(str(option["option_id"]))
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, bench_distribution_ids),
		PortableRandomSource.new(2026063281),
	)
	_check(step.success, "Native attach_energy bench distribution failed: %s" % step.message)
	_check(
		state.players[0].bench[0].energy_card_ids.size() == 1
		and state.players[0].bench[1].energy_card_ids.size() == 1
		and state.players[0].deck.is_empty(),
		"Native attach_energy bench distribution did not attach one energy per target",
	)

	state = _effect_state()
	state.players[0].active.energy_card_ids = []
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.turn_number = 2
	state.players[0].deck = ["sv1-ener-5", "sv1-ener-5", "sv1-ener-5"]
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "attach_energy",
		"args": {"amount": 1, "from_zone": "deck", "filter": "psychic", "to": "any", "going_second_bonus": 3},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063282))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.max_select == 3,
		"Native attach_energy going-second bonus did not expose three attachments",
	)
	var active_attach_id := ""
	for option_value in step.pending_choice.options:
		var option: Dictionary = option_value
		if str(option.get("value", {}).get("slot", "")) == "active":
			active_attach_id = str(option.get("option_id", ""))
			break
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [active_attach_id, active_attach_id, active_attach_id]),
		PortableRandomSource.new(2026063283),
	)
	_check(step.success, "Native attach_energy going-second choice failed: %s" % step.message)
	_check(
		state.players[0].active.energy_card_ids.size() == 3
		and state.players[0].deck.is_empty(),
		"Native attach_energy going-second bonus did not attach three energies to one target",
	)

	state = _effect_state()
	state.players[0].active = PokemonState.new("svg2-tort")
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[1] = null
	state.players[0].deck = ["sv1-ener-3", "sv1-ener-3"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "attach_energy",
		"args": {"amount": 2, "from_zone": "deck", "filter": "water", "to": "self_basic", "min_select": 0},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063284))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.options.size() == 1
		and str(step.pending_choice.options[0].get("value", {}).get("slot", "")) == "bench_0",
		"Native attach_energy self_basic did not restrict targets to Basic Pokemon",
	)
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [
			str(step.pending_choice.options[0]["option_id"]),
			str(step.pending_choice.options[0]["option_id"]),
		]),
		PortableRandomSource.new(2026063285),
	)
	_check(step.success, "Native attach_energy self_basic choice failed: %s" % step.message)
	_check(
		state.players[0].bench[0].energy_card_ids.size() == 2
		and state.players[0].deck.is_empty(),
		"Native attach_energy self_basic did not attach only to Basic target",
	)

	state = _effect_state()
	state.players[0].active.energy_card_ids = []
	state.players[0].discard = ["sv1-ener-2", "sv1-ener-1"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "attach_energy_from_discard",
		"args": {"amount": 1, "energy_type": "fire", "target": "self"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063286))
	_check(step.success and step.pending_choice != null,
		"Native attach_energy_from_discard self did not request target")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(2026063287),
	)
	_check(step.success, "Native attach_energy_from_discard self choice failed: %s" % step.message)
	_check(
		state.players[0].active.energy_card_ids == ["sv1-ener-2"]
		and state.players[0].discard == ["sv1-ener-1"],
		"Native attach_energy_from_discard did not attach Fire energy from discard",
	)

	state = _effect_state()
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[1] = PokemonState.new("svf-rio")
	state.players[0].discard = ["sv1-ener-7"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "attach_energy_from_discard",
		"args": {"amount": 1, "energy_type": "darkness", "target": "bench"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063288))
	_check(step.success and step.pending_choice != null,
		"Native attach_energy_from_discard bench did not request target")
	var bench_one_discard_attach := ""
	for option_value in step.pending_choice.options:
		var option: Dictionary = option_value
		if str(option.get("value", {}).get("slot", "")) == "bench_1":
			bench_one_discard_attach = str(option.get("option_id", ""))
			break
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [bench_one_discard_attach]),
		PortableRandomSource.new(2026063289),
	)
	_check(step.success, "Native attach_energy_from_discard bench choice failed: %s" % step.message)
	_check(
		state.players[0].bench[1].energy_card_ids == ["sv1-ener-7"]
		and state.players[0].discard.is_empty(),
		"Native attach_energy_from_discard did not attach Darkness energy to chosen bench",
	)

	state = _effect_state()
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[1] = PokemonState.new("svf-rio")
	state.players[0].discard = ["sv1-ener-1", "sv1-ener-2"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "attach_energy_from_discard",
		"args": {"amount": 2, "energy_type": "basic", "target": "bench", "min_select": 0},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063290))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.request_type == "distribute_energy"
		and step.pending_choice.min_select == 0,
		"Native attach_energy_from_discard distribution did not expose optional distribution",
	)
	var discard_distribution_ids: Array[String] = []
	for option in step.pending_choice.options:
		discard_distribution_ids.append(str(option["option_id"]))
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, discard_distribution_ids),
		PortableRandomSource.new(2026063291),
	)
	_check(step.success, "Native attach_energy_from_discard distribution failed: %s" % step.message)
	_check(
		state.players[0].bench[0].energy_card_ids.size() == 1
		and state.players[0].bench[1].energy_card_ids.size() == 1
		and state.players[0].discard.is_empty(),
		"Native attach_energy_from_discard did not distribute discard energies",
	)

	state = _effect_state()
	state.players[0].bench[0] = PokemonState.new("svd-seviper")
	state.players[0].bench[1] = PokemonState.new("sv2-delib")
	state.players[0].discard = ["sv1-ener-7"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "attach_energy_from_discard",
		"args": {
			"amount": 1,
			"energy_type": "Darkness",
			"target": "bench",
			"target_pokemon_type": "Darkness",
		},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063292))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.options.size() == 1
		and str(step.pending_choice.options[0].get("value", {}).get("slot", "")) == "bench_0",
		"Native attach_energy_from_discard did not filter Darkness targets",
	)
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(2026063293),
	)
	_check(step.success, "Native attach_energy_from_discard filtered choice failed: %s" % step.message)
	_check(
		state.players[0].bench[0].energy_card_ids == ["sv1-ener-7"]
		and state.players[0].bench[1].energy_card_ids.is_empty(),
		"Native attach_energy_from_discard ignored target_pokemon_type",
	)

	state = _effect_state()
	state.players[0].active.energy_card_ids = ["sv1-ener-1", "sv1-ener-2"]
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[0].energy_card_ids.clear()
	state.players[0].bench[1] = null
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "relocate_energy",
		"args": {"amount": 1, "from_self": true, "energy_type": "basic_energy"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063294))
	_check(step.success and step.pending_choice != null,
		"Native relocate_energy from_self did not request target")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(2026063295),
	)
	_check(step.success, "Native relocate_energy from_self target failed: %s" % step.message)
	_check(
		state.players[0].active.energy_card_ids == ["sv1-ener-2"]
		and state.players[0].bench[0].energy_card_ids == ["sv1-ener-1"],
		"Native relocate_energy from_self did not move one basic energy",
	)

	state = _effect_state()
	state.players[0].active.energy_card_ids = ["sv1-ener-1", "sv1-ener-2"]
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[0].energy_card_ids.clear()
	state.players[0].bench[1] = PokemonState.new("svf-rio")
	state.players[0].bench[1].energy_card_ids.clear()
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "relocate_energy",
		"args": {"amount": 99, "from_self": true},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063296))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.request_type == "distribute_energy"
		and step.pending_choice.min_select == 2,
		"Native relocate_energy from_self distribution did not request all energies",
	)
	var relocate_distribution_ids: Array[String] = []
	for option in step.pending_choice.options:
		relocate_distribution_ids.append(str(option["option_id"]))
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, relocate_distribution_ids),
		PortableRandomSource.new(2026063297),
	)
	_check(step.success, "Native relocate_energy from_self distribution failed: %s" % step.message)
	_check(
		state.players[0].active.energy_card_ids.is_empty()
		and state.players[0].bench[0].energy_card_ids.size() == 1
		and state.players[0].bench[1].energy_card_ids.size() == 1,
		"Native relocate_energy did not distribute active energies",
	)

	state = _effect_state()
	state.players[0].active.energy_card_ids = ["sv1-ener-1", "sv1-ener-2"]
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[0].energy_card_ids.clear()
	state.players[0].bench[0].energy_card_ids.append("sv1-ener-3")
	state.players[0].bench[1] = PokemonState.new("svf-rio")
	state.players[0].bench[1].energy_card_ids.clear()
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "relocate_energy",
		"args": {"amount": 2, "min_select": 0, "same_target": true},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063298))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.request_type == "select_energy_source",
		"Native relocate_energy did not request source when multiple sources exist",
	)
	var active_relocate_source := ""
	for option_value in step.pending_choice.options:
		var option: Dictionary = option_value
		if str(option.get("value", {}).get("slot", "")) == "active":
			active_relocate_source = str(option.get("option_id", ""))
			break
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [active_relocate_source]),
		PortableRandomSource.new(2026063299),
	)
	_check(step.success and step.pending_choice != null,
		"Native relocate_energy source choice did not continue to targets")
	var bench_one_relocate := ""
	for option_value in step.pending_choice.options:
		var option: Dictionary = option_value
		if str(option.get("value", {}).get("slot", "")) == "bench_1":
			bench_one_relocate = str(option.get("option_id", ""))
			break
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [bench_one_relocate, bench_one_relocate]),
		PortableRandomSource.new(2026063300),
	)
	_check(step.success, "Native relocate_energy same-target distribution failed: %s" % step.message)
	_check(
		state.players[0].active.energy_card_ids.is_empty()
		and state.players[0].bench[1].energy_card_ids == ["sv1-ener-1", "sv1-ener-2"]
		and state.players[0].bench[0].energy_card_ids == ["sv1-ener-3"],
		"Native relocate_energy did not keep same-target relocation",
	)

	state = _effect_state()
	state.players[0].active = PokemonState.new("sv2-tatsu")
	state.players[0].bench[0] = PokemonState.new("svf-rio")
	state.players[0].hand = []
	state.players[0].deck = ["sv1-ener-1"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "search_any_and_switch",
		"args": {"count": 1, "min_select": 0, "switch_optional": true},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606327))
	_check(step.success and step.pending_choice != null,
		"Native search_any_and_switch did not pause for search choice")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(202606328),
	)
	_check(step.success and step.pending_choice != null,
		"Native search_any_and_switch did not continue to switch confirm")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, ["confirm:yes"]),
		PortableRandomSource.new(202606329),
	)
	_check(step.success and step.pending_choice != null,
		"Native search_any_and_switch did not continue to bench selection")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(202606330),
	)
	_check(step.success, "Native search_any_and_switch switch choice failed: %s" % step.message)
	_check(
		state.players[0].active.card_id == "svf-rio"
		and state.players[0].hand == ["sv1-ener-1"],
		"Native search_any_and_switch did not search then switch",
	)

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].discard = ["svg2-empo"]
	state.players[0].deck = ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3"]
	state.players[0].bench[0] = null
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "discard_then_revive",
		"args": {"card_id": "svg2-empo"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606331))
	_check(step.success, "Native discard_then_revive failed: %s" % step.message)
	_check(
		state.players[0].bench[0] != null
		and state.players[0].bench[0].card_id == "svg2-empo"
		and state.players[0].discard.is_empty()
		and state.players[0].hand == ["sv1-ener-3", "sv1-ener-2", "sv1-ener-1"],
		"Native discard_then_revive did not revive and draw",
	)

	state = _effect_state()
	state.turn_number = 3
	state.players[0].active = PokemonState.new("svg2-turt")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.can_evolve_this_turn = true
	state.players[0].hand = ["svg2-tort"]
	stack = ResolutionStack.new()
	stack.push_effect({"op": "evolve_skip_stage", "args": {}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063321))
	_check(step.success, "Native evolve_skip_stage failed: %s" % step.message)
	_check(
		state.players[0].active.card_id == "svg2-tort"
		and state.players[0].active.evolution_stack_ids == ["svg2-turt"]
		and state.players[0].hand.is_empty()
		and not state.players[0].active.can_evolve_this_turn,
		"Native evolve_skip_stage did not evolve Basic directly to Stage 2",
	)

	state = _effect_state()
	state.players[1].active.energy_card_ids = ["sv1-ener-1"]
	state.players[1].discard = []
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "flip_coin_then_discard_energy",
		"args": {},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2))
	_check(step.success and step.pending_choice != null,
		"Native flip_coin_then_discard_energy did not create coin request")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, []),
		PortableRandomSource.new(202606333),
	)
	_check(step.success and step.pending_choice != null,
		"Native flip_coin_then_discard_energy did not continue to attachment choice")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(202606334),
	)
	_check(step.success, "Native flip_coin_then_discard_energy attachment choice failed: %s" % step.message)
	_check(
		state.players[1].active.energy_card_ids.is_empty()
		and state.players[1].discard == ["sv1-ener-1"],
		"Native flip_coin_then_discard_energy did not discard selected energy",
	)

	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "register_tool_exp_share",
		"args": {},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606332))
	_check(step.success, "Native register_tool_exp_share failed: %s" % step.message)

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3"]
	state.players[0].deck = ["sv1-ener-4"]
	state.players[0].discard = []
	stack = ResolutionStack.new()
	stack.push_effect({"op": "draw_cards", "args": {"amount": 1}, "branches": {}}, 0, "active")
	stack.push_effect({
		"op": "discard_cards",
		"args": {"amount": 2, "from": "hand"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260631))
	_check(step.success and step.pending_choice != null,
		"Native discard_cards command spec did not pause for choice")
	var discard_options: Array[String] = [
		str(step.pending_choice.options[0]["option_id"]),
		str(step.pending_choice.options[1]["option_id"]),
	]
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, discard_options),
		PortableRandomSource.new(20260632),
	)
	_check(step.success, "Native discard_cards command spec failed to resume: %s" % step.message)
	_check(state.players[0].discard == ["sv1-ener-2", "sv1-ener-1"],
		"Native discard_cards discarded the wrong hand cards")
	_check(state.players[0].hand == ["sv1-ener-3", "sv1-ener-4"],
		"Native discard_cards did not resume remaining command")

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2"]
	state.players[0].deck = ["sv1-ener-3", "sv1-ener-4"]
	state.players[0].discard = []
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "discard_then_draw_cards",
		"args": {"discard_hand": true, "draw": 2},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606321))
	_check(step.success, "Native discard_then_draw_cards discard-hand spec failed: %s" % step.message)
	_check(state.players[0].discard == ["sv1-ener-1", "sv1-ener-2"],
		"Native discard_then_draw_cards did not discard the whole hand")
	_check(state.players[0].hand == ["sv1-ener-4", "sv1-ener-3"],
		"Native discard_then_draw_cards did not draw after discarding hand")

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3"]
	state.players[0].deck = ["sv1-ener-4", "sv1-ener-5"]
	state.players[0].discard = []
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "discard_then_draw_cards",
		"args": {"discard_amount": 1, "draw_amount": 1},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606322))
	_check(step.success and step.pending_choice != null,
		"Native discard_then_draw_cards did not pause for discard choice")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(202606323),
	)
	_check(step.success, "Native discard_then_draw_cards failed to resume: %s" % step.message)
	_check(state.players[0].discard == ["sv1-ener-1"],
		"Native discard_then_draw_cards discarded the wrong selected card")
	_check(state.players[0].hand == ["sv1-ener-2", "sv1-ener-3", "sv1-ener-5"],
		"Native discard_then_draw_cards did not draw after selected discard")

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].deck = ["sv1-ener-2"]
	state.players[0].discard = []
	state.players[0].active.energy_card_ids = ["sv1-ener-5", "sv1-ener-6"]
	state.players[1].active.energy_card_ids = ["sv1-ener-3"]
	state.players[1].discard = []
	stack = ResolutionStack.new()
	stack.push_effect({"op": "draw_cards", "args": {"amount": 1}, "branches": {}}, 0, "active")
	stack.push_effect({
		"op": "discard_energy",
		"args": {"amount": 1, "from": "self", "filter": "any"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260633))
	_check(step.success, "Native discard_energy command spec failed: %s" % step.message)
	_check(state.players[0].active.energy_card_ids == ["sv1-ener-6"],
		"Native discard_energy did not remove self energy")
	_check(state.players[0].discard == ["sv1-ener-5"],
		"Native discard_energy did not put self energy in owner discard")
	_check(state.players[0].hand == ["sv1-ener-2"],
		"Native discard_energy did not continue remaining command")

	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "discard_energy",
		"args": {"amount": 1, "from": "opponent", "filter": "any"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260634))
	_check(step.success, "Native opponent discard_energy command spec failed: %s" % step.message)
	_check(state.players[1].active.energy_card_ids.is_empty(),
		"Native discard_energy did not remove opponent energy")
	_check(state.players[1].discard == ["sv1-ener-3"],
		"Native discard_energy did not put opponent energy in owner discard")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage_per_hand_size",
		"args": {"per": 10},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260635))
	_check(step.success, "Native damage_per_hand_size formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 3,
		"Native damage_per_hand_size formula produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage_plus_bench",
		"args": {"base": 10, "per_bench": 20},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260636))
	_check(step.success, "Native damage_plus_bench formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 5,
		"Native damage_plus_bench formula produced wrong damage")

	state = _effect_state()
	state.players[0].active.damage_counters = 2
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage_per_self_damage",
		"args": {"base": 60, "per_counter": 10},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260637))
	_check(step.success, "Native damage_per_self_damage formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 8,
		"Native damage_per_self_damage formula produced wrong damage")

	state = _effect_state()
	state.players[0].active.damage_counters = 3
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage_with_self_penalty",
		"args": {"base": 200, "per_counter": 20},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260638))
	_check(step.success, "Native damage_self_penalty formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 14,
		"Native damage_self_penalty formula produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 1
	stack = ResolutionStack.new()
	stack.context["finish_attack"] = true
	stack.context["base_damage"] = 30
	stack.push_effect({
		"op": "conditional_damage",
		"args": {"bonus": 120, "condition": "opponent_active_damaged"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606379))
	_check(step.success, "Native conditional_damage command spec failed: %s" % step.message)
	var saved_conditional_stack := ResolutionStack.from_dict(state.resolution_stack)
	_check(int(saved_conditional_stack.context.get("base_damage", 0)) == 150,
		"Native conditional_damage did not accumulate bonus in attack context")
	_check(state.players[1].active.damage_counters == 1,
		"Native conditional_damage applied damage outside attack context")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].was_ko_by_attack = true
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "conditional_damage",
		"args": {"bonus": 90, "condition": "ko_by_attack_last_turn"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063791))
	_check(step.success, "Native conditional_damage ko condition failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 9,
		"Native conditional_damage did not apply ko_by_attack bonus")
	_check(not state.players[0].was_ko_by_attack,
		"Native conditional_damage did not consume was_ko_by_attack")

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3", "sv1-ener-4"]
	state.players[0].discard = []
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "discard_hand_then_damage",
		"args": {"threshold": 5, "base_damage": 60, "bonus": 150},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063792))
	_check(step.success, "Native discard_hand_then_damage command spec failed: %s" % step.message)
	_check(state.players[0].hand.is_empty(),
		"Native discard_hand_then_damage did not discard hand below threshold")
	_check(state.players[0].discard == ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3", "sv1-ener-4"],
		"Native discard_hand_then_damage discarded wrong hand cards")
	_check(state.players[1].active.damage_counters == 6,
		"Native discard_hand_then_damage produced wrong base damage")

	state = _effect_state()
	state.players[0].active.energy_card_ids = ["sv1-ener-6", "sv1-ener-5"]
	state.players[0].discard = []
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "discard_energy_then_damage",
		"args": {"base": 10, "per_energy": 60},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063793))
	_check(step.success, "Native discard_energy_then_damage command spec failed: %s" % step.message)
	_check(state.players[0].active.energy_card_ids == ["sv1-ener-5"],
		"Native discard_energy_then_damage did not keep non-fighting energy")
	_check(state.players[0].discard == ["sv1-ener-6"],
		"Native discard_energy_then_damage did not discard fighting energy")
	_check(state.players[1].active.damage_counters == 7,
		"Native discard_energy_then_damage produced wrong damage")

	state = _effect_state()
	state.players[0].deck = ["sv2-delib", "sv1-ener-1", "sv1-ener-2"]
	state.players[0].discard = []
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "mill_then_damage",
		"args": {"mill_count": 3, "damage_per": 40},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063794))
	_check(step.success, "Native mill_then_damage command spec failed: %s" % step.message)
	_check(state.players[0].discard == ["sv1-ener-2", "sv1-ener-1"],
		"Native mill_then_damage did not discard revealed energies")
	_check(state.players[1].active.damage_counters == 8,
		"Native mill_then_damage produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].healed_this_turn = true
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "conditional_damage_then_heal",
		"args": {"base": 60, "bonus": 90},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063801))
	_check(step.success, "Native conditional_damage_then_heal command spec failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 15,
		"Native conditional_damage_then_heal produced wrong damage")

	state = _effect_state()
	state.players[0].active.damage_counters = 3
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage_then_heal",
		"args": {"damage": 10, "heal": 20},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(2026063802))
	_check(step.success, "Native deal_damage_then_heal command spec failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 1,
		"Native deal_damage_then_heal did not damage opponent")
	_check(state.players[0].active.damage_counters == 1,
		"Native deal_damage_then_heal did not heal source")
	_check(state.players[0].healed_this_turn,
		"Native deal_damage_then_heal did not mark healed_this_turn")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[1].active.energy_card_ids = ["sv1-ener-1", "sv1-ener-2"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage_per_energy",
		"args": {
			"base": 10,
			"per_energy": 20,
			"count_from": "opponent_active",
		},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606381))
	_check(step.success, "Native damage_per_energy formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 5,
		"Native damage_per_energy formula produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].active.energy_card_ids = ["sv1-ener-2", "sv1-ener-5"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage_per_self_energy",
		"args": {
			"base": 30,
			"per_energy": 30,
			"energy_filter": "fire",
		},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606382))
	_check(step.success, "Native damage_per_self_energy formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 6,
		"Native damage_per_self_energy formula produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].active.energy_card_ids = ["sv1-ener-1", "sv1-ener-2"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage_per_self_energy_type",
		"args": {
			"base": 60,
			"per_energy": 20,
			"energy_type": "Grass",
		},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606383))
	_check(step.success, "Native damage_per_self_energy_type formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 8,
		"Native damage_per_self_energy_type formula produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].discard = ["sv1-106", "svi-chim"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage_per_discard_psychic",
		"args": {"base": 80, "per_card": 10},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606384))
	_check(step.success, "Native damage_per_discard_psychic formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 9,
		"Native damage_per_discard_psychic formula produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].bench[0] = PokemonState.new("svg2-tort")
	state.players[0].bench[1] = PokemonState.new("sv1-106")
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage_per_evolved",
		"args": {"per_evolved": 50},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606385))
	_check(step.success, "Native damage_per_evolved formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 10,
		"Native damage_per_evolved formula produced wrong damage")

	state = _effect_state()
	state.players[0].active.damage_counters = 2
	state.players[0].active.energy_card_ids = ["sv1-ener-2"]
	state.players[0].bench[0].damage_counters = 1
	state.players[0].bench[1] = PokemonState.new("sv2-38")
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "set_attack_damage_formula",
		"args": {
			"base": 100,
			"per_own_bench": 20,
			"per_self_energy_type": "Fire",
			"per_energy": 30,
			"per_self_damage_counter": 10,
			"condition_bonus": {
				"condition": "own_bench_damaged",
				"bonus": 50,
				"consume": false,
			},
			"piercing": true,
			"ignore_defender_effects": true,
		},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(202606386))
	_check(step.success, "Native set_attack_damage_formula command spec failed: %s" % step.message)
	var saved_formula_stack := ResolutionStack.from_dict(state.resolution_stack)
	_check(int(saved_formula_stack.context.get("base_damage", 0)) == 240,
		"Native set_attack_damage_formula produced wrong base damage")
	_check(bool(saved_formula_stack.context.get("piercing", false)),
		"Native set_attack_damage_formula did not set piercing context")
	_check(bool(saved_formula_stack.context.get("ignore_defender_effects", false)),
		"Native set_attack_damage_formula did not set ignore defender context")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.context["finish_attack"] = true
	stack.push_effect({"op": "deal_damage", "args": {"amount": 30}, "branches": {}}, 0, "active")
	stack.push_effect({
		"op": "set_attack_flags",
		"args": {"ignore_weakness": true, "ignore_resistance": true, "ignore_effects": true},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260639))
	_check(step.success, "Native set_attack_flags command spec failed: %s" % step.message)
	var saved_attack_stack := ResolutionStack.from_dict(state.resolution_stack)
	_check(bool(saved_attack_stack.context.get("piercing", false)),
		"Native set_attack_flags did not set piercing context")
	_check(bool(saved_attack_stack.context.get("ignore_defender_effects", false)),
		"Native set_attack_flags did not set ignore defender context")
	_check(int(saved_attack_stack.context.get("base_damage", 0)) == 30,
		"Native set_attack_flags did not preserve accumulated damage context")

	state = _effect_state()
	state.players[0].active.card_id = "sv2-tatsu"
	state.players[0].active.evolution_stack_ids = ["sv2-38"]
	state.players[0].active.energy_card_ids = ["sv1-ener-3"]
	state.players[0].active.attached_tool_id = "svl-vitb"
	state.players[0].hand = []
	stack = ResolutionStack.new()
	stack.push_effect({"op": "return_to_hand", "args": {}, "branches": {}}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260640))
	_check(step.success, "Native return_to_hand command spec failed: %s" % step.message)
	_check(state.players[0].active == null, "Native return_to_hand did not clear active slot")
	_check(state.players[0].hand == ["sv2-tatsu", "sv2-38", "sv1-ener-3", "svl-vitb"],
		"Native return_to_hand returned the wrong cards to hand")

	state = _effect_state()
	state.players[1].bench[0] = PokemonState.new("svi-chim")
	state.players[1].bench[1] = PokemonState.new("svf-rio")
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_bench_damage",
		"args": {"amount": 10, "count": 5, "player": "opponent", "choose_targets": false},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260641))
	_check(step.success, "Native auto deal_bench_damage command spec failed: %s" % step.message)
	_check(
		state.players[1].bench[0].damage_counters == 1
		and state.players[1].bench[1].damage_counters == 1,
		"Native auto deal_bench_damage did not damage opponent bench",
	)

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].deck = ["sv1-ener-2"]
	state.players[1].bench[0] = PokemonState.new("svi-chim")
	state.players[1].bench[1] = PokemonState.new("svf-rio")
	stack = ResolutionStack.new()
	stack.push_effect({"op": "draw_cards", "args": {"amount": 1}, "branches": {}}, 0, "active")
	stack.push_effect({
		"op": "deal_bench_damage",
		"args": {"amount": 30, "count": 1, "player": "opponent", "choose_targets": true},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260642))
	_check(step.success and step.pending_choice != null,
		"Native choice deal_bench_damage command spec did not pause for choice")
	var bench_damage_option := _choice_id_for_slot(step.pending_choice, "bench_1")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [bench_damage_option]),
		PortableRandomSource.new(20260643),
	)
	_check(step.success, "Native choice deal_bench_damage failed to resume: %s" % step.message)
	_check(
		state.players[1].bench[0].damage_counters == 0
		and state.players[1].bench[1].damage_counters == 3,
		"Native choice deal_bench_damage damaged the wrong bench target",
	)
	_check(state.players[0].hand == ["sv1-ener-2"],
		"Native choice deal_bench_damage did not resume remaining command")

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].deck = ["sv1-ener-2"]
	state.players[1].active.damage_counters = 0
	state.players[1].bench[0] = PokemonState.new("svi-chim")
	state.players[1].bench[1] = null
	stack = ResolutionStack.new()
	stack.push_effect({"op": "draw_cards", "args": {"amount": 1}, "branches": {}}, 0, "active")
	stack.push_effect({
		"op": "choose_damage_target",
		"args": {"amount": 40, "player": "opponent", "piercing_on_bench": true},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260644))
	_check(step.success and step.pending_choice != null,
		"Native choose_damage_target command spec did not pause for choice")
	var any_damage_option := _choice_id_for_slot(step.pending_choice, "bench_0")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [any_damage_option]),
		PortableRandomSource.new(20260645),
	)
	_check(step.success, "Native choose_damage_target failed to resume: %s" % step.message)
	_check(
		state.players[1].active.damage_counters == 0
		and state.players[1].bench[0].damage_counters == 4,
		"Native choose_damage_target damaged the wrong target",
	)
	_check(state.players[0].hand == ["sv1-ener-2"],
		"Native choose_damage_target did not resume remaining command")

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].deck = ["sv1-ener-2"]
	state.players[0].active = PokemonState.new("sv2-starm")
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[1].active.damage_counters = 0
	state.players[1].bench[0] = PokemonState.new("svi-chim")
	state.players[1].bench[1] = null
	stack = ResolutionStack.new()
	stack.push_effect({"op": "draw_cards", "args": {"amount": 1}, "branches": {}}, 0, "active")
	stack.push_effect({
		"op": "place_counters_then_self_ko",
		"args": {"counters": 2, "target_player": "opponent"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(state, stack, PortableRandomSource.new(20260646))
	_check(step.success and step.pending_choice != null,
		"Native place_counters_then_self_ko command spec did not pause for choice")
	var comet_option := _choice_id_for_slot(step.pending_choice, "bench_0")
	step = engine.effect_engine.apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [comet_option]),
		PortableRandomSource.new(20260647),
	)
	_check(step.success, "Native place_counters_then_self_ko failed to resume: %s" % step.message)
	_check(state.players[1].bench[0].damage_counters == 2,
		"Native place_counters_then_self_ko did not place target counters")
	_check(state.players[0].active != null and state.players[0].active.damage_counters > 0,
		"Native place_counters_then_self_ko did not put source into KO state")
	_check(state.players[0].hand == ["sv1-ener-2"],
		"Native place_counters_then_self_ko did not resume remaining command")


func _run_compiled_runtime_dispatch_tests(engine: GameEngine) -> void:
	var trainer_id := "__test_compiled_trainer"
	engine.catalog.cards[trainer_id] = {
		"api_id": trainer_id,
		"name": "Compiled Trainer Probe",
		"supertype": "Trainer",
		"subtypes": ["Item"],
		"trainer_type": "Item",
		"trainer_effects": [{"effect_type": "__raw_should_not_run__", "params": {}}],
		"compiled_trainer_effects": [{
			"op": "draw_cards",
			"args": {"amount": 1},
			"branches": {},
		}],
		"abilities": [],
		"attacks": [],
	}
	var state := _effect_state()
	state.players[0].hand = [trainer_id]
	state.players[0].deck = ["sv1-ener-2"]
	state.players[0].discard = []
	var step := engine.apply_action(
		state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(20260648),
	)
	_check(step.success, "Compiled trainer runtime dispatch failed: %s" % step.message)
	_check(state.players[0].hand == ["sv1-ener-2"],
		"Compiled trainer runtime did not execute compiled draw_cards")
	_check(state.players[0].discard == [trainer_id],
		"Compiled trainer runtime did not discard the played item")

	var ability_id := "__test_compiled_ability"
	engine.catalog.cards[ability_id] = {
		"api_id": ability_id,
		"name": "Compiled Ability Probe",
		"supertype": "Pokémon",
		"subtypes": ["Basic"],
		"hp": 60,
		"energy_types": ["Colorless"],
		"retreat_cost": 1,
		"weaknesses": [],
		"resistances": [],
		"provides_energy": [],
		"abilities": [{
			"name": "Compiled Ability",
			"trigger": "repeatable",
			"effects": [{"effect_type": "__raw_should_not_run__", "params": {}}],
			"compiled_effects": [{
				"op": "draw_cards",
				"args": {"amount": 1},
				"branches": {},
			}],
		}],
		"attacks": [],
		"trainer_effects": [],
		"compiled_trainer_effects": [],
	}
	state = _effect_state()
	state.players[0].active = PokemonState.new(ability_id)
	state.players[0].deck = ["sv1-ener-3"]
	state.players[0].hand = []
	step = engine.apply_action(
		state,
		GameAction.new("USE_ABILITY", {
			"slot": "active",
			"ability_name": "Compiled Ability",
		}, false, 0),
		PortableRandomSource.new(20260649),
	)
	_check(step.success, "Compiled ability runtime dispatch failed: %s" % step.message)
	_check(state.players[0].hand == ["sv1-ener-3"],
		"Compiled ability runtime did not execute compiled draw_cards")

	var attack_id := "__test_compiled_attack"
	engine.catalog.cards[attack_id] = {
		"api_id": attack_id,
		"name": "Compiled Attack Probe",
		"supertype": "Pokémon",
		"subtypes": ["Basic"],
		"hp": 60,
		"energy_types": ["Colorless"],
		"retreat_cost": 1,
		"weaknesses": [],
		"resistances": [],
		"provides_energy": [],
		"abilities": [],
		"attacks": [{
			"name": "Compiled Strike",
			"cost": [],
			"converted_energy_cost": 0,
			"damage": 0,
			"effects": [{"effect_type": "__raw_should_not_run__", "params": {}}],
			"compiled_effects": [{
				"op": "draw_cards",
				"args": {"amount": 1},
				"branches": {},
			}],
		}],
		"trainer_effects": [],
		"compiled_trainer_effects": [],
	}
	state = _effect_state()
	state.players[0].active = PokemonState.new(attack_id)
	state.players[0].deck = ["sv1-ener-4"]
	state.players[0].hand = []
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(20260650),
	)
	_check(step.success, "Compiled attack runtime dispatch failed: %s" % step.message)
	_check(state.players[0].hand == ["sv1-ener-4"],
		"Compiled attack runtime did not execute compiled draw_cards")


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


func _run_card_effect_accuracy_tests(engine: GameEngine) -> void:
	var state := _battle_state()
	state.players[0].hand = ["sv1-153", "sv1-ener-5"]
	state.players[0].deck = ["sv1-104"]
	var step := engine.apply_action(
		state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(6100),
	)
	_check(
		not step.success and step.error_code == "cost_not_payable",
		"Ultra Ball succeeded without two discard cards or returned the wrong error",
	)
	_check(
		state.players[0].hand == ["sv1-153", "sv1-ener-5"]
		and state.players[0].discard.is_empty(),
		"Ultra Ball cost failure did not keep the card in hand",
	)
	_check(
		not _has_hand_action(engine.legal_actions(state, 0, false), "PLAY_TRAINER", 0),
		"Ultra Ball with unpaid discard cost was listed as legal",
	)

	state = _battle_state()
	state.players[0].hand = ["svd-dark-patch"]
	state.players[0].discard = ["sv1-ener-7"]
	state.players[0].bench[0] = PokemonState.new("svd-doduo")
	_check(
		not _has_hand_action(engine.legal_actions(state, 0, false), "PLAY_TRAINER", 0),
		"Dark Patch without a Darkness bench target was listed as legal",
	)
	step = engine.apply_action(
		state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(61001),
	)
	_check(
		not step.success and step.error_code == "no_legal_target",
		"Dark Patch without a legal target was not rejected",
	)
	_check(
		state.players[0].hand == ["svd-dark-patch"]
		and state.players[0].discard == ["sv1-ener-7"]
		and state.players[0].bench[0].energy_card_ids.is_empty(),
		"Rejected Dark Patch mutated the game state",
	)

	state = _battle_state()
	state.players[0].hand = ["sv2-catch"]
	_check(
		not _has_hand_action(engine.legal_actions(state, 0, false), "PLAY_TRAINER", 0),
		"Pokemon Catcher without opponent bench was listed as legal",
	)
	step = engine.apply_action(
		state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(61002),
	)
	_check(
		not step.success and step.error_code == "no_legal_target",
		"Pokemon Catcher without opponent bench was not rejected",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("svm-bronzong")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-8"])
	_check(
		not _has_action(engine.legal_actions(state, 0, false), "USE_ABILITY", {"slot": "active"}),
		"Bronzong Metal Transfer without a target was listed as legal",
	)
	step = engine.apply_action(
		state,
		GameAction.new("USE_ABILITY", {"slot": "active", "ability_name": "金属转移"}, false, 0),
		PortableRandomSource.new(61003),
	)
	_check(
		not step.success and step.error_code == "no_legal_target",
		"Bronzong Metal Transfer without a target was not rejected",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv1-113")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-5"])
	state.players[0].deck = ["sv1-ener-3"]
	_check(
		not _has_action(engine.legal_actions(state, 0, false), "DECLARE_ATTACK", {"attack_idx": 0}),
		"Cresselia zero-damage attack without matching deck energy was listed as legal",
	)
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(61004),
	)
	_check(
		not step.success and step.error_code == "no_legal_target",
		"Cresselia zero-damage attack without a legal target was not rejected",
	)

	state = _battle_state()
	state.players[0].hand = ["sv1-170"]
	state.players[0].bench[0] = PokemonState.new("svl-pikaex")
	state.players[0].bench[1] = PokemonState.new("sv2-delib")
	state.players[0].deck = [
		"sv1-ener-3", "sv1-ener-3", "sv1-ener-3", "sv1-ener-4", "sv1-ener-4",
	]
	step = engine.apply_action(
		state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(6101),
	)
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.min_select == 0
		and step.pending_choice.max_select == 2,
		"Electric Generator did not allow selecting 0-2 energy",
	)
	if step.pending_choice:
		step = engine.apply_choice(
			state,
			step.pending_choice,
			ChoiceResponse.new(step.pending_choice.request_id, []),
			PortableRandomSource.new(6102),
		)
	_check(step.success, "Electric Generator zero choice failed: %s" % step.message)
	_check(
		state.players[0].bench[0].energy_card_ids.is_empty()
		and state.players[0].bench[1].energy_card_ids.is_empty()
		and state.players[0].deck.size() == 5,
		"Electric Generator zero choice changed board or lost deck cards",
	)

	state = _battle_state()
	state.players[0].hand = ["sv1-170"]
	state.players[0].bench[0] = PokemonState.new("svl-pikaex")
	state.players[0].bench[1] = PokemonState.new("sv2-delib")
	state.players[0].deck = [
		"sv1-ener-3", "sv1-ener-3", "sv1-ener-3", "sv1-ener-4", "sv1-ener-4",
	]
	step = engine.apply_action(
		state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(6103),
	)
	if step.pending_choice:
		var electric_ids: Array[String] = []
		for index in range(min(2, step.pending_choice.options.size())):
			electric_ids.append(str(step.pending_choice.options[index]["option_id"]))
		step = engine.apply_choice(
			state,
			step.pending_choice,
			ChoiceResponse.new(step.pending_choice.request_id, electric_ids),
			PortableRandomSource.new(6104),
		)
	_check(step.success, "Electric Generator two choice failed: %s" % step.message)
	_check(
		state.players[0].bench[0].energy_card_ids.size() == 2
		and state.players[0].bench[1].energy_card_ids.is_empty()
		and state.players[0].deck.size() == 3,
		"Electric Generator did not attach only to benched Lightning Pokemon",
	)

	state = _battle_state()
	state.players[0].hand = ["svg2-hamm"]
	_set_energy_cards(state.players[1].active, ["sv1-ener-3"])
	state.players[1].bench[0] = PokemonState.new("sv2-delib")
	_set_energy_cards(state.players[1].bench[0], ["sv1-ener-4"])
	step = engine.apply_action(
		state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(2),
	)
	if step.pending_choice:
		step = engine.apply_choice(
			state,
			step.pending_choice,
			ChoiceResponse.new(step.pending_choice.request_id, []),
			PortableRandomSource.new(6105),
		)
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.request_type == "select_attachment",
		"Crushing Hammer did not request a specific attachment after heads",
	)
	if step.pending_choice:
		var bench_attachment_id := ""
		for option_value in step.pending_choice.options:
			var option: Dictionary = option_value
			if str(option.get("value", {}).get("slot", "")) == "bench_0":
				bench_attachment_id = str(option.get("option_id", ""))
				break
		step = engine.apply_choice(
			state,
			step.pending_choice,
			ChoiceResponse.new(step.pending_choice.request_id, [bench_attachment_id]),
			PortableRandomSource.new(6106),
		)
	_check(step.success, "Crushing Hammer attachment choice failed: %s" % step.message)
	_check(
		state.players[1].active.energy_card_ids == ["sv1-ener-3"]
		and state.players[1].bench[0].energy_card_ids.is_empty()
		and "sv1-ener-4" in state.players[1].discard,
		"Crushing Hammer discarded the wrong energy attachment",
	)

	state = _battle_state()
	state.players[0].hand = ["svg2-gard", "sv1-ener-1", "sv1-ener-1"]
	state.players[0].deck.clear()
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	step = engine.apply_action(
		state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(6107),
	)
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.min_select == 0
		and step.pending_choice.max_select == 2,
		"Gardenia did not allow optional energy attachment",
	)
	if step.pending_choice:
		var target_id := _choice_id_for_slot(step.pending_choice, "bench_0")
		step = engine.apply_choice(
			state,
			step.pending_choice,
			ChoiceResponse.new(step.pending_choice.request_id, [target_id]),
			PortableRandomSource.new(6108),
		)
	_check(step.success, "Gardenia one-energy choice failed: %s" % step.message)
	_check(
		state.players[0].bench[0].energy_card_ids.size() == 1,
		"Gardenia did not accept attaching fewer than the maximum",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("svm-cobalion")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-8", "sv1-ener-8"])
	state.players[0].bench[0] = PokemonState.new("svm-zacian")
	state.players[0].bench[1] = PokemonState.new("svm-zamazenta")
	state.players[0].deck = ["sv1-ener-8", "sv1-ener-8"]
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(6109),
	)
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.min_select == 0
		and step.pending_choice.max_select == 2,
		"Cobalion Follow-Up did not allow attaching fewer than two energy",
	)
	if step.pending_choice:
		var cobalion_target := _choice_id_for_slot(step.pending_choice, "bench_1")
		step = engine.apply_choice(
			state,
			step.pending_choice,
			ChoiceResponse.new(step.pending_choice.request_id, [cobalion_target]),
			PortableRandomSource.new(6110),
		)
	_check(step.success, "Cobalion one-energy choice failed: %s" % step.message)
	_check(
		state.players[0].bench[0].energy_card_ids.is_empty()
		and state.players[0].bench[1].energy_card_ids.size() == 1,
		"Cobalion did not accept a single legal attachment",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv1-109")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-5", "svi-dtur"])
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
		PortableRandomSource.new(6111),
	)
	_check(step.success, "Variable damage attack with DTE failed: %s" % step.message)
	_check(
		state.players[1].active.damage_counters == 4,
		"Variable attack damage did not pass through DTE reduction once",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv1-113")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, [
		"sv1-ener-5", "sv1-ener-5", "sv1-ener-5", "sv1-ener-5", "sv1-ener-5",
	])
	state.players[1].active.damage_prevented_next_turn = true
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
		PortableRandomSource.new(6112),
	)
	_check(step.success, "Conditional bonus prevention attack failed: %s" % step.message)
	_check(
		state.players[1].active.damage_counters == 0
		and not state.players[1].active.damage_prevented_next_turn,
		"Conditional bonus and base damage were not prevented as one attack damage packet",
	)

	state = _battle_state()
	state.apply_type_matchups = true
	state.players[0].active = PokemonState.new("svl-pikaex")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.attached_tool_id = "svl-vitb"
	_set_energy_cards(state.players[0].active, ["sv1-ener-4"])
	state.players[1].active = PokemonState.new("sv2-grex")
	state.players[1].active.placed_this_turn = false
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(6113),
	)
	_check(step.success, "Type matchup damage-order attack failed: %s" % step.message)
	_check(
		state.players[1].active.damage_counters == 7,
		"Weakness/resistance was not applied before tool damage modifiers",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv2-staryu")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-3", "sv1-ener-3"])
	state.players[1].active.damage_prevented_next_turn = true
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(6114),
	)
	_check(step.success, "Piercing attack failed: %s" % step.message)
	_check(
		state.players[1].active.damage_counters == 3,
		"Piercing attack did not ignore defender damage prevention",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv2-tatsu")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-3"])
	state.players[0].active.attached_tool_id = "svl-vitb"
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
		PortableRandomSource.new(6115),
	)
	_check(step.success, "Tatsugiri return-to-hand attack failed: %s" % step.message)
	_check(
		state.players[1].active.damage_counters == 0
		and state.players[0].active == null
		and "sv2-tatsu" in state.players[0].hand
		and "sv1-ener-3" in state.players[0].hand
		and "svl-vitb" in state.players[0].hand,
		"Tatsugiri return-to-hand dealt damage or failed to return attached cards",
	)
	_check(
		state.winner == 1,
		"Tatsugiri return-to-hand without bench did not lose by leaving no Pokemon in play",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv2-tatsu")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-3"])
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[0].bench[0].placed_this_turn = false
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
		PortableRandomSource.new(6116),
	)
	_check(
		step.success and state.pending_promotions == [0],
		"Active leaving play during attack did not pause for attacker promotion",
	)
	step = engine.apply_action(
		state,
		GameAction.new("PROMOTE", {"bench_idx": 0}, true, 0),
		PortableRandomSource.new(6117),
	)
	_check(step.success, "Promotion after attack leave-play failed: %s" % step.message)
	_check(
		state.active_player_idx == 1
		and state.phase == "MAIN"
		and state.players[0].active.card_id == "svi-chim",
		"Promotion after attack leave-play did not finish the attack turn",
	)

	state = _battle_state()
	state.phase = "ATTACK"
	step = engine.apply_action(
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(6118),
	)
	_check(
		not step.success and step.error_code == "illegal_attack",
		"Direct second attack in ATTACK phase was not rejected",
	)

	state = _battle_state()
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	_set_energy_cards(state.players[0].active, ["sv1-ener-5", "sv1-ener-5", "sv1-ener-5"])
	step = engine.apply_action(
		state,
		GameAction.new("RETREAT", {"bench_idx": 0, "energy_indices": [0, 1, 2]}, false, 0),
		PortableRandomSource.new(6119),
	)
	_check(
		not step.success and step.error_code == "illegal_retreat",
		"Direct retreat with extra energy payment was not rejected",
	)
	state = _battle_state()
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	_set_energy_cards(state.players[0].active, ["svi-dtur"])
	step = engine.apply_action(
		state,
		GameAction.new("RETREAT", {"bench_idx": 0, "energy_indices": [0]}, false, 0),
		PortableRandomSource.new(6120),
	)
	_check(step.success, "Single Double Turbo retreat payment should be legal: %s" % step.message)

	state = _battle_state()
	state.players[0].deck = ["sv1-ener-5"]
	var draw_stack := ResolutionStack.new()
	draw_stack.push_effect({
		"op": "draw_cards",
		"args": {"amount": 3, "player": "self"},
		"branches": {},
	}, 0, "active")
	step = engine.effect_engine.resolve(
		state,
		draw_stack,
		PortableRandomSource.new(6121),
	)
	_check(step.success, "Partial draw effect failed: %s" % step.message)
	_check(
		state.winner < 0
		and state.players[0].deck.is_empty()
		and state.players[0].hand.size() == 2,
		"Card-effect draw with insufficient deck caused a loss or drew the wrong amount",
	)

	state = _battle_state()
	state.turn_number = 3
	state.players[1].deck.clear()
	step = engine.apply_action(
		state,
		GameAction.new("END_TURN", {}, true, 0),
		PortableRandomSource.new(6122),
	)
	_check(
		step.success and state.winner == 0,
		"Turn-start empty-deck loss no longer works for the incoming player",
	)


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


func _run_turn_state_regression_tests(
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	var ko_state := _battle_state()
	ko_state.active_player_idx = 0
	ko_state.first_player_idx = 0
	ko_state.turn_number = 3
	ko_state.players[1].was_ko_by_attack = true
	var step := engine.apply_action(
		ko_state,
		GameAction.new("END_TURN", {}, true, 0),
		PortableRandomSource.new(3101),
	)
	_check(step.success, "KO trigger window setup turn failed: %s" % step.message)
	_check(
		ko_state.active_player_idx == 1
		and ko_state.players[1].was_ko_by_attack,
		"KO-by-attack marker was cleared before the victim's response turn",
	)
	var stack := ResolutionStack.new()
	stack.push_effect({
		"op": "conditional_damage",
		"args": {"condition": "ko_by_attack_last_turn", "bonus": 20},
		"branches": {},
	}, 1, "active")
	var conditional := engine.effect_engine.resolve(
		ko_state,
		stack,
		PortableRandomSource.new(3102),
	)
	_check(
		conditional.success,
		"KO-by-attack conditional effect failed: %s" % conditional.message,
	)
	_check(
		ko_state.players[0].active.damage_counters == 2,
		"KO-by-attack conditional effect did not apply its bonus damage",
	)
	_check(
		not ko_state.players[1].was_ko_by_attack,
		"KO-by-attack marker was not consumed by its conditional effect",
	)

	var unused_ko_state := _battle_state()
	unused_ko_state.active_player_idx = 0
	unused_ko_state.first_player_idx = 0
	unused_ko_state.turn_number = 3
	unused_ko_state.players[1].was_ko_by_attack = true
	step = engine.apply_action(
		unused_ko_state,
		GameAction.new("END_TURN", {}, true, 0),
		PortableRandomSource.new(3103),
	)
	_check(step.success, "Unused KO marker victim turn setup failed: %s" % step.message)
	step = engine.apply_action(
		unused_ko_state,
		GameAction.new("END_TURN", {}, true, 1),
		PortableRandomSource.new(3104),
	)
	_check(step.success, "Unused KO marker victim turn end failed: %s" % step.message)
	_check(
		not unused_ko_state.players[1].was_ko_by_attack,
		"Unused KO-by-attack marker survived past the victim's response turn",
	)

	var prevention_state := _battle_state()
	prevention_state.active_player_idx = 0
	prevention_state.first_player_idx = 0
	prevention_state.turn_number = 3
	prevention_state.players[0].active.damage_prevented_next_turn = true
	prevention_state.players[0].active.all_prevented_next_turn = true
	step = engine.apply_action(
		prevention_state,
		GameAction.new("END_TURN", {}, true, 0),
		PortableRandomSource.new(3105),
	)
	_check(step.success, "Prevention opponent turn setup failed: %s" % step.message)
	_check(
		prevention_state.players[0].active.damage_prevented_next_turn
		and prevention_state.players[0].active.all_prevented_next_turn,
		"Next-turn prevention expired before the opponent's response turn",
	)
	step = engine.apply_action(
		prevention_state,
		GameAction.new("END_TURN", {}, true, 1),
		PortableRandomSource.new(3106),
	)
	_check(step.success, "Prevention owner next turn setup failed: %s" % step.message)
	_check(
		not prevention_state.players[0].active.damage_prevented_next_turn
		and not prevention_state.players[0].active.all_prevented_next_turn,
		"Next-turn prevention did not expire at the owner's next turn start",
	)

	var dazzled_state := _battle_state()
	dazzled_state.active_player_idx = 1
	dazzled_state.first_player_idx = 0
	dazzled_state.turn_number = 4
	dazzled_state.players[1].active.dazzled = true
	step = engine.apply_action(
		dazzled_state,
		GameAction.new("END_TURN", {}, true, 1),
		PortableRandomSource.new(3107),
	)
	_check(step.success, "Dazzled expiry turn failed: %s" % step.message)
	_check(
		not dazzled_state.players[1].active.dazzled,
		"Dazzled marker survived after the affected player ended their turn",
	)

	var forced_state := GameState.new()
	var forced := engine.setup_game(
		forced_state,
		catalog.expand_deck("fire"),
		catalog.expand_deck("water"),
		PortableRandomSource.new(3108),
		1,
	)
	_check(forced.success, "Forced-first setup failed: %s" % forced.message)
	_check(
		forced_state.first_player_idx == 1
		and forced_state.active_player_idx == 1,
		"Forced-first setup did not set both first and active player",
	)
	_check(
		not forced_state.action_log.is_empty()
		and forced_state.action_log[0].find("玩家2先攻") >= 0,
		"Forced-first setup log did not name the forced first player",
	)


func _run_steel_rules_tests(
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	_check(
		FileAccess.file_exists("res://assets/cards/svm-zacian.webp"),
		"Steel placeholder image was not exported",
	)
	var steel_setup := GameState.new()
	var setup_step := engine.setup_game(
		steel_setup,
		catalog.expand_deck("steel"),
		catalog.expand_deck("fire"),
		PortableRandomSource.new(4201),
	)
	_check(setup_step.success, "Steel deck setup failed: %s" % setup_step.message)

	var attack_state := _steel_battle_state()
	attack_state.players[0].active = PokemonState.new("svm-zacian")
	attack_state.players[0].active.placed_this_turn = false
	_set_energy_cards(attack_state.players[0].active, ["sv1-ener-8"])
	attack_state.players[0].bench[0] = PokemonState.new("svm-bronzor")
	attack_state.players[0].bench[1] = PokemonState.new("svm-smeargle")
	attack_state.players[1].active = PokemonState.new("svm-zamazenta")
	attack_state.players[1].active.placed_this_turn = false
	_set_energy_cards(attack_state.players[1].active, ["sv1-ener-8"])
	var step := engine.apply_action(
		attack_state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(4202),
	)
	_check(step.success, "Zacian attack failed: %s" % step.message)
	_check(
		attack_state.players[1].active.damage_counters == 4,
		"Zacian Battle Legion did not ignore Zamazenta shield",
	)

	var transfer_state := _steel_battle_state()
	transfer_state.players[0].active = PokemonState.new("svm-bronzong")
	transfer_state.players[0].active.placed_this_turn = false
	_set_energy_cards(transfer_state.players[0].active, ["sv1-ener-8", "sv1-ener-5"])
	transfer_state.players[0].bench[0] = PokemonState.new("svm-orthworm")
	_set_energy_cards(transfer_state.players[0].bench[0], ["sv1-ener-8", "sv1-ener-8"])
	step = engine.apply_action(
		transfer_state,
		GameAction.new("USE_ABILITY", {"slot": "active", "ability_name": "金属转移"}, false, 0),
		PortableRandomSource.new(4203),
	)
	step = _apply_slot_choice(engine, transfer_state, step, "active", PortableRandomSource.new(4204))
	step = _apply_slot_choice(engine, transfer_state, step, "bench_0", PortableRandomSource.new(4205))
	_check(step.success, "Bronzong first transfer failed: %s" % step.message)
	_check(
		transfer_state.players[0].active.energy_card_ids == ["sv1-ener-5"]
		and transfer_state.players[0].bench[0].energy_card_ids.size() == 3,
		"Bronzong moved the wrong energy or failed to move Metal energy",
	)
	step = engine.apply_action(
		transfer_state,
		GameAction.new("USE_ABILITY", {"slot": "active", "ability_name": "金属转移"}, false, 0),
		PortableRandomSource.new(4206),
	)
	step = _apply_slot_choice(engine, transfer_state, step, "active", PortableRandomSource.new(4207))
	_check(step.success, "Bronzong repeat transfer failed: %s" % step.message)
	_check(
		transfer_state.players[0].active.energy_card_ids == ["sv1-ener-5", "sv1-ener-8"]
		and transfer_state.players[0].active.used_abilities.is_empty(),
		"Bronzong repeatable ability was marked used or failed to move Metal back",
	)

	var follow_up_state := _steel_battle_state()
	follow_up_state.players[0].active = PokemonState.new("svm-cobalion")
	follow_up_state.players[0].active.placed_this_turn = false
	_set_energy_cards(follow_up_state.players[0].active, ["sv1-ener-8", "sv1-ener-8"])
	follow_up_state.players[0].bench[0] = PokemonState.new("svm-zacian")
	follow_up_state.players[0].bench[1] = PokemonState.new("svm-zamazenta")
	follow_up_state.players[0].deck = ["sv1-ener-8", "sv1-ener-8", "sv1-151"]
	step = engine.apply_action(
		follow_up_state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(4208),
	)
	_check(step.success and step.pending_choice != null,
		"Cobalion Follow-Up did not request energy distribution")
	var follow_up_option := _choice_id_for_slot(step.pending_choice, "bench_0")
	step = engine.apply_choice(
		follow_up_state,
		step.pending_choice,
		ChoiceResponse.new(step.pending_choice.request_id, [
			follow_up_option, follow_up_option,
		]),
		PortableRandomSource.new(42081),
	)
	_check(step.success, "Cobalion Follow-Up duplicate-target choice failed: %s" % step.message)
	_check(
		follow_up_state.players[0].bench[0].energy_card_ids.size() == 1
		and follow_up_state.players[0].bench[1].energy_card_ids.is_empty()
		and follow_up_state.players[0].deck.count("sv1-ener-8") == 1,
		"Cobalion Follow-Up attached more than one energy to the same bench target",
	)

	var hp_state := _steel_battle_state()
	hp_state.players[0].active = PokemonState.new("svm-orthworm")
	hp_state.players[0].active.placed_this_turn = false
	_set_energy_cards(hp_state.players[0].active, ["sv1-ener-8", "sv1-ener-8", "sv1-ener-8"])
	hp_state.players[0].active.damage_counters = 14
	hp_state.players[0].bench[0] = PokemonState.new("svm-bronzong")
	hp_state.players[0].bench[1] = PokemonState.new("svm-zacian")
	_check(
		hp_state.players[0].active.current_hp(catalog) == 90,
		"Orthworm HP boost did not apply at three Metal energy",
	)
	step = engine.apply_action(
		hp_state,
		GameAction.new("USE_ABILITY", {"slot": "bench_0", "ability_name": "金属转移"}, false, 0),
		PortableRandomSource.new(4209),
	)
	step = _apply_slot_choice(engine, hp_state, step, "bench_1", PortableRandomSource.new(4210))
	_check(step.success, "Orthworm HP-drop transfer failed: %s" % step.message)
	_check(
		hp_state.players[0].active == null and "svm-orthworm" in hp_state.players[0].discard,
		"Orthworm was not knocked out after dropping below the HP boost threshold",
	)

	var pierce_state := _steel_battle_state()
	pierce_state.players[0].active = PokemonState.new("svm-orthworm")
	pierce_state.players[0].active.placed_this_turn = false
	_set_energy_cards(pierce_state.players[0].active, [
		"sv1-ener-8", "sv1-ener-8", "sv1-ener-8", "sv1-ener-8",
	])
	pierce_state.players[1].active = PokemonState.new("svm-zamazenta")
	pierce_state.players[1].active.placed_this_turn = false
	pierce_state.players[1].bench[0] = PokemonState.new("svm-zamazenta")
	step = engine.apply_action(
		pierce_state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(4211),
	)
	step = _apply_slot_choice(engine, pierce_state, step, "bench_0", PortableRandomSource.new(4212))
	_check(step.success, "Orthworm Pierce failed: %s" % step.message)
	_check(
		pierce_state.players[1].active.damage_counters == 10
		and pierce_state.players[1].bench[0].damage_counters == 3,
		"Orthworm Pierce did not damage active and selected bench correctly",
	)


func _steel_battle_state() -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.turn_number = 3
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.players[0].active = PokemonState.new("svm-zacian")
	state.players[0].active.placed_this_turn = false
	state.players[0].deck = ["sv1-ener-8", "sv1-ener-8", "sv1-ener-8"]
	state.players[0].prizes = ["sv1-ener-8", "sv1-ener-8"]
	state.players[1].active = PokemonState.new("sv1-104")
	state.players[1].active.placed_this_turn = false
	state.players[1].deck = ["sv1-ener-5", "sv1-ener-5", "sv1-ener-5"]
	state.players[1].prizes = ["sv1-ener-5", "sv1-ener-5"]
	return state


func _run_darkness_rules_tests(
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	_check(
		FileAccess.file_exists("res://assets/cards/svd-mabosstiff-ex.webp"),
		"Darkness placeholder image was not exported",
	)
	var darkness_setup := GameState.new()
	var setup_step := engine.setup_game(
		darkness_setup,
		catalog.expand_deck("darkness"),
		catalog.expand_deck("fire"),
		PortableRandomSource.new(4301),
	)
	_check(setup_step.success, "Darkness deck setup failed: %s" % setup_step.message)

	var pride_state := _darkness_battle_state()
	pride_state.players[0].active = PokemonState.new("svd-mabosstiff-ex")
	pride_state.players[0].active.placed_this_turn = false
	_set_energy_cards(pride_state.players[0].active, ["sv1-ener-7", "sv1-ener-7", "sv1-ener-7"])
	pride_state.players[0].bench[0] = PokemonState.new("svd-doduo")
	pride_state.players[0].bench[0].damage_counters = 1
	pride_state.players[1].active = PokemonState.new("svd-mabosstiff-ex")
	pride_state.players[1].active.placed_this_turn = false
	var step := engine.apply_action(
		pride_state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
		PortableRandomSource.new(4302),
	)
	_check(step.success, "Mabosstiff Pride Fang failed: %s" % step.message)
	_check(
		pride_state.players[1].active.damage_counters == 22,
		"Mabosstiff Pride Fang did not apply damaged-bench bonus",
	)

	var intimidate_state := _darkness_battle_state()
	intimidate_state.players[0].active = PokemonState.new("svd-mabosstiff-ex")
	intimidate_state.players[0].active.placed_this_turn = false
	_set_energy_cards(intimidate_state.players[0].active, ["sv1-ener-7", "sv1-ener-7", "sv1-ener-7"])
	intimidate_state.players[1].active = PokemonState.new("svd-maschiff")
	intimidate_state.players[1].active.placed_this_turn = false
	_set_energy_cards(intimidate_state.players[1].active, ["sv1-ener-7", "sv1-ener-7"])
	step = engine.apply_action(
		intimidate_state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(4303),
	)
	_check(step.success, "Mabosstiff Intimidate failed: %s" % step.message)
	_check(
		intimidate_state.players[1].active.outgoing_damage_reduction_next_turn == 50,
		"Intimidate did not mark opponent active",
	)
	step = engine.apply_action(
		intimidate_state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 1),
		PortableRandomSource.new(4304),
	)
	_check(step.success, "Reduced Maschiff attack failed: %s" % step.message)
	_check(
		intimidate_state.players[0].active.damage_counters == 0
		and intimidate_state.players[1].active.outgoing_damage_reduction_next_turn == 0,
		"Intimidate did not reduce and consume the next attack damage",
	)

	var patch_state := _darkness_battle_state()
	patch_state.players[0].hand = ["svd-dark-patch"]
	patch_state.players[0].discard = ["sv1-ener-7"]
	patch_state.players[0].bench[0] = PokemonState.new("svd-maschiff")
	patch_state.players[0].bench[1] = PokemonState.new("svd-doduo")
	step = engine.apply_action(
		patch_state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(4305),
	)
	step = _apply_slot_choice(engine, patch_state, step, "bench_0", PortableRandomSource.new(4306))
	_check(step.success, "Dark Patch attach failed: %s" % step.message)
	_check(
		patch_state.players[0].bench[0].energy_card_ids == ["sv1-ener-7"]
		and patch_state.players[0].bench[1].energy_card_ids.is_empty(),
		"Dark Patch attached to a non-Darkness target or missed Darkness target",
	)

	var belt_state := _darkness_battle_state()
	belt_state.players[0].active = PokemonState.new("svd-darkrai")
	belt_state.players[0].active.placed_this_turn = false
	_set_energy_cards(belt_state.players[0].active, ["sv1-ener-7", "sv1-ener-7", "sv1-ener-7"])
	belt_state.players[1].active = PokemonState.new("svd-mabosstiff-ex")
	belt_state.players[1].active.placed_this_turn = false
	belt_state.players[1].active.attached_tool_id = "svd-hard-belt"
	step = engine.apply_action(
		belt_state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
		PortableRandomSource.new(4307),
	)
	_check(step.success, "Hard Belt damage reduction attack failed: %s" % step.message)
	_check(
		belt_state.players[1].active.damage_counters == 10,
		"Hard Belt did not reduce Stage 1 incoming attack damage by 30",
	)

	var absol_state := _darkness_battle_state()
	absol_state.players[0].active = PokemonState.new("svd-absol")
	absol_state.players[0].active.placed_this_turn = false
	_set_energy_cards(absol_state.players[0].active, ["sv1-ener-7"])
	absol_state.players[1].bench[0] = PokemonState.new("svd-maschiff")
	absol_state.players[1].bench[1] = PokemonState.new("svd-doduo")
	step = engine.apply_action(
		absol_state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(4308),
	)
	_check(step.success, "Absol Swirling Disaster failed: %s" % step.message)
	_check(
		absol_state.players[1].active.damage_counters == 1
		and absol_state.players[1].bench[0].damage_counters == 1
		and absol_state.players[1].bench[1].damage_counters == 1,
		"Absol Swirling Disaster did not damage active and all bench",
	)


func _darkness_battle_state() -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.turn_number = 3
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.players[0].active = PokemonState.new("svd-absol")
	state.players[0].active.placed_this_turn = false
	state.players[0].deck = ["sv1-ener-7", "sv1-ener-7", "sv1-ener-7"]
	state.players[0].prizes = ["sv1-ener-7", "sv1-ener-7"]
	state.players[1].active = PokemonState.new("svd-maschiff")
	state.players[1].active.placed_this_turn = false
	state.players[1].deck = ["sv1-ener-7", "sv1-ener-7", "sv1-ener-7"]
	state.players[1].prizes = ["sv1-ener-7", "sv1-ener-7"]
	return state


func _set_energy_cards(pokemon: PokemonState, card_ids: Array) -> void:
	pokemon.energy_card_ids.clear()
	pokemon.energy_card_ids.assign(card_ids)


func _apply_slot_choice(
	engine: GameEngine,
	state: GameState,
	step: StepResult,
	slot: String,
	rng: PortableRandomSource,
) -> StepResult:
	_check(step.success, "Cannot apply slot choice after failed step: %s" % step.message)
	if not step.success or step.pending_choice == null:
		return step
	var request := step.pending_choice
	var option_id := _choice_id_for_slot(request, slot)
	if option_id.is_empty():
		return step
	return engine.apply_choice(
		state,
		request,
		ChoiceResponse.new(request.request_id, [option_id]),
		rng,
	)


func _choice_id_for_slot(request: ChoiceRequest, slot: String) -> String:
	for option_value in request.options:
		var option: Dictionary = option_value
		if str(option.get("value", {}).get("slot", "")) == slot:
			return str(option.get("option_id", ""))
	_check(false, "Choice request %s did not include slot %s" % [request.request_type, slot])
	return ""


func _has_hand_action(actions: Array, action_name: String, hand_idx: int) -> bool:
	return _has_action(actions, action_name, {"hand_idx": hand_idx})


func _has_action(actions: Array, action_name: String, params: Dictionary = {}) -> bool:
	for action_value in actions:
		var action: GameAction = action_value
		if action.action != action_name:
			continue
		var matches := true
		for key in params:
			if action.params.get(key) != params[key]:
				matches = false
				break
		if matches:
			return true
	return false


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
			var selected := _playout_action(actions, state, catalog)
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


func _playout_action(
	actions: Array[GameAction],
	state: GameState = null,
	catalog: CardCatalog = null,
) -> GameAction:
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
	var repeatable_fallback: GameAction
	for action_name in priorities:
		for action in actions:
			if action.action != action_name:
				continue
			if _is_repeatable_ability_action(state, catalog, action):
				if repeatable_fallback == null:
					repeatable_fallback = action
				continue
			return action
	return repeatable_fallback if repeatable_fallback != null else actions[0]


func _is_repeatable_ability_action(
	state: GameState,
	catalog: CardCatalog,
	action: GameAction,
) -> bool:
	if state == null or catalog == null or action.action != "USE_ABILITY":
		return false
	var actor := action.actor if action.actor >= 0 else state.active_player_idx
	if actor not in [0, 1]:
		return false
	var slot := str(action.params.get("slot", ""))
	var ability_name := str(action.params.get("ability_name", ""))
	var pokemon := state.get_player(actor).get_pokemon(slot)
	if pokemon == null:
		return false
	for ability_value in catalog.get_card(pokemon.card_id).get("abilities", []):
		var ability: Dictionary = ability_value
		if str(ability.get("name", "")) == ability_name:
			return str(ability.get("trigger", "")) == "repeatable"
	return false


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
