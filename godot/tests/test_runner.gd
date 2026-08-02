extends SceneTree

var failures: Array[String] = []


class MalformedAfterDamageTriggerCommands:
	extends VMTriggerCommands

	func _init(p_catalog: CardCatalog) -> void:
		catalog = p_catalog

	func collect_after_damage_triggers(
		_state: GameState,
		_context: Dictionary,
		candidates: Array[Dictionary],
	) -> void:
		candidates.append(make_candidate(
			"malformed:after_damage",
			VMModifierManager.AFTER_DAMAGE,
			1,
			0,
			EntityRef.new(
				"pokemon", 1, "field", "active", -1, "", "sv1-104").to_dict(),
			false,
			{"kind": "always"},
			[],
			[{
				"op": "trigger_draw_cards",
				"args": {
					"player": 1,
					"amount": 1,
					"source": "malformed",
					"extra": true,
				},
				"branches": {},
			}],
		))


class MalformedPokemonKoTriggerCommands:
	extends VMTriggerCommands

	func _init(p_catalog: CardCatalog) -> void:
		catalog = p_catalog

	func collect_pokemon_ko_triggers(
		_state: GameState,
		_defeated_idx: int,
		_source_slot: String,
		_knocked_out: PokemonState,
		_from_attack: bool,
		_attack_actor: int,
		candidates: Array[Dictionary],
	) -> void:
		candidates.append(make_candidate(
			"malformed:pokemon_ko",
			VMModifierManager.POKEMON_KO,
			1,
			0,
			EntityRef.new(
				"pokemon", 1, "field", "active", -1, "", "sv1-104").to_dict(),
			false,
			{"kind": "always"},
			[],
			[{
				"op": "trigger_draw_cards",
				"args": {
					"player": 1,
					"amount": 1,
					"source": "malformed",
					"extra": true,
				},
				"branches": {},
			}],
		))


class RuntimeVersionMismatchBackend:
	extends RefCounted

	var loaded := false

	func load_model(_path: String, _manifest: Dictionary) -> bool:
		loaded = true
		return true

	func unload_model() -> void:
		loaded = false

	func is_loaded() -> bool:
		return loaded

	func get_runtime_version() -> String:
		return "0.0.0-test"

	func get_last_error() -> String:
		return ""


class UnloadedDeepInference:
	extends RefCounted

	func is_loaded() -> bool:
		return false


class NonCooperativeAICoordinator:
	extends AICoordinator

	var delay_msec := 80

	func _decide(
		request: Dictionary,
		_cancel_check: Callable,
		_inference: Variant,
	) -> Dictionary:
		OS.delay_msec(delay_msec)
		return {
			"success": true,
			"kind": str(request.get("kind", "action")),
			"request_id": str(request.get("request_id", "")),
			"revision": int(request.get("revision", -1)),
		}


class TerminatingAICoordinator:
	extends AICoordinator

	func _worker_main(
		_request: Dictionary,
		_inference: Variant,
		_generation: int,
	) -> void:
		# Models a worker that exits before publishing its completion marker.
		return


class AcceptingChoiceNetworkController:
	extends NetworkMatchController

	var submitted_response: ChoiceResponse

	func _init(p_catalog: CardCatalog) -> void:
		super(p_catalog)

	func submit_choice(response: ChoiceResponse) -> bool:
		submitted_response = response
		return true


func _initialize() -> void:
	_run_phase_zero_tests()
	_run_phase_one_tests()
	_run_phase_two_tests()
	_run_phase_four_foundation_tests()
	_run_phase_five_foundation_tests()
	_run_phase_six_foundation_tests()
	_run_visual_upgrade_tests()
	# Most legacy geometry contracts intentionally inspect controls before their
	# first rendered container pass. Run the new frame-aware Main flow last so
	# those contracts keep their established synchronous environment.
	call_deferred("_run_async_phase_three_tests")


func _run_async_phase_three_tests() -> void:
	await _run_phase_three_tests()
	_stop_test_audio_players()
	# Flush queue_free calls made by the final UI fixtures before terminating the
	# SceneTree; otherwise they are reported as leaked ObjectDB instances.
	await process_frame
	await process_frame
	_finish_tests()


func _stop_test_audio_players() -> void:
	for node in root.find_children("*", "AudioStreamPlayer", true, false):
		var player := node as AudioStreamPlayer
		if player == null:
			continue
		player.stop()
		player.stream = null


func _finish_tests() -> void:

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
	_check(bool(ProjectSettings.get_setting(
		"input_devices/pointing/emulate_mouse_from_touch", false)),
		"Android touch input must emulate mouse events for shared card gesture handling")
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
	var deck_keys := decks.keys()
	deck_keys.sort()
	var profile_keys := AIDeckProfiles.PROFILES.keys()
	profile_keys.sort()
	_check(
		deck_keys == profile_keys,
		"Godot deck keys and Challenge AI profile keys must match. decks=%s profiles=%s" % [
			JSON.stringify(deck_keys),
			JSON.stringify(profile_keys),
		],
	)
	_check(fixture.get("counts", {}).get("effects", 0) == 77, "Expected 77 effect types")
	_check(
		int(fixture.get("vm_version", 0)) == VMContract.IR_VERSION,
		"Fixture VM version must match Godot VMContract",
	)
	_check(
		str(fixture.get("vm", {}).get("runtime_effect_source", "")) == "compiled_effects",
		"Runtime must use compiled VM effects",
	)
	for deck_key in decks:
		_check(decks[deck_key].get("card_count", 0) == 60, "Deck %s must contain 60 cards" % deck_key)
	var model_keys := Dictionary(models.get("models", {})).keys()
	model_keys.sort()
	_check(
		model_keys == deck_keys,
		"Expected Deep AI model manifest rows for all release decks",
	)
	_check(models.get("state_numeric_size", 0) == 960, "Deep AI state size mismatch")
	_check(
		models.get("state_card_slots", 0)
		== AIActionEncoder.STATE_CARD_SLOTS,
		"Deep AI card slot count mismatch",
	)
	_check(models.get("action_numeric_size", 0) == 178, "Deep AI action size mismatch")
	_check_release_effects_have_compiled_ir(cards)
	_check_card_rules_matrix(cards)
	_check(
		int(cards["sv2-tatsu"]["attacks"][1].get("damage", 0)) == 30
		and str(cards["sv2-tatsu"]["attacks"][1].get("damage_text", "")) == "30"
		and str(cards["sv1-107"]["attacks"][0].get("damage_text", "")) == "10×"
		and str(cards["svi-gree"]["attacks"][1].get("damage_text", "")) == "60+"
		and str(cards["svg-ceti"]["attacks"][1].get("damage_text", "")) == "200-"
		and str(cards["svg2-empo"]["attacks"][0].get("damage_text", "")) == "",
		"Exported attack damage_text labels are incorrect",
	)

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
		state.clone_state().to_dict() == restored_state.to_dict(),
		"GameState clone_state did not match snapshot roundtrip",
	)

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
	_run_rules_coverage_inventory(fixture, engine)
	var effect_types: Array = fixture.get("effect_types", [])
	_check(effect_types.size() == 77, "Expected 77 exported effect type names")
	for effect_type in effect_types:
		_check(
			RulesTestHarness.effect_engine_for(engine).supports_effect_type(str(effect_type)),
			"Unsupported effect type: %s" % effect_type,
		)
	var compiled_examples: Dictionary = fixture.get("compiled_effect_examples", {})
	_check(compiled_examples.size() == 77, "Expected one compiled example for every effect type")
	for effect_type in compiled_examples:
		_check(
			RulesTestHarness.effect_engine_for(engine).supports_command_spec(Dictionary(compiled_examples[effect_type])),
			"Unsupported compiled effect spec: %s" % effect_type,
		)
	var raw_examples: Dictionary = fixture.get("effect_examples", {})
	_check(raw_examples.size() == 77, "Expected one raw metadata example for every effect type")
	for effect_type in raw_examples:
		var raw_effect := Dictionary(raw_examples[effect_type])
		_check(
			str(raw_effect.get("effect_type", "")) == str(effect_type),
			"Raw effect metadata key mismatch for %s" % effect_type,
		)
		_check(
			not RulesTestHarness.effect_engine_for(engine).supports_command_spec(raw_effect),
			"Raw effect metadata must not be accepted as a VM command: %s" % effect_type,
		)
	_check_release_compiled_command_specs(catalog, engine)
	var recovery_filter := catalog.filter_cards(
		["sv1-104", "sv1-ener-1", "svi-mirc", "svf-potion"],
		"pokemon_and_energy",
	)
	_check(
		recovery_filter == ["sv1-104", "sv1-ener-1"],
		"pokemon_and_energy filter must include Pokemon and basic Energy only",
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
	var formula_ast_effects := [
		"damage_per_discard_psychic",
		"damage_per_energy",
		"damage_per_evolved",
		"damage_per_hand_size",
		"damage_per_self_damage",
		"damage_per_self_energy",
		"damage_per_self_energy_type",
		"damage_plus_bench",
		"damage_self_penalty",
		"attack_damage_formula",
	]
	var legacy_formula_ops := [
		"deal_damage_per_discard_psychic",
		"deal_damage_per_energy",
		"deal_damage_per_evolved",
		"deal_damage_per_hand_size",
		"deal_damage_per_self_damage",
		"deal_damage_per_self_energy",
		"deal_damage_per_self_energy_type",
		"deal_damage_plus_bench",
		"deal_damage_with_self_penalty",
		"set_attack_damage_formula",
	]
	for effect_type in formula_ast_effects:
		var spec := Dictionary(compiled_examples.get(effect_type, {}))
		_check(
			str(spec.get("op", "")) == "deal_damage",
			"Damage formula effect did not compile to generic deal_damage op: %s" % effect_type,
		)
		_check(
			Dictionary(spec.get("args", {})).has("formula_ast"),
			"Damage formula effect did not carry formula_ast: %s" % effect_type,
		)
		_check(
			not Dictionary(spec.get("args", {})).has("effect_type"),
			"Damage formula op still carries legacy effect_type args: %s" % effect_type,
		)
	for effect_type in compiled_examples:
		var spec := Dictionary(compiled_examples.get(effect_type, {}))
		_check(
			not (str(spec.get("op", "")) in legacy_formula_ops),
			"Compiled example still uses legacy formula op: %s" % effect_type,
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
		not RulesTestHarness.effect_engine_for(engine).supports_command_spec({
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
			not RulesTestHarness.effect_engine_for(engine).supports_command_spec({
				"op": op,
				"args": {},
				"branches": {},
			}),
			"Retired VM op must not be accepted: %s" % op,
		)
	_check(
		not RulesTestHarness.effect_engine_for(engine).supports_command_spec({
			"op": "deal_damage",
			"args": {"effect_type": "damage", "amount": 10},
			"branches": {},
		}),
		"Native VM op must not accept legacy effect_type args",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime is VMRuntime
		and RulesTestHarness.effect_engine_for(engine).runtime.catalog == engine.catalog
		and RulesTestHarness.effect_engine_for(engine).runtime.is_ready()
		and RulesTestHarness.effect_engine_for(engine).runtime.vm_interpreter.command_registry.descriptors().size()
		== VMContract.native_command_ops().size(),
		"EffectEngine did not initialize a VMRuntime facade",
	)
	_check(
		VMContract.MAX_VM_STEPS == 4096
		and VMContract.MAX_FRAME_DEPTH == 64
		and not bool(VMResult.require_explicit(
			{"message": "implicit"}, "test").get("success", true))
		and VMResult.require_explicit(
			{"message": "implicit"}, "test").get("error_code", "")
		== "invalid_vm_result",
		"VM runtime must freeze a complete descriptor registry and reject implicit success",
	)
	_check(
		VMContract.supports_effect_type("draw")
		and VMContract.supports_effect_type("zinnia_resolve")
		and not VMContract.supports_effect_type("__unknown_effect__")
		and VMContract.native_command_ops().has("draw_cards")
		and VMContract.native_command_ops().has("trigger_switch_with_active")
		and not VMContract.native_command_ops().has("__unknown_vm_op__"),
		"VM effect/op support matrix must live in VMContract",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.vm_interpreter.has_method("resolve")
		and RulesTestHarness.effect_engine_for(engine).runtime.vm_interpreter.has_method("apply_choice")
		and RulesTestHarness.effect_engine_for(engine).runtime.vm_interpreter.has_method("execute_effect")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_register_command_handlers")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_register_continuations")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_execute_command_spec")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_execute_effect")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_execute_continuation"),
		"VM runtime assembly and resolution loops must live below EffectEngine",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).supports_command_handler("draw_cards")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("apply_status")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("apply_dazzling_beam")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("deal_damage")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("deal_damage_per_energy")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("deal_damage_per_hand_size")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("discard_energy")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("discard_energy_then_damage")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("mill_then_damage")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("prevent_all")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("register_tool_modifier")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("return_to_hand")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("set_attack_damage_formula")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("set_attack_flags")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("trigger_draw_cards")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("trigger_move_basic_energy")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("trigger_place_damage_counters")
		and RulesTestHarness.effect_engine_for(engine).supports_command_handler("trigger_switch_with_active"),
		"VM command registry is missing known command handlers",
	)
	_check(
		not RulesTestHarness.effect_engine_for(engine).supports_command_handler("__unknown_vm_op__"),
		"VM command registry accepted an unknown command handler",
	)
	for op in RulesTestHarness.effect_engine_for(engine).native_command_ops():
		_check(
			RulesTestHarness.effect_engine_for(engine).supports_command_handler(str(op)),
			"Native VM op is missing an executable command handler: %s" % str(op),
		)
	_check(
		RulesTestHarness.effect_engine_for(engine).supports_continuation("search_move")
		and RulesTestHarness.effect_engine_for(engine).supports_continuation("energy_relocate_distribution")
		and RulesTestHarness.effect_engine_for(engine).supports_continuation("trekking_shoes"),
		"VM continuation registry is missing known continuation handlers",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.trainer_continuations is VMTrainerContinuations
		and not RulesTestHarness.effect_engine_for(engine).has_method("_continue_arven")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_continue_discard_then_draw"),
		"Trainer continuations must be registered through VMTrainerContinuations",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.board_continuations is VMBoardContinuations
		and not RulesTestHarness.effect_engine_for(engine).has_method("_continue_switch")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_continue_coin")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_continue_discard_attachment"),
		"Board continuations must be registered through VMBoardContinuations",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.energy_continuations is VMEnergyContinuations
		and not RulesTestHarness.effect_engine_for(engine).has_method("_continue_energy_attach_target")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_continue_energy_relocate_distribution"),
		"Energy continuations must be registered through VMEnergyContinuations",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.look_top_continuations is VMLookTopContinuations
		and not RulesTestHarness.effect_engine_for(engine).has_method("_continue_look_top")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_continue_trekking_shoes"),
		"Look-top continuations must be registered through VMLookTopContinuations",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.draw_commands is VMDrawCommands
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_draw_cards")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_draw_until")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_shuffle_then_draw_cards"),
		"Draw command handlers must be registered through VMDrawCommands",
	)
	var zone_helpers := VMZoneHelpers.new()
	_check(
		zone_helpers.has_method("zone")
		and zone_helpers.has_method("draw_available")
		and zone_helpers.has_method("move_selected_cards")
		and zone_helpers.has_method("remove_selected_from_zone")
		and zone_helpers.has_method("discard_event")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_zone")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_draw")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_draw_available")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_move_selected_cards")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_remove_selected_from_zone")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_discard_event"),
		"Zone mutation helpers must live in VMZoneHelpers, not EffectEngine",
	)
	var choice_requests := VMChoiceRequests.new()
	_check(
		choice_requests.has_method("request_cards")
		and choice_requests.has_method("confirm_request")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_request_cards")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_confirm_request"),
		"Generic choice request builders must live in VMChoiceRequests, not EffectEngine",
	)
	var vm_result := VMResult.new()
	_check(
		vm_result.has_method("ok")
		and vm_result.has_method("fail")
		and bool(VMResult.ok().get("success", false))
		and not bool(VMResult.fail("x").get("success", true))
		and not RulesTestHarness.effect_engine_for(engine).has_method("_ok")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_fail"),
		"VM result dictionaries must be built through VMResult, not EffectEngine",
	)
	var runtime_effects := VMRuntimeEffects.new()
	_check(
		runtime_effects.has_method("trainer_effects")
		and runtime_effects.has_method("ability_effects")
		and runtime_effects.has_method("strict_trainer_effects")
		and runtime_effects.has_method("missing_compiled_effect")
		and runtime_effects.has_method("effect_kind")
		and runtime_effects.has_method("effect_args"),
		"Godot VM runtime effect selectors must live in VMRuntimeEffects",
	)
	_check(
		runtime_effects.has_method("availability_effect_kind")
		and runtime_effects.has_method("availability_effect_params")
		and runtime_effects.has_method("replaces_attack_base_damage")
		and runtime_effects.has_method("effect_list"),
		"Godot VM availability effect parsing must live in VMRuntimeEffects",
	)
	_check(
		VMRuntimeEffects.availability_effect_kind({"op": "choose_heal_damage", "args": {}, "branches": {}}) == "potion_heal"
		and VMRuntimeEffects.availability_effect_kind({
			"op": "switch_pokemon",
			"args": {"target": "opponent"},
			"branches": {},
		}) == "switch_opponent"
		and VMRuntimeEffects.availability_effect_kind({
			"op": "set_attack_flags",
			"args": {"ignore_weakness": true},
			"branches": {},
		}) == "attack_flags"
		and VMRuntimeEffects.replaces_attack_base_damage({
			"op": "deal_damage",
			"args": {"formula_ast": {"const": 40}},
			"branches": {},
		}),
		"VMRuntimeEffects availability aliases changed rule semantics",
	)
	_check(
		RulesTestHarness.availability_for(engine) is VMAvailability
		and RulesTestHarness.action_availability_for(engine) is VMActionAvailability
		and RulesTestHarness.action_executor_for(engine) is VMActionExecutor
		and RulesTestHarness.action_dispatcher_for(engine) is VMActionDispatcher
		and RulesTestHarness.action_availability_for(engine).catalog == engine.catalog
		and RulesTestHarness.action_availability_for(engine).validator == RulesTestHarness.validator_for(engine)
		and RulesTestHarness.action_availability_for(engine).availability == RulesTestHarness.availability_for(engine)
		and RulesTestHarness.action_availability_for(engine).attack_settlement == RulesTestHarness.attack_settlement_for(engine)
		and RulesTestHarness.action_executor_for(engine).catalog == engine.catalog
		and RulesTestHarness.action_executor_for(engine).validator == RulesTestHarness.validator_for(engine)
		and RulesTestHarness.action_executor_for(engine).availability == RulesTestHarness.availability_for(engine)
		and RulesTestHarness.action_executor_for(engine).effect_engine == RulesTestHarness.effect_engine_for(engine)
		and RulesTestHarness.action_executor_for(engine).turn_settlement == RulesTestHarness.turn_settlement_for(engine)
		and RulesTestHarness.action_dispatcher_for(engine).action_executor == RulesTestHarness.action_executor_for(engine)
		and RulesTestHarness.action_dispatcher_for(engine).promotion_settlement == RulesTestHarness.promotion_settlement_for(engine)
		and RulesTestHarness.action_dispatcher_for(engine).attack_settlement == RulesTestHarness.attack_settlement_for(engine)
		and RulesTestHarness.action_dispatcher_for(engine).turn_settlement == RulesTestHarness.turn_settlement_for(engine)
		and RulesTestHarness.action_availability_for(engine).has_method("legal_actions")
		and RulesTestHarness.action_availability_for(engine).has_method("action_cost_error")
		and RulesTestHarness.action_availability_for(engine).has_method("action_target_availability_error")
		and RulesTestHarness.action_availability_for(engine).has_method("validate_action_references")
		and not RulesTestHarness.action_availability_for(engine).has_method("retreat_payments")
		and engine.has_method("query_legal_action_groups")
		and RulesTestHarness.action_registry_for(engine).is_frozen()
		and RulesTestHarness.action_registry_for(engine).public_kinds().size() == 11
		and RulesTestHarness.action_executor_for(engine).has_method("play_basic")
		and RulesTestHarness.action_executor_for(engine).has_method("play_trainer")
		and RulesTestHarness.action_executor_for(engine).has_method("run_effects")
		and RulesTestHarness.action_dispatcher_for(engine).has_method("register_action")
		and RulesTestHarness.action_dispatcher_for(engine).has_method("supports_action")
		and RulesTestHarness.action_dispatcher_for(engine).has_method("dispatch")
		and RulesTestHarness.action_dispatcher_for(engine).supports_action("NOOP")
		and RulesTestHarness.action_dispatcher_for(engine).supports_action("SETUP_DONE")
		and RulesTestHarness.action_dispatcher_for(engine).supports_action("PROMOTE")
		and RulesTestHarness.action_dispatcher_for(engine).supports_action("PLAY_BASIC")
		and RulesTestHarness.action_dispatcher_for(engine).supports_action("EVOLVE")
		and RulesTestHarness.action_dispatcher_for(engine).supports_action("ATTACH_ENERGY")
		and RulesTestHarness.action_dispatcher_for(engine).supports_action("PLAY_TRAINER")
		and RulesTestHarness.action_dispatcher_for(engine).supports_action("USE_ABILITY")
		and RulesTestHarness.action_dispatcher_for(engine).supports_action("USE_STADIUM")
		and RulesTestHarness.action_dispatcher_for(engine).supports_action("RETREAT")
		and RulesTestHarness.action_dispatcher_for(engine).supports_action("DECLARE_ATTACK")
		and RulesTestHarness.action_dispatcher_for(engine).supports_action("END_TURN")
		and RulesTestHarness.availability_for(engine).has_method("effects_have_legal_target")
		and RulesTestHarness.availability_for(engine).has_method("effects_cost_is_payable")
		and RulesTestHarness.availability_for(engine).has_method("stadium_is_activatable")
		and not engine.has_method("_effects_have_legal_target")
		and not engine.has_method("_effects_cost_is_payable")
		and not engine.has_method("_stadium_is_activatable"),
		"Godot legal action and target/cost checks must live in VM availability services",
	)
	_check(
		RulesTestHarness.transaction_manager_for(engine) is VMTransactionManager
		and RulesTestHarness.action_settlement_for(engine) is VMActionSettlement
		and RulesTestHarness.action_settlement_for(engine).knockout_settlement == RulesTestHarness.knockout_settlement_for(engine)
		and RulesTestHarness.action_settlement_for(engine).transaction_manager == RulesTestHarness.transaction_manager_for(engine)
		and RulesTestHarness.action_settlement_for(engine).has_method("apply_action")
		and RulesTestHarness.choice_settlement_for(engine) is VMChoiceSettlement
		and RulesTestHarness.choice_settlement_for(engine).effect_engine == RulesTestHarness.effect_engine_for(engine)
		and RulesTestHarness.choice_settlement_for(engine).attack_settlement == RulesTestHarness.attack_settlement_for(engine)
		and RulesTestHarness.choice_settlement_for(engine).knockout_settlement == RulesTestHarness.knockout_settlement_for(engine)
		and RulesTestHarness.choice_settlement_for(engine).transaction_manager == RulesTestHarness.transaction_manager_for(engine)
		and RulesTestHarness.choice_settlement_for(engine).has_method("apply_choice")
		and RulesTestHarness.transaction_manager_for(engine).has_method("capture_transaction")
		and RulesTestHarness.transaction_manager_for(engine).has_method("rollback_failed_step")
		and RulesTestHarness.transaction_manager_for(engine).has_method("restore_cancelled_action")
		and RulesTestHarness.transaction_manager_for(engine).has_method("cancel_action_checkpoint")
		and not engine.has_method("_merge_steps")
		and not engine.has_method("_capture_transaction")
		and not engine.has_method("_rollback_failed_step")
		and not engine.has_method("_rollback_transaction")
		and not engine.has_method("_restore_state")
		and not engine.has_method("_cancel_action_checkpoint"),
		"Public action/choice transaction rollback must live in VMTransactionManager",
	)
	var registered_action_kinds := RulesTestHarness.action_registry_for(engine).public_kinds() + ["NOOP"]
	var action_registry_complete := true
	for registered_kind in registered_action_kinds:
		var registered_definition := RulesTestHarness.action_registry_for(engine).definition(registered_kind)
		action_registry_complete = action_registry_complete and (
			Callable(registered_definition.get("preflight", Callable())).is_valid()
			and Callable(registered_definition.get("executor", Callable())).is_valid()
			and RulesTestHarness.action_dispatcher_for(engine).supports_action(registered_kind)
		)
	_check(
		RulesTestHarness.runtime_for(engine) is RulesRuntime
		and RulesTestHarness.runtime_for(engine).is_ready()
		and RulesTestHarness.action_registry_for(engine).is_frozen()
		and action_registry_complete,
		"Action registry/runtime bindings are incomplete",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.trainer_commands is VMTrainerCommands
		and RulesTestHarness.effect_engine_for(engine).runtime.trainer_commands.catalog == engine.catalog
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_discard_cards")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_search_cards")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_zinnia_resolve")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_hand_to_bottom_then_draw_request")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_zinnia_resolve_request")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_recover_from_discard_request")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_arven_request")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_trekking_shoes_request")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_conditional_search_request")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_search_request")
		and RulesTestHarness.effect_engine_for(engine).runtime.trainer_commands.has_method("zinnia_resolve_request")
		and RulesTestHarness.effect_engine_for(engine).runtime.trainer_commands.has_method("search_request"),
		"Trainer command handlers must be registered through VMTrainerCommands",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.modifier_commands is VMModifierCommands
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_register_reactive_thorns")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_register_tool_modifier")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_register_vm_modifier"),
		"Modifier command handlers must be registered through VMModifierCommands",
	)
	_check(
		RulesTestHarness.attack_settlement_for(engine) is VMAttackSettlement
		and RulesTestHarness.knockout_settlement_for(engine) is VMKnockoutSettlement
		and RulesTestHarness.knockout_settlement_for(engine).catalog == engine.catalog
		and RulesTestHarness.knockout_settlement_for(engine).validator == RulesTestHarness.validator_for(engine)
		and RulesTestHarness.attack_settlement_for(engine).knockout_settlement == RulesTestHarness.knockout_settlement_for(engine)
		and RulesTestHarness.attack_settlement_for(engine).effect_engine == RulesTestHarness.effect_engine_for(engine)
		and not engine.has_method("_declare_attack")
		and not engine.has_method("_run_attack_effects")
		and not engine.has_method("_attack_runtime_effects")
		and not engine.has_method("_complete_attack_context")
		and not engine.has_method("_resolve_attack_turn_frame")
		and not engine.has_method("_apply_attack_damage")
		and not engine.has_method("_resolve_trigger_commands")
		and not engine.has_method("_collect_exp_share_commands")
		and not engine.has_method("_resolve_knockouts")
		and not engine.has_method("_resolve_empty_boards_and_promotions")
		and not RulesTestHarness.attack_settlement_for(engine).has_method("resolve_trigger_commands")
		and not RulesTestHarness.attack_settlement_for(engine).has_method("collect_exp_share_commands")
		and RulesTestHarness.attack_settlement_for(engine).has_method("declare_attack")
		and RulesTestHarness.attack_settlement_for(engine).has_method("run_attack_effects")
		and RulesTestHarness.attack_settlement_for(engine).has_method("attack_runtime_effects")
		and RulesTestHarness.attack_settlement_for(engine).has_method("complete_attack_context")
		and RulesTestHarness.attack_settlement_for(engine).has_method("resolve_attack_turn_frame")
		and RulesTestHarness.attack_settlement_for(engine).has_method("apply_attack_damage")
		and not RulesTestHarness.attack_settlement_for(engine).has_method("resolve_knockouts")
		and not RulesTestHarness.attack_settlement_for(engine).has_method("resolve_empty_boards_and_promotions")
		and RulesTestHarness.knockout_settlement_for(engine).has_method("resolve_knockouts")
		and RulesTestHarness.knockout_settlement_for(engine).has_method("resolve_empty_boards_and_promotions"),
		"Attack settlement must be routed through VMAttackSettlement",
	)
	_check(
		RulesTestHarness.attack_settlement_for(engine).trigger_command_runner is VMTriggerCommands
		and RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands is VMTriggerCommands
		and RulesTestHarness.attack_settlement_for(engine).trigger_command_runner == RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands
		and RulesTestHarness.knockout_settlement_for(engine).trigger_command_runner == RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands
		and RulesTestHarness.attack_settlement_for(engine).trigger_command_runner.has_method("queue_candidates")
		and RulesTestHarness.attack_settlement_for(engine).trigger_command_runner.has_method("collect_after_damage_triggers")
		and RulesTestHarness.attack_settlement_for(engine).trigger_command_runner.has_method("collect_pokemon_ko_triggers")
		and RulesTestHarness.attack_settlement_for(engine).trigger_command_runner.has_method("collect_on_attach_triggers")
		and not RulesTestHarness.attack_settlement_for(engine).trigger_command_runner.has_method("collect_exp_share_commands")
		and not VMDamageModifierHooks.new().has_method("collect_after_damage_commands")
		and RulesTestHarness.attack_settlement_for(engine).trigger_command_runner.has_method("tool_has_effect")
		and RulesTestHarness.attack_settlement_for(engine).trigger_command_runner.has_method("pokemon_has_modifier"),
		"Trigger command execution must be routed through VMTriggerCommands",
	)
	var trigger_specs_result := RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands.command_specs_from_payloads([{
		"op": "draw_cards",
		"player": 1,
		"amount": 1,
		"source": "structural_test",
	}])
	var trigger_specs: Array = trigger_specs_result.get("commands", [])
	_check(
		bool(trigger_specs_result.get("success", false))
		and trigger_specs.size() == 1
		and str(trigger_specs[0].get("op", "")) == "trigger_draw_cards"
		and trigger_specs[0].get("args") is Dictionary
		and trigger_specs[0].get("branches") is Dictionary
		and RulesTestHarness.effect_engine_for(engine).supports_command_spec(trigger_specs[0]),
		"Trigger payloads must normalize to supported VM command specs",
	)
	var grouped_trigger_specs_result := RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands.command_specs_from_payloads([
		{
			"exclusive_group": "test_group",
			"command_specs": [{
				"op": "trigger_draw_cards",
				"args": {"player": 1, "amount": 1, "source": "first_group"},
				"branches": {},
			}],
		},
		{
			"exclusive_group": "test_group",
			"command_specs": [{
				"op": "trigger_place_damage_counters",
				"args": {"player": 0, "slot": "active", "count": 1, "source": "duplicate_group"},
				"branches": {},
			}],
		},
		{
			"exclusive_group": "other_group",
			"op": "draw_cards",
			"player": 0,
			"amount": 1,
			"source": "other_group",
		},
	])
	var grouped_trigger_specs: Array = grouped_trigger_specs_result.get("commands", [])
	_check(
		bool(grouped_trigger_specs_result.get("success", false))
		and grouped_trigger_specs.size() == 2
		and str(grouped_trigger_specs[0].get("op", "")) == "trigger_draw_cards"
		and str(grouped_trigger_specs[0].get("args", {}).get("source", "")) == "first_group"
		and str(grouped_trigger_specs[1].get("op", "")) == "trigger_draw_cards"
		and str(grouped_trigger_specs[1].get("args", {}).get("source", "")) == "other_group",
		"Trigger payload exclusive_group must keep the first stable-priority command spec",
	)
	var empty_group_trigger_specs_result := RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands.command_specs_from_payloads([
		{"exclusive_group": "empty_first", "command_specs": []},
		{"exclusive_group": "empty_first", "command_specs": [null]},
		{
			"exclusive_group": "empty_first",
			"command_specs": [{
				"op": "trigger_draw_cards",
				"args": {"player": 1, "amount": 1, "source": "empty_first"},
				"branches": {},
			}],
		},
	])
	var empty_group_trigger_specs: Array = empty_group_trigger_specs_result.get("commands", [])
	_check(
		bool(empty_group_trigger_specs_result.get("success", false))
		and empty_group_trigger_specs.size() == 1
		and str(empty_group_trigger_specs[0].get("op", "")) == "trigger_draw_cards"
		and str(empty_group_trigger_specs[0].get("args", {}).get("source", "")) == "empty_first",
		"Empty trigger exclusive_group payloads must not block a later command spec",
	)
	var non_trigger_spec_result := RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands.command_specs_from_payloads([{
		"op": "draw_cards",
		"args": {"amount": 1},
		"branches": {},
	}])
	_check(
		not bool(non_trigger_spec_result.get("success", true))
		and str(non_trigger_spec_result.get("error_code", "")) == "invalid_trigger_op",
		"Explicit trigger command specs must reject ordinary VM ops",
	)
	var registered_trigger_ops: Array = VMTriggerCommands.TRIGGER_COMMAND_OPS.duplicate()
	registered_trigger_ops.sort()
	_check(
		registered_trigger_ops == [
			"trigger_draw_cards",
			"trigger_move_basic_energy",
			"trigger_place_damage_counters",
			"trigger_switch_with_active",
		],
		"Trigger command registry must expose the complete frozen trigger op set",
	)
	for trigger_op in registered_trigger_ops:
		_check(
			RulesTestHarness.effect_engine_for(engine).supports_command_handler(str(trigger_op)),
			"Trigger command registry lacks an executable handler: %s" % trigger_op,
		)
	_check(
		RulesTestHarness.turn_settlement_for(engine) is VMTurnSettlement
		and RulesTestHarness.attack_settlement_for(engine).turn_settlement == RulesTestHarness.turn_settlement_for(engine)
		and RulesTestHarness.promotion_settlement_for(engine) is VMPromotionSettlement
		and RulesTestHarness.promotion_settlement_for(engine).attack_settlement == RulesTestHarness.attack_settlement_for(engine)
		and RulesTestHarness.promotion_settlement_for(engine).turn_settlement == RulesTestHarness.turn_settlement_for(engine)
		and RulesTestHarness.turn_settlement_for(engine).knockout_settlement == RulesTestHarness.knockout_settlement_for(engine)
		and not engine.has_method("_end_turn")
		and not engine.has_method("_begin_turn")
		and not engine.has_method("_resolve_checkup")
		and not engine.has_method("_promote")
		and not RulesTestHarness.attack_settlement_for(engine).has_method("_facade")
		and not RulesTestHarness.turn_settlement_for(engine).has_method("_attack_settlement")
		and RulesTestHarness.turn_settlement_for(engine).has_method("end_turn")
		and RulesTestHarness.turn_settlement_for(engine).has_method("begin_turn")
		and RulesTestHarness.turn_settlement_for(engine).has_method("resolve_checkup")
		and RulesTestHarness.promotion_settlement_for(engine).has_method("apply_promotion"),
		"Turn and promotion settlement must be routed through VM settlement modules",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.energy_commands is VMEnergyCommands
		and RulesTestHarness.effect_engine_for(engine).runtime.energy_commands.catalog == engine.catalog
		and RulesTestHarness.effect_engine_for(engine).runtime.energy_commands.trigger_commands == RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands
		and RulesTestHarness.effect_engine_for(engine).runtime.energy_continuations.energy_commands == RulesTestHarness.effect_engine_for(engine).runtime.energy_commands
		and RulesTestHarness.effect_engine_for(engine).runtime.energy_continuations.trigger_commands == RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_attach_energy")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_draw_and_attach_energy")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_relocate_energy")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_energy_attach")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_attach_from_discard")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_request_energy_target")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_attach_cards")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_energy_relocate_request")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_request_relocation_targets")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_attach_from_hand_to_bench")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_discard_energy")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_energy_matches")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_matching_energy_ids")
		and RulesTestHarness.effect_engine_for(engine).runtime.energy_commands.has_method("energy_attach")
		and RulesTestHarness.effect_engine_for(engine).runtime.energy_commands.has_method("request_energy_target")
		and RulesTestHarness.effect_engine_for(engine).runtime.energy_commands.has_method("request_relocation_targets"),
		"Energy command handlers must be registered through VMEnergyCommands",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.status_commands is VMStatusCommands
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_apply_status")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_prevent_damage")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_set_attack_flags")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_apply_status"),
		"Status command handlers must be registered through VMStatusCommands",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.coin_commands is VMCoinCommands
		and RulesTestHarness.effect_engine_for(engine).runtime.coin_commands.catalog == engine.catalog
		and RulesTestHarness.effect_engine_for(engine).runtime.coin_commands.combat_damage == RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.damage
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_flip_coin")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_coin_request")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_resolve_coin"),
		"Coin command handlers must be registered through VMCoinCommands",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.board_commands is VMBoardCommands
		and RulesTestHarness.effect_engine_for(engine).runtime.board_commands.catalog == engine.catalog
		and RulesTestHarness.effect_engine_for(engine).runtime.board_continuations.board_commands == RulesTestHarness.effect_engine_for(engine).runtime.board_commands
		and RulesTestHarness.effect_engine_for(engine).runtime.board_continuations.coin_commands == RulesTestHarness.effect_engine_for(engine).runtime.coin_commands
		and RulesTestHarness.effect_engine_for(engine).runtime.board_continuations.combat_damage == RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.damage
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_switch_pokemon")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_return_to_hand")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_rare_candy")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_return_to_hand")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_request_board_target")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_request_bench_target")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_switch_request")
		and RulesTestHarness.effect_engine_for(engine).runtime.board_commands.has_method("request_board_target")
		and RulesTestHarness.effect_engine_for(engine).runtime.board_commands.has_method("request_bench_target")
		and RulesTestHarness.effect_engine_for(engine).runtime.board_commands.has_method("switch_request"),
		"Board command handlers must be registered through VMBoardCommands",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.look_top_commands is VMLookTopCommands
		and RulesTestHarness.effect_engine_for(engine).runtime.look_top_commands.catalog == engine.catalog
		and RulesTestHarness.effect_engine_for(engine).runtime.look_top_commands.energy_commands == RulesTestHarness.effect_engine_for(engine).runtime.energy_commands
		and RulesTestHarness.effect_engine_for(engine).runtime.look_top_continuations.catalog == engine.catalog
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_look_top_deck")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_look_top_attach_energy")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_look_top_request"),
		"Look-top command handlers must be registered through VMLookTopCommands",
	)
	_check(
		RulesTestHarness.effect_engine_for(engine).runtime.combat_commands is VMCombatCommands
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.catalog == engine.catalog
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.trainer_commands == RulesTestHarness.effect_engine_for(engine).runtime.trainer_commands
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.board_commands == RulesTestHarness.effect_engine_for(engine).runtime.board_commands
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.damage is VMCombatDamage
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.formula is VMCombatFormula
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.choice is VMCombatChoice
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.conditionals is VMCombatConditionals
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.combo is VMCombatCombo
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.formula.damage == RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.damage
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.choice.board_commands == RulesTestHarness.effect_engine_for(engine).runtime.board_commands
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.choice.damage == RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.damage
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.conditionals.damage == RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.damage
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.combo.damage == RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.damage
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_deal_damage")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_conditional")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_heal_damage")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_cmd_set_attack_damage_formula")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_deal_damage")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_heal_pokemon")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_attack_damage_formula")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_evaluate_formula_ast")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_eval_formula_node")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_formula_energy_count")
		and not RulesTestHarness.effect_engine_for(engine).has_method("_selected_bench_damage")
		and not RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.has_method("deal_damage")
		and not RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.has_method("attack_damage_formula")
		and not RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.has_method("evaluate_formula_ast")
		and RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.formula.has_method("evaluate_formula_ast")
		and not RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.has_method("request_injured_target")
		and not RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.has_method("conditional_effect")
		and not RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.has_method("discard_hand_then_damage")
		and not RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.has_method("mill_then_damage"),
		"Combat command handlers must be registered through VMCombatCommands submodules",
	)
	_check(
		not RulesTestHarness.effect_engine_for(engine).supports_continuation("__unknown_continuation__"),
		"VM continuation registry accepted an unknown continuation",
	)
	var modifier_manager := VMModifierManager.new()
	modifier_manager.register_hook(VMModifierManager.MAX_HP, "late", 0, 10)
	modifier_manager.register_hook(VMModifierManager.MAX_HP, "early", 0, 20)
	modifier_manager.register_hook(VMModifierManager.MAX_HP, "tie", 0, 10)
	var modifier_hooks := modifier_manager.hooks_for(VMModifierManager.MAX_HP)
	_check(
		modifier_hooks.size() == 3
		and str(modifier_hooks[0].get("source", "")) == "early"
		and str(modifier_hooks[1].get("source", "")) == "late"
		and str(modifier_hooks[2].get("source", "")) == "tie",
		"VM modifier hook priority order is unstable",
	)
	modifier_manager.register_hook(
		VMModifierManager.AFTER_DAMAGE,
		"payload_source",
		1,
		0,
		{"kind": "payload_check"},
	)
	var payload_hooks := modifier_manager.hooks_for(VMModifierManager.AFTER_DAMAGE)
	_check(
		payload_hooks.size() == 1
		and str(payload_hooks[0].get("payload", {}).get("kind", "")) == "payload_check",
		"VM modifier hook payload was not preserved",
	)
	_run_compiled_effect_examples(fixture, catalog, engine)
	_run_native_command_spec_tests(engine)
	_run_compiled_runtime_dispatch_tests(engine)
	_run_python_golden_actions(engine)
	_run_release_deck_playouts(catalog, engine)
	_run_steel_rules_tests(catalog, engine)
	_run_darkness_rules_tests(catalog, engine)
	_run_turn_state_regression_tests(catalog, engine)
	_run_entry_rule_contract_tests(catalog, engine)
	_run_card_effect_accuracy_tests(engine)
	_run_conditional_damage_regression_tests(engine)

	var stack := ResolutionStack.new()
	stack.context = {"finish_attack": true, "actor": 0}
	stack.push_finalize_attack(0)
	stack.push_effect({"op": "draw_cards", "args": {"amount": 1}, "branches": {}}, 0, "active")
	var restored_stack := ResolutionStack.from_dict(stack.to_dict())
	_check(restored_stack.to_dict() == stack.to_dict(), "ResolutionStack roundtrip failed")
	_check(
		restored_stack.frames[0].get("kind", "") == "barrier"
		and restored_stack.frames[0].get("operation", "") == "finalize_attack",
		"ResolutionStack did not preserve the strict finalize_attack barrier",
	)
	var attack_turn_stack := ResolutionStack.new()
	attack_turn_stack.push_finalize_attack_turn(0)
	var restored_attack_turn_stack := ResolutionStack.from_dict(attack_turn_stack.to_dict())
	_check(
		restored_attack_turn_stack.has_finalize_attack_turn_frame(),
		"ResolutionStack did not preserve finalize_attack_turn frame",
	)

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
	var attach_result := _apply_test_action(engine,
		action_state, attach, PortableRandomSource.new(12))
	_check(attach_result.success, "Energy attachment failed: %s" % attach_result.message)
	_check(action_state.players[0].active.energy_card_ids == ["sv1-ener-5"],
		"Energy attachment state mismatch")
	var duplicate_result := _apply_test_action(engine,
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
	var attack_result := _apply_test_action(engine,
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
	var trainer_result := _apply_test_action(engine,
		choice_state, trainer, PortableRandomSource.new(14))
	_check(trainer_result.success, "Search trainer failed")
	_check(trainer_result.pending_choice != null, "Search trainer did not request a choice")
	if trainer_result.pending_choice:
		var request := trainer_result.pending_choice
		var response := ChoiceResponse.new(request.request_id, [request.options[0]["option_id"]])
		var choice_result := RulesTestHarness.apply_choice(engine,
			choice_state, request, response, PortableRandomSource.new(15))
		_check(choice_result.success, "Search choice failed: %s" % choice_result.message)
		_check(choice_state.players[0].bench_count() == 1,
			"Search destination bench mismatch")

	var cancel_state := _battle_state()
	cancel_state.turn_number = 3
	cancel_state.first_player_idx = 0
	cancel_state.players[0].hand = ["svi-cait", "sv1-ener-5"]
	cancel_state.action_log = ["preexisting log"]
	cancel_state.event_stream.push("preexisting", {"value": 1})
	var cancel_before_snapshot := cancel_state.snapshot()
	var cancel_before_events := cancel_state.event_stream._events.duplicate(true)
	var cancel_before_revision := cancel_state.revision
	var cancel_rng := PortableRandomSource.new(16)
	var cancel_before_rng := cancel_rng.get_state()
	var cancel_action := GameAction.new(
		"PLAY_TRAINER",
		{"hand_idx": 0},
		false,
		0,
		EntityRef.new("card", 0, "hand", "", 0, "", "svi-cait"),
	)
	var cancel_step := _apply_test_action(engine,
		cancel_state, cancel_action, cancel_rng)
	_check(cancel_step.pending_choice != null, "Cancellable trainer did not request choice")
	if cancel_step.pending_choice:
		var cancel_stack := ResolutionStack.from_dict(cancel_state.resolution_stack)
		_check(
			cancel_stack.context.get("cancel_action_checkpoint") is Dictionary,
			"Cancellable trainer did not serialize a cancel checkpoint",
		)
		var cancel_checkpoint := Dictionary(cancel_stack.context.get("cancel_action_checkpoint", {}))
		_check(
			Dictionary(cancel_checkpoint.get("state", {})).get("revision", -1) == cancel_before_revision,
			"Cancel checkpoint did not capture the pre-action revision",
		)
		var cancelled := RulesTestHarness.apply_choice(engine,
			cancel_state,
			cancel_step.pending_choice,
			ChoiceResponse.new(cancel_step.pending_choice.request_id, [], true),
			cancel_rng,
		)
		_check(cancelled.success, "Trainer cancellation failed")
		_check(cancel_state.players[0].hand == ["svi-cait", "sv1-ener-5"],
			"Trainer cancellation did not restore the pre-action state")
		var expected_cancel_snapshot := cancel_before_snapshot.duplicate(true)
		expected_cancel_snapshot["revision"] = cancel_before_revision + 2
		_check(
			cancel_state.snapshot() == expected_cancel_snapshot,
			"Trainer cancellation did not restore the serialized action checkpoint",
		)
		_check(
			cancel_state.event_stream._events == cancel_before_events,
			"Trainer cancellation did not restore event stream",
		)
		_check(
			cancel_rng.get_state() == cancel_before_rng,
			"Trainer cancellation did not restore RNG state",
		)
		var restored_cancel_stack := ResolutionStack.from_dict(cancel_state.resolution_stack)
		_check(
			restored_cancel_stack.pending_request == null
			and restored_cancel_stack.frames.is_empty()
			and not restored_cancel_stack.context.has("cancel_action_checkpoint"),
			"Trainer cancellation left pending stack data behind",
		)

	var partial_fail_id := "__test_partial_action_rollback"
	engine.catalog.cards[partial_fail_id] = {
		"api_id": partial_fail_id,
		"name": "Partial Action Rollback",
		"supertype": "Trainer",
		"subtypes": ["Item"],
		"trainer_type": "Item",
		"trainer_effects": [],
		"compiled_trainer_effects": [
			{
				"op": "shuffle_then_draw_cards",
				"args": {"draw": 1, "shuffle_hand": true},
				"branches": {},
			},
			{
				"op": "choose_heal_damage",
				"args": {"amount": 30, "target_player": "self"},
				"branches": {},
			},
		],
		"abilities": [],
		"attacks": [],
	}
	var partial_fail_state := _battle_state()
	partial_fail_state.players[0].hand = [partial_fail_id, "sv1-ener-5"]
	partial_fail_state.players[0].deck = ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3"]
	partial_fail_state.action_log = ["preexisting log"]
	partial_fail_state.event_stream.push("preexisting", {"value": 1})
	var partial_before_snapshot := partial_fail_state.snapshot()
	var partial_before_events := partial_fail_state.event_stream._events.duplicate(true)
	var partial_rng := PortableRandomSource.new(20260661)
	var partial_before_rng := partial_rng.get_state()
	var partial_step := _apply_test_action(engine,
		partial_fail_state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		partial_rng,
	)
	_check(
		not partial_step.success and partial_step.message.find("没有受伤的宝可梦") >= 0,
		"Partial action rollback fixture did not fail after the second VM command",
	)
	_check(
		partial_fail_state.snapshot() == partial_before_snapshot,
		"Failed public action did not restore state after earlier VM mutations",
	)
	_check(
		partial_rng.get_state() == partial_before_rng,
		"Failed public action did not restore RNG state after shuffle",
	)
	_check(
		partial_fail_state.event_stream._events == partial_before_events,
		"Failed public action did not restore event stream after earlier VM mutations",
	)
	_check(
		partial_step.pending_choice == null and partial_step.events.is_empty(),
		"Failed public action StepResult still exposes rolled-back pending/events",
	)

	var trigger_fail_state := _battle_state()
	_set_energy_cards(trigger_fail_state.players[0].active, ["sv1-ener-5"])
	trigger_fail_state.event_stream.push("preexisting", {"value": 2})
	var trigger_fail_before_snapshot := trigger_fail_state.snapshot()
	var trigger_fail_before_events := trigger_fail_state.event_stream._events.duplicate(true)
	var trigger_fail_rng := PortableRandomSource.new(20260662)
	var trigger_fail_before_rng := trigger_fail_rng.get_state()
	var original_trigger_runner := RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands
	var malformed_runner := MalformedAfterDamageTriggerCommands.new(engine.catalog)
	malformed_runner.vm_interpreter = RulesTestHarness.effect_engine_for(engine).runtime.vm_interpreter
	RulesTestHarness.attack_settlement_for(engine).set_trigger_command_runner(malformed_runner)
	var trigger_fail_step := _apply_test_action(engine,
		trigger_fail_state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		trigger_fail_rng,
	)
	RulesTestHarness.attack_settlement_for(engine).set_trigger_command_runner(original_trigger_runner)
	_check(
		not trigger_fail_step.success
		and trigger_fail_step.error_code == "invalid_trigger_payload",
		"Malformed after-damage trigger did not fail public attack settlement",
	)
	_check(
		trigger_fail_state.snapshot() == trigger_fail_before_snapshot,
		"Failed attack trigger settlement did not roll back applied damage and turn state",
	)
	_check(
		trigger_fail_state.event_stream._events == trigger_fail_before_events,
		"Failed attack trigger settlement did not restore event stream",
	)
	_check(
		trigger_fail_rng.get_state() == trigger_fail_before_rng,
		"Failed attack trigger settlement did not restore RNG state",
	)
	_check(
		trigger_fail_step.pending_choice == null and trigger_fail_step.events.is_empty(),
		"Failed attack trigger StepResult still exposes rolled-back pending/events",
	)

	var rollback_state := _battle_state()
	rollback_state.players[0].discard = ["sv1-ener-5"]
	rollback_state.players[0].deck = ["sv1-104", "svi-chim", "sv1-ener-5"]
	rollback_state.event_stream.push("preexisting", {"value": 1})
	var rollback_stack := ResolutionStack.new()
	rollback_stack.push_effect({"op": "__bad_after_choice__", "args": {}, "branches": {}}, 0, "active")
	rollback_stack.push_continuation("shuffle_from_discard", {"player_idx": 0})
	var rollback_option := {
		"option_id": "card:discard:0:sv1-ener-5",
		"label": "Fire Energy",
		"ref": EntityRef.new("card", 0, "discard", "", 0, "", "sv1-ener-5").to_dict(),
		"value": {"index": 0, "card_id": "sv1-ener-5"},
	}
	var rollback_request := ChoiceRequest.new(
		"choice:rollback",
		"shuffle_from_discard",
		0,
		"选择要洗回牌库的卡。",
		[rollback_option],
		1,
		1,
		false,
		false,
		{"revision": rollback_state.revision},
	)
	rollback_stack.pending_request = rollback_request
	rollback_state.resolution_stack = rollback_stack.to_dict()
	var rollback_before_state := rollback_state.snapshot()
	var rollback_before_events := rollback_state.event_stream._events.duplicate(true)
	var rollback_rng := PortableRandomSource.new(20260660)
	var rollback_before_rng := rollback_rng.get_state()
	var rollback_step := RulesTestHarness.apply_choice(engine,
		rollback_state,
		rollback_request,
		ChoiceResponse.new(rollback_request.request_id, [str(rollback_option["option_id"])]),
		rollback_rng,
	)
	_check(
		not rollback_step.success and rollback_step.error_code == "unsupported_vm_op",
		"Choice failure fixture did not hit unsupported VM op",
	)
	_check(
		rollback_state.snapshot() == rollback_before_state,
		"Failed choice did not restore state and resolution stack",
	)
	_check(
		rollback_rng.get_state() == rollback_before_rng,
		"Failed choice did not restore RNG state",
	)
	_check(
		rollback_state.event_stream._events == rollback_before_events,
		"Failed choice did not restore event stream",
	)
	_check(
		rollback_step.pending_choice == null and rollback_step.events.is_empty(),
		"Failed choice StepResult still exposes rolled-back pending/events",
	)

	# Transaction rollback must restore every schema-v2 field, not only the
	# legacy battle subset. These fields can all change while an effect/choice is
	# resolving and therefore belong to the same atomic checkpoint.
	var schema_restore_state := _battle_state()
	schema_restore_state.stadium_card_id = "sv1-188"
	schema_restore_state.stadium_owner_idx = 1
	schema_restore_state.result_status = GameState.RESULT_DRAW
	schema_restore_state.result_reason = "rollback-fixture"
	schema_restore_state.result_conditions = [["left"], ["right"]]
	schema_restore_state.rules_profile_id = "ROLLBACK_PROFILE"
	schema_restore_state.set_type_matchups_enabled(true)
	schema_restore_state.rules_options["fixture"] = true
	schema_restore_state.setup_stage = GameState.SETUP_BONUS_PLACEMENT
	schema_restore_state.setup_actor_idx = 1
	schema_restore_state.opening_coin_winner_idx = 1
	schema_restore_state.mulligan_bonus_max = 3
	schema_restore_state.setup_bonus_card_ids = [["svi-chim"], ["sv1-ener-5"]]
	schema_restore_state.turn_fact_book = {
		"current_turn": {"knockouts": [{"card_id": "svi-chim"}]},
		"previous_turn": {"knockouts": [{"card_id": "sv2-tatsu"}]},
	}
	var schema_restore_rng := PortableRandomSource.new(2026071610)
	var schema_restore_checkpoint := RulesTestHarness.transaction_manager_for(engine).capture_transaction(
		schema_restore_state, schema_restore_rng)
	var schema_restore_before := schema_restore_state.snapshot()
	schema_restore_state.stadium_owner_idx = 0
	schema_restore_state.clear_result()
	schema_restore_state.rules_profile_id = "MUTATED"
	schema_restore_state.set_type_matchups_enabled(false)
	schema_restore_state.rules_options.erase("fixture")
	schema_restore_state.setup_stage = GameState.SETUP_COMPLETE
	schema_restore_state.setup_actor_idx = -1
	schema_restore_state.opening_coin_winner_idx = 0
	schema_restore_state.mulligan_bonus_max = 0
	schema_restore_state.setup_bonus_card_ids = [[], []]
	schema_restore_state.turn_fact_book = {
		"current_turn": {"knockouts": []},
		"previous_turn": {"knockouts": []},
	}
	RulesTestHarness.transaction_manager_for(engine).rollback_transaction(
		schema_restore_state, schema_restore_rng, schema_restore_checkpoint)
	_check(
		schema_restore_state.snapshot() == schema_restore_before,
		"Schema-v2 transaction rollback left owner/result/rules/setup/turn facts mutated",
	)

	# A malformed mandatory Prize response is a failed transaction. It must not
	# consume the request revision or strand the player behind a stale choice.
	var retry_prize_state := _battle_state()
	retry_prize_state.players[0].prizes = ["sv1-ener-2", "sv1-ener-3"]
	retry_prize_state.players[1].active.damage_counters = 99
	retry_prize_state.players[1].bench[0] = PokemonState.new("svi-chim")
	var retry_prize_events: Array[Dictionary] = []
	var retry_prize_stack := ResolutionStack.new()
	var retry_prize_result := RulesTestHarness.knockout_settlement_for(engine).resolve_knockouts(
		retry_prize_state, 0, retry_prize_events, false, retry_prize_stack)
	var retry_prize_request: ChoiceRequest = retry_prize_result.get("pending_choice", null)
	var retry_prize_before := retry_prize_state.snapshot()
	var retry_prize_rng := PortableRandomSource.new(2026071611)
	var invalid_prize_step := RulesTestHarness.apply_choice(engine,
		retry_prize_state,
		retry_prize_request,
		ChoiceResponse.new(retry_prize_request.request_id, [], true),
		retry_prize_rng,
	)
	_check(
		not invalid_prize_step.success
		and invalid_prize_step.error_code == "choice_count"
		and retry_prize_state.snapshot() == retry_prize_before,
		"Invalid Prize choice changed state/revision instead of rolling back",
	)
	var retried_prize_step := RulesTestHarness.apply_choice(engine,
		retry_prize_state,
		retry_prize_request,
		ChoiceResponse.new(retry_prize_request.request_id, ["prize:0"]),
		retry_prize_rng,
	)
	_check(
		retried_prize_step.success
		and retry_prize_state.players[0].prizes == ["sv1-ener-3"]
		and "sv1-ener-2" in retry_prize_state.players[0].hand,
		"Valid Prize retry failed after an invalid response",
	)

	var choice_ko_state := _battle_state()
	choice_ko_state.players[1].bench[0] = PokemonState.new("svi-chim")
	choice_ko_state.event_stream.push("preexisting", {"value": 2})
	var choice_ko_stack := ResolutionStack.new()
	choice_ko_stack.push_continuation(
		"damage_target",
		{"target_player": 1, "amount": 999},
	)
	var choice_ko_card_id := choice_ko_state.players[1].active.card_id
	var choice_ko_option := {
		"option_id": "pokemon:1:active:%s" % choice_ko_card_id,
		"label": catalog.card_name(choice_ko_card_id),
		"ref": EntityRef.new("pokemon", 1, "", "active", -1, "", choice_ko_card_id).to_dict(),
		"value": {"slot": "active", "card_id": choice_ko_card_id},
	}
	var choice_ko_request := ChoiceRequest.new(
		"choice:ko-trigger-rollback",
		"damage_target",
		0,
		"选择1只对手宝可梦作为伤害目标。",
		[choice_ko_option],
		1,
		1,
		false,
		false,
		{"revision": choice_ko_state.revision},
	)
	choice_ko_stack.pending_request = choice_ko_request
	choice_ko_state.resolution_stack = choice_ko_stack.to_dict()
	var choice_ko_before_state := choice_ko_state.snapshot()
	var choice_ko_before_stack := choice_ko_state.resolution_stack.duplicate(true)
	var choice_ko_before_events := choice_ko_state.event_stream._events.duplicate(true)
	var choice_ko_rng := PortableRandomSource.new(20260661)
	var choice_ko_before_rng := choice_ko_rng.get_state()
	var original_ko_runner := RulesTestHarness.knockout_settlement_for(engine).trigger_command_runner
	RulesTestHarness.knockout_settlement_for(engine).trigger_command_runner = (
		MalformedPokemonKoTriggerCommands.new(engine.catalog)
	)
	RulesTestHarness.knockout_settlement_for(engine).trigger_command_runner.vm_interpreter = (
		RulesTestHarness.effect_engine_for(engine).runtime.vm_interpreter
	)
	var choice_ko_step := RulesTestHarness.apply_choice(engine,
		choice_ko_state,
		choice_ko_request,
		ChoiceResponse.new(choice_ko_request.request_id, [str(choice_ko_option["option_id"])]),
		choice_ko_rng,
	)
	RulesTestHarness.knockout_settlement_for(engine).trigger_command_runner = original_ko_runner
	_check(
		not choice_ko_step.success and choice_ko_step.error_code == "invalid_trigger_payload",
		"Post-choice KO trigger failure fixture did not hit invalid trigger payload",
	)
	_check(
		choice_ko_state.snapshot() == choice_ko_before_state,
		"Failed post-choice KO trigger did not restore state snapshot",
	)
	_check(
		choice_ko_state.resolution_stack == choice_ko_before_stack,
		"Failed post-choice KO trigger did not restore exact resolution stack",
	)
	_check(
		choice_ko_rng.get_state() == choice_ko_before_rng,
		"Failed post-choice KO trigger did not restore RNG state",
	)
	_check(
		choice_ko_state.event_stream._events == choice_ko_before_events,
		"Failed post-choice KO trigger did not restore event stream",
	)
	_check(
		choice_ko_step.pending_choice == null and choice_ko_step.events.is_empty(),
		"Failed post-choice KO trigger StepResult still exposes rolled-back pending/events",
	)

	var terminal_ko_state := _battle_state()
	terminal_ko_state.players[0].prizes = ["sv1-ener-2"]
	terminal_ko_state.players[1].bench[0] = PokemonState.new("svi-chim")
	terminal_ko_state.players[1].active.damage_counters = 99
	var terminal_ko_events: Array[Dictionary] = []
	var terminal_ko_result := RulesTestHarness.knockout_settlement_for(engine).resolve_knockouts(
		terminal_ko_state,
		0,
		terminal_ko_events,
		true,
	)
	var terminal_prize_request: ChoiceRequest = terminal_ko_result.get("pending_choice", null)
	_check(
		terminal_prize_request != null
		and terminal_prize_request.request_type == "select_prize",
		"Terminal KO did not pause for an explicit prize position",
	)
	if terminal_prize_request != null:
		var terminal_prize_step := RulesTestHarness.apply_choice(engine,
			terminal_ko_state,
			terminal_prize_request,
			ChoiceResponse.new(terminal_prize_request.request_id, ["prize:0"]),
			PortableRandomSource.new(2026071601),
		)
		terminal_ko_events.append_array(terminal_prize_step.events)
	var terminal_game_over_count := 0
	var terminal_game_over_index := -1
	var terminal_last_prize_index := -1
	for event_index in range(terminal_ko_events.size()):
		var terminal_event: Dictionary = terminal_ko_events[event_index]
		match str(terminal_event.get("event_type", "")):
			"prize_taken":
				terminal_last_prize_index = event_index
			"game_over":
				terminal_game_over_count += 1
				terminal_game_over_index = event_index
	_check(
		bool(terminal_ko_result.get("success", false))
		and terminal_ko_state.winner == 0
		and terminal_ko_state.phase == "GAME_OVER"
		and terminal_ko_state.pending_promotions.is_empty(),
		"Terminal KO batch retained a stale promotion after deciding the winner",
	)
	_check(
		terminal_last_prize_index >= 0
		and terminal_game_over_count == 1
		and terminal_game_over_index > terminal_last_prize_index
		and terminal_game_over_index == terminal_ko_events.size() - 1
		and int(terminal_ko_events[terminal_game_over_index].get(
			"data", {}).get("winner", -1)) == 0,
		"Terminal KO batch did not append one game_over after every prize event",
	)

	# Treasure Energy stays at its selected Prize position while its optional
	# attachment choice is pending. Declining moves it to hand; accepting moves
	# it directly to the chosen Pokemon after a snapshot roundtrip.
	var treasure_decline_state := _battle_state()
	treasure_decline_state.players[0].prizes = ["svi-trea", "sv1-ener-2"]
	treasure_decline_state.players[1].active.damage_counters = 99
	treasure_decline_state.players[1].bench[0] = PokemonState.new("svi-chim")
	var treasure_decline_events: Array[Dictionary] = []
	var treasure_decline_stack := ResolutionStack.new()
	var treasure_decline_ko := RulesTestHarness.knockout_settlement_for(engine).resolve_knockouts(
		treasure_decline_state, 0, treasure_decline_events, false, treasure_decline_stack)
	var treasure_decline_prize: ChoiceRequest = treasure_decline_ko.get(
		"pending_choice", null)
	var treasure_decline_prompt := RulesTestHarness.apply_choice(engine,
		treasure_decline_state,
		treasure_decline_prize,
		ChoiceResponse.new(treasure_decline_prize.request_id, ["prize:0"]),
		PortableRandomSource.new(2026071612),
	)
	var treasure_decline_request := treasure_decline_prompt.pending_choice
	_check(
		treasure_decline_prompt.success
		and treasure_decline_request != null
		and str(treasure_decline_request.metadata.get("purpose", ""))
		== "trigger_confirm"
		and treasure_decline_request.options.size() == 1
		and not treasure_decline_request.options[0].has("ref")
		and not treasure_decline_request.options[0].has("value")
		and treasure_decline_state.players[0].prizes
		== ["svi-trea", "sv1-ener-2"]
		and "svi-trea" not in treasure_decline_state.players[0].hand
		and _first_event_type_index(treasure_decline_prompt.events, "prize_taken") < 0,
		"Treasure Energy left the Prize zone before its trigger choice resolved",
	)
	var treasure_declined := RulesTestHarness.apply_choice(engine,
		treasure_decline_state,
		treasure_decline_request,
		ChoiceResponse.new(treasure_decline_request.request_id, [], true),
		PortableRandomSource.new(2026071613),
	)
	_check(
		treasure_declined.success
		and treasure_decline_state.players[0].prizes == ["sv1-ener-2"]
		and "svi-trea" in treasure_decline_state.players[0].hand
		and _first_event_type_index(treasure_declined.events, "prize_taken") >= 0
		and _first_event_type_index(treasure_declined.events, "energy_attached") < 0,
		"Declined Treasure Energy did not move exactly once from Prize to hand",
	)

	var treasure_attach_state := _battle_state()
	treasure_attach_state.players[0].bench[0] = PokemonState.new("svi-chim")
	treasure_attach_state.players[0].prizes = ["svi-trea", "sv1-ener-3"]
	treasure_attach_state.players[1].active.damage_counters = 99
	treasure_attach_state.players[1].bench[0] = PokemonState.new("svi-chim")
	var treasure_attach_events: Array[Dictionary] = []
	var treasure_attach_stack := ResolutionStack.new()
	var treasure_attach_ko := RulesTestHarness.knockout_settlement_for(engine).resolve_knockouts(
		treasure_attach_state, 0, treasure_attach_events, false, treasure_attach_stack)
	var treasure_attach_prize: ChoiceRequest = treasure_attach_ko.get(
		"pending_choice", null)
	var treasure_attach_prompt := RulesTestHarness.apply_choice(engine,
		treasure_attach_state,
		treasure_attach_prize,
		ChoiceResponse.new(treasure_attach_prize.request_id, ["prize:0"]),
		PortableRandomSource.new(2026071614),
	)
	var treasure_attach_request := treasure_attach_prompt.pending_choice
	var treasure_pause_snapshot := treasure_attach_state.snapshot()
	var treasure_restored_state := GameState.from_snapshot(treasure_pause_snapshot)
	var treasure_roundtrip_ok := (
		treasure_restored_state != null
		and treasure_restored_state.snapshot() == treasure_pause_snapshot
	)
	var treasure_confirmed := RulesTestHarness.apply_choice(engine,
		treasure_restored_state,
		treasure_attach_request,
		ChoiceResponse.new(treasure_attach_request.request_id, [
			str(treasure_attach_request.options[0].get("option_id", "")),
		]),
		PortableRandomSource.new(2026071615),
	)
	var treasure_target_request := treasure_confirmed.pending_choice
	var treasure_target_snapshot := treasure_restored_state.snapshot()
	var treasure_target_state := GameState.from_snapshot(treasure_target_snapshot)
	var treasure_target_roundtrip_ok := (
		treasure_target_state != null
		and treasure_target_state.snapshot() == treasure_target_snapshot
	)
	var treasure_bench_option := _choice_id_for_slot(
		treasure_target_request, "bench_0")
	var treasure_attached := RulesTestHarness.apply_choice(engine,
		treasure_target_state,
		treasure_target_request,
		ChoiceResponse.new(treasure_target_request.request_id, [treasure_bench_option]),
		PortableRandomSource.new(2026071616),
	)
	var treasure_prize_event_index := _first_event_type_index(
		treasure_attached.events, "prize_taken")
	var treasure_attach_event_index := _first_event_type_index(
		treasure_attached.events, "energy_attached")
	_check(
		treasure_roundtrip_ok
		and treasure_confirmed.success
		and treasure_target_request != null
		and treasure_target_request.request_type == "select_energy_target"
		and treasure_target_request.options.size() >= 1
		and treasure_target_request.options[0].get("ref") is Dictionary
		and not treasure_target_request.options[0].has("value")
		and treasure_target_roundtrip_ok
		and treasure_attached.success
		and treasure_target_state.players[0].prizes == ["sv1-ener-3"]
		and "svi-trea" not in treasure_target_state.players[0].hand
		and treasure_target_state.players[0].bench[0].energy_card_ids
		== ["svi-trea"]
		and treasure_prize_event_index >= 0
		and treasure_attach_event_index > treasure_prize_event_index,
		"Treasure Energy pause snapshot or Prize-to-attachment event order was invalid",
	)

	# Checkup KO settlement can pause on a prize position. Its choice-resume path
	# must evaluate the last prize before it advances into the incoming turn.
	var checkup_terminal_state := _battle_state()
	checkup_terminal_state.turn_number = 3
	checkup_terminal_state.first_player_idx = 0
	checkup_terminal_state.active_player_idx = 0
	checkup_terminal_state.players[0].prizes = ["sv1-ener-2"]
	checkup_terminal_state.players[1].active.damage_counters = 99
	checkup_terminal_state.players[1].active.status_conditions = ["POISONED"]
	checkup_terminal_state.players[1].bench[0] = PokemonState.new("svi-chim")
	var checkup_terminal_step := _apply_test_action(engine,
		checkup_terminal_state,
		GameAction.new("END_TURN", {}, true, 0),
		PortableRandomSource.new(2026071606),
	)
	var checkup_prize_request := checkup_terminal_step.pending_choice
	_check(
		checkup_terminal_step.success
		and checkup_prize_request != null
		and checkup_prize_request.request_type == "select_prize",
		"Checkup KO did not pause for its terminal prize choice",
	)
	var checkup_terminal_events: Array[Dictionary] = (
		checkup_terminal_step.events.duplicate(true)
	)
	if checkup_prize_request != null:
		checkup_terminal_step = RulesTestHarness.apply_choice(engine,
			checkup_terminal_state,
			checkup_prize_request,
			ChoiceResponse.new(checkup_prize_request.request_id, ["prize:0"]),
			PortableRandomSource.new(2026071607),
		)
		checkup_terminal_events.append_array(checkup_terminal_step.events)
	var checkup_terminal_types: Array[String] = []
	for event in checkup_terminal_events:
		checkup_terminal_types.append(str(event.get("event_type", "")))
	var checkup_prize_index := checkup_terminal_types.rfind("prize_taken")
	var checkup_game_over_index := checkup_terminal_types.rfind("game_over")
	_check(
		checkup_terminal_step.success
		and checkup_terminal_step.terminal
		and checkup_terminal_state.result_status == GameState.RESULT_WIN
		and checkup_terminal_state.winner == 0
		and checkup_terminal_state.pending_promotions.is_empty()
		and checkup_prize_index >= 0
		and checkup_game_over_index > checkup_prize_index
		and checkup_terminal_types.count("game_over") == 1
		and "promoted" not in checkup_terminal_types
		and "turn_start" not in checkup_terminal_types
		and "cards_drawn" not in checkup_terminal_types,
		"Terminal checkup prize resumed into promotion/turn draw instead of game_over",
	)

	var self_discard_state := _battle_state()
	self_discard_state.turn_number = 3
	self_discard_state.first_player_idx = 0
	self_discard_state.players[0].active = PokemonState.new("sv2-starm")
	self_discard_state.players[0].active.placed_this_turn = false
	self_discard_state.players[0].bench[0] = PokemonState.new("svi-chim")
	self_discard_state.players[0].bench[0].placed_this_turn = false
	self_discard_state.players[0].hand.clear()
	self_discard_state.players[1].prizes = ["sv1-ener-2"]
	var self_discard_opponent_hand_before := self_discard_state.players[1].hand.duplicate()
	var ability_name := str(
		catalog.get_card("sv2-starm").get("abilities", [])[0].get("name", ""))
	var self_discard_step := _apply_test_action(engine,
		self_discard_state,
		GameAction.new(
			"USE_ABILITY",
			{"slot": "active", "ability_name": ability_name},
			false,
			0,
			EntityRef.new("pokemon", 0, "", "active", -1, "", "sv2-starm"),
		),
		PortableRandomSource.new(18),
	)
	_check(self_discard_step.pending_choice != null,
		"Self-discard ability did not request target")
	if self_discard_step.pending_choice:
		var self_discard_request := self_discard_step.pending_choice
		_check(
			int(self_discard_request.metadata.get("amount", 0)) == 20
			and int(self_discard_request.metadata.get("source_player", -1)) == 0
			and str(self_discard_request.metadata.get("source_slot", "")) == "active"
			and str(self_discard_request.metadata.get("source_card_id", "")) == "sv2-starm"
			and int(self_discard_request.metadata.get("target_player", -1)) == 1,
			"Self-discard damage choice omitted its public amount/source metadata",
		)
		var self_discard_result := RulesTestHarness.apply_choice(engine,
			self_discard_state,
			self_discard_request,
			ChoiceResponse.new(
				self_discard_request.request_id,
				[self_discard_request.options[0]["option_id"]],
			),
			PortableRandomSource.new(19),
		)
		_check(self_discard_result.success, "Self-discard ability choice failed")
		_check(self_discard_state.players[0].active == null,
			"Self-discard source remained in the active slot")
		_check("sv2-starm" in self_discard_state.players[0].discard,
			"Self-discard source was not discarded")
		_check(
			self_discard_state.players[1].prizes == ["sv1-ener-2"]
			and self_discard_state.players[1].hand == self_discard_opponent_hand_before,
			"Opponent took a prize for Starmie's effect discard")
		var self_discard_saw_prize_event := false
		var self_discard_saw_ko_event := false
		for event in self_discard_result.events:
			if str(event.get("event_type", "")) == "prize_taken":
				self_discard_saw_prize_event = true
			if str(event.get("event_type", "")) == "pokemon_ko":
				self_discard_saw_ko_event = true
		_check(not self_discard_saw_prize_event,
			"Starmie's effect discard emitted a prize_taken event")
		_check(not self_discard_saw_ko_event,
			"Starmie's effect discard emitted a pokemon_ko event")
		_check(0 in self_discard_state.pending_promotions,
			"Self-discard did not enqueue promotion")

	var setup_state := GameState.new()
	var deck_keys: Array = catalog.decks.keys()
	var deck_one := catalog.expand_deck(str(deck_keys[0]))
	var deck_two := catalog.expand_deck(str(deck_keys[1]))
	var setup_result := engine.setup_game(
		setup_state, deck_one, deck_two, PortableRandomSource.new(20260620))
	_check(setup_result.success, "Game setup failed: %s" % setup_result.message)
	_check(
		setup_result.pending_choice != null
		and setup_result.pending_choice.request_type == "choose_turn_order",
		"Setup did not ask the coin winner to choose turn order before drawing",
	)
	if setup_result.pending_choice != null:
		var turn_order_request := setup_result.pending_choice
		setup_result = RulesTestHarness.apply_choice(engine,
			setup_state,
			turn_order_request,
			ChoiceResponse.new(turn_order_request.request_id, ["turn:first"]),
			PortableRandomSource.new(20260620),
		)
		_check(setup_result.success, "Turn-order setup choice failed: %s" % setup_result.message)
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


func _check_card_rules_matrix(release_cards: Dictionary) -> void:
	var matrix := _read_json("res://tests/fixtures/card_rules_matrix.json")
	var matrix_cards: Dictionary = matrix.get("cards", {})
	var release_ids := release_cards.keys()
	var matrix_ids := matrix_cards.keys()
	release_ids.sort()
	matrix_ids.sort()
	_check(
		int(matrix.get("format_version", 0)) == 1
		and int(matrix.get("vm_ir_version", 0)) == VMContract.IR_VERSION
		and int(matrix.get("expected_card_count", 0)) == 137
		and int(matrix.get("card_count", 0)) == 137
		and matrix_cards.size() == 137
		and Array(matrix.get("errors", [])).is_empty()
		and _deep_equal(matrix_ids, release_ids),
		"137-card rules matrix header, VM version, errors, or card IDs differ",
	)

	var native_ops: Array = VMContract.native_command_ops()
	var python_ops: Array = Array(matrix.get("python_supported_ops", [])).duplicate()
	var peer_ops: Array = Array(matrix.get("peer_supported_ops", [])).duplicate()
	native_ops.sort()
	python_ops.sort()
	peer_ops.sort()
	_check(
		native_ops.size() == 80
		and python_ops.size() == 80
		and peer_ops.size() == 80
		and _deep_equal(python_ops, native_ops)
		and _deep_equal(peer_ops, native_ops),
		"Python/peer 80-op inventories must exactly match Godot VMContract",
	)

	for card_id_value in matrix_ids:
		var card_id := str(card_id_value)
		var matrix_card: Dictionary = matrix_cards[card_id]
		var segments: Array = Array(matrix_card.get("segments", []))
		_check(
			int(matrix_card.get("segment_count", -1)) == segments.size(),
			"Rules matrix segment count differs for %s" % card_id,
		)
		for segment_index in range(segments.size()):
			var segment: Dictionary = Dictionary(segments[segment_index])
			var source := "%s[%d]:%s" % [
				card_id, segment_index, str(segment.get("name", ""))]
			var bindings: Array = Array(segment.get("bindings", []))
			_check(
				not str(segment.get("text", "")).strip_edges().is_empty()
				and not bindings.is_empty()
				and not str(segment.get("public_action", "")).strip_edges().is_empty()
				and segment.has("hooks") and segment["hooks"] is Array
				and segment.has("choice_constraints")
				and segment["choice_constraints"] is Array,
				"Non-empty card text lacks binding/action/hook/choice metadata at %s" % source,
			)
			for binding_value in bindings:
				var binding: Dictionary = Dictionary(binding_value)
				if str(binding.get("kind", "")) != "vm":
					continue
				var ops: Array = Array(binding.get("ops", []))
				_check(not ops.is_empty(), "VM binding has no executable ops at %s" % source)
				for op_value in ops:
					var op := str(op_value)
					_check(
						op in native_ops,
						"Rules matrix VM op is not executable at %s: %s" % [source, op],
					)
		for used_op_value in Array(matrix_card.get("used_vm_ops", [])):
			var used_op := str(used_op_value)
			_check(
				used_op in native_ops,
				"Rules matrix card %s references unsupported VM op %s" % [card_id, used_op],
			)


func _check_release_compiled_command_specs(catalog: CardCatalog, engine: GameEngine) -> void:
	for card_id in catalog.cards:
		var card := catalog.get_card(str(card_id))
		_check_compiled_specs(
			engine,
			_variant_array(card.get("compiled_trainer_effects", [])),
			"trainer:%s" % str(card_id),
		)
		var abilities := _variant_array(card.get("abilities", []))
		for ability_index in range(abilities.size()):
			var ability: Dictionary = abilities[ability_index]
			_check_compiled_specs(
				engine,
				_variant_array(ability.get("compiled_effects", [])),
				"ability:%s[%d]" % [str(card_id), ability_index],
			)
		var attacks := _variant_array(card.get("attacks", []))
		for attack_index in range(attacks.size()):
			var attack: Dictionary = attacks[attack_index]
			_check_compiled_specs(
				engine,
				_variant_array(attack.get("compiled_effects", [])),
				"attack:%s[%d]" % [str(card_id), attack_index],
			)


func _check_compiled_specs(engine: GameEngine, specs: Array, source: String) -> void:
	for spec_index in range(specs.size()):
		var spec: Dictionary = specs[spec_index]
		_check(
			str(spec.get("op", "")) != "__missing_compiled_effect__",
			"%s[%d] still has missing compiled effect marker" % [source, spec_index],
		)
		_check(
			not Dictionary(spec.get("args", {})).has("effect_type"),
			"%s[%d] still carries legacy effect_type args" % [source, spec_index],
		)
		_check(
			RulesTestHarness.effect_engine_for(engine).supports_command_spec(spec),
			"%s[%d] compiled VM command is unsupported: %s" % [
				source,
				spec_index,
				str(spec.get("op", "")),
			],
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
	# Flow barriers intentionally finish on a later frame, even when spatial
	# motion is disabled. Keep this broad UI contract deterministic and fast
	# while still exercising that asynchronous completion boundary.
	var settings_node := root.get_node_or_null("AppSettings")
	var previous_animation_mode := "cinematic"
	var previous_reduced_motion := false
	if settings_node:
		previous_animation_mode = str(settings_node.get("animation_mode"))
		previous_reduced_motion = bool(settings_node.get("reduced_motion"))
		settings_node.set("animation_mode", "reduced")
		settings_node.set("reduced_motion", true)
	var ui := packed.instantiate()
	root.add_child(ui)
	ui.initialize_ui()
	_check(ui.current_screen == "title", "UI did not open on title screen")
	var title_full_bleed_backdrop := ui.find_child(
		"TitleFullBleedBackdrop", true, false
	) as Control
	var embedded_backdrop := ui.find_child("EmbeddedBackdrop", true, false) as Control
	_check(
		title_full_bleed_backdrop != null
		and title_full_bleed_backdrop.visible
		and embedded_backdrop != null
		and not embedded_backdrop.visible,
		"Main title route did not use the full-bleed backdrop exclusively",
	)
	for button_name in [
		"LocalTwoPlayerButton", "AIButton", "NetworkButton",
		"SettingsButton", "HelpButton",
	]:
		var title_button := ui.find_child(button_name, true, false) as Button
		_check(title_button != null, "Title entry is missing: %s" % button_name)
		if title_button:
			_check(
				title_button.custom_minimum_size.y >= 48,
				"Title touch target is below 48 px: %s" % button_name,
			)
	for legacy_name in [
		"ChallengeAIButton", "DeepAIButton", "LANButton", "RelayButton", "OnlineCard",
	]:
		_check(
			ui.find_child(legacy_name, true, false) == null,
			"Legacy title entry is still present: %s" % legacy_name,
		)
	ui.show_deck_select()
	_check(ui.current_screen == "decks", "Deck selection screen did not open")
	_check(
		title_full_bleed_backdrop != null and not title_full_bleed_backdrop.visible,
		"Full-bleed title backdrop remained visible outside the title route",
	)
	var deck_page := ui.screen_host.get_child(0) as DeckSelectPage
	_check(deck_page != null, "Deck selection page is missing")
	if deck_page:
		_check(deck_page.deck_count() == 10, "Deck gallery must contain 10 decks")
		_check(
			not deck_page.selected_deck_key(0).is_empty()
			and not deck_page.selected_deck_key(1).is_empty(),
			"Deck selection defaults must initialize both player slots",
		)
	var started: bool = ui.start_local_match_for_test("fire", "water")
	_check(started, "UI could not start a local match")
	_check(ui.current_screen == "game", "Game screen did not open")
	_check(ui.state != null and ui.state.phase == "SETUP", "Local match is not in setup phase")
	_check(ui.modal_layer.visible, "Hot-seat privacy overlay is missing")
	_check(ui.find_child("BoardPanel", true, false) != null, "Board panel is missing")
	_check(ui.find_child("HandScroll", true, false) != null, "Hand area is missing")
	ui.modal_confirm.pressed.emit()
	_check(
		ui.active_request != null
		and ui.active_request.request_type == "choose_turn_order",
		"Opening privacy handoff did not reveal the turn-order choice to its owner",
	)
	if ui.active_request != null:
		var turn_order_id := (
			"turn:first" if ui.active_request.player == 0 else "turn:second"
		)
		ui.selected_choice_ids.assign([turn_order_id])
		ui._confirm_choice()
		await _wait_for_battle_transition(ui, "opening turn-order choice")
	_check(
		ui.state.first_player_idx == 0
		and ui.state.setup_stage == GameState.SETUP_INITIAL_PLACEMENT
		and ui.state.setup_actor_idx == 0,
		"Turn-order choice did not advance local UI into first-player placement",
	)
	ui.current_view_player = 0
	ui._refresh_game()
	_check(
		ui.battle_screen != null
		and ui.battle_screen.phase_advance_button != null
		and ui.battle_screen.find_child("AllActionsButton", true, false) == null
		and ui.battle_screen.find_child("ActionPanel", true, false) == null,
		"Battle sidebar did not keep only the system action entry",
	)
	_check(
		ui.battle_screen.table.interaction_router.all_card_actions_reachable(),
		"Setup card actions were not reachable from their hand cards",
	)
	var setup_actions: Array[GameAction] = RulesTestHarness.legal_actions(ui.engine, ui.state, 0, false)
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
		var setup_hand_index := int(active_action.params.get("hand_idx", -1))
		var setup_card_id := str(ui.state.players[0].hand[setup_hand_index])
		var setup_hand_view := ui.battle_screen.hand_views[setup_hand_index] as CardView
		var board_size_before_preview: Vector2 = ui.battle_screen.board_canvas.size
		setup_hand_view.activated.emit(setup_card_id, setup_hand_index, 0, "")
		var setup_detail := ui.battle_screen.detail_panel as BattleDetailPanel
		_check(
			ui.selected_entity_key == "hand:%d" % setup_hand_index
			and setup_hand_view.selected
			and setup_detail != null
			and setup_detail.is_showing_card()
			and setup_detail.current_card_id == setup_card_id
			and setup_detail.detail_image.texture != null
			and setup_detail.detail_title.text == ui.catalog.card_name(setup_card_id)
			and not setup_detail.detail_text.text.is_empty()
			and ui.battle_screen.board_canvas.size == board_size_before_preview,
			"Tapping a card did not enter card-source target selection",
		)
		setup_detail.close_button.pressed.emit()
		_check(
			ui.selected_entity_key.is_empty()
			and not setup_hand_view.selected
			and not ui.battle_screen.table.action_popover.visible
			and not setup_detail.visible,
			"Closing card detail did not clear Main's authoritative selection",
		)
		setup_hand_view.activated.emit(setup_card_id, setup_hand_index, 0, "")
		_check(
			ui.selected_entity_key == "hand:%d" % setup_hand_index
			and setup_hand_view.selected
			and setup_detail.is_showing_card(),
			"Re-selecting a card after closing detail did not restore interaction",
		)
		setup_hand_view.activated.emit(setup_card_id, setup_hand_index, 0, "")
		_check(
			ui.selected_entity_key.is_empty()
			and not setup_hand_view.selected
			and not ui.battle_screen.table.action_popover.visible
			and not setup_detail.visible,
			"Tapping the selected source card again did not close card interaction",
		)
		setup_hand_view.activated.emit(setup_card_id, setup_hand_index, 0, "")
		_check(setup_detail.visible,
			"Re-selecting a hand card did not restore its floating preview")
		ui._execute_action(active_action)
		_check(
			ui.state.players[0].active != null
			and ui.selected_entity_key.is_empty()
			and not setup_detail.visible,
			"UI action did not mutate rules state or clear the floating preview",
		)
		await _wait_for_battle_transition(ui, "setup placement")
		_check(
			ui.battle_screen.table.all_card_actions_reachable_from_visible_cards(),
			"Card interaction index did not refresh after a setup action",
		)
		var unavailable_hand_view: CardView
		for candidate_view_value in ui.battle_screen.hand_views:
			var candidate_view := candidate_view_value as CardView
			if candidate_view == null or not candidate_view.visible:
				continue
			var candidate_key := "hand:%d" % candidate_view.hand_index
			if ui.battle_screen.table.interaction_router.rows_for_source(
				candidate_key
			).is_empty():
				unavailable_hand_view = candidate_view
				break
		_check(
			unavailable_hand_view != null,
			"Setup fixture did not expose a non-actionable hand card",
		)
		if unavailable_hand_view:
			var unavailable_card_id := unavailable_hand_view.card_id
			var unavailable_key := "hand:%d" % unavailable_hand_view.hand_index
			unavailable_hand_view.activated.emit(
				unavailable_card_id,
				unavailable_hand_view.hand_index,
				0,
				"",
			)
			_check(
				ui.selected_entity_key == unavailable_key
				and unavailable_hand_view.selected
				and setup_detail.is_showing_card()
				and ui.battle_screen.table.action_popover.visible
				and ui.battle_screen.table.action_popover.is_informational_only(),
				"A non-actionable card did not enter inspectable selected state",
			)
			unavailable_hand_view.activated.emit(
				unavailable_card_id,
				unavailable_hand_view.hand_index,
				0,
				"",
			)
			_check(
				ui.selected_entity_key.is_empty()
				and not unavailable_hand_view.selected
				and not setup_detail.visible
				and not ui.battle_screen.table.action_popover.visible,
				"Tapping a selected non-actionable card did not clear all interaction",
			)
		var active_view: CardView = ui.battle_screen.table.get_slot_view(0, "active")
		if active_view and ui.state.players[0].active:
			var active_card_id := str(ui.state.players[0].active.card_id)
			active_view.activated.emit(active_card_id, -1, 0, "active")
			_check(
				ui.selected_entity_key == "pokemon:0:active"
				and setup_detail.is_showing_card()
				and setup_detail.current_card_id == active_card_id
				and setup_detail.detail_text.text.contains("特殊状态"),
				"Tapping a field Pokémon did not show its live-state preview",
			)
			active_view.activated.emit(active_card_id, -1, 0, "active")
			_check(not setup_detail.visible,
				"Tapping the selected field Pokémon again did not hide its preview")
	await _run_local_ui_playout(ui)
	await _wait_for_battle_transition(ui, "local playout terminal transition")
	_check(ui.current_screen == "end", "Completed local UI match did not show end screen")
	var title_button := ui.find_child("TitleButton", true, false) as Button
	_check(title_button != null, "Victory screen title return button is missing")
	if title_button:
		title_button.pressed.emit()
		_check(
			ui.current_screen == "title",
			"Victory screen did not return to the title page",
		)
		var restored_embedded_backdrop := ui.find_child(
			"EmbeddedBackdrop", true, false
		) as Control
		_check(
			title_full_bleed_backdrop != null
			and title_full_bleed_backdrop.visible
			and restored_embedded_backdrop != null
			and not restored_embedded_backdrop.visible,
			"Returning to the title route did not restore exclusive full-bleed backdrop use",
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
	var trainer := GameAction.create(
		"PLAY_TRAINER",
		{},
		0,
		EntityRef.new("card", 0, "hand", "", 0, "", "sv1-151"),
		null,
		"choice-overlay-trainer",
		choice_state.revision,
	)
	choice_ui._execute_action(trainer)
	await _wait_for_battle_transition(choice_ui, "trainer choice publication")
	_check(choice_ui.modal_layer.visible, "Choice overlay was not displayed")
	_check(choice_ui.active_request != null, "Choice overlay has no request")
	var choice_panel := choice_ui.active_choice_panel as ChoicePanel
	_check(choice_panel != null, "Choice overlay has no ChoicePanel")
	if choice_panel:
		_check(choice_panel.card_option_count() > 0, "Choice overlay has no card tiles")
		_check(
			choice_panel.is_preview_visible()
			and not choice_panel.previewed_card_id().is_empty()
			and choice_panel.preview_text.text.contains("HP"),
			"Card choice overlay did not show an automatic card preview",
		)
		_check(
			choice_ui.modal_panel.custom_minimum_size.x >= 560.0
			and choice_ui.modal_panel.custom_minimum_size.y >= 480.0
			and choice_ui._safe_content_size().x
			>= choice_ui.modal_panel.custom_minimum_size.x
			and choice_ui._safe_content_size().y
			>= choice_ui.modal_panel.custom_minimum_size.y
			and choice_panel.preview_panel.visible,
			"Card choice overlay did not fit a visible preview inside the safe modal area",
		)
		_check(
			choice_panel.text_option_count() == 0 and choice_ui.option_buttons.is_empty(),
			"Card choice overlay duplicated card options as text buttons",
		)
	choice_ui.active_choice_panel = null
	choice_ui.active_request = ChoiceRequest.new(
		"single-choice-switch",
		"search",
		0,
		"选择一张卡牌。",
		[
			{"option_id": "card:first", "label": "第一张", "value": {}},
			{"option_id": "card:second", "label": "第二张", "value": {}},
		],
		1,
		1,
	)
	choice_ui.selected_choice_ids.assign(["card:first"])
	choice_ui._toggle_choice("card:second")
	_check(
		choice_ui.selected_choice_ids.size() == 1
		and choice_ui.selected_choice_ids[0] == "card:second"
		and choice_ui.modal_confirm.text.contains("1/1"),
		"Single-choice panel did not replace the previous selection",
	)
	choice_ui._toggle_choice("card:second")
	_check(
		choice_ui.selected_choice_ids.is_empty()
		and choice_ui.modal_confirm.disabled,
		"Single-choice panel could not clear the current selection",
	)
	choice_ui.active_request = ChoiceRequest.new(
		"multi-choice-limit",
		"search",
		0,
		"选择两张卡牌。",
		[
			{"option_id": "card:first", "label": "第一张", "value": {}},
			{"option_id": "card:second", "label": "第二张", "value": {}},
			{"option_id": "card:third", "label": "第三张", "value": {}},
		],
		0,
		2,
	)
	choice_ui.selected_choice_ids.assign(["card:first", "card:second"])
	choice_ui._toggle_choice("card:third")
	_check(
		choice_ui.selected_choice_ids == ["card:first", "card:second"],
		"Full multi-choice panel unexpectedly replaced an existing selection",
	)
	choice_ui.queue_free()

	var choice_ux_ui := packed.instantiate()
	root.add_child(choice_ux_ui)
	choice_ux_ui.initialize_ui()
	choice_ux_ui.state = _battle_state()
	choice_ux_ui.current_view_player = 0
	var multi_ux_request := ChoiceView.new(
		"choice:ux:multi",
		choice_ux_ui.state.revision,
		"search",
		0,
		"从牌库中选择一至两张卡牌加入手牌；达到上限后可先取消一张。",
		[
			{
				"option_id": "ux:multi:first",
				"label": "墓仔狗",
				"ref": EntityRef.new(
					"card", 0, "deck", "", 0, "", "sv1-104"
				).to_dict(),
			},
			{
				"option_id": "ux:multi:second",
				"label": "巢穴球",
				"ref": EntityRef.new(
					"card", 0, "deck", "", 1, "", "sv1-151"
				).to_dict(),
			},
			{
				"option_id": "ux:multi:third",
				"label": "伤药",
				"ref": EntityRef.new(
					"card", 0, "deck", "", 2, "", "svf-potion"
				).to_dict(),
			},
		],
		1,
		2,
	)
	choice_ux_ui.show_choice(multi_ux_request)
	var multi_ux_panel := choice_ux_ui.active_choice_panel as ChoicePanel
	_check(multi_ux_panel != null, "Multi-choice UX panel was not created")
	if multi_ux_panel:
		_check(
			multi_ux_panel.prompt_label.visible
			and multi_ux_panel.prompt_label.text == multi_ux_request.prompt
			and multi_ux_panel.prompt_label.autowrap_mode
			!= TextServer.AUTOWRAP_OFF,
			"ChoicePanel did not preserve and wrap the complete choice prompt",
		)
		_check(
			multi_ux_panel.metadata_label.text.contains("1")
			and multi_ux_panel.metadata_label.text.contains("2")
			and multi_ux_panel.metadata_label.text.contains("张")
			and not multi_ux_panel.metadata_label.text.contains("项"),
			"Card multi-choice metadata did not use a natural card quantity",
		)
		_check(
			choice_ux_ui.modal_confirm.disabled,
			"Multi-choice confirmation was enabled below min_select",
		)
		choice_ux_ui._toggle_choice("ux:multi:first")
		_check(
			not choice_ux_ui.modal_confirm.disabled
			and choice_ux_ui.selected_choice_ids == ["ux:multi:first"],
			"Multi-choice confirmation did not enable at min_select",
		)
		choice_ux_ui._toggle_choice("ux:multi:second")
		var third_reason := str(
			multi_ux_panel._option_disabled_reasons.get("ux:multi:third", "")
		)
		var third_tile := multi_ux_panel._option_tiles.get(
			"ux:multi:third"
		) as PanelContainer
		_check(
			third_reason.contains("已达到选择上限")
			and third_tile != null
			and bool(third_tile.get_meta("choice_blocked", false))
			and str(third_tile.get_meta(
				"choice_disabled_reason", ""
			)).contains("已达到选择上限")
			and third_tile.tooltip_text.contains("已达到选择上限"),
			"Unselected card did not explain that the multi-choice limit was reached",
		)
		choice_ux_ui._toggle_choice("ux:multi:third")
		_check(
			choice_ux_ui.selected_choice_ids == [
				"ux:multi:first", "ux:multi:second",
			]
			and multi_ux_panel.blocked_reason_label.visible
			and multi_ux_panel.blocked_reason_label.text.contains("已达到选择上限"),
			"Clicking a choice blocked by max_select did not preserve state and explain why",
		)
		choice_ux_ui._toggle_choice("ux:multi:first")
		_check(
			choice_ux_ui.selected_choice_ids == ["ux:multi:second"]
			and str(multi_ux_panel._option_disabled_reasons.get(
				"ux:multi:third", ""
			)).is_empty()
			and not bool(third_tile.get_meta("choice_blocked", false))
			and str(third_tile.get_meta(
				"choice_disabled_reason", ""
			)).is_empty(),
			"Deselecting a multi-choice card did not release capacity",
		)
		choice_ux_ui._toggle_choice("ux:multi:third")
		_check(
			choice_ux_ui.selected_choice_ids == [
				"ux:multi:second", "ux:multi:third",
			],
			"A newly released multi-choice slot could not be selected",
		)
	choice_ux_ui._close_modal()
	choice_ux_ui._finish_modal_close(choice_ux_ui._modal_generation)

	var text_ux_request := ChoiceRequest.new(
		"choice:ux:text",
		"confirm",
		0,
		"要将查看到的卡牌加入手牌吗？",
		[
			{"option_id": "confirm:yes", "label": "是，加入手牌", "value": true},
			{"option_id": "confirm:no", "label": "否，放入弃牌", "value": false},
		],
		1,
		1,
	)
	choice_ux_ui.show_choice(text_ux_request)
	var text_ux_panel := choice_ux_ui.active_choice_panel as ChoicePanel
	_check(text_ux_panel != null, "Text choice UX panel was not created")
	if text_ux_panel:
		var yes_button := text_ux_panel._option_buttons.get("confirm:yes") as Button
		var no_button := text_ux_panel._option_buttons.get("confirm:no") as Button
		_check(
			text_ux_panel.prompt_label.text == text_ux_request.prompt
			and text_ux_panel.metadata_label.text.contains("1")
			and text_ux_panel.metadata_label.text.contains("项")
			and not text_ux_panel.metadata_label.text.contains("1–1"),
			"Text choice did not use its full prompt and natural item quantity",
		)
		yes_button.pressed.emit()
		var yes_selected_style := yes_button.get_theme_stylebox(
			"normal"
		) as StyleBoxFlat
		_check(
			choice_ux_ui.selected_choice_ids == ["confirm:yes"]
			and yes_button.text.begins_with("✓ ")
			and not no_button.text.begins_with("✓ ")
			and yes_selected_style != null
			and yes_selected_style.border_width_left >= 2,
			"Selected text option did not expose a clear selected style",
		)
		no_button.pressed.emit()
		var no_selected_style := no_button.get_theme_stylebox(
			"normal"
		) as StyleBoxFlat
		_check(
			choice_ux_ui.selected_choice_ids == ["confirm:no"]
			and not yes_button.text.begins_with("✓ ")
			and no_button.text.begins_with("✓ ")
			and no_selected_style != null
			and no_selected_style.border_width_left >= 2,
			"Clicking another text option did not atomically switch the selected style",
		)
	choice_ux_ui._close_modal()
	choice_ux_ui._finish_modal_close(choice_ux_ui._modal_generation)

	var optional_ux_request := ChoiceView.new(
		"choice:ux:optional",
		choice_ux_ui.state.revision,
		"search",
		0,
		"你可以选择最多两张卡牌，也可以不选择并继续。",
		[
			{
				"option_id": "optional:first",
				"label": "墓仔狗",
				"ref": EntityRef.new(
					"card", 0, "hand", "", 0, "", "sv1-104"
				).to_dict(),
			},
			{
				"option_id": "optional:second",
				"label": "伤药",
				"ref": EntityRef.new(
					"card", 0, "hand", "", 1, "", "svf-potion"
				).to_dict(),
			},
		],
		0,
		2,
		false,
		true,
		{"domain": "effect", "purpose": "search", "cancels_action": true},
	)
	choice_ux_ui.state.resolution_stack = {}
	choice_ux_ui.show_choice(optional_ux_request)
	var optional_ux_panel := choice_ux_ui.active_choice_panel as ChoicePanel
	_check(
		optional_ux_panel != null
		and not choice_ux_ui.modal_confirm.disabled
		and choice_ux_ui.modal_confirm.text.contains("不选择并继续")
		and choice_ux_ui.modal_cancel.visible
		and choice_ux_ui.modal_cancel.text.contains("取消使用此卡")
		and optional_ux_panel.metadata_label.text.contains("最多")
		and optional_ux_panel.metadata_label.text.contains("2")
		and optional_ux_panel.metadata_label.text.contains("张"),
		"Optional 0/N choice did not distinguish skip-confirm from cancelling card use",
	)
	choice_ux_ui._toggle_choice("optional:first")
	_check(
		not choice_ux_ui.modal_confirm.text.contains("不选择并继续"),
		"Optional choice CTA did not change after selecting a card",
	)
	choice_ux_ui._close_modal()
	choice_ux_ui._finish_modal_close(choice_ux_ui._modal_generation)

	choice_ux_ui.state.resolution_stack = {}
	var empty_ux_request := ChoiceRequest.new(
		"choice:ux:empty",
		"resolve_empty",
		0,
		"没有找到符合条件的卡牌。",
		[],
		0,
		0,
	)
	choice_ux_ui.show_choice(empty_ux_request)
	var empty_ux_panel := choice_ux_ui.active_choice_panel as ChoicePanel
	_check(
		empty_ux_panel != null
		and empty_ux_panel.prompt_label.text == empty_ux_request.prompt
		and not empty_ux_panel.empty_label.visible
		and empty_ux_panel.metadata_label.text.contains("无需选择")
		and not choice_ux_ui.modal_confirm.disabled
		and choice_ux_ui.modal_confirm.text.contains("继续结算")
		and not choice_ux_ui.modal_cancel.visible,
		"Empty 0/0 choice did not expose a safe and understandable continuation state",
	)
	choice_ux_ui._close_modal()
	choice_ux_ui._finish_modal_close(choice_ux_ui._modal_generation)

	var attachment_ux_request := ChoiceView.new(
		"choice:ux:attachment",
		choice_ux_ui.state.revision,
		"select_attachment",
		0,
		"选择战斗宝可梦身上要丢弃的能量。",
		[
			{
				"option_id": "attachment:0:active:energy:0:sv1-ener-5",
				"label": "墓仔狗 · 基本火能量",
				"ref": EntityRef.new(
					"attachment", 0, "", "active", 0, "energy", "sv1-ener-5"
				).to_dict(),
				"value": {
					"player": 0,
					"slot": "active",
					"index": 0,
					"card_id": "sv1-ener-5",
				},
			},
			{
				"option_id": "attachment:0:active:energy:1:svi-jete",
				"label": "墓仔狗 · 喷射能量",
				"ref": EntityRef.new(
					"attachment", 0, "", "active", 1, "energy", "svi-jete"
				).to_dict(),
				"value": {
					"player": 0,
					"slot": "active",
					"index": 1,
					"card_id": "svi-jete",
				},
			},
		],
		1,
		1,
	)
	choice_ux_ui.show_choice(attachment_ux_request)
	var attachment_panel := choice_ux_ui.active_choice_panel as ChoicePanel
	_check(
		attachment_panel != null
		and attachment_panel.card_option_count() == 2
		and (attachment_panel._option_captions.get(
			"attachment:0:active:energy:0:sv1-ener-5"
		) as Label).text.contains("基本火能量")
		and (attachment_panel._option_captions.get(
			"attachment:0:active:energy:1:svi-jete"
		) as Label).text.contains("喷射能量"),
		"Attachment card captions discarded the distinct attachment labels",
	)
	choice_ux_ui._close_modal()
	choice_ux_ui._finish_modal_close(choice_ux_ui._modal_generation)

	var arven_ux_request := ChoiceView.new(
		"choice:ux:arven",
		choice_ux_ui.state.revision,
		"arven",
		0,
		"选择物品卡和宝可梦道具，各最多一张。",
		[
			{"option_id": "arven:item:0", "label": "巢穴球", "ref": EntityRef.new("card", 0, "deck", "", 0, "", "sv1-151").to_dict()},
			{"option_id": "arven:item:1", "label": "高级球", "ref": EntityRef.new("card", 0, "deck", "", 1, "", "sv1-153").to_dict()},
			{"option_id": "arven:tool:0", "label": "不服输头带", "ref": EntityRef.new("card", 0, "deck", "", 2, "", "sv1-201").to_dict()},
			{"option_id": "arven:tool:1", "label": "勇气护符", "ref": EntityRef.new("card", 0, "deck", "", 3, "", "sv1-202").to_dict()},
		],
		0,
		2,
	)
	choice_ux_ui.show_choice(arven_ux_request)
	choice_ux_ui._toggle_choice("arven:item:0")
	var arven_panel := choice_ux_ui.active_choice_panel as ChoicePanel
	var second_item_reason := (
		arven_panel.option_disabled_reason("arven:item:1")
		if arven_panel
		else ""
	)
	_check(
		second_item_reason.contains("物品和宝可梦道具各最多"),
		"Arven choice did not explain its one-item and one-tool category limit",
	)
	choice_ux_ui._toggle_choice("arven:tool:0")
	_check(
		choice_ux_ui.selected_choice_ids == ["arven:item:0", "arven:tool:0"],
		"Arven choice blocked a legal item-plus-tool combination",
	)
	choice_ux_ui._close_modal()
	choice_ux_ui._finish_modal_close(choice_ux_ui._modal_generation)

	var clara_ux_request := ChoiceView.new(
		"choice:ux:clara",
		choice_ux_ui.state.revision,
		"clara",
		0,
		"从弃牌区选择宝可梦和基本能量，各最多一张。",
		[
			{"option_id": "clara:pokemon:0", "label": "墓仔狗", "ref": EntityRef.new("card", 0, "discard", "", 0, "", "sv1-104").to_dict()},
			{"option_id": "clara:pokemon:1", "label": "天然雀", "ref": EntityRef.new("card", 0, "discard", "", 1, "", "sv1-107").to_dict()},
			{"option_id": "clara:energy:0", "label": "火能量", "ref": EntityRef.new("card", 0, "discard", "", 2, "", "sv1-ener-2").to_dict()},
			{"option_id": "clara:energy:1", "label": "水能量", "ref": EntityRef.new("card", 0, "discard", "", 3, "", "sv1-ener-3").to_dict()},
		],
		0,
		2,
		false,
		false,
		{"pokemon_count": 1, "energy_count": 1},
	)
	choice_ux_ui.show_choice(clara_ux_request)
	choice_ux_ui._toggle_choice("clara:pokemon:0")
	var clara_panel := choice_ux_ui.active_choice_panel as ChoicePanel
	var second_pokemon_reason := (
		clara_panel.option_disabled_reason("clara:pokemon:1")
		if clara_panel
		else ""
	)
	_check(
		second_pokemon_reason.contains("宝可梦最多"),
		"Clara choice did not explain its Pokémon category limit",
	)
	choice_ux_ui._toggle_choice("clara:energy:0")
	var second_energy_reason := (
		clara_panel.option_disabled_reason("clara:energy:1")
		if clara_panel
		else ""
	)
	_check(
		second_energy_reason.contains("基本能量最多")
		and choice_ux_ui.selected_choice_ids == [
			"clara:pokemon:0", "clara:energy:0",
		],
		"Clara choice did not enforce distinct Pokémon/basic-energy limits",
	)
	choice_ux_ui.queue_free()

	var field_choice_ui := packed.instantiate()
	root.add_child(field_choice_ui)
	field_choice_ui.initialize_ui()
	var field_choice_state := _battle_state()
	field_choice_state.players[0].bench[0] = PokemonState.new("sv2-delib")
	field_choice_state.players[1].bench[0] = PokemonState.new("sv2-delib")
	_set_energy_cards(
		field_choice_state.players[1].bench[0],
		["sv1-ener-4", "sv1-ener-5"],
	)
	field_choice_ui.state = field_choice_state
	field_choice_ui.current_view_player = 0
	field_choice_ui._build_game_screen()
	var field_choice := ChoiceView.new(
		"field-choice",
		field_choice_state.revision,
		"select_heal_target",
		0,
		"选择回复目标。",
		[
			{
				"option_id": "target:active",
				"label": "战斗区",
				"ref": EntityRef.new(
					"pokemon", 0, "", "active", -1, "", "sv1-104"
				).to_dict(),
			},
			{
				"option_id": "target:bench_0",
				"label": "备战区 1",
				"ref": EntityRef.new(
					"pokemon", 0, "", "bench_0", -1, "", "sv2-delib"
				).to_dict(),
			},
		],
		1,
		1,
	)
	field_choice_ui._show_choice_overlay(field_choice)
	_check(
		not field_choice_ui.modal_layer.visible
		and field_choice_ui.battle_screen.table.choice_target_options.size() == 2
		and field_choice_ui.battle_screen.table.get_slot_view(0, "active").targetable
		and field_choice_ui.battle_screen.table.get_slot_view(0, "bench_0").targetable,
		"Visible single-target card choice did not route to highlighted field cards",
	)
	var unique_attachment_id := "attachment:1:bench_0:energy:0:sv1-ener-4"
	var unique_attachment_choice := ChoiceView.new(
		"field-attachment-choice",
		field_choice_state.revision,
		"select_attachment",
		0,
		"选择对手备战宝可梦身上的能量。",
		[{
			"option_id": unique_attachment_id,
			"label": "备战区 1 · 基本水能量",
			"ref": EntityRef.new(
				"attachment", 1, "", "bench_0", 0, "energy", "sv1-ener-4"
			).to_dict(),
			"value": {
				"player": 1,
				"slot": "bench_0",
				"index": 0,
				"card_id": "sv1-ener-4",
			},
		}],
		1,
		1,
	)
	field_choice_ui._show_choice_overlay(unique_attachment_choice)
	var opponent_bench_key := CardInteractionRouter.pokemon_key(1, "bench_0")
	var field_choice_table := field_choice_ui.battle_screen.table as BattleTable
	var unique_group_value: Variant = field_choice_table.choice_target_options.get(
		opponent_bench_key,
		{},
	)
	var unique_group := (
		Dictionary(unique_group_value)
		if unique_group_value is Dictionary
		else {}
	)
	var unique_group_options: Array = unique_group.get("options", [])
	_check(
		not field_choice_ui.modal_layer.visible
		and str(unique_group.get("kind", "")) == "attachment_group"
		and int(unique_group.get("player", -1)) == 1
		and str(unique_group.get("slot", "")) == "bench_0"
		and unique_group_options.size() == 1
		and str(Dictionary(unique_group_options[0]).get(
			"option_id", "")) == unique_attachment_id
		and field_choice_table.get_slot_view(
			1, "bench_0").targetable,
		"Unique attachment choice did not map its Pokemon to one exact attachment group",
	)
	var direct_attachment_ids: Array[String] = []
	field_choice_ui.battle_screen.choice_target_selected.connect(
		func(option_id: String) -> void:
			direct_attachment_ids.append(option_id)
	)
	var main_target_choice_handler := Callable(
		field_choice_ui,
		"_on_battle_choice_target_selected",
	)
	if field_choice_ui.battle_screen.choice_target_selected.is_connected(
		main_target_choice_handler,
	):
		field_choice_ui.battle_screen.choice_target_selected.disconnect(
			main_target_choice_handler,
		)
	field_choice_table._on_card_activated("sv2-delib", -1, 1, "bench_0")
	_check(
		direct_attachment_ids == [unique_attachment_id]
		and not field_choice_table.attachment_choice_popover.visible,
		"Single attachment group did not resolve directly from its Pokemon",
	)
	field_choice_ui.battle_screen.choice_target_selected.connect(
		main_target_choice_handler,
	)
	var duplicate_attachment_choice := ChoiceView.new(
		"duplicate-field-attachment-choice",
		field_choice_state.revision,
		"select_attachment",
		0,
		"选择对手备战宝可梦身上的能量。",
		[
			{
				"option_id": unique_attachment_id,
				"label": "备战区 1 · 基本水能量",
				"ref": EntityRef.new(
					"attachment", 1, "", "bench_0", 0, "energy", "sv1-ener-4"
				).to_dict(),
				"value": {
					"player": 1,
					"slot": "bench_0",
					"index": 0,
					"card_id": "sv1-ener-4",
				},
			},
			{
				"option_id": "attachment:1:bench_0:energy:1:sv1-ener-5",
				"label": "备战区 1 · 基本草能量",
				"ref": EntityRef.new(
					"attachment", 1, "", "bench_0", 1, "energy", "sv1-ener-5"
				).to_dict(),
				"value": {
					"player": 1,
					"slot": "bench_0",
					"index": 1,
					"card_id": "sv1-ener-5",
				},
			},
		],
		1,
		2,
	)
	field_choice_ui._show_choice_overlay(duplicate_attachment_choice)
	var duplicate_group_value: Variant = field_choice_table.choice_target_options.get(
		opponent_bench_key,
		{},
	)
	var duplicate_group := (
		Dictionary(duplicate_group_value)
		if duplicate_group_value is Dictionary
		else {}
	)
	var duplicate_group_options: Array = duplicate_group.get("options", [])
	_check(
		not field_choice_ui.modal_layer.visible
		and field_choice_ui.active_choice_panel == null
		and str(duplicate_group.get("kind", "")) == "attachment_group"
		and duplicate_group_options.size() == 2
		and str(Dictionary(duplicate_group_options[0]).get("ref", {}).get(
			"card_id", "")) == "sv1-ener-4"
		and int(Dictionary(duplicate_group_options[0]).get("ref", {}).get(
			"index", -1)) == 0
		and str(Dictionary(duplicate_group_options[1]).get("ref", {}).get(
			"card_id", "")) == "sv1-ener-5"
		and int(Dictionary(duplicate_group_options[1]).get("ref", {}).get(
			"index", -1)) == 1,
		"Multiple attachments did not remain exact options in their Pokemon group",
	)
	field_choice_table._on_card_activated("sv2-delib", -1, 1, "bench_0")
	var attachment_popover := field_choice_table.attachment_choice_popover
	_check(
		attachment_popover.visible
		and attachment_popover.option_count() == 2
		and attachment_popover._button_by_id.has(unique_attachment_id)
		and attachment_popover._button_by_id.has(
			"attachment:1:bench_0:energy:1:sv1-ener-5",
		),
		"Multiple attachments did not open the source-anchored exact-energy popover",
	)
	var toggled_attachment_ids: Array[String] = []
	field_choice_ui.battle_screen.choice_option_toggled.connect(
		func(option_id: String) -> void:
			toggled_attachment_ids.append(option_id)
	)
	var first_attachment_button := attachment_popover._button_by_id.get(
		unique_attachment_id,
	) as Button
	if first_attachment_button != null:
		first_attachment_button.pressed.emit()
	_check(
		toggled_attachment_ids == [unique_attachment_id]
		and field_choice_ui.selected_choice_ids == [unique_attachment_id]
		and attachment_popover._selected_ids == [unique_attachment_id]
		and attachment_popover._confirm_button.visible
		and not attachment_popover._confirm_button.disabled,
		"Attachment popover did not emit and reflect an exact-energy selection",
	)
	var attachment_confirmations: Array[bool] = []
	field_choice_ui.battle_screen.choice_selection_confirmed.connect(
		func() -> void:
			attachment_confirmations.append(true)
	)
	var main_choice_confirm_handler := Callable(field_choice_ui, "_confirm_choice")
	if field_choice_ui.battle_screen.choice_selection_confirmed.is_connected(
		main_choice_confirm_handler,
	):
		field_choice_ui.battle_screen.choice_selection_confirmed.disconnect(
			main_choice_confirm_handler,
		)
	attachment_popover._confirm_button.pressed.emit()
	_check(
		attachment_confirmations.size() == 1
		and not attachment_popover.visible,
		"Attachment popover did not emit confirmation and close",
	)
	field_choice_ui.battle_screen.choice_selection_confirmed.connect(
		main_choice_confirm_handler,
	)
	var coin_choice := ChoiceView.new(
		"coin-choice",
		field_choice_state.revision,
		"coin_flip",
		0,
		"硬币结果",
		[],
		0,
		0,
		false,
		false,
		{"predetermined_flips": [true, false, true]},
	)
	field_choice_ui._show_choice_overlay(coin_choice)
	var has_coin_face := false
	for label_value in field_choice_ui.modal_body.find_children("*", "Label", true, false):
		var label := label_value as Label
		if label and label.text in ["正", "反"]:
			has_coin_face = true
			break
	_check(
		field_choice_ui.modal_layer.visible
		and field_choice_ui.active_choice_panel == null
		and has_coin_face,
		"Coin flip choice did not use the dedicated coin animation surface",
	)
	field_choice_ui.queue_free()

	var choice_panel_scene := load("res://ui/dialogs/choice_panel.tscn") as PackedScene
	_check(choice_panel_scene != null, "ChoicePanel scene failed to load")
	if choice_panel_scene:
		var panel := choice_panel_scene.instantiate() as ChoicePanel
		root.add_child(panel)
		var direct_panel_prompt := "请选择需要处理的卡牌；你可以点击另一张卡牌直接换选。"
		panel.configure(
			"最多选择 2 张卡牌。",
			true,
			CardCatalog.new(),
			{
				"prompt": direct_panel_prompt,
				"min_select": 0,
				"max_select": 2,
				"request_type": "search",
			},
		)
		var first_card := panel.add_card_option(
			"dup:target", "sv1-104", "备战区 1", 0)
		var second_card := panel.add_card_option("dup:second", "sv1-151", "牌库 2", 0)
		_check(
			panel.prompt_label.visible
			and panel.prompt_label.text == direct_panel_prompt
			and first_card.catalog == panel.catalog
			and second_card.catalog == panel.catalog,
			"ChoicePanel configure context did not render its complete prompt",
		)
		panel.size = Vector2(980.0, 600.0)
		panel._apply_responsive_layout()
		var wide_choice_columns := panel.responsive_column_count()
		panel.size = Vector2(560.0, 600.0)
		panel._apply_responsive_layout()
		var compact_choice_columns := panel.responsive_column_count()
		_check(
			wide_choice_columns <= 5
			and compact_choice_columns >= 2
			and compact_choice_columns < wide_choice_columns
			and panel.card_grid is HFlowContainer
			and panel.get_combined_minimum_size().x <= 320.0,
			"ChoicePanel card grid did not reduce its column count at compact width",
		)
		for narrow_case in [
			{"width": 480.0, "columns": 2},
			{"width": 400.0, "columns": 2},
			{"width": 320.0, "columns": 1},
		]:
			var narrow_width := float(narrow_case["width"])
			panel.size = Vector2(narrow_width, 600.0)
			panel._apply_responsive_layout()
			var narrow_columns := panel.responsive_column_count()
			var occupied_width := (
				float(narrow_columns) * ChoicePanel.CARD_TILE_SIZE.x
				+ float(maxi(0, narrow_columns - 1)) * ChoicePanel.CARD_GRID_GAP
				+ panel.content_row.get_theme_constant("separation")
				+ panel.responsive_preview_width()
			)
			_check(
				panel.is_preview_visible()
				and narrow_columns == int(narrow_case["columns"])
				and occupied_width <= narrow_width + 0.5,
				"ChoicePanel hid or overflowed its preview at %d px: columns=%d occupied=%.1f" % [
					int(narrow_width), narrow_columns, occupied_width,
				],
			)
		second_card.activated.emit("sv1-151", -1, 0, "")
		_check(
			panel.is_preview_visible()
			and panel.previewed_card_id() == "sv1-151"
			and panel.preview_title.text.contains("巢穴球"),
			"Narrow ChoicePanel did not update the visible preview after a card click",
		)
		panel._preview_card("missing-choice-card")
		_check(
			panel.is_preview_visible()
			and panel.previewed_card_id() == "missing-choice-card"
			and panel.preview_title.text.contains("资料暂不可用")
			and panel.preview_image.texture == null,
			"Missing card data silently removed the ChoicePanel preview",
		)
		panel._preview_card("sv1-104")
		panel.set_option_disabled_reasons({"dup:second": "已达到选择上限"})
		panel.show_blocked_reason("已达到选择上限")
		panel.set_option_disabled_reasons({})
		_check(
			not panel.blocked_reason_label.visible
			and panel.blocked_reason_label.accessibility_name.is_empty(),
			"ChoicePanel retained a stale blocked accessibility announcement",
		)
		panel.size = Vector2(980.0, 600.0)
		panel._apply_responsive_layout()
		panel.refresh_selection(["dup:target"], 1, false)
		var selected_badge := panel._option_badges.get("dup:target") as Label
		var unselected_badge := panel._option_badges.get("dup:second") as Label
		var selected_tile := panel._option_tiles.get("dup:target") as PanelContainer
		var selection_ring := first_card.get_node_or_null("SelectionRing") as Panel
		var selection_style := (
			selection_ring.get_theme_stylebox("panel") as StyleBoxFlat
			if selection_ring
			else null
		)
		var tile_style := (
			selected_tile.get_theme_stylebox("panel") as StyleBoxFlat
			if selected_tile
			else null
		)
		_check(
			first_card.selected
			and not second_card.selected
			and selected_badge != null
			and selected_badge.visible
			and selected_badge.text.begins_with("✓")
			and selected_badge.tooltip_text.contains("已选择")
			and unselected_badge != null
			and not unselected_badge.visible,
			"ChoicePanel did not expose a clear exclusive selected state",
		)
		_check(
			selection_style != null
			and not selection_style.draw_center
			and selection_style.border_width_left >= 3
			and selection_style.shadow_size >= 8
			and tile_style != null
			and tile_style.border_width_left >= 2
			and panel.selection_hint_label.text.contains("换选"),
			"ChoicePanel selected card did not receive the strong outline contract",
		)
		panel.refresh_selection(["dup:target", "dup:target"], 2, true)
		_check(panel.card_option_count() == 2, "ChoicePanel did not create card tiles")
		_check(
			panel.is_preview_visible()
			and panel.previewed_card_id() == "sv1-104"
			and panel.preview_text.text.contains("HP"),
			"ChoicePanel did not automatically preview the first card option",
		)
		second_card.activated.emit("sv1-151", -1, 0, "")
		_check(
			panel.previewed_card_id() == "sv1-151"
			and panel.preview_title.text.contains("巢穴球"),
			"ChoicePanel did not update preview from card activation",
		)
		_check(
			panel.selected_count_for("dup:target") == 2,
			"ChoicePanel duplicate selection count was not tracked",
		)
		panel.clear_options()
		panel.add_text_option("confirm:yes", "是")
		panel.add_text_option("confirm:no", "否")
		panel.refresh_selection(["confirm:yes"], 1, false)
		_check(panel.card_option_count() == 0, "Non-card choices created card tiles")
		_check(panel.text_option_count() == 2, "Non-card choices did not create compact buttons")
		_check(
			not panel.is_preview_visible() and panel.previewed_card_id().is_empty(),
			"Non-card choices left the card preview visible",
		)
		_check(
			panel.selected_count_for("confirm:yes") == 1,
			"Non-card choice selection state was not tracked",
		)
		panel.clear_options()
		panel.add_revealed_cards(["svf-potion"], CardCatalog.new(), "牌库顶")
		_check(
			panel.energy_preview.visible
			and panel.energy_preview_label.text == "牌库顶"
			and panel.previewed_card_id() == "svf-potion"
			and panel.preview_title.text.contains("伤药"),
			"ChoicePanel did not preview revealed non-option cards",
		)
		var enum_tokens := [
			"Pokémon", "Trainer", "Energy", "Basic", "Stage", "Colorless",
		]
		var localized_preview := true
		for preview_card_id in ["sv1-104", "sv1-106", "sv1-151", "svi-jete"]:
			panel._preview_card(preview_card_id)
			for enum_token in enum_tokens:
				localized_preview = (
					localized_preview
					and not panel.preview_text.text.contains(str(enum_token))
				)
		_check(
			localized_preview,
			"Choice preview leaked raw English card type or energy enum values",
		)
		panel.queue_free()

	var energy_ui := packed.instantiate()
	root.add_child(energy_ui)
	energy_ui.initialize_ui()
	if choice_panel_scene:
		var energy_panel := choice_panel_scene.instantiate() as ChoicePanel
		root.add_child(energy_panel)
		energy_panel.configure(
			"最多分配 2 张能量。",
			true,
			CardCatalog.new(),
			{
				"prompt": "依次为每张能量选择附着目标。",
				"min_select": 0,
				"max_select": 2,
				"request_type": "distribute_energy",
				"allow_duplicates": true,
			},
		)
		energy_panel.add_text_option("target:active", "战斗区")
		energy_panel.add_text_option("target:bench_0", "备战区 1")
		energy_panel.add_energy_preview(
			["sv1-ener-1", "sv1-ener-2"], CardCatalog.new())
		energy_ui.active_request = ChoiceView.new(
			"choice:energy:max-per-target",
			0,
			"distribute_energy",
			0,
			"分配能量",
			[
				{"option_id": "target:active", "label": "战斗区", "ref": EntityRef.new("slot", 0, "", "active").to_dict()},
				{"option_id": "target:bench_0", "label": "备战区 1", "ref": EntityRef.new("slot", 0, "", "bench_0").to_dict()},
			],
			0,
			2,
			true,
			false,
			{"max_per_target": 1},
		)
		energy_ui.active_choice_panel = energy_panel
		energy_ui.selected_choice_ids.clear()
		energy_ui._refresh_choice_buttons()
		_check(
			energy_panel.undo_button.disabled
			and energy_panel.clear_button.disabled,
			"Empty energy distribution left undo or clear enabled",
		)
		energy_ui._toggle_choice("target:active")
		_check(
			energy_ui.selected_choice_ids == ["target:active"]
			and energy_panel._energy_assignment_labels[0].text.contains("战斗区")
			and energy_panel._energy_assignment_labels[1].text.contains("请选择目标")
			and not energy_panel.undo_button.disabled
			and not energy_panel.clear_button.disabled,
			"Energy distribution did not expose non-zero progress and the current card",
		)
		var active_cap_reason := str(
			energy_panel._option_disabled_reasons.get("target:active", "")
		)
		_check(
			active_cap_reason.contains("该目标最多")
			and active_cap_reason.contains("1")
			and active_cap_reason.contains("张能量"),
			"Energy target did not explain its max_per_target limit",
		)
		energy_ui._toggle_choice("target:active")
		_check(
			energy_ui.selected_choice_ids == ["target:active"]
			and energy_panel.blocked_reason_label.text.contains("该目标最多"),
			"Energy max_per_target did not block an extra assignment with feedback",
		)
		energy_ui._toggle_choice("target:bench_0")
		_check(
			energy_ui.selected_choice_ids == ["target:active", "target:bench_0"]
			and not energy_ui.modal_confirm.disabled
			and energy_panel._energy_assignment_labels[1].text.contains("备战区 1"),
			"Energy distribution did not complete across two legal targets",
		)
		energy_ui._rewind_energy_distribution(1)
		_check(
			energy_ui.selected_choice_ids == ["target:active"]
			and energy_panel._energy_assignment_labels[1].text.contains("请选择目标"),
			"Energy distribution rewind did not roll back to the selected energy",
		)
		energy_ui._undo_energy_distribution()
		_check(
			energy_ui.selected_choice_ids.is_empty()
			and energy_panel._energy_assignment_labels[0].text.contains("请选择目标")
			and energy_panel.undo_button.disabled
			and energy_panel.clear_button.disabled,
			"Energy distribution undo did not remove the last assignment",
		)
		energy_ui._toggle_choice("target:active")
		energy_ui._toggle_choice("target:bench_0")
		energy_ui._clear_energy_distribution()
		_check(
			energy_ui.selected_choice_ids.is_empty()
			and energy_panel._energy_assignment_labels[0].text.contains("请选择目标")
			and energy_panel.undo_button.disabled
			and energy_panel.clear_button.disabled,
			"Energy distribution clear did not reset assignments",
		)

		energy_ui.active_request = ChoiceView.new(
			"choice:energy:same-target",
			0,
			"distribute_energy",
			0,
			"把这些能量附着到同一目标。",
			[
				{"option_id": "target:active", "label": "战斗区", "ref": EntityRef.new("slot", 0, "", "active").to_dict()},
				{"option_id": "target:bench_0", "label": "备战区 1", "ref": EntityRef.new("slot", 0, "", "bench_0").to_dict()},
			],
			2,
			2,
			true,
			false,
			{"max_per_target": 2, "same_target": true},
		)
		energy_ui.selected_choice_ids.clear()
		energy_ui._refresh_choice_buttons()
		energy_ui._toggle_choice("target:active")
		var same_target_reason := str(
			energy_panel._option_disabled_reasons.get("target:bench_0", "")
		)
		_check(
			same_target_reason.contains("同一目标"),
			"Energy same_target choice did not explain why another target is blocked",
		)
		energy_ui._toggle_choice("target:bench_0")
		_check(
			energy_ui.selected_choice_ids == ["target:active"]
			and energy_panel.blocked_reason_label.text.contains("同一目标"),
			"Energy same_target constraint did not preserve the current assignment",
		)
		energy_ui._toggle_choice("target:active")
		_check(
			energy_ui.selected_choice_ids == ["target:active", "target:active"]
			and not energy_ui.modal_confirm.disabled
			and energy_panel.selected_count_for("target:active") == 2
			and energy_panel._energy_assignment_labels[0].text.contains("战斗区")
			and energy_panel._energy_assignment_labels[1].text.contains("战斗区")
			and not energy_panel._energy_assignment_labels[0].text.contains("请选择目标")
			and not energy_panel._energy_assignment_labels[1].text.contains("请选择目标"),
			"Same-target energy distribution did not reach an unambiguous complete state",
		)
		energy_panel.queue_free()
	energy_ui.queue_free()

	var retreat_ui := packed.instantiate()
	root.add_child(retreat_ui)
	retreat_ui.initialize_ui()
	var retreat_state := _battle_state()
	retreat_state.turn_number = 3
	retreat_state.phase = "MAIN"
	retreat_state.players[0].active = PokemonState.new("sv1-104")
	retreat_state.players[0].active.placed_this_turn = false
	_set_energy_cards(retreat_state.players[0].active, ["sv1-ener-5"])
	retreat_state.players[0].bench[0] = PokemonState.new("sv2-delib")
	retreat_state.players[0].bench[0].placed_this_turn = false
	retreat_state.players[0].discard = []
	retreat_ui.state = retreat_state
	retreat_ui.current_screen = "game"
	retreat_ui.current_view_player = 0
	retreat_ui.game_mode = "local"
	retreat_ui._build_game_screen()
	var retreat_step: StepResult = retreat_ui._execute_action(
		GameAction.new("RETREAT", {"bench_idx": 0, "energy_indices": [0]}, false, 0))
	_check(
		retreat_step.success
		and retreat_ui.modal_layer.visible
		and retreat_ui.active_request == null,
		"Retreat action did not show a confirmation modal before execution",
	)
	_check(
		retreat_ui.state.players[0].active.card_id == "sv1-104"
		and retreat_ui.state.players[0].bench[0].card_id == "sv2-delib"
		and retreat_ui.state.players[0].discard.is_empty()
		and not retreat_ui.state.players[0].retreated_this_turn,
		"Retreat confirmation changed state before the player confirmed",
	)
	var retreat_payment_views: Array[Node] = retreat_ui.modal_body.find_children(
		"*", "CardView", true, false)
	_check(
		retreat_payment_views.size() == 1 and retreat_ui.modal_confirm.disabled,
		"Retreat confirmation did not require card-based attached-energy payment",
	)
	if not retreat_payment_views.is_empty():
		var payment_view := retreat_payment_views[0] as CardView
		payment_view.detail_requested.emit(payment_view.card_id)
		_check(
			retreat_ui.modal_confirm.text == "返回撤退确认"
			and retreat_ui.modal_body.find_child(
				"CardInspectorPanel", true, false
			) != null,
			"Retreat payment inspector exposed the wrong return destination",
		)
		retreat_ui.modal_confirm.pressed.emit()
		retreat_payment_views.assign(retreat_ui.modal_body.find_children(
			"*", "CardView", true, false))
		payment_view = (
			retreat_payment_views[0] as CardView
			if not retreat_payment_views.is_empty()
			else null
		)
		_check(
			payment_view != null and retreat_ui.modal_title.text == "确认撤退",
			"Retreat payment inspector did not return to its confirmation panel",
		)
		if payment_view:
			payment_view.activated.emit(payment_view.card_id, -1, 0, "")
			_check(
				not retreat_ui.modal_confirm.disabled and payment_view.selected,
				"Selecting the retreat energy card did not unlock confirmation",
			)
	retreat_ui.queue_free()

	var end_turn_ui := packed.instantiate()
	root.add_child(end_turn_ui)
	end_turn_ui.initialize_ui()
	var end_turn_state := _battle_state()
	end_turn_ui.state = end_turn_state
	end_turn_ui.current_screen = "game"
	end_turn_ui.current_view_player = 0
	end_turn_ui.game_mode = "local"
	end_turn_ui._build_game_screen()
	var end_turn_step: StepResult = end_turn_ui._execute_action(
		GameAction.new("END_TURN", {}, true, 0))
	_check(
		end_turn_step.success
		and end_turn_ui.modal_layer.visible
		and end_turn_ui.state.active_player_idx == 0
		and end_turn_ui.modal_body.get_child_count() > 0
		and str(end_turn_ui.modal_body.get_child(0).text).contains("附加能量"),
		"End turn did not warn about remaining legal card actions",
	)
	end_turn_ui.queue_free()
	if settings_node:
		settings_node.set("animation_mode", previous_animation_mode)
		settings_node.set("reduced_motion", previous_reduced_motion)


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
	var request := ChoiceView.from_dict(fixture["choice"])
	for index in range(request.options.size()):
		var encoded := encoder.encode_choice(
			observation, request, request.options[index], index)
		_check(
			_deep_equal(encoded, fixture["expected"]["choices"][index]),
			"AI choice encoder differs at index %d" % index,
		)
	var bool_choice_request := ChoiceView.new(
		"bool-choice",
		0,
		"confirm",
		int(observation["perspective"]),
		"Confirm optional effect?",
		[{"option_id": "confirm:yes", "label": "Yes"}],
	)
	var bool_choice_encoded := encoder.encode_choice(
		observation, bool_choice_request, bool_choice_request.options[0], 0)
	_check(
		bool_choice_encoded.has("numeric")
		and bool_choice_encoded["numeric"].size() == AIActionEncoder.ACTION_NUMERIC_SIZE
		and int(bool_choice_encoded.get("card_id", -1)) == 0,
		"AI choice encoder failed a public identity-free option",
	)
	_run_ai_runtime_v5_tests(catalog, observation)

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
	var release_deep_enabled := bool(
		runtime.release_manifest.get("deep_runtime_enabled", false))
	if release_deep_enabled:
		_check(
			runtime.runtime_enabled
			and runtime.is_available()
			and int(runtime.release_manifest.get(
				"compatible_model_count", -1))
			== int(runtime.release_manifest.get("model_count", -2))
			and int(runtime.release_manifest.get(
				"legacy_model_count", -1)) == 0,
			"Promoted Deep runtime is not complete",
		)
	else:
		_check(
			not runtime.runtime_enabled
			and not runtime.is_available()
			and not runtime.load_for_deck("fire")
			and runtime.last_error == "deep_runtime_disabled",
			"Legacy Deep runtime was not disabled deterministically",
		)
		_check(
			int(runtime.release_manifest.get(
				"compatible_model_count", -1)) == 0
			and int(runtime.release_manifest.get("legacy_model_count", -1))
			== int(runtime.release_manifest.get(
				"release_decks", []).size()),
			"Disabled Deep release model counts are invalid",
		)
	_check(
		str(runtime.release_manifest.get("deep_fallback", "")) == "challenge",
		"Deep release metadata does not require Challenge fallback",
	)
	var release_schemas: Dictionary = runtime.release_manifest.get("schemas", {})
	var release_onnx: Dictionary = runtime.release_manifest.get("onnx", {})
	_check(
		int(release_schemas.get("encoder", 0))
		== DeepAIRuntime.ENCODER_VERSION
		and int(release_schemas.get("checkpoint", 0))
		== DeepAIRuntime.CHECKPOINT_VERSION
		and int(release_schemas.get("deep_planner", 0))
		== DeepAIRuntime.PLANNER_VERSION
		and int(release_onnx.get("opset", 0)) == 17
		and str(release_onnx.get("runtime_version", "")) == "1.26.0",
		"Deep AI release expectations do not come from the release manifest",
	)
	var runtime_manifest_encoder := int(
		Dictionary(runtime.manifest.get("compatibility_bridge", {})).get("python_encoder_version", 0)
	)
	var runtime_manifest_current: bool = (
		runtime_manifest_encoder == DeepAIRuntime.ENCODER_VERSION
	)
	if runtime.is_available():
		var mismatched_native_runtime := DeepAIRuntime.new()
		mismatched_native_runtime.backend = RuntimeVersionMismatchBackend.new()
		_check(
			not mismatched_native_runtime.load_for_deck("fire")
			and mismatched_native_runtime.last_error
			== "onnx_runtime_version_mismatch",
			"Deep AI accepted a native ONNX Runtime outside the release contract",
		)
		var original_opset := int(runtime.manifest.get("opset", 0))
		runtime.manifest["opset"] = int(release_onnx.get("opset", 0)) + 1
		_check(
			not runtime.load_for_deck("fire")
			and runtime.last_error == "runtime_onnx_contract_mismatch",
			"Deep AI accepted an ONNX runtime manifest outside the release contract",
		)
		runtime.manifest["opset"] = original_opset
		if not runtime_manifest_current:
			_check(
				not runtime.load_for_deck("fire")
				and runtime.last_error == "compatibility_bridge_mismatch",
				"Deep AI accepted an incompatible Python encoder manifest",
			)
		else:
			var release_manifest := _read_json("res://data/release_manifest.json")
			var release_decks: Array[String] = []
			release_decks.assign(release_manifest.get("release_decks", []))
			var runtime_models: Dictionary = runtime.manifest.get("models", {})
			var runtime_routes: Dictionary = runtime.manifest.get(
				"deck_routes", {})
			_check(
				int(release_manifest.get("model_count", 0)) == 1
				and runtime_models.size() == 1
				and runtime_models.has("universal")
				and runtime_routes.size() == release_decks.size(),
				"Release and ONNX runtime manifests disagree on the model count",
			)
			for deck_key in release_decks:
				_check(str(runtime_routes.get(deck_key, "")) == "universal", (
					"ONNX runtime manifest is missing release route %s" % deck_key))
				_check(runtime.load_for_deck(deck_key), (
					"Unable to load %s ONNX model: %s" % [deck_key, runtime.last_error]))
				runtime.unload()

	var state := _battle_state()
	state.active_player_idx = 0
	state.turn_number = 3
	state.phase = "MAIN"
	state.public_deck_keys = ["psychic", "water"]
	var engine := GameEngine.new(catalog)
	var actions := RulesTestHarness.legal_actions(engine, state, 0, false)
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
	var disabled_deep_request: Dictionary = ai_request.duplicate(true)
	disabled_deep_request["mode"] = "deep"
	var disabled_deep_result := worker.decide(
		disabled_deep_request,
		func() -> bool: return false,
		null,
	)
	_check(
		disabled_deep_result.get("success", false)
		and disabled_deep_result.get("deep_fallback", false)
		and disabled_deep_result.get("fallback_reason", "") == "runtime_unavailable",
		"Disabled Deep action did not fall back to Challenge AI deterministically",
	)
	if runtime.is_available() and runtime_manifest_current and runtime.load_for_deck("psychic"):
		var deep_request: Dictionary = ai_request.duplicate(true)
		deep_request["mode"] = "deep"
		deep_request["match_seed"] = 77
		var deep_result := DeepRootISMCTS.new().decide(
			deep_request,
			func() -> bool: return false,
			runtime.get_backend(),
		)
		_check(deep_result.get("success", false), "Deep AI did not return an action")
		_check(
			str(deep_result.get("planner", ""))
			== DeepRootISMCTS.PLANNER_ID
			and int(deep_result.get("simulations", -1))
			>= DeepRootISMCTS.WINDOWS_MIN_SIMULATIONS,
			"Deep AI did not use the production information-set search contract",
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
			"Deep AI runtime failure did not switch to strongest Challenge AI",
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
	var ai_button := ai_ui.find_child("AIButton", true, false) as Button
	_check(ai_button != null and not ai_button.disabled,
		"AI title entry is unavailable")
	_check(
		ai_ui.find_child("ChallengeAIButton", true, false) == null
		and ai_ui.find_child("DeepAIButton", true, false) == null,
		"AI variants were not moved out of the title page",
	)
	ai_ui.show_deck_select("challenge")
	var ai_mode_option := ai_ui.find_child("AIModeOption", true, false) as OptionButton
	_check(ai_mode_option != null, "AI mode selector is unavailable on the deck page")
	if ai_mode_option:
		_check(
			ai_mode_option.item_count == 1
			and str(ai_mode_option.get_item_metadata(0)) == "challenge"
			and ai_mode_option.disabled,
			"Release AI selector did not expose only the locked Challenge mode",
		)
	var hidden_ai_state := GameState.new()
	hidden_ai_state.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	hidden_ai_state.setup_actor_idx = 1
	hidden_ai_state.players[0].active = PokemonState.new("svi-chim")
	hidden_ai_state.players[0].bench[0] = PokemonState.new("svi-ente")
	hidden_ai_state.players[0].hand = ["svi-hrot"]
	hidden_ai_state.players[0].deck = ["sv1-ener-2"]
	hidden_ai_state.players[0].prizes = ["svi-infr"]
	hidden_ai_state.players[1].hand = ["sv2-38"]
	hidden_ai_state.players[1].prizes = ["sv2-grex"]
	hidden_ai_state.setup_bonus_card_ids = [["svi-hrot"], ["sv2-38"]]
	ai_ui.state = hidden_ai_state
	var hidden_ai_snapshot: Dictionary = ai_ui._ai_state_snapshot(1)
	var hidden_ai_players: Array = hidden_ai_snapshot.get("players", [])
	var hidden_bonus_ids: Array = hidden_ai_snapshot.get(
		"setup_bonus_card_ids", [[], []])
	_check(
		hidden_ai_players.size() == 2
		and Dictionary(hidden_ai_players[0]).get("active") == null
		and Array(Dictionary(hidden_ai_players[0]).get("bench", [])).is_empty()
		and Array(Dictionary(hidden_ai_players[0]).get("hand", [])) == ["__hidden_card__"]
		and Array(Dictionary(hidden_ai_players[0]).get("deck", [])) == ["__hidden_card__"]
		and Array(Dictionary(hidden_ai_players[0]).get("prizes", [])) == ["__hidden_prize__"]
		and Array(Dictionary(hidden_ai_players[1]).get("prizes", [])) == ["__hidden_prize__"]
		and hidden_bonus_ids.size() == 2
		and Array(hidden_bonus_ids[0]).is_empty(),
		"Challenge AI setup snapshot leaked hidden board, hand, deck, prize, or bonus identities",
	)
	var main_phase_ai_state := _battle_state()
	main_phase_ai_state.players[0].hand = ["opponent-hand-secret"]
	main_phase_ai_state.players[0].deck = ["opponent-deck-a", "opponent-deck-b"]
	main_phase_ai_state.players[0].prizes = ["opponent-prize-secret"]
	main_phase_ai_state.players[0].discard = ["opponent-public-discard"]
	main_phase_ai_state.players[1].hand = ["own-visible-hand"]
	main_phase_ai_state.players[1].deck = ["own-deck-a", "own-deck-b"]
	main_phase_ai_state.players[1].prizes = ["own-prize-secret"]
	main_phase_ai_state.players[1].discard = ["own-public-discard"]
	ai_ui.state = main_phase_ai_state
	var main_phase_snapshot: Dictionary = ai_ui._ai_state_snapshot(1)
	var main_phase_players: Array = main_phase_snapshot.get("players", [])
	_check(
		main_phase_players.size() == 2
		and Array(Dictionary(main_phase_players[0]).get("hand", [])) == ["__hidden_card__"]
		and Array(Dictionary(main_phase_players[0]).get("deck", []))
		== ["__hidden_card__", "__hidden_card__"]
		and Array(Dictionary(main_phase_players[1]).get("hand", [])) == ["own-visible-hand"]
		and Array(Dictionary(main_phase_players[1]).get("deck", []))
		== ["__hidden_card__", "__hidden_card__"]
		and Array(Dictionary(main_phase_players[0]).get("prizes", []))
		== ["__hidden_prize__"]
		and Array(Dictionary(main_phase_players[1]).get("prizes", []))
		== ["__hidden_prize__"]
		and Array(Dictionary(main_phase_players[0]).get("discard", []))
		== ["opponent-public-discard"]
		and Array(Dictionary(main_phase_players[1]).get("discard", []))
		== ["own-public-discard"],
		"Challenge AI MAIN snapshot leaked hidden zones or masked public discard/own hand",
	)
	_check(
		ai_ui.find_child("AIDifficultyOption", true, false) == null,
		"AI difficulty selector was still visible",
	)
	_check(
		ai_ui.start_ai_match_for_test(
			"challenge", "fire", "water", 0, 20260621, false, true),
		"Unable to start Challenge AI match",
	)
	_check(
		not ai_ui.state.apply_type_matchups
		and not bool(ai_ui.state.rules_options.get("apply_type_matchups", true)),
		"Challenge AI did not force weakness/resistance matchups off",
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
			"challenge", "fire", "water", 0),
		"Unable to start Challenge AI match with automatic seed",
	)
	var automatic_seed_a := int(ai_ui.last_match_seed)
	ai_ui._stop_ai()
	_check(
		ai_ui.start_ai_match_for_test(
			"challenge", "fire", "water", 0),
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
			"deep", "fire", "water", 0, 20260621, false, true),
		"Unable to start Deep AI match",
	)
	_check(
		not ai_ui.state.apply_type_matchups
		and not bool(ai_ui.state.rules_options.get("apply_type_matchups", true)),
		"Deep AI did not force weakness/resistance matchups off",
	)
	_check(ai_ui.current_view_player == 0, "Deep AI match exposed the AI player view")
	_check(not ai_ui.modal_layer.visible,
		"Deep AI match opened the local privacy overlay")
	ai_ui._stop_ai()
	_check(
		ai_ui.start_local_match_for_test(
			"fire", "water", 20260622, 0, false, true),
		"Unable to start local match with weakness/resistance matchups enabled",
	)
	_check(
		ai_ui.state.apply_type_matchups
		and bool(ai_ui.state.rules_options.get("apply_type_matchups", false)),
		"AI rule canonicalization changed local-match rules",
	)
	ai_ui.queue_free()


func _run_ai_runtime_v5_tests(
	catalog: CardCatalog,
	observation: Dictionary,
) -> void:
	var rules_rng := PortableRandomSource.new(20260720)
	var rules_rng_state := rules_rng.get_state()
	var seed_a := AIDecisionSeed.derive(99, 12, 1, "action", "ai:12:1")
	var seed_b := AIDecisionSeed.derive(99, 12, 1, "action", "ai:12:1")
	var choice_seed := AIDecisionSeed.derive(
		99, 12, 1, "select_attachment", "ai-choice:12:1")
	_check(
		seed_a == seed_b
		and seed_a == 1356900918
		and seed_a != choice_seed
		and rules_rng.get_state() == rules_rng_state,
		"AI decision seed must be stable without advancing the rules RNG",
	)
	var encoder := AIActionEncoder.new(catalog)
	for request_type in [
		"arven", "clara", "discard_cards", "discard_then_draw",
		"evolve_skip_stage", "hand_bottom_draw", "houb", "look_top",
		"look_top_attach_energy", "search_move", "select_card",
		"shuffle_from_discard", "zinnia", "bench_damage_target",
		"damage_target", "place_counters_self_discard", "select_bench",
		"select_energy_source", "select_energy_target", "select_heal_target",
		"select_opponent_bench", "select_prize_energy_target",
		"select_attachment", "select_retreat_payment",
		"distribute_energy", "confirm", "confirm_trigger", "select_prize",
		"choose_mulligan_draw_count", "choose_turn_order", "coin_flip",
		"choose_trigger_order",
	]:
		_check(
			AIActionEncoder.supports_choice_type(request_type),
			"AI encoder is missing release choice type %s" % request_type,
		)
	var unknown_action := encoder.encode_action(
		observation,
		GameAction.create("UNKNOWN_ACTION", {}, int(observation["perspective"])),
		"water",
	)
	_check(
		str(unknown_action.get("error", "")) == "unknown_action_type:UNKNOWN_ACTION",
		"AI encoder silently accepted an unknown action type",
	)
	var internal_action := encoder.encode_action(
		observation,
		GameAction.create("NOOP", {}, int(observation["perspective"])),
		"water",
	)
	_check(
		str(internal_action.get("error", "")) == "action_not_encodable:NOOP",
		"AI encoder exposed the internal NOOP action",
	)
	var unknown_request := ChoiceView.new(
		"unknown-choice", 0, "unknown_choice", int(observation["perspective"]),
		"unknown", [{"option_id": "unknown:0", "label": "unknown"}],
	)
	var unknown_choice := encoder.encode_choice(
		observation, unknown_request, unknown_request.options[0], 0)
	_check(
		str(unknown_choice.get("error", "")) == "unknown_choice_type:unknown_choice",
		"AI encoder silently accepted an unknown choice type",
	)
	var perspective := int(observation["perspective"])
	var trainer_source := EntityRef.new(
		"card", perspective, "hand", "", 0, "", "sv1-180")
	var own_target_action := GameAction.create(
		"PLAY_TRAINER", {}, perspective, trainer_source,
		EntityRef.new("pokemon", perspective, "", "active", -1, "", "sv2-grex"),
	)
	var opponent_target_action := GameAction.create(
		"PLAY_TRAINER", {}, perspective, trainer_source,
		EntityRef.new(
			"pokemon", 1 - perspective, "", "active", -1, "", "sv2-grex"),
	)
	var own_target_encoded := encoder.encode_action(
		observation, own_target_action, "water")
	var opponent_target_encoded := encoder.encode_action(
		observation, opponent_target_action, "water")
	_check(
		not own_target_encoded.has("error")
		and not opponent_target_encoded.has("error")
		and not _deep_equal(
			own_target_encoded["numeric"], opponent_target_encoded["numeric"]),
		"AI action encoder collapsed target ownership",
	)

	var own_attachment := EntityRef.new(
		"attachment", int(observation["perspective"]), "", "active", 0,
		"energy", "sv1-ener-2")
	var opponent_attachment := EntityRef.new(
		"attachment", 1 - int(observation["perspective"]), "", "active", 0,
		"energy", "sv1-ener-2")
	var next_attachment := EntityRef.new(
		"attachment", int(observation["perspective"]), "", "active", 1,
		"energy", "sv1-ener-2")
	var attachment_request := ChoiceView.new(
		"attachment-choice", 0, "select_attachment", int(observation["perspective"]),
		"attachment",
		[
			{"option_id": "attachment:own:0", "label": "own", "ref": own_attachment.to_dict()},
			{"option_id": "attachment:opponent:0", "label": "opponent", "ref": opponent_attachment.to_dict()},
			{"option_id": "attachment:own:1", "label": "next", "ref": next_attachment.to_dict()},
		],
	)
	var own_encoded := encoder.encode_choice(
		observation, attachment_request, attachment_request.options[0], 0)
	var opponent_encoded := encoder.encode_choice(
		observation, attachment_request, attachment_request.options[1], 0)
	var next_encoded := encoder.encode_choice(
		observation, attachment_request, attachment_request.options[2], 0)
	_check(
		not own_encoded.has("error")
		and not opponent_encoded.has("error")
		and not next_encoded.has("error")
		and not _deep_equal(own_encoded["numeric"], opponent_encoded["numeric"])
		and not _deep_equal(own_encoded["numeric"], next_encoded["numeric"]),
		"AI encoder collapsed target ownership or attachment identity",
	)
	var retreat_state := GameState.new()
	retreat_state.players[0].active = PokemonState.new("svi-chim")
	retreat_state.players[0].active.energy_card_ids = [
		"svi-dtur", "sv1-ener-2", "sv1-ener-2",
	]
	var retreat_options: Array[Dictionary] = []
	for index in range(retreat_state.players[0].active.energy_card_ids.size()):
		var energy_id := retreat_state.players[0].active.energy_card_ids[index]
		retreat_options.append({
			"option_id": "retreat:%d" % index,
			"label": energy_id,
			"ref": EntityRef.new(
				"attachment", 0, "", "active", index, "energy", energy_id
			).to_dict(),
		})
	var retreat_request := ChoiceView.new(
		"retreat-choice", 0, "select_retreat_payment", 0, "retreat",
		retreat_options, 1, retreat_options.size(), false, true,
		{"required_units": 2},
	)
	var dte_response := NativeChallengeAI.retreat_payment_response(
		retreat_state, retreat_request, catalog)
	_check(
		dte_response.option_ids == ["retreat:0"] and not dte_response.cancelled,
		"AI retreat payment did not use one Double Turbo Energy",
	)
	retreat_request.metadata["required_units"] = 3
	var mixed_response := NativeChallengeAI.retreat_payment_response(
		retreat_state, retreat_request, catalog)
	_check(
		mixed_response.option_ids == ["retreat:0", "retreat:1"]
		and not mixed_response.cancelled,
		"AI retreat payment was not inclusion-minimal for mixed energy units",
	)
	retreat_request.metadata["required_units"] = 5
	var insufficient_response := NativeChallengeAI.retreat_payment_response(
		retreat_state, retreat_request, catalog)
	_check(
		insufficient_response.cancelled and insufficient_response.option_ids.is_empty(),
		"AI retreat payment did not cancel an impossible payment",
	)

	var coordinator := NonCooperativeAICoordinator.new()
	var request := {
		"kind": "action",
		"request_id": "generation:1",
		"revision": 1,
		"coordinator_timeout_msec": 50,
	}
	_check(coordinator.start_request(request), "AI coordinator test worker did not start")
	var cancel_started := Time.get_ticks_msec()
	coordinator.cancel_request()
	_check(
		Time.get_ticks_msec() - cancel_started < 50,
		"AI coordinator cancellation blocked on a live worker",
	)
	var restart_started := Time.get_ticks_msec()
	var restarted_while_busy := coordinator.start_request(request)
	_check(
		not restarted_while_busy
		and coordinator.last_start_error == "previous_request_running"
		and Time.get_ticks_msec() - restart_started < 50,
		"AI coordinator restart blocked on a stale worker",
	)
	var reap_deadline := Time.get_ticks_msec() + 1000
	var stale_result: Dictionary = {}
	while coordinator.needs_poll() and Time.get_ticks_msec() < reap_deadline:
		var cancelled_poll := coordinator.poll_result()
		if not cancelled_poll.is_empty():
			stale_result = cancelled_poll
		OS.delay_msec(1)
	_check(
		not coordinator.needs_poll() and stale_result.is_empty(),
		"Cancelled AI worker was not reaped or leaked a stale result",
	)

	request["request_id"] = "generation:2"
	_check(coordinator.start_request(request), "AI coordinator did not start a new generation")
	OS.delay_msec(55)
	var in_flight_result := coordinator.poll_result()
	_check(
		in_flight_result.is_empty() and coordinator.needs_poll(),
		"AI coordinator imposed a device-dependent deadline on an active search",
	)
	reap_deadline = Time.get_ticks_msec() + 1000
	var completed_result: Dictionary = {}
	while completed_result.is_empty() and Time.get_ticks_msec() < reap_deadline:
		completed_result = coordinator.poll_result()
		OS.delay_msec(1)
	_check(
		not coordinator.needs_poll()
		and completed_result.get("success", false)
		and str(completed_result.get("request_id", "")) == "generation:2"
		and not completed_result.has("error")
		and rules_rng.get_state() == rules_rng_state,
		"AI coordinator did not return and reap a fixed-work search safely",
	)
	var terminating_coordinator := TerminatingAICoordinator.new()
	request["request_id"] = "generation:terminated"
	_check(
		terminating_coordinator.start_request(request),
		"Terminating AI coordinator test worker did not start",
	)
	var terminated_result: Dictionary = {}
	reap_deadline = Time.get_ticks_msec() + 1000
	while terminated_result.is_empty() and Time.get_ticks_msec() < reap_deadline:
		terminated_result = terminating_coordinator.poll_result()
		OS.delay_msec(1)
	_check(
		str(terminated_result.get("error", ""))
		== "worker_terminated_without_result"
		and not terminating_coordinator.needs_poll(),
		"AI coordinator did not reap a task that exited without a result",
	)
	_run_deep_root_contract_tests(catalog)


func _run_deep_root_contract_tests(_catalog: CardCatalog) -> void:
	_check(
		DeepRootISMCTS.PLANNER_ID == "infoset_puct_v2"
		and DeepRootISMCTS.SCHEMA_VERSION == 2
		and is_equal_approx(DeepRootISMCTS.C_PUCT, 1.4)
		and DeepRootISMCTS.WINDOWS_MIN_SIMULATIONS == 32
		and DeepRootISMCTS.WINDOWS_TARGET_SIMULATIONS == 128
		and DeepRootISMCTS.WINDOWS_MAX_SIMULATIONS == 256
		and DeepRootISMCTS.WINDOWS_LEAF_BATCH_SIZE == 8
		and DeepRootISMCTS.ANDROID_MIN_SIMULATIONS == 16
		and DeepRootISMCTS.ANDROID_TARGET_SIMULATIONS == 64
		and DeepRootISMCTS.ANDROID_MAX_SIMULATIONS == 128
		and DeepRootISMCTS.ANDROID_LEAF_BATCH_SIZE == 4
		and DeepRootISMCTS.WATCHDOG_USEC == 2000000,
		"Information-set PUCT constants differ from the release contract",
	)
	var state := GameState.new()
	state.public_deck_keys = ["fire", "water"]
	var fallback := AICoordinator.new().decide_sync_for_evaluation(
		{
			"kind": "action",
			"mode": "deep",
			"engine": "turn_beam_v2",
			"state": state.to_dict(),
			"actor": 0,
			"revision": 0,
			"request_id": "deep-fallback-contract",
			"deck_key": "fire",
			"actions": [],
		},
		null,
	)
	_check(
		bool(fallback.get("deep_fallback", false))
		and str(fallback.get("fallback_reason", ""))
		== "runtime_unavailable"
		and str(Dictionary(fallback.get("deep_failure", {})).get(
			"planner", "")) == DeepRootISMCTS.PLANNER_ID,
		"Deep runtime failure did not produce the structured Challenge fallback",
	)


func _run_ai_strength_regression_tests(
	catalog: CardCatalog,
	_engine: GameEngine,
	worker: NativeChallengeAI,
) -> void:
	var strongest_preset := NativeChallengeAI.strongest_preset()
	_check(
		int(strongest_preset.get("depth", 0))
		== NativeChallengeAI.GAMEPLAY_DEFAULT_DEPTH
		and not strongest_preset.has("seconds")
		and not strongest_preset.has("simulations")
		and not strongest_preset.has("dynamic_budget"),
		"Challenge AI preset exposed a time or simulation strength control",
	)
	_check(ClassDB.class_exists("ChallengeAIMath"), "ChallengeAIMath GDExtension class is unavailable")
	_test_ai_damage_counter_scoring_uses_ten_hp_units(catalog)
	_test_ai_optional_choice_selects_positive_options_to_max(catalog)
	_test_fire_choice_search_follows_executable_evolution_chain()
	_test_ai_planner_candidate_kind_diversity()
	_test_ai_random_event_invalidates_plan_cache()
	_test_ai_complete_leaf_beats_incomparable_partial()
	_test_ai_cached_action_passes_post_plan_tactical_guard(catalog, _engine, worker)
	_test_ai_cached_self_cost_ability_passes_post_plan_tactical_guard(
		catalog, _engine, worker)
	_test_ai_self_discard_scoring_uses_counter_units_and_source_slot(catalog, worker)
	_test_ai_mandatory_tactics_establishes_backup_before_ordinary_attack(
		catalog, _engine)
	_test_ai_mandatory_tactics_immediate_match_win_beats_backup(catalog, _engine)
	_test_ai_adaptive_belief_samples_follow_random_semantics(catalog)
	_test_ai_public_attack_profile_values_energy_and_readiness(catalog)
	_test_ai_public_attack_profile_status_gates(catalog)
	_test_ai_fixed_replan_profile_and_scope(catalog, worker)

	var ko_state := GameState.new()
	ko_state.phase = "MAIN"
	ko_state.turn_number = 5
	ko_state.first_player_idx = 1
	ko_state.active_player_idx = 0
	ko_state.public_deck_keys = ["lightning", "water"]
	ko_state.players[0].active = PokemonState.new("svl-zera")
	ko_state.players[0].active.placed_this_turn = false
	ko_state.players[0].active.energy_card_ids.assign(["sv1-ener-4", "sv1-ener-4"])
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
	var ko_plain_result := _ai_decision_result_for_actions(worker, ko_state, 0, "lightning", [
		GameAction.new("END_TURN", {}, true, 0),
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
	], "ko-profile-off", false)
	var ko_profile_result := _ai_decision_result_for_actions(worker, ko_state, 0, "lightning", [
		GameAction.new("END_TURN", {}, true, 0),
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
	], "ko-profile-on", true)
	_check(
		ko_plain_result.get("success", false)
		and ko_profile_result.get("success", false)
		and ko_plain_result.get("action", {}) == ko_profile_result.get("action", {}),
		"AI profile instrumentation changed the selected action",
	)
	_check(
		ko_profile_result.has("profile")
		and Dictionary(ko_profile_result.get("profile", {})).has("segments_ms"),
		"AI profile instrumentation did not return profile segments",
	)
	var diagnostic_engine := GameEngine.new()
	var diagnostic_end := diagnostic_engine._canonicalize_action(
		ko_state, GameAction.new("END_TURN", {}, true, 0), 0)
	var diagnostic_attack := diagnostic_engine._canonicalize_action(
		ko_state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		0,
	)
	var ko_diagnostic_actions: Array[GameAction] = [
		diagnostic_end,
		diagnostic_attack,
	]
	var ko_diagnostics := worker.diagnose_decision(
		ko_state,
		0,
		diagnostic_end,
		ko_diagnostic_actions,
		"lightning",
		catalog,
		_engine,
		20260702,
	)
	_check(
		int(ko_diagnostics.get("missed_immediate_ko", 0)) == 1,
		"AI diagnostic interface did not flag a missed immediate KO",
	)

	var eval_state := GameState.new()
	eval_state.phase = "MAIN"
	eval_state.turn_number = 6
	eval_state.active_player_idx = 0
	eval_state.public_deck_keys = ["lightning", "water"]
	eval_state.players[0].active = PokemonState.new("svl-zera")
	eval_state.players[0].active.energy_card_ids.assign(["sv1-ener-4", "sv1-ener-4"])
	eval_state.players[0].bench[0] = PokemonState.new("svl-pikaex")
	eval_state.players[0].bench[0].energy_card_ids.assign(["sv1-ener-4"])
	eval_state.players[0].hand = ["sv1-ener-4", "svl-flaa2"]
	eval_state.players[0].deck = ["sv1-ener-4", "sv1-ener-4", "svl-mareep"]
	eval_state.players[0].prizes = ["sv1-ener-4", "sv1-ener-4", "sv1-ener-4"]
	eval_state.players[1].active = PokemonState.new("sv2-grex")
	eval_state.players[1].active.damage_counters = 3
	eval_state.players[1].active.energy_card_ids.assign(["sv1-ener-3"])
	eval_state.players[1].bench[0] = PokemonState.new("sv2-39")
	eval_state.players[1].hand = ["sv1-ener-3"]
	eval_state.players[1].deck = ["sv1-ener-3", "sv1-ener-3"]
	eval_state.players[1].prizes = ["sv1-ener-3", "sv1-ener-3", "sv1-ener-3", "sv1-ener-3"]
	var gdscript_eval := worker._evaluate_raw_gdscript(eval_state, 0, catalog)
	var native_eval := worker._evaluate_raw(eval_state, 0, catalog)
	_check(
		is_equal_approx(
			native_eval - worker._strategic_evaluation_delta(eval_state, 0, catalog),
			gdscript_eval,
		),
		"ChallengeAIMath native evaluation differs from GDScript fallback",
	)

	var semantic_risk_state := GameState.new()
	semantic_risk_state.phase = "MAIN"
	semantic_risk_state.turn_number = 7
	semantic_risk_state.active_player_idx = 0
	semantic_risk_state.public_deck_keys = ["water", "lightning"]
	semantic_risk_state.players[0].active = PokemonState.new("sv2-delib")
	semantic_risk_state.players[0].active.energy_card_ids.assign(["sv1-ener-3"])
	semantic_risk_state.players[0].deck = [
		"sv1-ener-3", "sv1-ener-3", "sv2-38", "sv2-39",
		"sv2-cand", "sv2-staryu", "sv1-152", "sv1-153",
	]
	semantic_risk_state.players[1].active = PokemonState.new("svl-pikaex")
	semantic_risk_state.players[1].active.energy_card_ids.assign([
		"sv1-ener-4", "sv1-ener-4", "sv1-ener-4",
	])
	semantic_risk_state.players[1].deck = [
		"sv1-ener-4", "sv1-ener-4", "svl-mare2", "svl-flaa2",
	]
	var semantic_safe_state := GameState.from_dict(semantic_risk_state.snapshot())
	semantic_safe_state.players[1].active.energy_card_ids.clear()
	var semantic_locked_state := GameState.from_dict(semantic_risk_state.snapshot())
	_set_test_attack_lock(semantic_locked_state, 1)
	var semantic_protected_state := GameState.from_dict(semantic_risk_state.snapshot())
	_set_test_prevention(semantic_protected_state, 0, true, false)
	var semantic_thin_deck_state := GameState.from_dict(semantic_safe_state.snapshot())
	semantic_thin_deck_state.players[0].deck = ["sv1-ener-3"]
	var semantic_risk_score := worker._evaluate_raw(semantic_risk_state, 0, catalog)
	var semantic_safe_score := worker._evaluate_raw(semantic_safe_state, 0, catalog)
	var semantic_locked_score := worker._evaluate_raw(semantic_locked_state, 0, catalog)
	var semantic_protected_score := worker._evaluate_raw(semantic_protected_state, 0, catalog)
	var semantic_thin_deck_score := worker._evaluate_raw(semantic_thin_deck_state, 0, catalog)
	_check(
		semantic_safe_score > semantic_risk_score + 120.0,
		"Semantic v2 evaluation did not penalize immediate next-turn KO risk",
	)
	_check(
		semantic_locked_score > semantic_risk_score + 80.0,
		"Semantic v2 evaluation did not value attack locks against a ready threat",
	)
	_check(
		semantic_protected_score > semantic_risk_score + 60.0,
		"Semantic v2 evaluation did not value next-turn damage prevention",
	)
	_check(
		semantic_safe_score > semantic_thin_deck_score + 80.0,
		"Semantic v2 evaluation did not penalize dangerous deck pressure",
	)
	var semantic_variant_result := _ai_decision_result_for_actions(
		worker, ko_state, 0, "lightning", [
			GameAction.new("END_TURN", {}, true, 0),
			GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		], "semantic-variant-plumbing", false, NativeChallengeAI.HEURISTIC_VARIANT_SEMANTIC_V2)
	_check(
		semantic_variant_result.get("heuristic_variant", "") == NativeChallengeAI.HEURISTIC_VARIANT_SEMANTIC_V2,
		"AI request did not preserve the semantic_v2 heuristic variant",
	)
	var semantic_choice_state := GameState.new()
	semantic_choice_state.phase = "MAIN"
	semantic_choice_state.public_deck_keys = ["psychic", "water"]
	semantic_choice_state.players[0].active = PokemonState.new("sv1-113")
	semantic_choice_state.players[0].active.energy_card_ids.clear()
	semantic_choice_state.players[0].deck = ["sv1-180", "sv1-ener-5"]
	var semantic_choice_stack := ResolutionStack.new()
	VMChoiceRequests.request_cards(
		catalog,
		semantic_choice_state,
		semantic_choice_stack,
		0,
		"deck",
		semantic_choice_state.players[0].deck,
		"search_move",
		{
			"player_idx": 0,
			"source_zone": "deck",
			"destination": "hand",
			"shuffle": false,
		},
		0,
		1,
		"Choose optional search target.",
		true,
	)
	semantic_choice_state.resolution_stack = semantic_choice_stack.to_dict()
	var semantic_choice_response := _ai_choice_for_request(
		worker,
		semantic_choice_state,
		0,
		"psychic",
		semantic_choice_stack.pending_request,
		"semantic-choice-lookahead",
		NativeChallengeAI.HEURISTIC_VARIANT_SEMANTIC_V2,
	)
	_check(
		semantic_choice_response != null
		and not semantic_choice_response.cancelled
		and semantic_choice_response.option_ids.size() == 1
		and semantic_choice_response.option_ids[0].ends_with(":sv1-ener-5"),
		"Semantic v2 choice lookahead did not select the missing energy search target: %s" % [
			JSON.stringify(semantic_choice_response.to_dict() if semantic_choice_response != null else {})
		],
	)
	var colorless_draw_plan_state := GameState.new()
	colorless_draw_plan_state.public_deck_keys = ["colorless", "psychic"]
	colorless_draw_plan_state.players[0].active = PokemonState.new("svi-ambi")
	colorless_draw_plan_state.players[0].active.energy_card_ids = ["svi-dtur", "svi-mirc"]
	colorless_draw_plan_state.players[0].hand = [
		"sv1-180", "sv1-180", "sv1-151", "sv1-153",
		"svi-tand", "svi-maus", "svi-dtur", "svi-jete",
	]
	colorless_draw_plan_state.players[0].deck = [
		"svi-gree", "svi-aipo", "sv1-151", "sv1-153", "svi-dtur", "svi-mirc",
	]
	_check(
		worker._semantic_draw_value(colorless_draw_plan_state, 0, 2, false, "colorless", catalog) > 60.0,
		"Semantic v2 undervalued draw while a colorless hand-size attack plan was online",
	)
	var psychic_discard_plan_state := GameState.new()
	psychic_discard_plan_state.public_deck_keys = ["psychic", "water"]
	psychic_discard_plan_state.players[0].active = PokemonState.new("sv1-113")
	psychic_discard_plan_state.players[0].hand = ["sv1-107", "sv1-107", "sv1-180"]
	psychic_discard_plan_state.players[0].deck = ["sv1-106"]
	var duplicate_psychic_discard := worker._discard_choice_score(
		psychic_discard_plan_state, 0, "sv1-107", "psychic", catalog)
	var draw_trainer_discard := worker._discard_choice_score(
		psychic_discard_plan_state, 0, "sv1-180", "psychic", catalog)
	var water_line_state := GameState.new()
	water_line_state.public_deck_keys = ["water", "psychic"]
	water_line_state.players[0].active = PokemonState.new("sv2-delib")
	water_line_state.players[0].hand = ["sv2-grex", "sv2-38"]
	water_line_state.players[0].deck = ["sv2-39", "sv1-ener-3"]
	var froakie_keep := worker._card_keep_value(
		water_line_state, 0, "sv2-38", "water", catalog)
	var naked_greninja_keep := worker._card_keep_value(
		water_line_state, 0, "sv2-grex", "water", catalog)
	var water_ready_line_state := water_line_state.clone_state()
	water_ready_line_state.players[0].bench[0] = PokemonState.new("sv2-39")
	var ready_greninja_keep := worker._card_keep_value(
		water_ready_line_state, 0, "sv2-grex", "water", catalog)
	var thin_deck_draw_state := GameState.new()
	thin_deck_draw_state.public_deck_keys = ["water", "psychic"]
	thin_deck_draw_state.players[0].active = PokemonState.new("sv2-delib")
	thin_deck_draw_state.players[0].hand = [
		"sv1-151", "sv1-152", "sv1-153", "sv2-catch", "sv2-cand", "sv2-38",
	]
	thin_deck_draw_state.players[0].deck = [
		"sv1-ener-3", "sv1-ener-3", "sv2-38", "sv2-39", "sv2-staryu", "sv2-starm",
	]
	var thin_draw_value := worker._semantic_draw_value(
		thin_deck_draw_state, 0, 3, false, "water", catalog)
	var bench_search_state := GameState.new()
	bench_search_state.public_deck_keys = ["fighting", "water"]
	bench_search_state.players[0].active = PokemonState.new("svf-rio")
	bench_search_state.players[0].hand = ["sv1-151", "sv1-176", "sv1-153"]
	bench_search_state.players[0].deck = ["svf-pass", "svf-rio", "svf-scyt", "sv1-ener-6"]
	var nest_ball_discard := worker._discard_choice_score(
		bench_search_state, 0, "sv1-151", "fighting", catalog)
	var judge_discard := worker._discard_choice_score(
		bench_search_state, 0, "sv1-176", "fighting", catalog)
	var fighting_line_focus_state := GameState.new()
	fighting_line_focus_state.public_deck_keys = ["fighting", "water"]
	fighting_line_focus_state.players[0].active = PokemonState.new("svf-scyt")
	fighting_line_focus_state.players[0].bench[0] = PokemonState.new("svf-rio")
	fighting_line_focus_state.players[0].hand = ["svf-luca", "svf-klea"]
	fighting_line_focus_state.players[0].deck = ["svf-rio", "svf-scyt", "sv1-ener-6"]
	var lucario_keep := worker._card_keep_value(
		fighting_line_focus_state, 0, "svf-luca", "fighting", catalog)
	var kleavor_keep := worker._card_keep_value(
		fighting_line_focus_state, 0, "svf-klea", "fighting", catalog)
	var lone_kleavor_state := GameState.new()
	lone_kleavor_state.public_deck_keys = ["fighting", "water"]
	lone_kleavor_state.players[0].active = PokemonState.new("svf-klea")
	lone_kleavor_state.players[0].deck = ["svf-rio", "svf-klea", "sv1-ener-6"]
	var safe_backup_bonus := worker._lone_active_backup_search_bonus(
		lone_kleavor_state, 0, catalog)
	var threatened_kleavor_state := lone_kleavor_state.clone_state()
	threatened_kleavor_state.players[1].active = PokemonState.new("svi-infr")
	threatened_kleavor_state.players[1].active.energy_card_ids = [
		"sv1-ener-2", "sv1-ener-2",
	]
	var threatened_backup_bonus := worker._lone_active_backup_search_bonus(
		threatened_kleavor_state, 0, catalog)
	var survival_riolu_keep := worker._card_keep_value(
		threatened_kleavor_state, 0, "svf-rio", "fighting", catalog)
	var stranded_kleavor_keep := worker._card_keep_value(
		threatened_kleavor_state, 0, "svf-klea", "fighting", catalog)
	var lucario_evolve_value := worker._development_action_value(
		fighting_line_focus_state,
		0,
		GameAction.new("EVOLVE", {"hand_idx": 0, "slot": "bench_0"}, false, 0),
		"fighting",
		catalog,
	)
	var kleavor_active_evolve_value := worker._development_action_value(
		fighting_line_focus_state,
		0,
		GameAction.new("EVOLVE", {"hand_idx": 1, "slot": "active"}, false, 0),
		"fighting",
		catalog,
	)
	var steel_relocate_source_state := GameState.new()
	steel_relocate_source_state.public_deck_keys = ["steel", "water"]
	steel_relocate_source_state.players[0].active = PokemonState.new("svm-zacian")
	steel_relocate_source_state.players[0].active.energy_card_ids.assign([
		"sv1-ener-8", "sv1-ener-8",
	])
	steel_relocate_source_state.players[0].bench[0] = PokemonState.new("svm-smeargle")
	steel_relocate_source_state.players[0].bench[0].energy_card_ids.assign([
		"sv1-ener-8", "sv1-ener-8",
	])
	var steel_source_context := {"energy_type": "Metal"}
	var steel_smeargle_source := worker._energy_source_choice_value(
		steel_relocate_source_state,
		0,
		"bench_0",
		steel_source_context,
		"steel",
		catalog,
	)
	var steel_zacian_source := worker._energy_source_choice_value(
		steel_relocate_source_state,
		0,
		"active",
		steel_source_context,
		"steel",
		catalog,
	)
	_check(
		duplicate_psychic_discard > draw_trainer_discard,
		"Semantic v2 discard choice did not recognize duplicate Psychic Pokemon as discard-damage fuel: %.3f <= %.3f" % [
			duplicate_psychic_discard, draw_trainer_discard,
		],
	)
	_check(
		froakie_keep > naked_greninja_keep,
		"Semantic v2 search keep value preferred a naked Stage 2 core over its missing basic",
	)
	_check(
		ready_greninja_keep > naked_greninja_keep + 120.0,
		"Semantic v2 did not raise Stage 2 core value after the Stage 1 prerequisite was in play",
	)
	_check(
		thin_draw_value < 0.0,
		"Semantic v2 undervalued thin-deck pressure for draw effects",
	)
	_check(
		nest_ball_discard < judge_discard,
		"Semantic v2 discard choice did not protect basic bench search while the bench was empty",
	)
	_check(
		lucario_keep > kleavor_keep + 40.0,
		"Semantic v2 fighting line focus allowed Kleavor to outrank Lucario while Riolu was available",
	)
	_check(
		survival_riolu_keep > stranded_kleavor_keep + 200.0,
		"Semantic v2 search failed to prioritize a Basic backup for a lone Active",
	)
	_check(
		is_equal_approx(safe_backup_bonus, 80.0)
		and is_equal_approx(
			threatened_backup_bonus,
			float(NativeChallengeAI.SCORE_WEIGHTS["lone_active_backup"]),
		),
		"Semantic v2 applied emergency lone-Active search weight without a public KO threat",
	)
	_check(
		lucario_evolve_value > kleavor_active_evolve_value + 80.0,
		"Semantic v2 active side-core evolve value still blocked the Lucario line",
	)
	_check(
		steel_smeargle_source > steel_zacian_source + 120.0,
		"Semantic v2 metal relocation source choice still strips energy from a ready Zacian",
	)

	var safe_damage_state := GameState.new()
	safe_damage_state.phase = "MAIN"
	safe_damage_state.setup_stage = GameState.SETUP_COMPLETE
	safe_damage_state.turn_number = 5
	safe_damage_state.first_player_idx = 1
	safe_damage_state.active_player_idx = 0
	safe_damage_state.public_deck_keys = ["darkness", "lightning"]
	safe_damage_state.players[0].active = PokemonState.new("svd-maschiff")
	safe_damage_state.players[0].active.placed_this_turn = false
	safe_damage_state.players[0].active.energy_card_ids.assign(["sv1-ener-7", "sv1-ener-7"])
	safe_damage_state.players[1].active = PokemonState.new("svl-pikaex")
	safe_damage_state.players[1].active.placed_this_turn = false
	var safe_damage_end: GameAction = null
	var safe_damage_attack: GameAction = null
	for legal_action in RulesTestHarness.legal_actions(
		_engine, safe_damage_state, 0, false):
		if legal_action.kind == "END_TURN":
			safe_damage_end = legal_action
		elif (
			legal_action.kind == "DECLARE_ATTACK"
			and int(legal_action.payload.get("attack_index", -1)) == 0
		):
			safe_damage_attack = legal_action
	_check(
		safe_damage_end != null and safe_damage_attack != null,
		"Safe-damage fallback fixture did not expose strict v4 End/Attack actions",
	)
	if safe_damage_end != null and safe_damage_attack != null:
		var safe_damage_actions: Array[GameAction] = [
			safe_damage_end, safe_damage_attack,
		]
		var safe_damage_attack_loses := worker._action_immediately_loses_match(
			safe_damage_state, 0, safe_damage_attack, "darkness", catalog, _engine, 20260631)
		var safe_damage_attack_executes := worker._action_executes_successfully(
			safe_damage_state, 0, safe_damage_attack, "darkness", catalog, _engine, 20260632)
		var damaging_fallback := worker._validated_or_fallback_action(
			safe_damage_state,
			0,
			safe_damage_end,
			safe_damage_actions,
			"darkness",
			catalog,
			_engine,
			20260630,
		)
		_check(
			damaging_fallback != null and damaging_fallback.action == "DECLARE_ATTACK",
			(
				"AI fallback ended the turn instead of taking a safe damaging attack; "
				+ "immediate_loss=%s executes=%s selected=%s"
			) % [
				str(safe_damage_attack_loses),
				str(safe_damage_attack_executes),
				JSON.stringify(
					damaging_fallback.to_dict() if damaging_fallback != null else null),
			],
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
	energy_state.players[1].active.energy_card_ids.assign(["sv1-ener-4"])
	energy_state.players[1].hand = ["sv1-ener-4"]
	var weak_attack_action := GameAction.new(
		"DECLARE_ATTACK", {"attack_idx": 0}, true, 1)
	var active_attach_action := GameAction.new(
		"ATTACH_ENERGY", {"hand_idx": 0, "target_slot": "active"}, false, 1)
	_check(
		worker._traditional_action_candidate_score(
			energy_state, 1, active_attach_action, "lightning", catalog)
		> worker._traditional_action_candidate_score(
			energy_state, 1, weak_attack_action, "lightning", catalog),
		"Traditional beam candidate scorer disagreed with the weak-attack tactical guard",
	)
	var energy_action := _ai_decision_for_actions(worker, energy_state, 1, "lightning", [
		weak_attack_action,
		active_attach_action,
		GameAction.new("END_TURN", {}, true, 1),
	], "weak-attack-before-energy")
	_check(
		energy_action != null
		and energy_action.action == "ATTACH_ENERGY"
		and str(energy_action.params.get("target_slot", "")) == "active",
		"AI fallback did not delay a weak attack for obvious core energy; actual=%s"
		% JSON.stringify(energy_action.to_dict() if energy_action != null else null),
	)

	var bench_energy_state := GameState.new()
	bench_energy_state.phase = "MAIN"
	bench_energy_state.turn_number = 5
	bench_energy_state.first_player_idx = 0
	bench_energy_state.active_player_idx = 1
	bench_energy_state.public_deck_keys = ["water", "lightning"]
	bench_energy_state.players[0].active = PokemonState.new("sv2-delib")
	bench_energy_state.players[0].active.placed_this_turn = false
	bench_energy_state.players[1].active = PokemonState.new("svl-chat")
	bench_energy_state.players[1].active.placed_this_turn = false
	bench_energy_state.players[1].bench[0] = PokemonState.new("svl-pikaex")
	bench_energy_state.players[1].bench[0].placed_this_turn = false
	bench_energy_state.players[1].bench[0].energy_card_ids.assign(["sv1-ener-4"])
	bench_energy_state.players[1].hand = ["sv1-ener-4"]
	var bench_energy_action := _ai_decision_for_actions(worker, bench_energy_state, 1, "lightning", [
		GameAction.new("ATTACH_ENERGY", {"hand_idx": 0, "target_slot": "active"}, false, 1),
		GameAction.new("ATTACH_ENERGY", {"hand_idx": 0, "target_slot": "bench_0"}, false, 1),
		GameAction.new("END_TURN", {}, true, 1),
	], "bench-core-energy-plan")
	_check(
		bench_energy_action != null
		and bench_energy_action.action == "ATTACH_ENERGY"
		and str(bench_energy_action.params.get("target_slot", "")) == "bench_0",
		"AI energy plan attached to a low-value active instead of the core attacker; actual=%s"
		% JSON.stringify(bench_energy_action.to_dict() if bench_energy_action != null else null),
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
		"AI fallback did not spend obvious energy before a major hand refresh; actual=%s"
		% JSON.stringify(major_draw_action.to_dict() if major_draw_action != null else null),
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
		"AI fallback did not use a productive ability before ending turn; actual=%s"
		% JSON.stringify(ability_action.to_dict() if ability_action != null else null),
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

	var setup_lightning := GameState.new()
	setup_lightning.phase = "SETUP"
	setup_lightning.active_player_idx = 0
	setup_lightning.first_player_idx = 0
	setup_lightning.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	setup_lightning.setup_actor_idx = 0
	setup_lightning.public_deck_keys = ["lightning", "water"]
	setup_lightning.players[0].hand = ["svl-pikaex", "svl-thun", "svl-emol"]
	var setup_lightning_action := _ai_decision_for_actions(worker, setup_lightning, 0, "lightning", [
		GameAction.new("PLAY_BASIC", {"hand_idx": 0, "target": "active"}, false, 0),
		GameAction.new("PLAY_BASIC", {"hand_idx": 1, "target": "active"}, false, 0),
		GameAction.new("PLAY_BASIC", {"hand_idx": 2, "target": "active"}, false, 0),
	], "setup-lightning-active")
	_check(
		setup_lightning_action != null
		and int(setup_lightning_action.params.get("hand_idx", -1)) != 0,
		"AI setup chose lightning bench core Pikachu ex as active over setup pivots; actual=%s"
		% JSON.stringify(setup_lightning_action.to_dict() if setup_lightning_action != null else null),
	)

	var setup_water := GameState.new()
	setup_water.phase = "SETUP"
	setup_water.active_player_idx = 0
	# Tatsugiri's setup pivot is specifically a going-second route: its first
	# attack can then convert the opening attachment into two more Energy.
	setup_water.first_player_idx = 1
	setup_water.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	setup_water.setup_actor_idx = 0
	setup_water.public_deck_keys = ["water", "steel"]
	setup_water.players[0].hand = ["sv2-tatsu", "sv2-staryu", "sv2-38"]
	var setup_water_action := _ai_decision_for_actions(worker, setup_water, 0, "water", [
		GameAction.new("PLAY_BASIC", {"hand_idx": 0, "target": "active"}, false, 0),
		GameAction.new("PLAY_BASIC", {"hand_idx": 1, "target": "active"}, false, 0),
		GameAction.new("PLAY_BASIC", {"hand_idx": 2, "target": "active"}, false, 0),
	], "setup-water-active")
	_check(
		setup_water_action != null
		and int(setup_water_action.params.get("hand_idx", -1)) == 0,
		"AI setup did not choose Tatsugiri over Staryu/Froakie; actual=%s"
		% JSON.stringify(setup_water_action.to_dict() if setup_water_action != null else null),
	)

	var setup_fighting := GameState.new()
	setup_fighting.phase = "SETUP"
	setup_fighting.active_player_idx = 0
	setup_fighting.first_player_idx = 0
	setup_fighting.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	setup_fighting.setup_actor_idx = 0
	setup_fighting.public_deck_keys = ["fighting", "water"]
	setup_fighting.players[0].hand = ["svf-rio", "svf-farf", "svf-hawl"]
	var setup_fighting_action := _ai_decision_for_actions(worker, setup_fighting, 0, "fighting", [
		GameAction.new("PLAY_BASIC", {"hand_idx": 0, "target": "active"}, false, 0),
		GameAction.new("PLAY_BASIC", {"hand_idx": 1, "target": "active"}, false, 0),
		GameAction.new("PLAY_BASIC", {"hand_idx": 2, "target": "active"}, false, 0),
	], "setup-fighting-active")
	_check(
		setup_fighting_action != null
		and int(setup_fighting_action.params.get("hand_idx", -1)) != 0,
		"AI setup chose Riolu active when fighting setup pivots were available; actual=%s"
		% JSON.stringify(setup_fighting_action.to_dict() if setup_fighting_action != null else null),
	)

	var setup_psychic := GameState.new()
	setup_psychic.phase = "SETUP"
	setup_psychic.active_player_idx = 0
	setup_psychic.first_player_idx = 0
	setup_psychic.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	setup_psychic.setup_actor_idx = 0
	setup_psychic.public_deck_keys = ["psychic", "water"]
	setup_psychic.players[0].hand = ["sv1-107", "sv1-111", "sv1-113"]
	var setup_psychic_action := _ai_decision_for_actions(worker, setup_psychic, 0, "psychic", [
		GameAction.new("PLAY_BASIC", {"hand_idx": 0, "target": "active"}, false, 0),
		GameAction.new("PLAY_BASIC", {"hand_idx": 1, "target": "active"}, false, 0),
		GameAction.new("PLAY_BASIC", {"hand_idx": 2, "target": "active"}, false, 0),
	], "setup-psychic-active")
	_check(
		setup_psychic_action != null
		and int(setup_psychic_action.params.get("hand_idx", -1)) == 2,
		"AI setup did not choose the psychic setup pivot over Natu/Latios",
	)

	var houb_state := GameState.new()
	houb_state.public_deck_keys = ["fighting", "water"]
	houb_state.players[0].active = PokemonState.new("svf-farf")
	houb_state.players[0].hand = ["svf-luca", "svf-rio", "sv1-ener-1", "sv1-ener-1"]
	var houb_request := ChoiceRequest.new(
		"choice:houb", "houb", 0, "Choose one card to bottom.",
		_ai_choice_options_for_zone(catalog, houb_state, 0, "hand"),
		1, 1, false, false, {"domain": "effect", "purpose": "houb"})
	var houb_response := _ai_choice_for_request(
		worker, houb_state, 0, "fighting", houb_request, "houb-discard-cost")
	_check(
		houb_response != null
		and houb_response.option_ids.size() == 1
		and houb_response.option_ids[0].ends_with(":sv1-ener-1"),
		"AI houb choice did not prefer duplicate off-plan energy over core/evolution cards",
	)

	var zinnia_state := GameState.new()
	zinnia_state.public_deck_keys = ["fighting", "water"]
	zinnia_state.players[0].active = PokemonState.new("svf-farf")
	zinnia_state.players[0].hand = ["svf-luca", "svf-rio", "sv1-ener-1", "sv1-ener-1", "svf-potion"]
	var zinnia_request := ChoiceRequest.new(
		"choice:zinnia", "zinnia", 0, "Choose two cards to discard.",
		_ai_choice_options_for_zone(catalog, zinnia_state, 0, "hand"),
		2, 2, false, false, {"domain": "effect", "purpose": "zinnia"})
	var zinnia_response := _ai_choice_for_request(
		worker, zinnia_state, 0, "fighting", zinnia_request, "zinnia-discard-cost")
	_check(
		zinnia_response != null
		and zinnia_response.option_ids.size() == 2
		and not zinnia_response.option_ids.has("card:hand:0:svf-luca")
		and not zinnia_response.option_ids.has("card:hand:1:svf-rio"),
		"AI zinnia discard selected unique fighting core or evolution setup cards",
	)

	var arven_state := GameState.new()
	arven_state.public_deck_keys = ["psychic", "water"]
	arven_state.players[0].deck = ["sv1-151", "sv1-152", "sv1-201", "sv1-202"]
	var arven_request := ChoiceRequest.new(
		"choice:arven", "arven", 0, "Choose an item and a tool.",
		_ai_choice_options_for_zone(catalog, arven_state, 0, "deck"),
		1, 2, false, false, {"domain": "effect", "purpose": "arven"})
	var arven_response := _ai_choice_for_request(
		worker, arven_state, 0, "psychic", arven_request, "arven-item-tool")
	var arven_item_count := 0
	var arven_tool_count := 0
	if arven_response != null:
		for option_id in arven_response.option_ids:
			var parts := str(option_id).split(":")
			var selected_card_id := str(parts[parts.size() - 1])
			if catalog.is_item(selected_card_id):
				arven_item_count += 1
			if catalog.is_tool(selected_card_id):
				arven_tool_count += 1
	_check(
		arven_response != null
		and arven_response.option_ids.size() == 2
		and arven_item_count == 1
		and arven_tool_count == 1,
		"AI arven choice did not limit selection to one item and one Pokemon tool",
	)

	var optional_state := GameState.new()
	optional_state.public_deck_keys = ["psychic", "water"]
	optional_state.players[0].hand = ["sv1-ener-1"]
	var optional_request := ChoiceRequest.new(
		"choice:optional", "search_move", 0, "Choose optional card.",
		_ai_choice_options_for_zone(catalog, optional_state, 0, "hand"),
		0, 1, false, true, {"domain": "effect", "purpose": "search_move"})
	var optional_response := _ai_choice_for_request(
		worker, optional_state, 0, "psychic", optional_request, "optional-no-positive")
	_check(
		optional_response != null and optional_response.cancelled,
		"AI optional choice did not cancel when no positive option existed",
	)

	var shoes_keep_state := GameState.new()
	shoes_keep_state.public_deck_keys = ["psychic", "water"]
	shoes_keep_state.players[0].active = PokemonState.new("sv1-113")
	shoes_keep_state.players[0].active.energy_card_ids = ["sv1-ener-5"]
	shoes_keep_state.players[0].deck = ["sv1-ener-5"]
	var shoes_keep_response := _ai_choice_for_request(
		worker, shoes_keep_state, 0, "psychic",
		ChoiceRequest.new(
			"choice:shoes-keep", "confirm", 0, "Keep top card?",
			_ai_confirm_options(), 1, 1, false, false, {
				"domain": "effect",
				"purpose": "trekking_shoes",
				"top_card_id": "sv1-ener-5",
			}),
		"trekking-shoes-keep")
	_check(
		shoes_keep_response != null
		and shoes_keep_response.option_ids == ["confirm:yes"],
		"AI trekking shoes did not keep missing psychic energy",
	)

	var shoes_discard_state := GameState.new()
	shoes_discard_state.public_deck_keys = ["psychic", "water"]
	shoes_discard_state.players[0].hand = ["sv1-180", "sv1-180"]
	shoes_discard_state.players[0].deck = ["sv1-180"]
	var shoes_discard_response := _ai_choice_for_request(
		worker, shoes_discard_state, 0, "psychic",
		ChoiceRequest.new(
			"choice:shoes-discard", "confirm", 0, "Keep top card?",
			_ai_confirm_options(), 1, 1, false, false, {
				"domain": "effect",
				"purpose": "trekking_shoes",
				"top_card_id": "sv1-180",
			}),
		"trekking-shoes-discard")
	_check(
		shoes_discard_response != null
		and shoes_discard_response.option_ids == ["confirm:no"],
		"AI trekking shoes kept a low-value duplicate draw supporter",
	)

	var low_hand_draw_state := GameState.new()
	low_hand_draw_state.phase = "MAIN"
	low_hand_draw_state.public_deck_keys = ["psychic", "water"]
	low_hand_draw_state.players[0].active = PokemonState.new("sv1-113")
	low_hand_draw_state.players[0].hand = ["sv1-180", "sv1-ener-5"]
	low_hand_draw_state.players[0].deck = [
		"sv1-ener-5", "sv1-ener-5", "sv1-107", "sv1-108", "sv1-109",
	]
	var high_hand_draw_state := GameState.from_dict(low_hand_draw_state.snapshot())
	high_hand_draw_state.players[0].hand = [
		"sv1-180", "sv1-ener-5", "sv1-ener-5", "sv1-107", "sv1-108",
		"sv1-109", "sv1-110", "sv1-111", "sv1-112",
	]
	var draw_trainer_action := GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0)
	_check(
		worker._action_score(
			high_hand_draw_state, 0, draw_trainer_action, "psychic", catalog)
		< worker._action_score(
			low_hand_draw_state, 0, draw_trainer_action, "psychic", catalog),
		"AI draw trainer score did not decrease for saturated hands",
	)

	_check(
		not AIDeckProfiles.contains("psychic", "core", "sv1-110")
		and AIDeckProfiles.contains("psychic", "engine", "sv1-110")
		and not AIDeckProfiles.contains("steel", "core", "svm-bronzong")
		and AIDeckProfiles.contains("steel", "engine", "svm-bronzong")
		and not AIDeckProfiles.contains("lightning", "core", "svl-flaa2")
		and AIDeckProfiles.contains("lightning", "engine", "svl-flaa2")
		and AIDeckProfiles.contains("lightning", "evolution", "svl-flaa2"),
		"AI deck profiles still treat engine Pokemon as primary core cards",
	)
	_check(
		AIDeckProfiles.high_impact_damage_floor("steel") == 100
		and AIDeckProfiles.high_impact_damage_floor("psychic") == 110,
		"AI deck profiles did not preserve deck-specific high-impact damage floors",
	)

	var steel_floor_state := GameState.new()
	steel_floor_state.players[0].active = PokemonState.new("svm-zacian")
	steel_floor_state.players[0].active.energy_card_ids.assign([
		"sv1-ener-8", "sv1-ener-8",
	])
	_check(
		worker._energy_plan_target_bonus(
			steel_floor_state, 0, "active", "sv1-ener-8", "steel", catalog) > 400.0,
		"AI steel energy planning did not treat 100-damage core attacks as high impact",
	)

	var repeat_window_state := GameState.new()
	repeat_window_state.phase = "MAIN"
	repeat_window_state.public_deck_keys = ["steel", "fire"]
	repeat_window_state.players[0].active = PokemonState.new("svm-bronzong")
	repeat_window_state.action_log = [
		"青铜钟使用特性金属转移。",
		"玩家1附着了钢能量。",
		"苍响使用了战斗军团。",
	]
	_check(
		worker._should_avoid_repeating_ability(
			repeat_window_state,
			0,
			GameAction.new("USE_ABILITY", {
				"slot": "active",
				"ability_name": "金属转移",
			}, false, 0),
			catalog,
		),
		"AI repeatable ability guard ignored recent non-adjacent ability use",
	)

	var target_state := GameState.new()
	target_state.phase = "MAIN"
	target_state.setup_stage = GameState.SETUP_COMPLETE
	target_state.active_player_idx = 1
	target_state.public_deck_keys = ["lightning", "psychic"]
	target_state.players[0].active = PokemonState.new("sv1-104")
	target_state.players[0].bench[0] = PokemonState.new("sv1-107")
	target_state.players[0].bench[1] = PokemonState.new("svl-pikaex")
	target_state.players[0].bench[1].damage_counters = 12
	target_state.players[1].active = PokemonState.new("sv1-104")
	target_state.players[1].bench[0] = PokemonState.new("svl-pikaex")
	target_state.players[1].bench[1] = PokemonState.new("sv1-107")
	var target_options: Array[Dictionary] = [
		{
			"option_id": "pokemon:0:bench_0:sv1-107",
			"label": "bench0",
		},
		{
			"option_id": "pokemon:0:bench_1:svl-pikaex",
			"label": "bench1",
		},
	]
	var target_response := _ai_choice_for_request(
		worker, target_state, 1, "psychic",
		ChoiceRequest.new(
			"choice:target", "select_opponent_bench", 1, "Choose opponent bench.",
			target_options, 1, 1),
		"opponent-target-player-parse")
	_check(
		target_response != null
		and target_response.option_ids == ["pokemon:0:bench_1:svl-pikaex"],
		"AI opponent bench target did not parse target player from option id",
	)

	var switch_state := GameState.new()
	switch_state.public_deck_keys = ["psychic", "dragon"]
	switch_state.players[0].active = PokemonState.new("sv1-104")
	switch_state.players[0].bench[0] = PokemonState.new("sv1-107")
	switch_state.players[1].active = PokemonState.new("svg-dram")
	switch_state.players[1].active.energy_card_ids = ["sv1-ener-1", "sv1-ener-2"]
	var switch_response := _ai_choice_for_request(
		worker, switch_state, 0, "psychic",
		ChoiceRequest.new(
			"choice:switch", "confirm", 0, "Switch active Pokemon?",
			_ai_confirm_options(), 1, 1, false, false, {
				"domain": "effect",
				"purpose": "confirm_switch",
				"source_player": 0,
				"target_player": 0,
			}),
		"confirm-self-switch")
	_check(
		switch_response != null
		and switch_response.option_ids == ["confirm:no"],
		"AI optional self-switch exposed an unsafe unready engine Pokemon",
	)
	_check(
		not worker._retreat_has_good_target(switch_state, 0, 0, "psychic", catalog),
		"AI retreat helper allowed retreat into a target that current opponent active can KO",
	)

	_check(
		not worker.has_method("_select_ucb")
		and not worker.has_method("_simulate")
		and not worker.has_method("_neural_action_priors"),
		"Retired UCB/rollout/neural decision paths remain in the release AI",
	)

	var cresselia_state := GameState.new()
	cresselia_state.players[0].active = PokemonState.new("sv1-113")
	cresselia_state.players[0].active.energy_card_ids = ["sv1-ener-5", "sv1-ener-5"]
	cresselia_state.players[0].bench[0] = PokemonState.new("sv1-104")
	cresselia_state.players[0].bench[0].energy_card_ids.assign([
		"sv1-ener-5", "sv1-ener-5", "sv1-ener-5",
	])
	cresselia_state.players[1].active = PokemonState.new("sv2-delib")
	_check(
		worker._estimated_attack_damage(cresselia_state, 0, 1, catalog) >= 120,
		"AI damage estimate ignored Cresselia field energy conditional bonus",
	)
	_check(
		worker._best_pokemon_damage(cresselia_state.players[0].active, catalog) >= 120,
		"AI potential damage ignored Cresselia conditional damage ceiling",
	)

	var cetitan_state := GameState.new()
	cetitan_state.players[0].active = PokemonState.new("svg-ceti")
	var damaged_cetitan := PokemonState.new("svg-ceti")
	damaged_cetitan.damage_counters = 4
	_check(
		worker._best_pokemon_damage(cetitan_state.players[0].active, catalog) >= 200,
		"AI potential damage ignored self-damage penalty attack ceiling",
	)
	_check(
		worker._pokemon_strength(cetitan_state.players[0].active, catalog)
		> worker._pokemon_strength(damaged_cetitan, catalog),
		"AI board strength ignored self-damage penalty attack decay",
	)

	var lucario_state := GameState.new()
	lucario_state.players[0].active = PokemonState.new("svf-luca")
	lucario_state.players[0].active.energy_card_ids = ["sv1-ener-6", "sv1-ener-6"]
	lucario_state.players[1].active = PokemonState.new("sv2-delib")
	_check(
		worker._estimated_attack_damage(lucario_state, 0, 0, catalog) >= 130,
		"AI damage estimate ignored Lucario fighting energy discard damage",
	)

	var greedent_state := GameState.new()
	greedent_state.players[0].active = PokemonState.new("svi-gree")
	greedent_state.players[0].active.energy_card_ids = ["sv1-ener-1", "sv1-ener-2"]
	greedent_state.players[0].hand.assign([
		"sv1-ener-1", "sv1-ener-2", "sv1-ener-3", "sv1-ener-4", "sv1-ener-5",
	])
	greedent_state.players[1].active = PokemonState.new("sv2-delib")
	_check(
		worker._estimated_attack_damage(greedent_state, 0, 1, catalog) >= 210,
		"AI damage estimate ignored Greedent discard-hand threshold damage",
	)

	var coin_ko_state := GameState.new()
	coin_ko_state.players[0].active = PokemonState.new("svf-klea")
	coin_ko_state.players[0].active.energy_card_ids = ["sv1-ener-6", "sv1-ener-6"]
	coin_ko_state.players[1].active = PokemonState.new("svl-pikaex")
	_check(
		worker._estimated_attack_damage(coin_ko_state, 0, 0, catalog) > 0,
		"AI damage estimate ignored coin-flip KO expected damage",
	)

	var coin_fail_state := GameState.new()
	coin_fail_state.players[0].active = PokemonState.new("sv2-38")
	coin_fail_state.players[0].active.energy_card_ids = ["sv1-ener-3"]
	coin_fail_state.players[1].active = PokemonState.new("sv1-104")
	_check(
		worker._estimated_attack_damage(coin_fail_state, 0, 0, catalog) == 15,
		"AI damage estimate did not halve coin-flip attack-fail damage",
	)


func _test_ai_damage_counter_scoring_uses_ten_hp_units(
	catalog: CardCatalog,
) -> void:
	var healthy := PlayerState.new()
	healthy.active = PokemonState.new("sv1-104")
	var damaged := healthy.clone_state()
	damaged.active.damage_counters = 3
	var healthy_score := AITurnBeamPlanner._board_score(healthy, catalog)
	var damaged_score := AITurnBeamPlanner._board_score(damaged, catalog)
	_check(
		is_equal_approx(healthy_score - damaged_score, 30.0 * 0.35 * 1.2),
		"AI planner board score did not value each damage counter as 10 HP",
	)


func _test_ai_optional_choice_selects_positive_options_to_max(
	catalog: CardCatalog,
) -> void:
	var request := ChoiceView.new(
		"choice:optional-positive-to-max",
		0,
		"select_card",
		0,
		"Choose any useful cards.",
		[
			{"option_id": "benefit:high", "label": "high"},
			{"option_id": "benefit:medium", "label": "medium"},
			{"option_id": "benefit:low", "label": "low"},
			{"option_id": "benefit:overflow", "label": "overflow"},
			{"option_id": "cost", "label": "cost"},
		],
		0,
		3,
		false,
		true,
	)
	var response := AIChoiceSelector.response_from_ranked_scores(
		request,
		[
			{"index": 0, "score": 9.0},
			{"index": 1, "score": 5.0},
			{"index": 2, "score": 2.0},
			{"index": 3, "score": 1.0},
			{"index": 4, "score": -4.0},
		],
		catalog,
	)
	_check(
		not response.cancelled
		and response.option_ids == [
			"benefit:high", "benefit:medium", "benefit:low",
		],
		"AI optional choice did not take the highest positive-value options up to max_select",
	)


func _test_fire_choice_search_follows_executable_evolution_chain() -> void:
	var strategy := AIStrategyRegistry.new().strategy_for("fire")
	var choice_view := {
		"request_type": "search_deck",
		"presentation": {"purpose": "search"},
	}
	var monferno_option := {"card_id": "svi-monf"}
	var infernape_option := {"card_id": "svi-infr"}
	var chimchar_only := {
		"perspective": 0,
		"own": {
			"active": {"card_id": "svi-chim"},
			"bench": [],
			"hand": [],
		},
	}
	var chimchar_monferno_score := strategy.choice_option_score(
		chimchar_only, choice_view, monferno_option)
	var chimchar_infernape_score := strategy.choice_option_score(
		chimchar_only, choice_view, infernape_option)
	_check(
		chimchar_monferno_score > chimchar_infernape_score + 20.0,
		"Fire search did not prefer executable Monferno over stranded Infernape from Chimchar",
	)

	var monferno_ready := {
		"perspective": 0,
		"own": {
			"active": {"card_id": "svi-monf"},
			"bench": [],
			"hand": [],
		},
	}
	var ready_infernape_score := strategy.choice_option_score(
		monferno_ready, choice_view, infernape_option)
	var ready_monferno_score := strategy.choice_option_score(
		monferno_ready, choice_view, monferno_option)
	_check(
		ready_infernape_score > ready_monferno_score,
		"Fire search did not prioritize Infernape when Monferno was already in play",
	)
	var duplicate_infernape := monferno_ready.duplicate(true)
	duplicate_infernape["own"]["hand"] = ["svi-infr"]
	_check(
		strategy.choice_option_score(
			duplicate_infernape, choice_view, infernape_option
		) < ready_infernape_score,
		"Fire search did not penalize retrieving an Infernape already held in hand",
	)

	var rare_candy_ready := chimchar_only.duplicate(true)
	rare_candy_ready["own"]["hand"] = ["sv1-152"]
	var candy_infernape_score := strategy.choice_option_score(
		rare_candy_ready, choice_view, infernape_option)
	var candy_monferno_score := strategy.choice_option_score(
		rare_candy_ready, choice_view, monferno_option)
	_check(
		candy_infernape_score > candy_monferno_score,
		"Fire search did not prioritize Infernape for an executable Rare Candy route",
	)
	var duplicate_monferno := chimchar_only.duplicate(true)
	duplicate_monferno["own"]["hand"] = ["svi-monf"]
	var held_monferno_score := strategy.choice_option_score(
		duplicate_monferno, choice_view, monferno_option)
	var held_infernape_score := strategy.choice_option_score(
		duplicate_monferno, choice_view, infernape_option)
	_check(
		held_monferno_score < chimchar_monferno_score,
		"Fire search did not penalize retrieving a Monferno already held in hand",
	)
	_check(
		held_infernape_score > held_monferno_score,
		"Fire search did not prioritize Infernape when Monferno was already in hand",
	)


func _test_ai_planner_candidate_kind_diversity() -> void:
	var ranked: Array[Dictionary] = []
	for index in range(6):
		ranked.append({
			"action": GameAction.create(
				"DECLARE_ATTACK", {"attack_index": index}, 0),
			"score": 1000.0 - float(index),
			"index": index,
		})
	ranked.append({
		"action": GameAction.create("EVOLVE", {}, 0),
		"score": 100.0,
		"index": 6,
	})
	ranked.append({
		"action": GameAction.create("ATTACH_ENERGY", {}, 0),
		"score": 90.0,
		"index": 7,
	})
	var selected := AITurnBeamPlanner._diverse_top_actions(ranked, 3)
	var kinds: Array[String] = []
	for row_value in selected:
		var row: Dictionary = row_value
		var action: GameAction = row.get("action")
		if action != null:
			kinds.append(action.kind)
	_check(
		selected.size() == 3
		and kinds.has("DECLARE_ATTACK")
		and kinds.has("EVOLVE")
		and kinds.has("ATTACH_ENERGY"),
		"AI planner candidate cap starved evolution/resource action categories behind attacks",
	)
	var development_only: Array[Dictionary] = []
	for kind in [
		"USE_ABILITY", "PLAY_TRAINER", "EVOLVE", "ATTACH_ENERGY", "PLAY_BASIC", "RETREAT",
	]:
		development_only.append({
			"action": GameAction.create(kind, {}, 0),
			"score": 500.0 - float(development_only.size()),
			"index": development_only.size(),
		})
	development_only.append({
		"action": GameAction.create("END_TURN", {}, 0),
		"score": -100.0,
		"index": development_only.size(),
	})
	var terminal_candidates := AITurnBeamPlanner._diverse_top_actions(
		development_only, 6)
	var final_depth_candidates := AITurnBeamPlanner._terminal_candidates(
		terminal_candidates)
	var has_terminal_candidate := false
	for terminal_row_value in terminal_candidates:
		var terminal_row: Dictionary = terminal_row_value
		var terminal_action: GameAction = terminal_row.get("action")
		if terminal_action != null and terminal_action.terminal:
			has_terminal_candidate = true
			break
	_check(
		has_terminal_candidate,
		"AI planner candidate cap omitted every turn-completing action",
	)
	var all_final_candidates_terminal := not final_depth_candidates.is_empty()
	for final_row_value in final_depth_candidates:
		var final_row: Dictionary = final_row_value
		var final_action: GameAction = final_row.get("action")
		if final_action == null or not final_action.terminal:
			all_final_candidates_terminal = false
			break
	_check(
		all_final_candidates_terminal,
		"AI planner final depth retained a nonterminal action outside the scored turn horizon",
	)


func _test_ai_random_event_invalidates_plan_cache() -> void:
	var action := GameAction.create("PLAY_TRAINER", {}, 0)
	var deterministic_step := StepResult.new(true, "played")
	var random_step := StepResult.new(
		true, "flipped", null, [{"event_type": "coin_flip"}])
	var random_trace := {
		"had_choice": false,
		"unpredictable": AITurnBeamPlanner._step_has_unpredictable_event(random_step),
	}
	_check(
		AITurnBeamPlanner._action_allows_cache_continuation(
			action, deterministic_step, {"had_choice": false, "unpredictable": false})
		and bool(random_trace["unpredictable"])
		and not AITurnBeamPlanner._action_allows_cache_continuation(
			action, random_step, random_trace),
		"AI planner kept a cached continuation open after a random event",
	)


func _test_ai_complete_leaf_beats_incomparable_partial() -> void:
	var partial_best := {
		"score": 240.0,
		"ended": false,
		"sequence": [GameAction.create("EVOLVE", {}, 0)],
	}
	var attack_leaf := {
		"score": 180.0,
		"ended": true,
		"sequence": [GameAction.create(
			"DECLARE_ATTACK", {"attack_index": 0}, 0)],
	}
	var selected := AITurnBeamPlanner._preferred_final_node(attack_leaf, partial_best)
	var selected_sequence: Array = selected.get("sequence", [])
	var selected_action: GameAction = (
		selected_sequence[0] if not selected_sequence.is_empty() else null)
	_check(
		is_equal_approx(float(selected.get("score", -INF)), 180.0)
		and selected_action != null
		and selected_action.kind == "DECLARE_ATTACK",
		"AI planner compared an unopposed partial state against a completed reply-scored leaf",
	)


func _test_ai_cached_action_passes_post_plan_tactical_guard(
	catalog: CardCatalog,
	engine: GameEngine,
	worker: NativeChallengeAI,
) -> void:
	var state := _battle_state()
	state.revision = 9
	state.turn_number = 4
	state.active_player_idx = 0
	state.public_deck_keys = ["psychic", "water"]
	state.set_type_matchups_enabled(false)
	var legal_actions: Array[GameAction] = []
	var end_turn: GameAction = null
	var attach_energy: GameAction = null
	for action_value in RulesTestHarness.legal_actions(engine, state, 0, false):
		var action: GameAction = action_value
		if action.kind == "END_TURN":
			end_turn = action
		elif action.kind == "ATTACH_ENERGY" and attach_energy == null:
			attach_energy = action
	if end_turn != null:
		legal_actions.append(end_turn)
	if attach_energy != null:
		legal_actions.append(attach_energy)
	_check(
		end_turn != null and attach_energy != null,
		"AI cache tactical-guard fixture did not expose end-turn and attachment actions",
	)
	if end_turn == null or attach_energy == null:
		return
	var match_seed := 2026072104
	var information_set := AIInformationSet.capture(
		state, 0, catalog, legal_actions, [], match_seed)
	_check(
		information_set.is_valid(),
		"AI cache tactical-guard fixture could not capture an information set",
	)
	if not information_set.is_valid():
		return
	var action_rows: Array = []
	for action in legal_actions:
		action_rows.append(action.to_dict())
	var request := {
		"kind": "action",
		"state": state.snapshot(),
		"actor": 0,
		"revision": state.revision,
		"request_id": "cached-post-plan-tactical-guard",
		"mode": "challenge",
		"deck_key": "psychic",
		"seed": 20260721,
		"match_seed": match_seed,
		"match_instance_id": "cached-guard-match",
		"simulation_budget": 16,
		"max_depth": 2,
		"deterministic": true,
		"actions": action_rows,
	}
	var cache_key := worker._turn_plan_cache_key(
		request, information_set, "psychic")
	var cached_intent := worker._intent_with_precondition(
		end_turn, information_set.cache_precondition())
	worker._turn_plan_cache.clear()
	worker._turn_plan_cache[cache_key] = {
		"intents": [cached_intent],
		"last_revision": state.revision - 1,
	}
	var result := worker.decide(request, func() -> bool: return false)
	worker._turn_plan_cache.clear()
	var selected: Dictionary = result.get("action", {})
	_check(
		bool(result.get("success", false))
		and bool(result.get("turn_plan_cache_hit", false))
		and str(selected.get("kind", "")) == "ATTACH_ENERGY"
		and str(result.get("forced_tactic", "")) == "post_plan_tactical_guard",
		"AI cache hit bypassed the post-plan tactical guard: %s" % JSON.stringify(result),
	)


func _test_ai_cached_self_cost_ability_passes_post_plan_tactical_guard(
	catalog: CardCatalog,
	engine: GameEngine,
	worker: NativeChallengeAI,
) -> void:
	var state := _battle_state()
	state.revision = 19
	state.turn_number = 5
	state.first_player_idx = 0
	state.active_player_idx = 0
	state.public_deck_keys = ["water", "fire"]
	state.set_type_matchups_enabled(false)
	state.players[0].active = PokemonState.new("sv2-starm")
	state.players[0].active.placed_this_turn = false
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[0].bench[0].placed_this_turn = false
	state.players[0].hand.clear()
	var legal_actions: Array[GameAction] = []
	legal_actions.assign(RulesTestHarness.legal_actions(engine, state, 0, false))
	var self_discard_ability: GameAction = null
	var end_turn: GameAction = null
	for action in legal_actions:
		if (
			action.kind == "USE_ABILITY"
			and str(action.payload.get("ability_name", "")) == "神秘彗星"
		):
			self_discard_ability = action
		elif action.kind == "END_TURN":
			end_turn = action
	_check(
		self_discard_ability != null and end_turn != null,
		"AI cached self-discard guard fixture did not expose ability and end-turn actions",
	)
	if self_discard_ability == null or end_turn == null:
		return
	var self_damage_source := PokemonState.new("svf-luca")
	self_damage_source.placed_this_turn = false
	state.players[0].bench[1] = self_damage_source
	var self_damage_action := GameAction.create(
		"USE_ABILITY",
		{"slot": "bench_1", "ability_name": "旺盛斗气"},
		0,
		EntityRef.new("pokemon", 0, "", "bench_1", -1, "", "svf-luca"),
	)
	_check(
		worker._cached_action_needs_tactical_guard(
			state, 0, self_discard_ability, catalog)
		and worker._cached_action_needs_tactical_guard(
			state, 0, self_damage_action, catalog),
		"AI cache guard did not classify self-discard/self-damage abilities as irreversible",
	)

	var match_seed := 2026072201
	var information_set := AIInformationSet.capture(
		state, 0, catalog, legal_actions, [], match_seed)
	_check(
		information_set.is_valid(),
		"AI cached self-discard guard fixture could not capture an information set",
	)
	if not information_set.is_valid():
		return
	var action_rows: Array = []
	for action in legal_actions:
		action_rows.append(action.to_dict())
	var request := {
		"kind": "action",
		"state": state.snapshot(),
		"actor": 0,
		"revision": state.revision,
		"request_id": "cached-self-discard-post-plan-tactical-guard",
		"mode": "challenge",
		"deck_key": "water",
		"seed": 20260722,
		"match_seed": match_seed,
		"match_instance_id": "cached-self-discard-guard-match",
		"simulation_budget": 16,
		"max_depth": 2,
		"deterministic": true,
		"actions": action_rows,
	}
	var cache_key := worker._turn_plan_cache_key(
		request, information_set, "water")
	worker._turn_plan_cache.clear()
	worker._turn_plan_cache[cache_key] = {
		"intents": [worker._intent_with_precondition(
			self_discard_ability, information_set.cache_precondition())],
		"last_revision": state.revision - 1,
	}
	var result := worker.decide(request, func() -> bool: return false)
	worker._turn_plan_cache.clear()
	var selected: Dictionary = result.get("action", {})
	_check(
		bool(result.get("success", false))
		and bool(result.get("turn_plan_cache_hit", false))
		and str(selected.get("kind", "")) == "END_TURN"
		and str(result.get("forced_tactic", "")) == "post_plan_tactical_guard",
		"Cached self-discard ability bypassed the tactical guard: %s" % JSON.stringify(result),
	)


func _test_ai_self_discard_scoring_uses_counter_units_and_source_slot(
	catalog: CardCatalog,
	worker: NativeChallengeAI,
) -> void:
	var state := _battle_state()
	state.players[0].active = PokemonState.new("svl-pikaex")
	state.players[0].active.energy_card_ids.assign([
		"sv1-ener-4", "sv1-ener-4", "sv1-ener-4",
	])
	state.players[0].bench[0] = PokemonState.new("sv2-starm")
	state.players[0].bench[0].evolution_stack_ids.append("sv2-staryu")
	var effect: Dictionary = Dictionary(
		catalog.get_card("sv2-starm").get("abilities", [])[0]).get(
			"effects", [])[0]
	var damage := worker._effect_damage_estimate(state, 0, effect, catalog)
	var source_cost := worker._self_discard_source_cost(
		state, 0, "bench_0", catalog)
	var value_before := worker._semantic_damage_effect_value(
		state, 0, effect, "bench_0", catalog)
	state.players[0].active = PokemonState.new("sv1-104")
	var value_after_active_change := worker._semantic_damage_effect_value(
		state, 0, effect, "bench_0", catalog)
	state.players[0].bench[0].energy_card_ids.append("sv1-ener-3")
	state.players[0].bench[0].attached_tool_id = "sv1-202"
	var loaded_source_cost := worker._self_discard_source_cost(
		state, 0, "bench_0", catalog)
	var loaded_value := worker._semantic_damage_effect_value(
		state, 0, effect, "bench_0", catalog)
	_check(
		damage == 20
		and is_equal_approx(value_before, 20.0 * 1.15 - source_cost)
		and is_equal_approx(value_after_active_change, value_before)
		and loaded_source_cost > source_cost
		and is_equal_approx(
			value_before - loaded_value, loaded_source_cost - source_cost),
		"AI self-discard scoring lost counter units or charged the Active instead of its source",
	)


func _test_ai_mandatory_tactics_establishes_backup_before_ordinary_attack(
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	var state := _ai_lone_active_backup_fixture("sv2-delib", 6)
	var actions: Array[GameAction] = []
	actions.assign(RulesTestHarness.legal_actions(engine, state, 0, false))
	var has_attack := false
	var has_basic := false
	for action in actions:
		has_attack = has_attack or action.kind == "DECLARE_ATTACK"
		has_basic = has_basic or (
			action.kind == "PLAY_BASIC"
			and action.target != null
			and action.target.slot.begins_with("bench_"))
	var information_set := AIInformationSet.capture(
		state, 0, catalog, actions, [], 2026072105)
	var resolved := AIMandatoryTactics.new().resolve(
		information_set,
		state,
		0,
		actions,
		engine,
		null,
		20260721,
	)
	var selected: GameAction = resolved.get("action")
	_check(
		has_attack
		and has_basic
		and bool(resolved.get("resolved", false))
		and str(resolved.get("reason", "")) == "establish_only_backup"
		and selected != null
		and selected.kind == "PLAY_BASIC"
		and selected.target != null
		and selected.target.slot.begins_with("bench_"),
		"AI mandatory tactics attacked before establishing its only backup: %s"
		% JSON.stringify(resolved),
	)
	var diagnostics := NativeChallengeAI.new().diagnose_decision(
		state,
		0,
		selected,
		actions,
		"lightning",
		catalog,
		engine,
		2026072105,
	)
	_check(
		int(diagnostics.get("missed_immediate_ko", 1)) == 0,
		"AI diagnostics reported intentional only-backup development as a missed KO",
	)

	# The mandatory survival branch used to sort the serialized action signature,
	# whose source hand index precedes card_id. That made the chosen backup depend
	# on presentation order and bypassed both the trusted and deck-strategy scores.
	var prefer_mareep := func(
		_state: GameState,
		_actor: int,
		action: GameAction,
	) -> float:
		return (
			500.0
			if action.source != null and action.source.card_id == "svl-mare2"
			else 0.0
		)
	var ordered_state := _ai_lone_active_backup_fixture("sv2-delib", 6)
	ordered_state.players[0].hand.assign(["svl-pikaex", "svl-mare2"])
	var ordered_actions: Array[GameAction] = []
	ordered_actions.assign(
		RulesTestHarness.legal_actions(engine, ordered_state, 0, false))
	var ordered_info := AIInformationSet.capture(
		ordered_state, 0, catalog, ordered_actions, [], 2026072107)
	var ordered_result := AIMandatoryTactics.new().resolve(
		ordered_info,
		ordered_state,
		0,
		ordered_actions,
		engine,
		null,
		2026072107,
		Callable(),
		0,
		192,
		Callable(),
		prefer_mareep,
	)
	var ordered_backup: GameAction = ordered_result.get("action")

	var reversed_state := ordered_state.clone_state()
	reversed_state.players[0].hand.reverse()
	var reversed_actions: Array[GameAction] = []
	reversed_actions.assign(
		RulesTestHarness.legal_actions(engine, reversed_state, 0, false))
	var reversed_info := AIInformationSet.capture(
		reversed_state, 0, catalog, reversed_actions, [], 2026072107)
	var reversed_result := AIMandatoryTactics.new().resolve(
		reversed_info,
		reversed_state,
		0,
		reversed_actions,
		engine,
		null,
		2026072107,
		Callable(),
		0,
		192,
		Callable(),
		prefer_mareep,
	)
	var reversed_backup: GameAction = reversed_result.get("action")
	var reversed_diagnostics := NativeChallengeAI.new().diagnose_decision(
		reversed_state,
		0,
		reversed_backup,
		reversed_actions,
		"lightning",
		catalog,
		engine,
		2026072107,
	)
	_check(
		ordered_info.is_valid()
		and reversed_info.is_valid()
		and str(ordered_result.get("reason", "")) == "establish_only_backup"
		and str(reversed_result.get("reason", "")) == "establish_only_backup"
		and ordered_backup != null
		and reversed_backup != null
		and ordered_backup.source != null
		and reversed_backup.source != null
		and ordered_backup.source.card_id == "svl-mare2"
		and reversed_backup.source.card_id == "svl-mare2"
		and int(reversed_diagnostics.get("missed_immediate_ko", 1)) == 0,
		"AI survival backup ignored trusted scoring or depended on hand order: %s / %s"
		% [JSON.stringify(ordered_result), JSON.stringify(reversed_result)],
	)

	# Scores inside the explicit epsilon are one deterministic tie. Using
	# is_equal_approx here used to leave a near-zero dead band whose winner
	# depended on the supplied legal-action order.
	var prefer_pikachu_by_sub_epsilon := func(
		_state: GameState,
		_actor: int,
		action: GameAction,
	) -> float:
		return (
			0.0005
			if action.source != null and action.source.card_id == "svl-pikaex"
			else 0.0
		)
	var reversed_action_order: Array[GameAction] = []
	reversed_action_order.assign(ordered_actions)
	reversed_action_order.reverse()
	var near_tie_forward := AIMandatoryTactics.survival_backup_action(
		ordered_state,
		0,
		ordered_actions,
		null,
		null,
		null,
		prefer_pikachu_by_sub_epsilon,
	)
	var near_tie_reversed := AIMandatoryTactics.survival_backup_action(
		ordered_state,
		0,
		reversed_action_order,
		null,
		null,
		null,
		prefer_pikachu_by_sub_epsilon,
	)
	_check(
		near_tie_forward != null
		and near_tie_reversed != null
		and near_tie_forward.source != null
		and near_tie_reversed.source != null
		and near_tie_forward.source.card_id == "svl-mare2"
		and near_tie_reversed.source.card_id == "svl-mare2",
		"AI survival backup near-tie depended on legal-action order: %s / %s"
		% [
			near_tie_forward.to_dict() if near_tie_forward != null else {},
			near_tie_reversed.to_dict() if near_tie_reversed != null else {},
		],
	)

	# Keep the deck hook independently covered: a flat trusted evaluator must not
	# mask the read-only strategy adjustment used by survival ranking.
	var flat_trusted_score := func(
		_state: GameState,
		_actor: int,
		_action: GameAction,
	) -> float:
		return 0.0
	var prefer_pikachu_strategy_score := func(
		_info: Dictionary,
		action_row: Dictionary,
		_semantic_catalog: Dictionary,
	) -> float:
		var source_value: Variant = action_row.get("source")
		var card_id := (
			str(Dictionary(source_value).get("card_id", ""))
			if source_value is Dictionary
			else ""
		)
		return 25.0 if card_id == "svl-pikaex" else 0.0
	var strategy_only := {"action_score": prefer_pikachu_strategy_score}
	var strategy_ranked_forward := AIMandatoryTactics.survival_backup_action(
		ordered_state,
		0,
		ordered_actions,
		ordered_info,
		strategy_only,
		catalog,
		flat_trusted_score,
	)
	var strategy_ranked_reversed := AIMandatoryTactics.survival_backup_action(
		ordered_state,
		0,
		reversed_action_order,
		ordered_info,
		strategy_only,
		catalog,
		flat_trusted_score,
	)
	_check(
		strategy_ranked_forward != null
		and strategy_ranked_reversed != null
		and strategy_ranked_forward.source != null
		and strategy_ranked_reversed.source != null
		and strategy_ranked_forward.source.card_id == "svl-pikaex"
		and strategy_ranked_reversed.source.card_id == "svl-pikaex",
		"AI survival backup ignored the deck strategy score: %s / %s"
		% [
			strategy_ranked_forward.to_dict()
			if strategy_ranked_forward != null else {},
			strategy_ranked_reversed.to_dict()
			if strategy_ranked_reversed != null else {},
		],
	)


func _test_ai_mandatory_tactics_immediate_match_win_beats_backup(
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	var state := _ai_lone_active_backup_fixture("sv2-delib", 1)
	state.players[0].hand.assign(["svl-pikaex", "svl-mare2"])
	var actions: Array[GameAction] = []
	actions.assign(RulesTestHarness.legal_actions(engine, state, 0, false))
	var information_set := AIInformationSet.capture(
		state, 0, catalog, actions, [], 2026072106)
	var prefer_mareep := func(
		_state: GameState,
		_actor: int,
		action: GameAction,
	) -> float:
		return (
			500.0
			if action.source != null and action.source.card_id == "svl-mare2"
			else 0.0
		)
	var resolved := AIMandatoryTactics.new().resolve(
		information_set,
		state,
		0,
		actions,
		engine,
		null,
		20260722,
		Callable(),
		0,
		192,
		Callable(),
		prefer_mareep,
	)
	var selected: GameAction = resolved.get("action")
	_check(
		bool(resolved.get("resolved", false))
		and str(resolved.get("reason", "")) == "immediate_match_win"
		and selected != null
		and selected.kind == "DECLARE_ATTACK",
		"AI mandatory tactics benched a Basic instead of taking a deterministic match win: %s"
		% JSON.stringify(resolved),
	)


func _ai_lone_active_backup_fixture(
	opponent_card_id: String,
	own_prize_count: int,
) -> GameState:
	var state := GameState.new()
	state.phase = "MAIN"
	state.setup_stage = GameState.SETUP_COMPLETE
	state.turn_number = 5
	state.first_player_idx = 1
	state.active_player_idx = 0
	state.public_deck_keys = ["lightning", "water"]
	state.set_type_matchups_enabled(false)
	state.players[0].active = PokemonState.new("svl-zera")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.energy_card_ids.assign([
		"sv1-ener-4", "sv1-ener-4",
	])
	state.players[0].hand = ["svl-mare2"]
	state.players[0].deck = ["sv1-ener-4", "sv1-ener-4"]
	state.players[0].prizes.clear()
	for _index in range(own_prize_count):
		state.players[0].prizes.append("sv1-ener-4")
	state.players[1].active = PokemonState.new(opponent_card_id)
	state.players[1].active.placed_this_turn = false
	state.players[1].bench[0] = PokemonState.new("sv2-staryu")
	state.players[1].bench[0].placed_this_turn = false
	state.players[1].deck = ["sv1-ener-3", "sv1-ener-3"]
	state.players[1].prizes.assign([
		"sv1-ener-3", "sv1-ener-3", "sv1-ener-3",
		"sv1-ener-3", "sv1-ener-3", "sv1-ener-3",
	])
	return state


func _test_ai_adaptive_belief_samples_follow_random_semantics(
	catalog: CardCatalog,
) -> void:
	var semantic_catalog := CardSemanticCatalog.new(catalog)
	var deterministic_actions: Array[GameAction] = [
		GameAction.create(
			"DECLARE_ATTACK",
			{"attack_index": 0},
			0,
			EntityRef.new("pokemon", 0, "field", "active", -1, "", "svl-zera"),
		),
		GameAction.create("END_TURN", {}, 0),
	]
	var random_attack_actions: Array[GameAction] = [
		GameAction.create(
			"DECLARE_ATTACK",
			{"attack_index": 0},
			0,
			EntityRef.new("pokemon", 0, "field", "active", -1, "", "sv1-107"),
		),
	]
	var hidden_top_attack_actions: Array[GameAction] = [
		GameAction.create(
			"DECLARE_ATTACK",
			{"attack_index": 0},
			0,
			EntityRef.new("pokemon", 0, "field", "active", -1, "", "svi-infr"),
		),
	]
	var random_trainer_actions: Array[GameAction] = [
		GameAction.create(
			"PLAY_TRAINER",
			{},
			0,
			EntityRef.new("card", 0, "hand", "", 0, "", "sv2-catch"),
		),
	]
	var hidden_top_trainer_actions: Array[GameAction] = [
		GameAction.create(
			"PLAY_TRAINER",
			{},
			0,
			EntityRef.new("card", 0, "hand", "", 0, "", "svi-enst"),
		),
		GameAction.create(
			"PLAY_TRAINER",
			{},
			0,
			EntityRef.new("card", 0, "hand", "", 1, "", "svl-trks"),
		),
	]
	var hidden_top_setup_attack_actions: Array[GameAction] = [
		GameAction.create(
			"DECLARE_ATTACK",
			{"attack_index": 0},
			0,
			EntityRef.new("pokemon", 0, "field", "active", -1, "", "svm-smeargle"),
		),
	]
	_check(
		TraditionalTurnPlanner.recommended_belief_samples(
			deterministic_actions, semantic_catalog) == 1,
		"AI adaptive belief sampling split a deterministic action set",
	)
	_check(
		TraditionalTurnPlanner.recommended_belief_samples(
			random_attack_actions, semantic_catalog) == 3,
		"AI adaptive belief sampling did not detect a real catalog coin-flip attack",
	)
	_check(
		TraditionalTurnPlanner.recommended_belief_samples(
			hidden_top_attack_actions, semantic_catalog) == 3,
		"AI adaptive belief sampling did not detect hidden top-deck attack damage",
	)
	_check(
		TraditionalTurnPlanner.recommended_belief_samples(
			random_trainer_actions, semantic_catalog) == 3,
		"AI adaptive belief sampling did not detect a real catalog coin-flip Trainer",
	)
	_check(
		TraditionalTurnPlanner.recommended_belief_samples(
			hidden_top_trainer_actions, semantic_catalog) == 3,
		"AI adaptive belief sampling did not detect hidden top-deck Trainers",
	)
	_check(
		TraditionalTurnPlanner.recommended_belief_samples(
			hidden_top_setup_attack_actions, semantic_catalog) == 3,
		"AI adaptive belief sampling did not detect a hidden top-deck setup attack",
	)
	var hidden_state := _battle_state()
	var hidden_information := AIInformationSet.capture(
		hidden_state, 0, catalog, deterministic_actions, [], 2026072301)
	_check(
		hidden_information.is_valid()
		and TraditionalTurnPlanner.recommended_belief_samples(
			deterministic_actions,
			semantic_catalog,
			hidden_information,
		) == 3,
		"AI did not use three shared seeds when hidden zones affected a deterministic action set",
	)


func _test_ai_public_attack_profile_values_energy_and_readiness(
	catalog: CardCatalog,
) -> void:
	var typed_energy := PokemonState.new("sv1-107")
	typed_energy.energy_card_ids = ["sv1-ener-5"]
	var wrong_energy := PokemonState.new("sv1-107")
	wrong_energy.energy_card_ids = ["sv1-ener-4"]
	var no_energy := PokemonState.new("sv1-107")
	var typed_profile := AITurnBeamPlanner._public_attack_profile(
		typed_energy, catalog)
	var wrong_profile := AITurnBeamPlanner._public_attack_profile(
		wrong_energy, catalog)
	var empty_profile := AITurnBeamPlanner._public_attack_profile(
		no_energy, catalog)
	var typed_player := PlayerState.new()
	typed_player.active = typed_energy
	var wrong_player := PlayerState.new()
	wrong_player.active = wrong_energy
	var empty_player := PlayerState.new()
	empty_player.active = no_energy
	var typed_score := AITurnBeamPlanner._board_score(typed_player, catalog)
	var wrong_score := AITurnBeamPlanner._board_score(wrong_player, catalog)
	var empty_score := AITurnBeamPlanner._board_score(empty_player, catalog)
	_check(
		int(typed_profile.get("useful_units", -1)) == 1
		and int(typed_profile.get("minimum_missing", -1)) == 0
		and int(wrong_profile.get("useful_units", -1)) == 0
		and int(wrong_profile.get("stranded_units", -1)) == 1
		and int(wrong_profile.get("minimum_missing", -1)) == 1
		and typed_score > wrong_score,
		"AI public attack profile did not value valid typed energy above wrong-type energy",
	)
	_check(
		int(empty_profile.get("minimum_missing", -1)) == 1
		and float(typed_profile.get("ready_ratio", -1.0))
		> float(empty_profile.get("ready_ratio", -1.0))
		and typed_score > empty_score,
		"AI board readiness score was not ordered from zero to one missing energy",
	)

	var double_units := PokemonState.new("svd-maschiff")
	double_units.energy_card_ids = ["svi-dtur"]
	var single_unit := PokemonState.new("svd-maschiff")
	single_unit.energy_card_ids = ["sv1-ener-5"]
	var double_profile := AITurnBeamPlanner._public_attack_profile(
		double_units, catalog)
	var single_profile := AITurnBeamPlanner._public_attack_profile(
		single_unit, catalog)
	var double_player := PlayerState.new()
	double_player.active = double_units
	var single_player := PlayerState.new()
	single_player.active = single_unit
	_check(
		int(double_profile.get("available_units", -1)) == 2
		and int(double_profile.get("useful_units", -1)) == 2
		and int(double_profile.get("minimum_missing", -1)) == 0
		and int(single_profile.get("available_units", -1)) == 1
		and int(single_profile.get("minimum_missing", -1)) == 1
		and AITurnBeamPlanner._board_score(double_player, catalog)
		> AITurnBeamPlanner._board_score(single_player, catalog),
		"AI public attack profile did not count special double energy via available_energy",
	)


func _test_ai_public_attack_profile_status_gates(
	catalog: CardCatalog,
) -> void:
	var normal := PokemonState.new("sv1-107")
	normal.energy_card_ids = ["sv1-ener-5"]
	var asleep := normal.clone_state()
	asleep.status_conditions = ["ASLEEP"]
	var paralyzed := normal.clone_state()
	paralyzed.status_conditions = ["PARALYZED"]
	var confused := normal.clone_state()
	confused.status_conditions = ["CONFUSED"]
	var normal_profile := AITurnBeamPlanner._public_attack_profile(normal, catalog)
	var asleep_profile := AITurnBeamPlanner._public_attack_profile(asleep, catalog)
	var paralyzed_profile := AITurnBeamPlanner._public_attack_profile(
		paralyzed, catalog)
	var confused_profile := AITurnBeamPlanner._public_attack_profile(
		confused, catalog)
	var normal_player := PlayerState.new()
	normal_player.active = normal
	var asleep_player := PlayerState.new()
	asleep_player.active = asleep
	var paralyzed_player := PlayerState.new()
	paralyzed_player.active = paralyzed
	var confused_player := PlayerState.new()
	confused_player.active = confused
	var normal_score := AITurnBeamPlanner._board_score(normal_player, catalog)
	var asleep_score := AITurnBeamPlanner._board_score(asleep_player, catalog)
	var paralyzed_score := AITurnBeamPlanner._board_score(paralyzed_player, catalog)
	var confused_score := AITurnBeamPlanner._board_score(confused_player, catalog)
	_check(
		is_equal_approx(float(normal_profile.get("gate_probability", -1.0)), 1.0)
		and is_equal_approx(float(asleep_profile.get("gate_probability", -1.0)), 0.0)
		and is_equal_approx(float(
			paralyzed_profile.get("gate_probability", -1.0)), 0.0)
		and is_equal_approx(float(confused_profile.get(
			"gate_probability", -1.0)), 0.5),
		"AI public attack profile assigned incorrect status attack gates",
	)
	_check(
		normal_score > confused_score
		and confused_score > asleep_score
		and is_equal_approx(asleep_score, paralyzed_score),
		"AI board score did not apply ordered normal/confused/asleep/paralyzed gates",
	)


func _test_ai_fixed_replan_profile_and_scope(
	catalog: CardCatalog,
	worker: NativeChallengeAI,
) -> void:
	var state := _battle_state()
	state.turn_number = 4
	state.revision = 10
	state.public_deck_keys = ["psychic", "water"]
	state.set_type_matchups_enabled(false)
	var information_set := AIInformationSet.capture(
		state, 0, catalog, [], [], 2026072107)
	var match_a_request := {"match_instance_id": "replan-ledger-match-a"}
	var turn_key := worker._turn_plan_cache_key(
		match_a_request, information_set, "psychic")
	var fixed := worker._fixed_traditional_planner_request({
		"seed": 123,
		"seconds": 0.001,
		"time_budget_ms": 1,
		"node_budget": 1,
		"max_depth": 1,
		"belief_samples": 1,
	})
	_check(
		str(fixed.get("engine", "")) == "turn_beam_v2"
		and int(fixed.get("max_depth", 0)) == 8
		and int(fixed.get("root_actions", 0)) == 8
		and int(fixed.get("per_root_beam_width", 0)) == 2
		and int(fixed.get("max_actions_per_node", 0)) == 8
		and int(fixed.get("reply_depth", 0)) == 3
		and not fixed.has("seconds")
		and not fixed.has("time_budget_ms")
		and not fixed.has("node_budget")
		and not fixed.has("belief_samples"),
		"AI cache miss did not retain the fixed depth-eight work profile",
	)

	var next_turn := GameState.from_dict(state.snapshot())
	next_turn.turn_number = 5
	next_turn.revision = 14
	var next_turn_information := AIInformationSet.capture(
		next_turn, 0, catalog, [], [], 2026072107)
	var next_turn_key := worker._turn_plan_cache_key(
		match_a_request, next_turn_information, "psychic")
	var match_b_request := {"match_instance_id": "replan-ledger-match-b"}
	var next_match_key := worker._turn_plan_cache_key(
		match_b_request, information_set, "psychic")
	_check(
		not turn_key.is_empty()
		and next_turn_key != turn_key
		and next_match_key != turn_key,
		"AI turn plan cache did not scope fixed-work plans by turn and match",
	)


func _ai_decision_for_actions(
	worker: NativeChallengeAI,
	state: GameState,
	actor: int,
	deck_key: String,
	actions: Array,
	request_id: String,
) -> GameAction:
	var result := _ai_decision_result_for_actions(
		worker, state, actor, deck_key, actions, request_id, false)
	_check(result.get("success", false), "AI strength decision failed: %s" % result.get("error", "unknown"))
	if not result.get("success", false):
		return null
	return GameAction.from_dict(result["action"])


func _ai_decision_result_for_actions(
	worker: NativeChallengeAI,
	state: GameState,
	actor: int,
	deck_key: String,
	actions: Array,
	request_id: String,
	profile: bool,
	heuristic_variant: String = NativeChallengeAI.DEFAULT_HEURISTIC_VARIANT,
) -> Dictionary:
	var rows: Array = []
	var fixture_engine := GameEngine.new()
	for action in actions:
		if action.is_legacy_constructed():
			# Focused heuristic fixtures use concise legacy constructors, but the
			# worker boundary receives only canonical Actions v4 envelopes.
			rows.append(fixture_engine._canonicalize_action(
				state, action, actor).to_dict())
		else:
			rows.append(action.to_dict())
	return worker.decide({
		"kind": "action",
		"state": state.snapshot(),
		"actor": actor,
		"revision": state.revision,
		"request_id": request_id,
		"mode": "challenge",
		"deck_key": deck_key,
		"seed": 20260626,
		"internal_tactical_fixture": true,
		"simulation_budget": 0,
		"seconds": 0.0,
		"max_depth": 1,
		"deterministic": true,
		"profile": profile,
		"heuristic_variant": heuristic_variant,
		"actions": rows,
	}, func() -> bool: return false)


func _ai_choice_for_request(
	worker: NativeChallengeAI,
	state: GameState,
	actor: int,
	deck_key: String,
	choice: ChoiceRequest,
	request_id: String,
	heuristic_variant: String = NativeChallengeAI.DEFAULT_HEURISTIC_VARIANT,
) -> ChoiceResponse:
	var choice_view := ChoiceView.from_request(choice, state.revision)
	var result := worker.decide({
		"kind": "choice",
		"state": state.snapshot(),
		"actor": actor,
		"revision": state.revision,
		"request_id": request_id,
		"mode": "challenge",
		"deck_key": deck_key,
		"heuristic_variant": heuristic_variant,
		"choice": choice_view.to_dict(),
	}, func() -> bool: return false)
	_check(result.get("success", false), "AI choice decision failed: %s" % result.get("error", "unknown"))
	if not result.get("success", false):
		return null
	return ChoiceResponse.from_dict(result["choice_response"])


func _ai_choice_options_for_zone(
	catalog: CardCatalog,
	state: GameState,
	player_idx: int,
	zone: String,
) -> Array[Dictionary]:
	var source: Array[String] = []
	match zone:
		"hand":
			source = state.get_player(player_idx).hand
		"deck":
			source = state.get_player(player_idx).deck
		"discard":
			source = state.get_player(player_idx).discard
	var options: Array[Dictionary] = []
	for index in range(source.size()):
		var card_id := source[index]
		options.append({
			"option_id": "card:%s:%d:%s" % [zone, index, card_id],
			"label": catalog.card_name(card_id),
			"ref": EntityRef.new("card", player_idx, zone, "", index, "", card_id).to_dict(),
		})
	return options


func _ai_confirm_options() -> Array[Dictionary]:
	return [
		{"option_id": "confirm:yes", "label": "Yes"},
		{"option_id": "confirm:no", "label": "No"},
	]


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

	var valid := ProtocolV6.envelope(
		ProtocolV6.ACTION_SUBMIT,
		"room-1",
		1,
		1,
		7,
		"action-1",
		"",
		{"action": {}},
	)
	_check(
		ProtocolV6.validate(valid, "room-1", 1, 0).get("ok", false),
		"Protocol v6 rejected a valid message",
	)
	var wrong_version: Dictionary = valid.duplicate(true)
	wrong_version["protocol_version"] = 2
	_check(
		ProtocolV6.validate(wrong_version).get("code", "") == "protocol_mismatch",
		"Protocol v6 accepted an incompatible client",
	)
	_check(
		ProtocolV6.validate(valid, "room-1", 1, 1).get("code", "") == "stale_sequence",
		"Protocol v6 accepted a duplicate sequence",
	)
	var gap: Dictionary = valid.duplicate(true)
	gap["sequence"] = 3
	_check(
		ProtocolV6.validate(gap, "room-1", 1, 1).get("code", "") == "sequence_gap",
		"Protocol v6 accepted a sequence gap",
	)
	_check(
		ProtocolV6.validate(valid, "room-1", 0, 0).get("code", "") == "wrong_sender",
		"Protocol v6 accepted a forged sender",
	)
	var unknown: Dictionary = valid.duplicate(true)
	unknown["message_type"] = "write_state_directly"
	_check(
		ProtocolV6.validate(unknown).get("code", "") == "unknown_message_type",
		"Protocol v6 accepted an unknown message type",
	)
	var oversized := ProtocolV6.envelope(
		ProtocolV6.PING,
		"room-1",
		1,
		1,
		-1,
		"",
		"",
		{"padding": "x".repeat(ProtocolV6.MAX_MESSAGE_BYTES)},
	)
	_check(
		ProtocolV6.validate(oversized).get("code", "") == "message_too_large",
		"Protocol v6 accepted an oversized payload",
	)
	_check(
		ProtocolV6.validate_payload(
			ProtocolV6.ACTION_SUBMIT,
			{"action": "not-a-dictionary"},
		).get("code", "") == "invalid_payload",
		"Protocol v6 accepted a malformed action payload",
	)
	_check(
		ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE,
			{"state": "not-a-dictionary"},
		).get("code", "") == "invalid_payload",
		"Protocol v6 accepted a malformed state payload",
	)

	var session := AuthoritativeSession.new("room-1")
	var started := session.start_match("fire", "fire", 20260621, 0)
	_check(started.success, "Authoritative network session did not start")
	_check(
		session.state.public_deck_keys == ["fire", "fire"],
		"Authoritative session rejected or rewrote equal deck selections",
	)
	_check(
		session.state.players[0].deck != session.state.players[1].deck,
		"Equal deck selections did not receive independent shuffles",
	)
	var host_view := session.view_for(0)
	var client_view := session.view_for(1)
	_check(
		ProtocolV6.validate_payload(ProtocolV6.STATE_UPDATE, host_view).get("ok", false)
		and ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, client_view).get("ok", false),
		"Protocol v6 rejected an authoritative state view",
	)
	var excessive_deck_count: Dictionary = host_view.duplicate(true)
	excessive_deck_count["state"]["opponent"]["deck_count"] = 61
	_check(
		ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, excessive_deck_count).get("code", "")
		== "invalid_payload",
		"Protocol v6 accepted a deck count above 60",
	)
	var excessive_hand: Dictionary = host_view.duplicate(true)
	var oversized_hand: Array[String] = []
	oversized_hand.resize(61)
	oversized_hand.fill("sv-test")
	excessive_hand["state"]["your"]["hand"] = oversized_hand
	excessive_hand["state"]["your"]["hand_count"] = 61
	_check(
		ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, excessive_hand).get("code", "")
		== "invalid_payload",
		"Protocol v6 accepted more than 60 cards in hand",
	)
	var excessive_discard: Dictionary = host_view.duplicate(true)
	var oversized_discard: Array[String] = []
	oversized_discard.resize(61)
	oversized_discard.fill("sv-test")
	excessive_discard["state"]["opponent"]["discard"] = oversized_discard
	_check(
		ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, excessive_discard).get("code", "")
		== "invalid_payload",
		"Protocol v6 accepted more than 60 discarded cards",
	)
	var excessive_prize_count: Dictionary = host_view.duplicate(true)
	excessive_prize_count["state"]["opponent"]["prize_count"] = 7
	_check(
		ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, excessive_prize_count).get("code", "")
		== "invalid_payload",
		"Protocol v6 accepted a prize count above 6",
	)
	var excessive_bench: Dictionary = host_view.duplicate(true)
	excessive_bench["state"]["opponent"]["bench"].append(null)
	_check(
		ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, excessive_bench).get("code", "")
		== "invalid_payload",
		"Protocol v6 accepted more than five Bench slots",
	)
	var malformed_nested_state: Dictionary = host_view.duplicate(true)
	malformed_nested_state["state"]["your"]["active"] = {
		"card_id": "sv-test",
		"damage_counters": 0,
		"energy_card_ids": {"not": "an array"},
	}
	_check(
		ProtocolV6.validate_payload(
			ProtocolV6.STATE_UPDATE, malformed_nested_state).get("code", "")
		== "invalid_payload",
		"Protocol v6 accepted a malformed nested Pokemon payload",
	)
	var clamped_view_state := StateSerializer.from_player_view(
		excessive_deck_count["state"], 0)
	_check(
		clamped_view_state.players[1].deck.size() == ProtocolV6.MAX_DECK_CARDS,
		"State deserialization allocated an unbounded hidden deck",
	)
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
		var startup_generation_before: int = int(
			network_view_ui._startup_choreography_generation)
		network_view_ui._apply_network_view(view_row["view"], int(view_row["player"]))
		_check(not network_view_ui.modal_layer.visible,
			"Network %s view opened the local privacy overlay" % view_row["label"])
		_check(
			network_view_ui._network_view_is_fresh_match_start()
			and network_view_ui._startup_choreography_generation
			== startup_generation_before + 2,
			"Fresh network %s mount did not enter startup choreography"
			% view_row["label"],
		)
		network_view_ui.queue_free()
	var resync_view: Dictionary = host_view.duplicate(true)
	var resync_state_payload: Dictionary = resync_view["state"]
	resync_state_payload["revision"] = max(1, int(resync_state_payload["revision"]))
	resync_view["state"] = resync_state_payload
	resync_view["legal_action_groups"] = []
	resync_view["wait_context"] = {
		"waiting_for_player": 1,
		"choice_kind": "attachment",
	}
	var resync_view_ui := main_scene.instantiate()
	root.add_child(resync_view_ui)
	resync_view_ui.initialize_ui()
	var resync_generation_before: int = int(
		resync_view_ui._startup_choreography_generation)
	resync_view_ui._apply_network_view(resync_view, 0)
	_check(resync_view_ui.state != null,
		"Valid non-initial network state was rejected")
	_check(not resync_view_ui._network_view_is_fresh_match_start(),
		"Non-initial network state was classified as a fresh match")
	_check(
		resync_view_ui._startup_choreography_generation == resync_generation_before + 1
		and not resync_view_ui._startup_choreography_running,
		"Non-initial network state replayed startup choreography",
	)
	_check(not resync_view_ui.battle_screen.table._startup_input_blocked,
		"Non-initial network state left the startup input blocker active")
	_check(
		resync_view_ui.battle_screen.header.task_hint_label.text
		== "等待对手选择附着能量…",
		"Network transition completion did not refresh the coarse wait hint",
	)
	resync_view_ui.queue_free()
	var malformed_view_ui := main_scene.instantiate()
	root.add_child(malformed_view_ui)
	malformed_view_ui.initialize_ui()
	malformed_view_ui._apply_network_view({"state": {"your": "bad", "opponent": {}}}, 0)
	_check(
		malformed_view_ui.state == null,
		"Malformed network view was accepted by the main UI",
	)
	malformed_view_ui.queue_free()
	var legal: Array = host_view["legal_action_groups"]
	_check(not legal.is_empty(), "Authoritative session produced no setup action")
	if not legal.is_empty():
		var concrete := LegalActionGroup.from_dict(legal[0]).concrete_actions()
		var action: Dictionary = concrete[0].to_dict()
		action["action_id"] = "network-action-1"
		var step := session.submit_action(0, action)
		_check(step.success, "Authoritative session rejected a legal action")
		var duplicate := session.submit_action(0, action)
		_check(
			not duplicate.success and duplicate.error_code == "duplicate_action",
			"Authoritative session accepted a duplicate action ID",
		)
		var forged: Dictionary = concrete[0].to_dict()
		forged["actor"] = 1
		forged["action_id"] = "forged-action"
		_check(
			session.submit_action(0, forged).error_code == "unauthorized_actor",
			"Authoritative session accepted an action for another player",
		)

	var invalid_local_deck_controller := NetworkMatchController.new()
	_check(
		invalid_local_deck_controller.host_lan(0, "__missing_deck")
		== ERR_INVALID_PARAMETER
		and invalid_local_deck_controller.join_lan(
			"127.0.0.1", 0, "__missing_deck") == ERR_INVALID_PARAMETER
		and invalid_local_deck_controller.host_relay(
			"ws://127.0.0.1", "__missing_deck") == ERR_INVALID_PARAMETER
		and invalid_local_deck_controller.join_relay(
			"ws://127.0.0.1", "0000", "__missing_deck") == ERR_INVALID_PARAMETER
		and invalid_local_deck_controller.connection_phase
		== NetworkMatchController.ConnectionPhase.CLOSED,
		"Network controller accepted an unknown local deck key",
	)
	var invalid_session := AuthoritativeSession.new("invalid-deck-session")
	var invalid_session_start := invalid_session.start_match(
		"fire", "__missing_deck", 1)
	_check(
		not invalid_session_start.success
		and invalid_session_start.error_code == "invalid_deck"
		and invalid_session.state == null,
		"Authoritative session mutated state for an unknown deck key",
	)

	var lobby_controller := NetworkMatchController.new()
	var lobby_transport := FakeNetworkTransport.new()
	lobby_controller.host = true
	lobby_controller.player_idx = 0
	lobby_controller.connected = true
	lobby_controller.room_id = "room-same-deck"
	lobby_controller.local_deck_key = "fire"
	lobby_controller.seed = 20260621
	lobby_controller.transport = lobby_transport
	lobby_controller.session = AuthoritativeSession.new("room-same-deck")
	lobby_controller.connection_phase = NetworkMatchController.ConnectionPhase.LOBBY
	var same_deck_select := ProtocolV6.envelope(
		ProtocolV6.DECK_SELECT,
		"room-same-deck",
		1,
		1,
		-1,
		"",
		"",
		{
			"deck_key": "fire",
			"rules_version": AppState.RULES_SCHEMA_VERSION,
			"action_version": AppState.ACTION_SCHEMA_VERSION,
			"rules_profile_id": GameState.RULES_PROFILE_ID,
			"rules_options": lobby_controller.rules_options.duplicate(true),
		},
	)
	lobby_controller._handle_message(same_deck_select)
	var first_match_state := lobby_controller.session.state
	var first_match_revision := first_match_state.revision
	_check(
		lobby_controller.connection_phase
		== NetworkMatchController.ConnectionPhase.PLAYING
		and first_match_state.public_deck_keys == ["fire", "fire"],
		"Same-deck lobby selection did not start a match",
	)
	var repeated_deck_select: Dictionary = same_deck_select.duplicate(true)
	repeated_deck_select["sequence"] = 2
	lobby_controller._handle_message(repeated_deck_select)
	_check(
		lobby_controller.session.state == first_match_state
		and lobby_controller.session.state.revision == first_match_revision,
		"Repeated deck selection reset the active match",
	)
	_check(
		not lobby_transport.sent_messages.is_empty()
		and lobby_transport.sent_messages[-1]["payload"].get("code", "")
		== "invalid_phase",
		"Repeated deck selection was not rejected explicitly",
	)
	var schema_controller := NetworkMatchController.new()
	var schema_transport := FakeNetworkTransport.new()
	schema_controller.host = true
	schema_controller.player_idx = 0
	schema_controller.room_id = "room-schema"
	schema_controller.local_deck_key = "fire"
	schema_controller.seed = 17
	schema_controller.transport = schema_transport
	schema_controller.session = AuthoritativeSession.new("room-schema")
	schema_controller.connection_phase = NetworkMatchController.ConnectionPhase.LOBBY
	schema_controller._handle_message(ProtocolV6.envelope(
		ProtocolV6.DECK_SELECT,
		"room-schema",
		1,
		1,
		-1,
		"",
		"",
		{
			"deck_key": "fire",
			"rules_version": AppState.RULES_SCHEMA_VERSION + 1,
			"action_version": AppState.ACTION_SCHEMA_VERSION,
			"rules_profile_id": GameState.RULES_PROFILE_ID,
			"rules_options": {"apply_type_matchups": false},
		},
	))
	_check(
		schema_controller.session.state == null
		and not schema_transport.sent_messages.is_empty()
		and schema_transport.sent_messages[-1]["payload"].get("code", "")
		== "schema_mismatch",
		"Host accepted an incompatible rules schema",
	)
	var revision_controller := NetworkMatchController.new()
	var revision_transport := FakeNetworkTransport.new()
	revision_controller.host = false
	revision_controller.player_idx = 1
	revision_controller.room_id = "room-revision"
	revision_controller.transport = revision_transport
	revision_controller.connection_phase = NetworkMatchController.ConnectionPhase.PLAYING
	var mismatched_state_revision := ProtocolV6.envelope(
		ProtocolV6.STATE_UPDATE,
		"room-revision",
		0,
		1,
		int(client_view["state"]["revision"]) + 1,
		"",
		"",
		client_view,
	)
	revision_controller._handle_message(mismatched_state_revision)
	var revision_events := revision_controller._drain_events()
	_check(
		revision_controller.current_revision == -1
		and revision_events.any(func(event: Dictionary) -> bool:
			return event.get("code", "") == "revision_mismatch"),
		"Client accepted a state update with mismatched revisions",
	)

	var failed_send_controller := NetworkMatchController.new()
	var failed_send_transport := FakeNetworkTransport.new()
	failed_send_transport.send_succeeds = false
	failed_send_controller.host = true
	failed_send_controller.room_id = "room-send"
	failed_send_controller.transport = failed_send_transport
	_check(
		not failed_send_controller._send(ProtocolV6.PING)
		and failed_send_controller.send_sequence == 0,
		"Failed send consumed an outgoing sequence number",
	)
	failed_send_transport.send_succeeds = true
	_check(
		failed_send_controller._send(ProtocolV6.PING)
		and failed_send_controller.send_sequence == 1
		and failed_send_transport.sent_messages[-1]["sequence"] == 1,
		"Successful retry did not reuse the unconsumed sequence number",
	)

	var attack_controller := NetworkMatchController.new()
	var fake_transport := FakeNetworkTransport.new()
	attack_controller.host = true
	attack_controller.player_idx = 0
	attack_controller.room_id = "room-attack"
	attack_controller.transport = fake_transport
	attack_controller.session = AuthoritativeSession.new("room-attack")
	attack_controller.session.start_match("fire", "water", 99, 0)
	attack_controller.connection_phase = NetworkMatchController.ConnectionPhase.PLAYING
	var stale_wire_action := GameAction.create(
		"END_TURN", {}, 1, null, null, "stale-action",
		attack_controller.session.state.revision)
	var stale_message := ProtocolV6.envelope(
		ProtocolV6.ACTION_SUBMIT,
		"room-attack",
		1,
		1,
		-1,
		"stale-action",
		"",
		{"action": stale_wire_action.to_dict()},
	)
	attack_controller._handle_message(stale_message)
	_check(
		not fake_transport.sent_messages.is_empty()
		and fake_transport.sent_messages[0]["payload"].get("code", "")
		== "stale_revision",
		"Host accepted a stale state revision",
	)
	fake_transport.sent_messages.clear()
	attack_controller.session.state.processed_action_ids.append("retry-action")
	var retry_action := GameAction.create(
		"END_TURN", {}, 1, null, null, "retry-action",
		attack_controller.session.state.revision)
	var duplicate_retry := ProtocolV6.envelope(
		ProtocolV6.ACTION_SUBMIT,
		"room-attack",
		1,
		2,
		-1,
		"retry-action",
		"",
		{"action": retry_action.to_dict()},
	)
	attack_controller._handle_message(duplicate_retry)
	_check(
		not fake_transport.sent_messages.is_empty()
		and fake_transport.sent_messages[0]["payload"].get("code", "")
		== "duplicate_action",
		"An acknowledged action retry was reported stale before idempotency lookup",
	)
	var malformed_controller := NetworkMatchController.new()
	var malformed_transport := FakeNetworkTransport.new()
	malformed_controller.host = true
	malformed_controller.player_idx = 0
	malformed_controller.room_id = "room-malformed"
	malformed_controller.transport = malformed_transport
	malformed_controller.session = AuthoritativeSession.new("room-malformed")
	malformed_controller.session.start_match("fire", "water", 101, 0)
	var malformed_action := ProtocolV6.envelope(
		ProtocolV6.ACTION_SUBMIT,
		"room-malformed",
		1,
		1,
		malformed_controller.session.state.revision,
		"bad-action",
		"",
		{"action": "not-a-dictionary"},
	)
	malformed_controller._handle_message(malformed_action)
	_check(
		not malformed_transport.sent_messages.is_empty()
		and malformed_transport.sent_messages[0]["payload"].get("code", "")
		== "invalid_payload",
		"Host did not reject a malformed action payload cleanly",
	)
	var choice_controller := NetworkMatchController.new()
	var choice_transport := FakeNetworkTransport.new()
	choice_controller.host = true
	choice_controller.player_idx = 0
	choice_controller.room_id = "room-choice"
	choice_controller.transport = choice_transport
	choice_controller.session = AuthoritativeSession.new("room-choice")
	choice_controller.session.start_match("fire", "water", 100, 0)
	choice_controller.connection_phase = NetworkMatchController.ConnectionPhase.PLAYING
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
	var wrong_choice := ProtocolV6.envelope(
		ProtocolV6.CHOICE_SUBMIT,
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
		var probe := ProtocolV6.envelope(
			ProtocolV6.PING, "room-1", 1, 1)
		_check(client_transport.send(probe), "ENet client failed to send")
		var received := false
		for _poll in range(1000):
			client_transport.poll()
			for event in host_transport.poll():
				if (
					event.get("type", "") == "message"
					and event.get("message", {}).get("message_type", "") == ProtocolV6.PING
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
		"LAN controllers did not complete the v5 lobby handshake",
	)
	if not host_state_event.is_empty() and not client_state_event.is_empty():
		var host_match_view: Dictionary = host_state_event["view"]
		var client_match_view: Dictionary = client_state_event["view"]
		var initial_match_revision := int(host_match_view["state"]["revision"])
		_check(
			initial_match_revision == int(client_match_view["state"]["revision"]),
			"LAN controllers disagreed on the initial revision",
		)
		var host_choice_payload: Variant = host_match_view.get("choice_request")
		var client_choice_payload: Variant = client_match_view.get("choice_request")
		_check(
			(host_choice_payload is Dictionary) != (client_choice_payload is Dictionary),
			"LAN turn-order choice was not visible to exactly the coin winner",
		)
		var choosing_match: NetworkMatchController = host_match
		var turn_order_payload: Dictionary = {}
		if host_choice_payload is Dictionary:
			turn_order_payload = Dictionary(host_choice_payload)
		elif client_choice_payload is Dictionary:
			choosing_match = client_match
			turn_order_payload = Dictionary(client_choice_payload)
		if not turn_order_payload.is_empty():
			var turn_order_request := ChoiceRequest.from_dict(turn_order_payload)
			var turn_order_option := ""
			if not turn_order_request.options.is_empty():
				turn_order_option = str(turn_order_request.options[0].get("option_id", ""))
			_check(
				turn_order_request.request_type == "choose_turn_order"
				and not turn_order_option.is_empty(),
				"LAN opening choice was not a valid turn-order request",
			)
			_check(
				choosing_match.submit_choice(ChoiceResponse.new(
					turn_order_request.request_id, [turn_order_option])),
				"LAN turn-order choice was not accepted",
			)
			var host_choice_revision := initial_match_revision
			var client_choice_revision := initial_match_revision
			for _poll in range(4000):
				for event in host_match.poll():
					if event.get("type", "") == "state":
						host_match_view = event["view"]
						host_choice_revision = int(host_match_view["state"]["revision"])
				for event in client_match.poll():
					if event.get("type", "") == "state":
						client_match_view = event["view"]
						client_choice_revision = int(client_match_view["state"]["revision"])
				if (
					host_choice_revision > initial_match_revision
					and client_choice_revision > initial_match_revision
				):
					break
				OS.delay_msec(1)
			_check(
				host_choice_revision > initial_match_revision
				and client_choice_revision > initial_match_revision,
				"LAN peers did not receive the authoritative turn-order result",
			)

			var setup_match: NetworkMatchController = host_match
			var setup_actions: Array = host_match_view.get("legal_action_groups", [])
			if setup_actions.is_empty():
				setup_match = client_match
				setup_actions = client_match_view.get("legal_action_groups", [])
			_check(not setup_actions.is_empty(), "LAN setup actor received no legal placement")
			if not setup_actions.is_empty():
				var group := LegalActionGroup.from_dict(setup_actions[0])
				var match_action := group.concrete_actions()[0]
				var setup_base_revision := host_choice_revision
				_check(setup_match.submit_action(match_action), "LAN setup action was not accepted")
				var updated_host_revision := setup_base_revision
				var updated_client_revision := setup_base_revision
				for _poll in range(4000):
					for event in host_match.poll():
						if event.get("type", "") == "state":
							updated_host_revision = int(event["view"]["state"]["revision"])
					for event in client_match.poll():
						if event.get("type", "") == "state":
							updated_client_revision = int(event["view"]["state"]["revision"])
					if (
						updated_host_revision > setup_base_revision
						and updated_client_revision > setup_base_revision
					):
						break
					OS.delay_msec(1)
				_check(
					updated_host_revision > setup_base_revision
					and updated_client_revision > setup_base_revision,
					"LAN peers did not receive the authoritative setup result",
				)
	client_match.close()
	host_match.close()

	var packed := load("res://scenes/main/main.tscn") as PackedScene
	var network_ui := packed.instantiate()
	root.add_child(network_ui)
	network_ui.initialize_ui()
	var network_button := network_ui.find_child("NetworkButton", true, false) as Button
	_check(network_button != null and not network_button.disabled,
		"Network title entry is unavailable")
	_check(
		network_ui.find_child("LANButton", true, false) == null
		and network_ui.find_child("RelayButton", true, false) == null,
		"Network transports were not moved out of the title page",
	)
	network_ui.show_network_setup("lan")
	_check(
		network_ui.find_child("NetworkConnectButton", true, false) != null,
		"LAN lobby controls were not created",
	)
	var network_kind_option := network_ui.find_child(
		"NetworkKindOption", true, false
	) as OptionButton
	_check(
		network_kind_option != null
		and network_kind_option.item_count == 2
		and str(network_kind_option.get_item_metadata(0)) == "lan"
		and str(network_kind_option.get_item_metadata(1)) == "relay",
		"Network lobby does not expose LAN and Relay transport metadata",
	)
	network_ui.show_network_setup("relay")
	_check(
		network_ui.find_child("NetworkRoomInput", true, false) != null,
		"Relay room code input was not created",
	)
	network_ui.queue_free()


func _run_phase_six_foundation_tests() -> void:
	var release_manifest := _read_json("res://data/release_manifest.json")
	var app_state: Node = root.get_node("AppState")
	_check(
		str(app_state.get("APP_VERSION")) == str(release_manifest.get("version", "")),
		"Stage 6 app version does not match the release manifest",
	)
	var smoke_runner := ExportSmokeRunner.new()
	var smoke_runtime := DeepAIRuntime.new()
	var no_smoke := smoke_runner.run_if_requested(PackedStringArray(), smoke_runtime)
	_check(
		not bool(no_smoke.get("handled", true)),
		"Export smoke runner handled a normal application launch",
	)
	_check(
		smoke_runner._load_release_ui_resources(),
		"Export smoke runner could not load the release title/font/energy resources",
	)
	var network_smoke := smoke_runner.run_if_requested(
		PackedStringArray([ExportSmokeRunner.PHASE_FIVE_FLAG]),
		smoke_runtime,
	)
	_check(
		bool(network_smoke.get("handled", false))
		and bool(network_smoke.get("success", false))
		and int(network_smoke.get("exit_code", -1)) == 0
		and str(network_smoke.get("message", "")).begins_with(
			"PHASE6_EXPORT_NETWORK_OK"
		),
		"Export smoke runner did not preserve the phase 6 protocol contract",
	)
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
	_check_pointer_only_input_contract()
	for layout_failure in BattleTableLayoutContract.run():
		failures.append(layout_failure)
	_run_card_direct_interaction_contract_tests()
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
		"res://ui/energy_icon_catalog.gd",
		"res://ui/game_theme.tres",
		"res://ui/card_view.tscn",
		"res://ui/zone_view.tscn",
		"res://ui/dialogs/settings_panel.tscn",
		"res://ui/dialogs/choice_panel.tscn",
		"res://ui/dialogs/privacy_panel.tscn",
		"res://ui/dialogs/pause_panel.tscn",
		"res://presentation/presentation_event.gd",
		"res://presentation/presentation_director.gd",
		"res://scenes/battle/components/card_interaction_router.gd",
		"res://scenes/battle/components/card_action_popover.gd",
		"res://scenes/battle/components/card_action_popover.tscn",
		"res://scenes/battle/components/battle_table_layout.gd",
		"res://scenes/battle/playmat.gd",
		"res://scenes/title/title_page.tscn",
		"res://scenes/decks/deck_select_page.tscn",
		"res://scenes/network/network_lobby_page.tscn",
		"res://scenes/battle/battle_screen.tscn",
		"res://scenes/end/victory_screen.tscn",
		"res://tools/ui_workbench.tscn",
	]:
		_check(FileAccess.file_exists(path), "Visual upgrade asset is missing: %s" % path)
	var battle_playmat_source := FileAccess.get_file_as_string(
		"res://scenes/battle/playmat.gd"
	)
	_check(
		not battle_playmat_source.contains("lip_rect")
		and not battle_playmat_source.contains("_draw_bench_outline_without_top")
		and battle_playmat_source.contains("func _draw_bench_tray")
		and battle_playmat_source.contains(
			"_draw_rounded_panel(rect, tray_fill, tray_border, 1.5, 8.0)"
		)
		and battle_playmat_source.contains(
			"var lane_y := rect.end.y - 2.0 if side == \"opponent\" else rect.position.y + 2.0"
		),
		"Bench trays lost the shallow rounded treatment or restored the legacy beveled lip",
	)
	var expected_energy_icon_paths := {
		"Grass": "res://assets/ui/energy/grass.png",
		"Fire": "res://assets/ui/energy/fire.png",
		"Water": "res://assets/ui/energy/water.png",
		"Lightning": "res://assets/ui/energy/lightning.png",
		"Psychic": "res://assets/ui/energy/psychic.png",
		"Fighting": "res://assets/ui/energy/fighting.png",
		"Darkness": "res://assets/ui/energy/darkness.png",
		"Metal": "res://assets/ui/energy/metal.png",
		"Colorless": "res://assets/ui/energy/colorless.png",
	}
	var expected_energy_source_ids := {
		"Grass": "sv1-ener-1",
		"Fire": "sv1-ener-2",
		"Water": "sv1-ener-3",
		"Lightning": "sv1-ener-4",
		"Psychic": "sv1-ener-5",
		"Fighting": "sv1-ener-6",
		"Darkness": "sv1-ener-7",
		"Metal": "sv1-ener-8",
		"Colorless": "svi-mirc",
	}
	var normalized_energy_icon_paths: Array[String] = []
	for energy_type in expected_energy_icon_paths:
		var icon_path := EnergyIconCatalog.path_for(energy_type)
		normalized_energy_icon_paths.append(icon_path)
		_check(
			icon_path == expected_energy_icon_paths[energy_type]
			and FileAccess.file_exists(icon_path),
			"Energy icon mapping is missing or incorrect: %s" % energy_type,
		)
		_check(
			EnergyIconCatalog.texture_for(energy_type) != null,
			"Energy icon texture failed to load: %s" % energy_type,
		)
		_check(
			EnergyIconCatalog.source_card_id_for(energy_type)
			== expected_energy_source_ids[energy_type],
			"Energy icon source-card mapping is incorrect: %s" % energy_type,
		)
	var luminous_path := "res://assets/ui/energy/luminous.png"
	normalized_energy_icon_paths.append(luminous_path)
	_check(
		EnergyIconCatalog.path_for_card_id("svg2-lume") == luminous_path
		and FileAccess.file_exists(luminous_path)
		and EnergyIconCatalog.texture_for_card_id("svg2-lume") != null,
		"Luminous Energy icon mapping is missing or failed to load",
	)
	for icon_path in normalized_energy_icon_paths:
		var icon_image := Image.load_from_file(ProjectSettings.globalize_path(icon_path))
		_check(
			icon_image != null
			and icon_image.get_size() == Vector2i(256, 256)
			and icon_image.get_pixel(0, 0).a == 0.0
			and icon_image.get_pixel(128, 128).a > 0.95,
			"Energy icon is not a normalized transparent 256px asset: %s" % icon_path,
		)
		var import_source := _read_text("%s.import" % icon_path)
		_check(
			import_source.find("compress/mode=0") >= 0
			and import_source.find("mipmaps/generate=true") >= 0
			and import_source.find("process/fix_alpha_border=true") >= 0,
			"Energy icon import must be Lossless with mipmaps and alpha-border repair: %s"
			% icon_path,
		)
	_check(
		EnergyIconCatalog.texture_for_card_id("svi-dtur") == null,
		"An unsupported special-energy card unexpectedly exposed an icon",
	)
	for unsupported_type in ["Dragon", "Rainbow", "Special", "Unknown"]:
		_check(
			EnergyIconCatalog.texture_for(unsupported_type) == null,
			"Unsupported energy type unexpectedly exposed an icon: %s" % unsupported_type,
		)

	var main_scene := load("res://scenes/main/main.tscn") as PackedScene
	var main_preview := main_scene.instantiate()
	root.add_child(main_preview)
	_check_pointer_only_focus_tree(main_preview, "Main title/modal shell")
	var shell_animations := main_preview.find_child(
		"ShellAnimations", true, false
	) as AnimationPlayer
	_check(
		shell_animations != null
		and shell_animations.has_animation("modal_open")
		and shell_animations.has_animation("modal_close"),
		"Main shell does not expose editable modal open and close animations",
	)
	_check(
		main_preview._network_connection_fields_valid("lan", "host", "", "")
		and not main_preview._network_connection_fields_valid("lan", "client", "", "")
		and main_preview._network_connection_fields_valid(
			"relay", "host", "wss://relay.example.test", ""
		)
		and not main_preview._network_connection_fields_valid(
			"relay", "client", "wss://relay.example.test", ""
		),
		"Main network validation mishandled LAN-host or Relay address requirements",
	)
	main_preview.free()

	var page_contracts := {
		"res://scenes/title/title_page.tscn": [
			"LocalTwoPlayerButton", "AIButton", "NetworkButton",
			"SettingsButton", "HelpButton",
		],
		"res://scenes/decks/deck_select_page.tscn": [
			"PlayerOneSlotButton", "PlayerTwoSlotButton", "GalleryGrid",
			"AIModeOption", "DetailsButton", "StartButton",
		],
		"res://scenes/network/network_lobby_page.tscn": [
			"NetworkKindOption", "NetworkRoleOption", "NetworkAddressInput",
			"NetworkConnectButton",
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
	var motion_settings: Node = root.get_node("AppSettings")
	var motion_previous_animation_mode := str(motion_settings.get("animation_mode"))
	var motion_previous_quality_profile := str(motion_settings.get("quality_profile"))
	motion_settings.call(
		"update",
		float(motion_settings.get("master_volume")),
		bool(motion_settings.get("muted")),
		false,
		int(motion_settings.get("card_cache_size")),
		"standard",
		"low",
		float(motion_settings.get("music_volume")),
		float(motion_settings.get("sfx_volume")),
	)
	var frontend_motion := load("res://ui/frontend/frontend_motion.gd")
	_check(
		is_zero_approx(float(frontend_motion.duration(0.24))),
		"Low quality did not disable frontend transition motion",
	)
	motion_settings.call(
		"update",
		float(motion_settings.get("master_volume")),
		bool(motion_settings.get("muted")),
		motion_previous_animation_mode == "reduced",
		int(motion_settings.get("card_cache_size")),
		motion_previous_animation_mode,
		motion_previous_quality_profile,
		float(motion_settings.get("music_volume")),
		float(motion_settings.get("sfx_volume")),
	)
	var title_scene := load("res://scenes/title/title_page.tscn") as PackedScene
	var title_page := title_scene.instantiate()
	root.add_child(title_page)
	title_page.configure("Signal Test")
	_check_pointer_only_focus_tree(title_page, "Title page")
	var title_modes: Array[String] = []
	var title_network_kinds: Array[String] = []
	var title_signals := {}
	title_page.mode_selected.connect(
		func(mode: String) -> void: title_modes.append(mode)
	)
	title_page.network_selected.connect(
		func(kind: String) -> void: title_network_kinds.append(kind)
	)
	title_page.settings_requested.connect(
		func() -> void: title_signals["settings"] = true
	)
	title_page.help_requested.connect(
		func() -> void: title_signals["help"] = true
	)
	(title_page.find_child("LocalTwoPlayerButton", true, false) as Button).pressed.emit()
	(title_page.find_child("AIButton", true, false) as Button).pressed.emit()
	(title_page.find_child("NetworkButton", true, false) as Button).pressed.emit()
	(title_page.find_child("SettingsButton", true, false) as Button).pressed.emit()
	(title_page.find_child("HelpButton", true, false) as Button).pressed.emit()
	_check(title_modes == ["local", "challenge"],
		"Title page did not emit local and default Challenge modes")
	_check(title_network_kinds == ["lan"],
		"Title page network signal did not default to LAN")
	_check(bool(title_signals.get("settings", false)),
		"Title page settings signal was not emitted")
	_check(bool(title_signals.get("help", false)),
		"Title page help signal was not emitted")
	var title_pointer_buttons: Array[Button] = []
	for button_name in [
		"LocalTwoPlayerButton", "AIButton", "NetworkButton",
		"SettingsButton", "HelpButton",
	]:
		title_pointer_buttons.append(
			title_page.find_child(button_name, true, false) as Button
		)
	for button in title_pointer_buttons:
		_check(
			button != null and button.focus_mode == Control.FOCUS_NONE,
			"Title control must be pointer/touch-only: %s" % (
				button.name if button != null else "missing button"
			),
		)
	for legacy_name in [
		"ChallengeAIButton", "DeepAIButton", "LANButton", "RelayButton", "OnlineCard",
	]:
		_check(
			title_page.find_child(legacy_name, true, false) == null,
			"Title page retained legacy node %s" % legacy_name,
		)
	title_page.queue_free()

	var deck_scene := load(
		"res://scenes/decks/deck_select_page.tscn"
	) as PackedScene
	var deck_page := deck_scene.instantiate()
	root.add_child(deck_page)
	deck_page.configure(page_catalog, "challenge")
	_check_pointer_only_focus_tree(deck_page, "Deck selection page")
	var ai_mode_option := deck_page.find_child(
		"AIModeOption", true, false
	) as OptionButton
	_check(ai_mode_option != null, "Deck page AI mode selector is missing")
	if ai_mode_option:
		_check(
			ai_mode_option.item_count == 1
			and str(ai_mode_option.get_item_metadata(0)) == "challenge"
			and ai_mode_option.disabled,
			"Deck page must expose only the release-enabled Challenge AI mode",
		)
		_check(
			str(ai_mode_option.get_item_metadata(ai_mode_option.selected)) == "challenge",
			"Challenge configure did not preselect Challenge AI",
		)
	_check(
		deck_page.first_player_option.item_count == 1
		and int(deck_page.first_player_option.get_item_metadata(0)) == -1
		and deck_page.first_player_option.disabled,
		"Deck page must defer turn order to the opening coin winner",
	)
	var deck_keys: Array = page_catalog.decks.keys()
	deck_keys.sort()
	if deck_keys.size() >= 2:
		deck_page.select_deck(0, str(deck_keys[-1]))
		deck_page.select_deck(1, str(deck_keys[-2]))
	deck_page.player_two_slot_button.pressed.emit()
	deck_page.gallery_scroll.scroll_vertical = 37
	var preserved_deck_state := {
		"first": deck_page.selected_deck_key(0),
		"second": deck_page.selected_deck_key(1),
		"active": deck_page._active_player_idx,
		"first_player": deck_page.first_player_option.selected,
		"scroll": deck_page.gallery_scroll.scroll_vertical,
		"detail": deck_page.detail_title.text,
	}
	if ai_mode_option:
		ai_mode_option.select(0)
		ai_mode_option.item_selected.emit(0)
	_check(deck_page.mode == "challenge", "Deck page changed the release AI mode")
	_check(
		deck_page.selected_deck_key(0) == preserved_deck_state["first"]
		and deck_page.selected_deck_key(1) == preserved_deck_state["second"]
		and deck_page._active_player_idx == preserved_deck_state["active"]
		and deck_page.first_player_option.selected == preserved_deck_state["first_player"]
		and deck_page.gallery_scroll.scroll_vertical == preserved_deck_state["scroll"]
		and deck_page.detail_title.text == preserved_deck_state["detail"],
		"Switching AI type reset deck selection, turn, detail, or scroll state",
	)
	var deck_signal := {}
	deck_page.start_requested.connect(func(
		mode: String,
		first_key: String,
		second_key: String,
		forced_first: int,
		apply_type_matchups: bool,
	) -> void:
		deck_signal.merge({
			"mode": mode,
			"first": first_key,
			"second": second_key,
			"forced_first": forced_first,
			"apply_type_matchups": apply_type_matchups,
		}, true)
	)
	deck_page.deck_details_requested.connect(
		func(deck_key: String) -> void: deck_signal["details"] = deck_key
	)
	(deck_page.find_child("StartButton", true, false) as Button).pressed.emit()
	(deck_page.find_child("DetailsButton", true, false) as Button).pressed.emit()
	_check(deck_signal.get("mode", "") == "challenge",
		"Deck page start signal did not carry the release AI mode")
	_check(not str(deck_signal.get("first", "")).is_empty(),
		"Deck page start signal omitted the first deck")
	_check(not str(deck_signal.get("second", "")).is_empty(),
		"Deck page start signal omitted the second deck")
	_check(
		int(deck_signal.get("forced_first", 99)) == -1
		and not bool(deck_signal.get("apply_type_matchups", true)),
		"Deck page start signal changed official turn-order or default matchup rules",
	)
	_check(
		deck_page.find_child("AIDifficultyOption", true, false) == null,
		"Deck page still exposed an AI difficulty selector",
	)
	_check(not str(deck_signal.get("details", "")).is_empty(),
		"Deck page details signal omitted the selected deck")
	deck_page.queue_free()

	var network_scene := load(
		"res://scenes/network/network_lobby_page.tscn"
	) as PackedScene
	var network_page := network_scene.instantiate()
	root.add_child(network_page)
	network_page.configure(page_catalog, "lan", "wss://relay.example.test")
	_check_pointer_only_focus_tree(network_page, "Network lobby page")
	for editable_input: LineEdit in [
		network_page.address_input,
		network_page.port_input,
		network_page.room_input,
	]:
		_check(
			editable_input.focus_mode == Control.FOCUS_CLICK,
			"Network text input must require pointer/touch focus: %s"
			% editable_input.name,
		)
	_check(
		network_page.room_code_display.focus_mode == Control.FOCUS_NONE,
		"Read-only network room code must not enter keyboard/controller focus",
	)
	network_page._compact = false
	network_page._apply_compact_step_visibility()
	var kind_option := network_page.find_child(
		"NetworkKindOption", true, false
	) as OptionButton
	_check(kind_option != null, "Network kind selector is missing")
	var lan_index := -1
	var relay_index := -1
	if kind_option:
		for index in range(kind_option.item_count):
			var metadata := str(kind_option.get_item_metadata(index))
			if metadata == "lan":
				lan_index = index
			elif metadata == "relay":
				relay_index = index
		_check(
			kind_option.item_count == 2 and lan_index >= 0 and relay_index >= 0,
			"Network kind metadata does not expose LAN and Relay",
		)
		_check(
			str(kind_option.get_item_metadata(kind_option.selected)) == "lan",
			"LAN configure did not preselect LAN",
		)
	var changed_kinds: Array[String] = []
	network_page.kind_changed.connect(
		func(kind: String) -> void: changed_kinds.append(kind)
	)
	network_page.role_option.select(1)
	network_page.refresh_fields(1)
	if network_page.deck_option.item_count > 1:
		network_page.deck_option.select(1)
	var preserved_role: int = network_page.role_option.selected
	var preserved_deck: int = network_page.deck_option.selected
	network_page.address_input.text = "192.168.1.44"
	network_page.address_input.text_changed.emit(network_page.address_input.text)
	network_page.set_connection_state(
		NetworkLobbyPage.ConnectionState.WAITING,
		"旧 LAN 房间等待中",
		"OLDLAN",
	)
	_check(
		kind_option != null and kind_option.disabled,
		"Network kind selector was not locked while waiting",
	)
	if kind_option and relay_index >= 0:
		kind_option.select(relay_index)
		kind_option.item_selected.emit(relay_index)
	_check(
		kind_option != null
		and network_page.kind == "lan"
		and str(kind_option.get_item_metadata(kind_option.selected)) == "lan"
		and changed_kinds.is_empty(),
		"Locked network kind selector changed transport",
	)
	network_page.set_connection_state(
		NetworkLobbyPage.ConnectionState.ERROR,
		"旧 LAN 连接错误",
	)
	network_page.address_error.visible = true
	if kind_option and relay_index >= 0:
		kind_option.select(relay_index)
		kind_option.item_selected.emit(relay_index)
	_check(changed_kinds == ["relay"] and network_page.kind == "relay",
		"Network kind change did not emit Relay")
	_check(
		network_page.connection_state == NetworkLobbyPage.ConnectionState.IDLE
		and network_page.role_option.selected == preserved_role
		and network_page.deck_option.selected == preserved_deck
		and network_page.room_input.text.is_empty()
		and network_page._current_room_code.is_empty()
		and not network_page.room_code_display.visible
		and not network_page.address_error.visible
		and not network_page.status_label.text.contains("旧 LAN"),
		"Switching to Relay did not preserve selections or clear stale lobby state",
	)
	_check(
		not network_page.port_row.visible and network_page.room_row.visible,
		"Relay client fields did not hide the LAN port and show the room code",
	)
	network_page.address_input.text = "wss://relay.custom.test"
	network_page.address_input.text_changed.emit(network_page.address_input.text)
	network_page.room_input.text = "STALE42"
	network_page.room_error.visible = true
	network_page.set_connection_state(
		NetworkLobbyPage.ConnectionState.ERROR,
		"旧 Relay 连接错误",
	)
	if kind_option and lan_index >= 0:
		kind_option.select(lan_index)
		kind_option.item_selected.emit(lan_index)
	_check(changed_kinds == ["relay", "lan"] and network_page.kind == "lan",
		"Network kind change did not emit LAN")
	_check(
		network_page.address_input.text == "192.168.1.44"
		and network_page.role_option.selected == preserved_role
		and network_page.deck_option.selected == preserved_deck
		and network_page.room_input.text.is_empty()
		and not network_page.room_error.visible
		and network_page.port_row.visible and not network_page.room_row.visible,
		"Switching to LAN did not restore its draft or update transport fields",
	)
	if kind_option and relay_index >= 0:
		kind_option.select(relay_index)
		kind_option.item_selected.emit(relay_index)
	_check(
		network_page.address_input.text == "wss://relay.custom.test",
		"Switching back to Relay did not restore the Relay address draft",
	)
	network_page.room_input.text = "ROOM42"
	var network_signal := {}
	network_page.connect_requested.connect(func(
		kind: String,
		role: String,
		address: String,
		port: int,
		room_code: String,
		deck_key: String,
		apply_type_matchups: bool,
	) -> void:
		network_signal.merge({
			"kind": kind,
			"role": role,
			"address": address,
			"port": port,
			"room": room_code,
			"deck": deck_key,
			"apply_type_matchups": apply_type_matchups,
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
	_check(network_signal.get("address", "") == "wss://relay.custom.test"
		and int(network_signal.get("port", 0)) > 0,
		"Network page signal changed the address/port payload shape")
	_check(not str(network_signal.get("deck", "")).is_empty(),
		"Network page signal omitted the selected deck")
	_check(not bool(network_signal.get("apply_type_matchups", true)),
		"Network challenger changed the host-locked default matchup option")
	network_page.set_connection_state(
		NetworkLobbyPage.ConnectionState.WAITING,
		"旧房间等待中",
		"OLDROOM",
	)
	_check(network_page.room_code_display.visible,
		"Relay host room code was not exposed while waiting")
	network_page.set_connection_state(NetworkLobbyPage.ConnectionState.VALIDATING)
	_check(network_page._current_room_code.is_empty()
		and not network_page.room_code_display.visible,
		"Starting a new network attempt retained the previous room code")
	network_page.set_connection_state(NetworkLobbyPage.ConnectionState.WAITING)
	_check(not network_page.room_code_display.visible,
		"Relay retry displayed a stale room code before room_created")
	_check(not network_page.address_input.accessibility_name.is_empty()
		and not network_page.deck_option.accessibility_name.is_empty(),
		"Network form controls are missing accessible names")
	network_page.set_connection_state(NetworkLobbyPage.ConnectionState.IDLE)
	if kind_option and lan_index >= 0:
		kind_option.select(lan_index)
		kind_option.item_selected.emit(lan_index)
	network_page.role_option.select(0)
	network_page.refresh_fields(0)
	network_page.address_input.text = ""
	network_page.address_input.text_changed.emit("")
	network_signal.clear()
	(network_page.find_child(
		"NetworkConnectButton", true, false
	) as Button).pressed.emit()
	_check(
		network_signal.get("kind", "") == "lan"
		and network_signal.get("role", "") == "host"
		and network_signal.get("address", "sentinel") == ""
		and not bool(network_signal.get("apply_type_matchups", true))
		and not network_page.address_input.editable,
		"LAN host was blocked by its hidden, unused address field",
	)
	network_page.queue_free()

	var settings_scene := load(
		"res://ui/dialogs/settings_panel.tscn"
	) as PackedScene
	var settings_panel := settings_scene.instantiate()
	root.add_child(settings_panel)
	settings_panel.configure()
	_check_pointer_only_focus_tree(settings_panel, "Settings panel")
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
	settings_panel.reduced_motion_toggle.button_pressed = true
	_check(
		str(settings_panel.animation_mode_option.get_item_metadata(
			settings_panel.animation_mode_option.selected
		)) == "reduced",
		"Reduced-motion toggle did not update the animation mode selector",
	)
	var standard_index := -1
	for index in range(settings_panel.animation_mode_option.item_count):
		if settings_panel.animation_mode_option.get_item_metadata(index) == "standard":
			standard_index = index
			break
	settings_panel.animation_mode_option.select(standard_index)
	settings_panel.animation_mode_option.item_selected.emit(standard_index)
	_check(not settings_panel.reduced_motion_toggle.button_pressed
		and not bool(settings_panel.values().get("reduced_motion", true)),
		"Animation mode selector did not clear the reduced-motion toggle")
	_check(not settings_panel.master_volume_slider.accessibility_name.is_empty()
		and not settings_panel.sfx_volume_slider.accessibility_name.is_empty(),
		"Settings sliders are missing accessible names")
	settings_panel.queue_free()

	var modal_ui := main_scene.instantiate()
	root.add_child(modal_ui)
	modal_ui.initialize_ui()
	_check(
		not modal_ui.modal_scroll.follow_focus
		and modal_ui.modal_confirm.focus_mode == Control.FOCUS_NONE
		and modal_ui.modal_cancel.focus_mode == Control.FOCUS_NONE,
		"Main modal shell must be pointer/touch-only",
	)
	_check_pointer_only_focus_tree(modal_ui, "Main modal shell")
	_check(modal_ui.toast_label.theme_type_variation == &"FrontToastLabel"
		and modal_ui.toast_label.get_theme_constant("outline_size") <= 2,
		"Toast typography is not using the readable frontend status style")
	var scaled_safe_insets: Vector4 = modal_ui._safe_insets_to_canvas(
		Vector2i(1920, 0),
		Vector2i(2400, 1080),
		Rect2i(1968, 24, 2304, 1032),
		Vector2(2000, 900),
	)
	_check(
		scaled_safe_insets.is_equal_approx(Vector4(40, 20, 40, 20)),
		"Physical display safe area was not converted to logical canvas units",
	)
	var choice_controller := AcceptingChoiceNetworkController.new(page_catalog)
	modal_ui.network_controller = choice_controller
	modal_ui.game_mode = "network"
	modal_ui.state = null
	modal_ui.active_request = ChoiceRequest.new(
		"choice:network-ui",
		"select_card",
		0,
		"选择一项",
		[{"option_id": "one", "label": "第一项"}],
		1,
		1,
		false,
	)
	modal_ui.selected_choice_ids.assign(["one"])
	modal_ui._confirm_choice()
	_check(
		choice_controller.submitted_response != null
		and choice_controller.submitted_response.option_ids == ["one"],
		"Network choice was not submitted to the authoritative controller",
	)
	modal_ui.game_mode = "local"
	modal_ui._show_settings()
	var retryable_settings_save := false
	for connection in modal_ui.modal_confirm.pressed.get_connections():
		var callback: Callable = connection.get("callable", Callable())
		if callback.get_method() == &"request_save":
			retryable_settings_save = (
				int(connection.get("flags", 0)) & CONNECT_ONE_SHOT
			) == 0
	_check(
		retryable_settings_save,
		"Settings save action cannot be retried after a transient write failure",
	)
	modal_ui._close_modal()
	modal_ui._finish_modal_close(modal_ui._modal_generation)
	modal_ui._show_help()
	_check(modal_ui.modal_layer.visible,
		"Help modal did not open from the main shell")
	_check_pointer_only_focus_tree(modal_ui.modal_layer, "Help modal")
	_check(is_equal_approx(float(modal_ui.modal_shade.color.a), 0.72),
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
	modal_ui._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	modal_ui._finish_modal_close(modal_ui._modal_generation)
	_check(not modal_ui.modal_layer.visible,
		"System back did not close the cancellable frontend help modal")
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
	_check_pointer_only_focus_tree(modal_ui.modal_layer, "Battle choice modal")
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
	privacy_ui._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	_check(privacy_ui.modal_layer.visible,
		"System back dismissed the non-cancellable hot-seat privacy overlay")
	privacy_ui._finish_modal_close(privacy_ui._modal_generation)
	privacy_ui._refresh_game()
	# Hot-seat rendering must receive a player-view clone, not the authoritative
	# in-process state. Verify the presentation object itself contains no hidden
	# identities even if a future widget forgets to draw a privacy cover.
	var saved_authoritative_state: GameState = privacy_ui.state
	var saved_view_player: int = privacy_ui.current_view_player
	var hidden_authoritative_state := saved_authoritative_state.clone_state()
	hidden_authoritative_state.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	hidden_authoritative_state.setup_actor_idx = 0
	hidden_authoritative_state.get_player(0).hand.assign(["sv1-104", "sv1-107"])
	hidden_authoritative_state.get_player(1).hand.assign(["sv1-106", "sv1-108"])
	hidden_authoritative_state.get_player(0).deck.assign(["sv1-109", "sv1-110"])
	hidden_authoritative_state.get_player(1).deck.assign(["sv1-111", "sv1-112"])
	hidden_authoritative_state.get_player(0).prizes.assign(["sv1-113", "sv1-114"])
	hidden_authoritative_state.get_player(1).prizes.assign(["sv1-150", "sv1-151"])
	hidden_authoritative_state.get_player(0).discard.assign(["sv1-104"])
	hidden_authoritative_state.get_player(1).discard.assign(["sv1-106"])
	hidden_authoritative_state.get_player(0).active = PokemonState.new("sv1-104")
	hidden_authoritative_state.get_player(1).active = PokemonState.new("sv1-106")
	hidden_authoritative_state.get_player(0).bench[0] = PokemonState.new("sv1-107")
	hidden_authoritative_state.get_player(1).bench[0] = PokemonState.new("sv1-108")
	privacy_ui.state = hidden_authoritative_state
	privacy_ui.current_view_player = 0
	privacy_ui._refresh_game()
	var player_zero_view: GameState = privacy_ui.battle_screen.table.state_ref
	_check(
		player_zero_view != hidden_authoritative_state
		and player_zero_view.get_player(0).hand == ["sv1-104", "sv1-107"]
		and player_zero_view.get_player(1).hand.all(
			func(card_id: String) -> bool: return card_id.is_empty())
		and player_zero_view.get_player(0).deck.all(
			func(card_id: String) -> bool: return card_id.is_empty())
		and player_zero_view.get_player(1).deck.all(
			func(card_id: String) -> bool: return card_id.is_empty())
		and player_zero_view.get_player(0).prizes.all(
			func(card_id: String) -> bool: return card_id.is_empty())
		and player_zero_view.get_player(1).prizes.all(
			func(card_id: String) -> bool: return card_id.is_empty())
		and player_zero_view.get_player(0).active.card_id == "sv1-104"
		and player_zero_view.get_player(1).active.card_id.is_empty()
		and player_zero_view.get_player(1).bench[0].card_id.is_empty()
		and player_zero_view.get_player(1).discard == ["sv1-106"],
		"Hot-seat player 1 presentation input leaked a hidden identity",
	)
	privacy_ui.current_view_player = 1
	hidden_authoritative_state.setup_actor_idx = 1
	privacy_ui._refresh_game()
	var player_one_view: GameState = privacy_ui.battle_screen.table.state_ref
	_check(
		player_one_view.get_player(1).hand == ["sv1-106", "sv1-108"]
		and player_one_view.get_player(0).hand.all(
			func(card_id: String) -> bool: return card_id.is_empty())
		and player_one_view.get_player(1).active.card_id == "sv1-106"
		and player_one_view.get_player(0).active.card_id.is_empty()
		and hidden_authoritative_state.get_player(0).active.card_id == "sv1-104"
		and hidden_authoritative_state.get_player(1).prizes == ["sv1-150", "sv1-151"],
		"Hot-seat player 2 presentation input leaked or mutated authoritative state",
	)
	hidden_authoritative_state.setup_stage = GameState.SETUP_COMPLETE
	privacy_ui.current_view_player = 0
	privacy_ui._refresh_game()
	var revealed_player_view: GameState = privacy_ui.battle_screen.table.state_ref
	_check(
		revealed_player_view.get_player(1).active.card_id == "sv1-106"
		and revealed_player_view.get_player(1).bench[0].card_id == "sv1-108"
		and revealed_player_view.get_player(1).hand.all(
			func(card_id: String) -> bool: return card_id.is_empty())
		and revealed_player_view.get_player(1).prizes.all(
			func(card_id: String) -> bool: return card_id.is_empty()),
		"Completed setup did not reveal only the opponent's public board",
	)
	privacy_ui.state = saved_authoritative_state
	privacy_ui.current_view_player = saved_view_player
	privacy_ui._refresh_game()
	# The synchronous runner has no rendered container pass. Seed the menu and
	# turn-status rectangles that bound the final battle-header feedback gap.
	var battle_menu: Button = privacy_ui.battle_screen.header.menu_button
	var battle_turn_status: Label = privacy_ui.battle_screen.header.turn_label
	battle_menu.position = Vector2(12.0, 10.0)
	battle_menu.size = Vector2(84.0, 48.0)
	battle_turn_status.position = Vector2(620.0, 12.0)
	battle_turn_status.size = Vector2(292.0, 44.0)
	privacy_ui._show_toast("能量已附着。")
	privacy_ui._layout_toast(Vector2(1280.0, 720.0), 0, 0, 0, 0)
	var battle_toast_rect: Rect2 = privacy_ui.toast_label.get_global_rect()
	var battle_menu_rect: Rect2 = battle_menu.get_global_rect()
	var battle_turn_rect: Rect2 = battle_turn_status.get_global_rect()
	_check(
		battle_toast_rect.position.x >= battle_menu_rect.end.x + 12.0
		and battle_toast_rect.end.x <= battle_turn_rect.position.x - 12.0
		and not battle_toast_rect.intersects(battle_menu_rect)
		and not battle_toast_rect.intersects(battle_turn_rect)
		and battle_toast_rect.size.x <= 300.0
		and battle_toast_rect.size.y >= 44.0
		and battle_toast_rect.size.y <= 52.0,
		"Battle toast escaped the reserved header gap: toast=%s menu=%s turn=%s screen=%s" % [
			battle_toast_rect,
			battle_menu_rect,
			battle_turn_rect,
			privacy_ui.current_screen,
		],
	)
	privacy_ui.battle_screen._on_detail_requested("sv1-104")
	_check_pointer_only_focus_tree(privacy_ui.modal_layer, "Battle card inspector")
	_check(
		privacy_ui.modal_layer.visible
		and privacy_ui.modal_body.find_child("CardInspectorPanel", true, false) != null
		and privacy_ui.battle_screen.detail_panel != null
		and privacy_ui.battle_screen.find_child("DetailPanel", true, false) != null
		and not privacy_ui.battle_screen.detail_panel.visible,
		"Long press did not use the modal inspector while hiding the tap preview",
	)
	_check(
		privacy_ui.modal_confirm.custom_minimum_size.y >= 48.0
		and privacy_ui.modal_confirm.focus_mode == Control.FOCUS_NONE,
		"Card inspector close control is below the 48 px touch target",
	)
	privacy_ui.modal_confirm.pressed.emit()
	privacy_ui._finish_modal_close(privacy_ui._modal_generation)
	privacy_ui.battle_screen.show_card_detail("sv1-104")
	_check(
		privacy_ui.battle_screen.detail_panel.visible,
		"Battle floating card preview could not be reopened after the inspector",
	)
	# Exercise the complete GUI signal chain rather than calling Main directly:
	# Header -> BattleTable -> BattleScreen -> Main. The header must also stay
	# above every table-local surface so touch hit testing cannot be intercepted.
	var battle_root_surface := privacy_ui.battle_screen.table.get_node(
		"BattleRoot"
	) as Control
	var battle_body_surface := privacy_ui.battle_screen.table.get_node(
		"BattleRoot/Body"
	) as Control
	var battle_action_panel := privacy_ui.battle_screen.table.action_popover.get_node(
		"Panel"
	) as Control
	_check(
		privacy_ui.battle_screen.header.z_index
		> privacy_ui.battle_screen.table.action_popover.z_index
		and privacy_ui.battle_screen.header.z_index
		> privacy_ui.battle_screen.input_blocker.z_index
		and battle_root_surface.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and battle_body_surface.mouse_filter == Control.MOUSE_FILTER_IGNORE
		and privacy_ui.battle_screen.board_panel.mouse_filter
		== Control.MOUSE_FILTER_IGNORE
		and privacy_ui.battle_screen.board_canvas.mouse_filter
		== Control.MOUSE_FILTER_IGNORE
		and privacy_ui.battle_screen.table.action_popover.mouse_filter
		== Control.MOUSE_FILTER_IGNORE
		and battle_action_panel.mouse_filter == Control.MOUSE_FILTER_STOP
		and privacy_ui.battle_screen.input_blocker.offset_top >= 68.0,
		"Battle menu can be intercepted by a table-local overlay",
	)
	privacy_ui.battle_screen.header.menu_button.pressed.emit()
	_check(
		privacy_ui.modal_layer.visible
		and privacy_ui.modal_title.text == "对局菜单",
		"Battle menu button did not open the pause modal through the public signal chain",
	)
	_check(privacy_ui.modal_layer.z_index > privacy_ui.battle_screen.z_index + 20,
		"Pause menu modal layer can be drawn under battle overlay panels")
	_check(
		privacy_ui.battle_screen.find_child("DetailPanel", true, false) != null
		and not privacy_ui.battle_screen.detail_panel.visible,
		"Pause menu did not hide the transient card preview",
	)
	_check(float(privacy_ui.modal_shade.color.a) >= 0.99,
		"Pause menu did not use an opaque privacy shade")
	privacy_ui._finish_modal_close(privacy_ui._modal_generation)
	privacy_ui.show_title()
	privacy_ui._show_help()
	_check(is_equal_approx(float(privacy_ui.modal_shade.color.a), 0.72),
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
	var director_probe := PresentationDirector.new()
	root.add_child(director_probe)
	var shuffle_signal := {}
	var normalized_shuffle := PresentationEvent.normalize({
		"event_type": "deck_shuffled",
		"actor": 0,
		"data": {"player": 0},
	}, 9, 0, 0)
	director_probe.card_motion_requested.connect(func(
		event: Dictionary,
		_duration: float,
	) -> void:
		shuffle_signal["motion"] = str(event.get("event_type", "")) == "deck_shuffled"
	)
	director_probe._dispatch(normalized_shuffle)
	_check(
		bool(shuffle_signal.get("motion", false)),
		"Deck shuffle presentation did not request card motion",
	)
	_check(
		director_probe._duration_for(normalized_shuffle) > 0.5,
		"Deck shuffle presentation does not have an explicit motion duration",
	)
	director_probe.queue_free()

	var packed := load("res://scenes/battle/battle_screen.tscn") as PackedScene
	_check(packed != null, "Battle screen scene failed to load")
	if packed:
		var battle := packed.instantiate()
		root.add_child(battle)
		battle.initialize_ui()
		_prime_card_action_popover(battle.table.action_popover)
		battle.table.hud._ready()
		battle.table.set_anchors_preset(Control.PRESET_TOP_LEFT)
		battle.table.size = Vector2(1280.0, 720.0)
		var state := _battle_state()
		state.players[0].hand = [
			"sv1-104", "sv1-ener-5", "sv1-151", "sv1-189",
		]
		state.players[0].active.energy_card_ids.assign([
			"sv1-ener-5", "sv1-ener-5", "svi-mirc", "svg2-lume",
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
		for action in RulesTestHarness.legal_actions(engine, state, 0, true):
			rows.append({"action": action, "label": action.action})
		battle.update_view(state, 0, rows, "", false, "local")
		battle._layout_board()
		var runtime_popover_safe_rect: Rect2 = battle.table._safe_popover_rect()
		var runtime_header_rect: Rect2 = battle.header.get_global_rect()
		_check(
			runtime_popover_safe_rect.size.y <= 0.0
			or runtime_header_rect.size.y <= 0.0
			or runtime_popover_safe_rect.position.y
			>= runtime_header_rect.end.y + 8.0 - 0.01,
			"CardActionPopover safe area still extends behind the battle header",
		)
		var subtype_catalog := CardCatalog.new(true)
		subtype_catalog.cards["test-subtype-stadium"] = {
			"name": "测试竞技场",
			"supertype": "Trainer",
			"subtypes": ["Stadium"],
			# Deliberately omit trainer_type: CardCatalog subtype classification is
			# the same authority used by the rules layer.
		}
		var subtype_state := GameState.new()
		subtype_state.phase = "MAIN"
		subtype_state.active_player_idx = 0
		subtype_state.players[0].hand = ["test-subtype-stadium"]
		var subtype_stadium_action := GameAction.new(
			"PLAY_TRAINER",
			{"hand_idx": 0},
			false,
			0,
			EntityRef.new(
				"card", 0, "hand", "", 0, "", "test-subtype-stadium"
			),
		)
		var subtype_action_rows: Array[Dictionary] = [{
			"action": subtype_stadium_action,
			"label": "打出竞技场",
		}]
		var original_table_catalog: CardCatalog = battle.table.catalog
		var original_table_state: GameState = battle.table.state_ref
		var original_table_rows: Array[Dictionary] = battle.table.action_rows
		battle.table.catalog = subtype_catalog
		battle.table.state_ref = subtype_state
		battle.table.action_rows = subtype_action_rows
		var subtype_routed_rows: Array[Dictionary] = (
			battle.table._routed_action_rows()
		)
		_check(
			battle.table._trainer_type_for_action(
				subtype_stadium_action
			) == "Stadium"
			and subtype_routed_rows.size() == 1
			and subtype_routed_rows[0].get(
				"drag_target_keys", []
			) == ["stadium"],
			"BattleTable ignored CardCatalog Stadium subtype classification",
		)
		battle.table.catalog = original_table_catalog
		battle.table.state_ref = original_table_state
		battle.table.action_rows = original_table_rows
		var actionable_stadium_state := state.clone_state()
		actionable_stadium_state.stadium_card_id = "sv1-180"
		var actionable_stadium_rows: Array[Dictionary] = [{
			"action": GameAction.new("USE_STADIUM", {}, false, 0),
			"label": "发动竞技场效果",
		}]
		battle.update_view(
			actionable_stadium_state,
			0,
			actionable_stadium_rows,
			"",
			false,
			"local",
		)
		var actionable_stadium := battle.zones["stadium"] as ZoneView
		if actionable_stadium.frame == null:
			actionable_stadium.frame = actionable_stadium.get_node("Frame") as Panel
		if actionable_stadium.action_button == null:
			actionable_stadium.action_button = actionable_stadium.get_node(
				"ActionButton"
			) as Button
		actionable_stadium._apply_frame_style()
		var actionable_stadium_style := actionable_stadium.frame.get_theme_stylebox(
			"panel"
		) as StyleBoxFlat
		_check(
			actionable_stadium.is_actionable()
			and actionable_stadium_style != null
			and actionable_stadium_style.border_width_left == 2
			and actionable_stadium_style.shadow_size == 3
			and not actionable_stadium.action_button.visible,
			"An activatable Stadium was missing the label-free actionable outline",
		)
		battle.update_view(state, 0, rows, "", false, "local")
		# Starting a drag is a stronger source selection than a card left selected
		# from an earlier tap. The dragged Energy must therefore expose its own
		# legal targets instead of inheriting the stale hand-card selection.
		battle.update_view(state, 0, rows, "hand:0", false, "local")
		battle.table._on_hand_drag_started(1)
		_check(
			battle.table._drag_source_key == "hand:1"
			and battle.own_active.targetable
			and battle.own_active.get_legal_target_hint() == "附能"
			and battle.own_active.get_allowed_drop_hand_indices().has(1),
			"Dragging a different hand card reused the previously selected card's targets",
		)
		battle.table._on_hand_drag_ended()
		battle.update_view(state, 0, rows, "", false, "local")
		var single_target_state := state.clone_state()
		single_target_state.players[0].active = PokemonState.new("sv1-108")
		single_target_state.players[0].active.used_abilities.assign(["以太感知"])
		single_target_state.players[0].bench[0] = PokemonState.new("sv1-104")
		var single_retreat := GameAction.new(
			"RETREAT",
			{"bench_idx": 0, "energy_indices": []},
			false,
			0,
			null,
			EntityRef.new("pokemon", 0, "", "bench_0"),
		)
		var single_retreat_rows: Array[Dictionary] = [{
			"action": single_retreat,
			"label": "撤退",
		}]
		battle.update_view(
			single_target_state,
			0,
			single_retreat_rows,
			"pokemon:0:active",
			false,
			"local",
		)
		_check(
			not battle.table.action_popover.visible
			and battle.own_bench[0].targetable
			and battle.own_bench[0].get_legal_target_hint() == "撤退",
			"A disabled ability row forced an extra popover before a single targeted action",
		)
		var test_attack := GameAction.new(
			"DECLARE_ATTACK",
			{"attack_idx": 0},
			true,
			0,
			EntityRef.new("pokemon", 0, "", "active"),
		)
		var mixed_active_rows: Array[Dictionary] = [
			{"action": test_attack, "label": "攻击"},
			{"action": single_retreat, "label": "撤退"},
		]
		battle.update_view(
			single_target_state,
			0,
			mixed_active_rows,
			"pokemon:0:active",
			false,
			"local",
		)
		var mixed_groups: Array[Dictionary] = battle.table.interaction_router.action_groups_for_source(
			"pokemon:0:active"
		)
		var mixed_popover_rows: Array[Dictionary] = battle.table._popover_rows_for_groups(
			mixed_groups
		)
		var retreat_group_is_neutral := false
		for mixed_row in mixed_popover_rows:
			var mixed_action := mixed_row.get("action") as GameAction
			if mixed_action and mixed_action.action == "RETREAT":
				retreat_group_is_neutral = (
					str(mixed_row.get("label", "")) == "撤退"
					and str(mixed_row.get("hint", "")) == "选择备战宝可梦"
				)
		_check(
			battle.table.action_popover.visible and retreat_group_is_neutral,
			"Retreat group exposed a target/payment before the bench was selected",
		)
		battle.table._on_popover_action_chosen(single_retreat)
		_check(
			battle.table._selected_action_group_key == "RETREAT",
			"Retreat action group did not enter target-selection mode",
		)
		var attack_only_rows: Array[Dictionary] = [{
			"action": test_attack,
			"label": "攻击",
		}]
		battle.update_view(
			single_target_state,
			0,
			attack_only_rows,
			"pokemon:0:active",
			false,
			"local",
		)
		_check(
			battle.table._selected_action_group_key.is_empty()
			and battle.table._forced_popover_rows.is_empty()
			and battle.table.action_popover.visible,
			"A stale selected action group hid the replacement legal action set",
		)
		battle.table.action_popover.dismiss()
		_check(
			not battle.table.action_popover.visible
			and battle.table._current_task_hint() == "再次点击卡牌取消选择",
			"Dismissed card actions did not advertise the same-card cancel gesture",
		)
		var actionable_same_card_clear := {}
		battle.selection_clear_requested.connect(func(expected_key: String) -> void:
			actionable_same_card_clear["key"] = expected_key
			battle.update_view(
				single_target_state,
				0,
				attack_only_rows,
				"",
				false,
				"local",
			)
		, CONNECT_ONE_SHOT)
		battle.own_active.activated.emit(
			single_target_state.players[0].active.card_id,
			-1,
			0,
			"active",
		)
		_check(
			str(actionable_same_card_clear.get("key", ""))
			== "pokemon:0:active"
			and battle.selected_entity_key.is_empty()
			and not battle.own_active.selected
			and not battle.table.action_popover.visible,
			"Tapping a selected actionable card did not clear its interaction",
		)
		battle.update_view(state, 0, rows, "", false, "local")
		var floating_detail := battle.detail_panel as BattleDetailPanel
		_check(
			floating_detail != null
			and battle.find_child("DetailPanel", true, false) == floating_detail
			and floating_detail.get_parent().name == "OverlayPanels"
			and not floating_detail.visible
			and not battle.hud.is_ancestor_of(floating_detail)
			and battle.find_child("ActionPanel", true, false) == null,
			"Battle detail preview is not a hidden root overlay independent of the HUD",
		)
		battle.update_view(
			state,
			0,
			rows,
			"pokemon:0:active",
			false,
			"local",
		)
		var preview_board_size: Vector2 = battle.board_canvas.size
		battle.show_card_detail(state.players[0].active.card_id, state.players[0].active)
		battle.table._layout_overlay_drawers()
		var preview_board_rect: Rect2 = battle.board_panel.get_global_rect()
		var preview_detail_rect: Rect2 = floating_detail.get_global_rect()
		var preview_geometry_ready: bool = (
			preview_board_rect.size.x > 1.0 and preview_board_rect.size.y > 1.0
		)
		_check(
			floating_detail.is_showing_card()
			and floating_detail.current_card_id == state.players[0].active.card_id
			and floating_detail.detail_image.texture != null
			and floating_detail.detail_title.text == battle.catalog.card_name(
				state.players[0].active.card_id
			)
			and floating_detail.detail_text.text.contains("HP")
			and floating_detail.detail_text.text.contains("剩余 HP 100")
			and floating_detail.detail_text.text.contains("卡面 HP 70")
			and not floating_detail.detail_text.text.contains("100／70")
			and floating_detail.close_button.custom_minimum_size.y >= 48.0
			and (
				not preview_geometry_ready
				or preview_board_rect.encloses(preview_detail_rect)
			)
			and battle.board_canvas.size == preview_board_size,
			"Floating card preview did not render safely without changing table size: visible=%s id=%s image=%s title=%s text=%s close=%.1f board=%s detail=%s size=%s/%s" % [
				floating_detail.visible,
				floating_detail.current_card_id,
				floating_detail.detail_image.texture != null,
				floating_detail.detail_title.text,
				floating_detail.detail_text.text.left(24),
				floating_detail.close_button.custom_minimum_size.y,
				preview_board_rect,
				preview_detail_rect,
				preview_board_size,
				battle.board_canvas.size,
			],
		)
		var preview_opponent_prizes := battle.zones["opponent_prizes"] as ZoneView
		var preview_own_prizes := battle.zones["own_prizes"] as ZoneView
		var preview_stadium := battle.zones["stadium"] as ZoneView
		var preview_detail_position := floating_detail.position
		var preview_detail_local_rect := Rect2(
			floating_detail.position,
			floating_detail.size * floating_detail.scale,
		)
		var preview_opponent_prize_bounds: Rect2 = battle.table._visual_rect_in_control(
			preview_opponent_prizes,
			preview_opponent_prizes.get_stack_visual_max_rect().grow(6.0),
			battle.table,
		)
		var preview_own_prize_bounds: Rect2 = battle.table._visual_rect_in_control(
			preview_own_prizes,
			preview_own_prizes.get_stack_visual_max_rect().grow(6.0),
			battle.table,
		)
		var preview_stadium_bounds: Rect2 = battle.table._visual_rect_in_control(
			preview_stadium,
			Rect2(Vector2.ZERO, preview_stadium.size).grow(4.0),
			battle.table,
		)
		battle.update_view(
			state,
			0,
			rows,
			"pokemon:1:active",
			false,
			"local",
		)
		battle.show_card_detail(
			state.players[1].active.card_id,
			state.players[1].active,
		)
		battle.table._layout_overlay_drawers()
		var opponent_preview_local_rect := Rect2(
			floating_detail.position,
			floating_detail.size * floating_detail.scale,
		)
		_check(
			floating_detail.position.distance_to(preview_detail_position) < 0.01
			and (
				not preview_geometry_ready
				or (
					not opponent_preview_local_rect.intersects(
						preview_opponent_prize_bounds
					)
					and not opponent_preview_local_rect.intersects(
						preview_own_prize_bounds
					)
					and not opponent_preview_local_rect.intersects(
						preview_stadium_bounds
					)
					and opponent_preview_local_rect.end.x
					<= preview_stadium_bounds.position.x
				)
			),
			"Opponent-card detail moved away from the fixed prize corridor",
		)
		var stadium_position_before_compact := preview_stadium.position
		# Constrain the same fixed corridor without changing the scene-tree viewport;
		# this exercises BattleTable's compact-detail switch deterministically.
		preview_stadium.position.x = minf(preview_stadium.position.x, 300.0)
		battle.table._layout_detail_panel()
		var compact_preview_rect := Rect2(
			floating_detail.position,
			floating_detail.size * floating_detail.scale,
		)
		var compact_stadium_bounds: Rect2 = battle.table._visual_rect_in_control(
			preview_stadium,
			Rect2(Vector2.ZERO, preview_stadium.size).grow(4.0),
			battle.table,
		)
		_check(
			not preview_geometry_ready
			or (
				floating_detail.is_compact_layout()
				and floating_detail.layout_size()
				== BattleDetailPanel.COMPACT_PANEL_SIZE
				and floating_detail.scale.is_equal_approx(Vector2.ONE)
				and floating_detail.close_button.custom_minimum_size
				== Vector2(48.0, 48.0)
				and floating_detail.close_button.get_global_rect().size.x >= 48.0
				and floating_detail.close_button.get_global_rect().size.y >= 48.0
				and preview_board_rect.encloses(floating_detail.get_global_rect())
			),
			"Constrained detail corridor did not switch to a 1:1 bottom layout",
		)
		preview_stadium.position = stadium_position_before_compact
		battle.update_view(
			state,
			0,
			rows,
			"pokemon:0:active",
			false,
			"local",
		)
		battle.show_card_detail(state.players[0].active.card_id, state.players[0].active)
		battle.table._layout_overlay_drawers()
		_check(
			not preview_geometry_ready
			or preview_detail_local_rect.position.distance_to(
				floating_detail.position
			) < 0.01,
			"Restoring the detail corridor did not restore its fixed anchor",
		)
		var live_preview_state := state.clone_state()
		live_preview_state.players[0].active.damage_counters = 3
		live_preview_state.players[0].active.status_conditions.append("BURNED")
		battle.update_view(
			live_preview_state,
			0,
			rows,
			"pokemon:0:active",
			false,
			"local",
		)
		_check(
			floating_detail.visible
			and floating_detail.current_card_id
			== live_preview_state.players[0].active.card_id
			and floating_detail.detail_text.text.contains("伤害 30")
			and floating_detail.detail_text.text.contains("灼伤"),
			"Visible card preview did not refresh live Pokemon state for the same source key",
		)
		var changed_hand_state := state.clone_state()
		changed_hand_state.players[0].hand[0] = "sv1-151"
		var no_card_actions: Array[Dictionary] = []
		battle.update_view(
			state,
			0,
			no_card_actions,
			"hand:0",
			false,
			"local",
		)
		battle.show_card_detail(str(state.players[0].hand[0]))
		var unavailable_same_card_clear := {}
		battle.selection_clear_requested.connect(func(expected_key: String) -> void:
			unavailable_same_card_clear["key"] = expected_key
			battle.update_view(
				state,
				0,
				no_card_actions,
				"",
				false,
				"local",
			)
		, CONNECT_ONE_SHOT)
		(battle.hand_views[0] as CardView).activated.emit(
			str(state.players[0].hand[0]),
			0,
			0,
			"",
		)
		_check(
			str(unavailable_same_card_clear.get("key", "")) == "hand:0"
			and battle.selected_entity_key.is_empty()
			and not (battle.hand_views[0] as CardView).selected
			and not battle.table.action_popover.visible
			and not floating_detail.visible,
			"Tapping a selected non-actionable hand card did not clear detail and highlight",
		)
		battle.update_view(
			state,
			0,
			no_card_actions,
			"pokemon:1:active",
			false,
			"local",
		)
		battle.show_card_detail(
			state.players[1].active.card_id,
			state.players[1].active,
		)
		_check(
			battle.opponent_active.selected
			and floating_detail.is_showing_card()
			and battle.table.action_popover.visible
			and battle.table.action_popover.is_informational_only()
			and battle.opponent_active.get_disabled_reason()
			== "对手的卡牌不能由你操作",
			"Opponent card did not enter a visible inspect-only selected state",
		)
		var opponent_same_card_clear := {}
		battle.selection_clear_requested.connect(func(expected_key: String) -> void:
			opponent_same_card_clear["key"] = expected_key
			battle.update_view(
				state,
				0,
				no_card_actions,
				"",
				false,
				"local",
			)
		, CONNECT_ONE_SHOT)
		battle.opponent_active.activated.emit(
			state.players[1].active.card_id,
			-1,
			1,
			"active",
		)
		_check(
			str(opponent_same_card_clear.get("key", ""))
			== "pokemon:1:active"
			and battle.selected_entity_key.is_empty()
			and not battle.opponent_active.selected
			and not battle.table.action_popover.visible
			and not floating_detail.visible,
			"Tapping a selected opponent card did not clear detail and highlight",
		)
		battle.update_view(
			state,
			0,
			no_card_actions,
			"hand:0",
			false,
			"local",
		)
		battle.show_card_detail(str(state.players[0].hand[0]))
		battle.table._selected_action_group_key = "stale-group"
		battle.table._popover_dismissed_source_key = "hand:0"
		battle.table._forced_popover_rows.clear()
		battle.table._forced_popover_rows.append({
			"action": GameAction.new("PLAY_TRAINER", {"hand_idx": 0}),
		})
		battle.table._forced_popover_source_key = "hand:0"
		battle.update_view(
			changed_hand_state,
			0,
			no_card_actions,
			"hand:0",
			false,
			"local",
		)
		_check(
			floating_detail.visible
			and floating_detail.current_card_id == "sv1-151"
			and floating_detail.detail_title.text
			== battle.catalog.card_name("sv1-151")
			and battle.table._selected_action_group_key.is_empty()
			and battle.table._popover_dismissed_source_key.is_empty()
			and battle.table._forced_popover_rows.is_empty(),
			"Visible hand preview kept the old card after the selected index changed identity",
		)
		floating_detail.close_button.pressed.emit()
		_check(
			not floating_detail.visible and floating_detail.current_card_id.is_empty(),
			"Floating card preview close control did not clear the preview: visible=%s id=%s connections=%d" % [
				floating_detail.visible,
				floating_detail.current_card_id,
				floating_detail.close_button.pressed.get_connections().size(),
			],
		)
		var hidden_preview_state := changed_hand_state.clone_state()
		hidden_preview_state.players[0].hand[0] = "sv1-189"
		battle.update_view(
			hidden_preview_state,
			0,
			no_card_actions,
			"hand:0",
			false,
			"local",
		)
		_check(
			not floating_detail.visible,
			"A state refresh reopened a card preview that the user explicitly closed",
		)
		battle.update_view(state, 0, rows, "", false, "local")
		_check(
			battle.effects != null and not battle.effects.is_processing(),
			"Idle battle effects layer kept processing",
		)
		if battle.effects:
			battle.effects.floating_text("10", Vector2(40, 40), Color.WHITE)
			_check(
				battle.effects.is_processing(),
				"Battle effects layer did not process active floating text",
			)
			battle.effects.clear_transients()
			_check(
				not battle.effects.is_processing(),
				"Battle effects layer kept processing after transients cleared",
			)
		if battle.playmat:
			battle.playmat.quality_profile = "low"
			_check(
				not battle.playmat.is_processing(),
				"Low-quality playmat kept dynamic processing enabled",
			)
			battle.playmat.quality_profile = "high"
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
			and active_energy.get_child_count() == 2,
			"Active Pokemon energy row did not render grouped energy badges",
		)
		var textured_energy_badges := 0
		var has_colorless_special_stack := false
		if active_energy:
			for badge_value in active_energy.get_children():
				var badge := badge_value as Control
				if badge == null:
					continue
				var icon := badge.find_child("Icon", true, false) as TextureRect
				if icon and icon.texture:
					textured_energy_badges += 1
				var count_badge := badge.find_child(
					"CountBadge", true, false
				) as Control
				if (
					str(badge.get_meta("energy_group_key", ""))
					== "energy:type:Colorless"
					and badge.get_meta("energy_card_ids", [])
					== ["svi-mirc", "svg2-lume"]
					and int(badge.get_meta("provided_unit_count", 0)) == 2
					and badge.find_child("SpecialMarker", true, false) == null
					and count_badge
					and str(count_badge.get_meta("count_text", "")) == "2"
				):
					has_colorless_special_stack = true
		_check(
			textured_energy_badges == 2 and has_colorless_special_stack,
			"Colorless Special Energy did not render one effective-unit stack",
		)
		var fallback_energy_badge: Control = battle.own_active._new_energy_badge(
			"Special", 2
		)
		_check(
			fallback_energy_badge.find_child("Icon", true, false) == null
			and fallback_energy_badge.find_child(
				"FallbackLabel", true, false
			) != null,
			"Energy badge without an icon did not retain the text fallback",
		)
		fallback_energy_badge.free()
		var card_scene := load("res://ui/card_view.tscn") as PackedScene
		_check(card_scene != null, "CardView scene failed to load for energy overflow test")
		if card_scene:
			var narrow_card := card_scene.instantiate() as CardView
			root.add_child(narrow_card)
			narrow_card.set_catalog(engine.catalog)
			narrow_card.size = Vector2(104.0, 146.0)
			var overflow_pokemon := PokemonState.new("sv1-104")
			overflow_pokemon.energy_card_ids.assign([
				"sv1-ener-1",
				"sv1-ener-2",
				"sv1-ener-3",
				"sv1-ener-4",
				"sv1-ener-5",
				"sv1-ener-6",
				"svg2-lume",
			])
			narrow_card.configure("sv1-104", overflow_pokemon)
			var overflow_energy_row := narrow_card.find_child(
				"EnergyRow", true, false
			) as HBoxContainer
			var overflow_badge := narrow_card.find_child(
				"EnergyOverflowBadge", true, false
			) as Control
			var occupied_width := 0.0
			var badges_are_input_transparent := overflow_energy_row != null
			if overflow_energy_row:
				for badge_value in overflow_energy_row.get_children():
					var badge := badge_value as Control
					if badge == null:
						continue
					occupied_width += badge.custom_minimum_size.x
					badges_are_input_transparent = (
						badges_are_input_transparent
						and badge.mouse_filter == Control.MOUSE_FILTER_IGNORE
					)
				occupied_width += 2.0 * float(maxi(
					0, overflow_energy_row.get_child_count() - 1
				))
			_check(
				overflow_energy_row != null
				and overflow_energy_row.mouse_filter == Control.MOUSE_FILTER_IGNORE
				and overflow_energy_row.get_child_count() <= 4
				and overflow_badge != null
				and overflow_badge.mouse_filter == Control.MOUSE_FILTER_IGNORE
				and overflow_badge.tooltip_text.contains("另有")
				and occupied_width <= narrow_card.size.x - 10.0 + 0.01
				and badges_are_input_transparent,
				"Narrow CardView energy badges overflowed or intercepted full-card gestures",
			)
			_check(
				narrow_card.tooltip_text.contains("附加能量")
				and narrow_card.tooltip_text.contains("草能量")
				and narrow_card.tooltip_text.contains("夜光能量")
				and narrow_card.accessibility_description == narrow_card.tooltip_text,
				"CardView did not expose the complete attached-energy summary",
			)
			var card_minimum_before := narrow_card.get_combined_minimum_size()
			narrow_card.set_actions([{
				"action": GameAction.new("TEST_ACTION"),
				"label": "测试动作",
			}])
			_check(
				narrow_card.action_buttons.get_child_count() == 0
				and not narrow_card.action_overlay.visible
				and narrow_card.get_combined_minimum_size() == card_minimum_before,
				"CardView retained layout-changing internal action controls",
			)
			var frame_modulate_before := narrow_card.frame.modulate
			var image_modulate_before := narrow_card.image.modulate
			var frame_self_modulate_before := narrow_card.frame.self_modulate
			var image_self_modulate_before := narrow_card.image.self_modulate
			narrow_card.set_actionable(true)
			var actionable_style := narrow_card.actionable_marker.get_theme_stylebox(
				"panel"
			) as StyleBoxFlat
			_check(
				narrow_card.is_actionable()
				and narrow_card.actionable_marker.visible
				and narrow_card.actionable_marker.get_node_or_null(
					"ActionableMarkerLabel"
				) == null
				and narrow_card.actionable_marker.mouse_filter == Control.MOUSE_FILTER_IGNORE
				and narrow_card.actionable_marker.offset_left <= -2.0
				and narrow_card.actionable_marker.offset_right >= 2.0
				and narrow_card.actionable_marker.z_as_relative
				and narrow_card.actionable_marker.z_index == 0
				and actionable_style != null
				and actionable_style.border_width_left >= 3
				and not actionable_style.draw_center
				and actionable_style.bg_color.a <= 0.001
				and narrow_card.frame.modulate == frame_modulate_before
				and narrow_card.image.modulate == image_modulate_before
				and narrow_card.frame.self_modulate == frame_self_modulate_before
				and narrow_card.image.self_modulate == image_self_modulate_before,
				"CardView did not use a label-free full-card actionable outline",
			)
			narrow_card.configure_target(0, "active")
			narrow_card.set_interaction_state(true, "", "附能", [2])
			var target_outline := narrow_card.target_glow.get_theme_stylebox(
				"panel"
			) as StyleBoxFlat
			var legal_drop_data := {
				"kind": "hand_card",
				"hand_index": 2,
				"card_id": "sv1-ener-5",
			}
			var illegal_drop_data := legal_drop_data.duplicate()
			illegal_drop_data["hand_index"] = 1
			_check(
				narrow_card.targetable
				and target_outline != null
				and narrow_card.target_glow.z_as_relative
				and narrow_card.target_glow.z_index == 0
				and not target_outline.draw_center
				and target_outline.bg_color.a <= 0.001
				and narrow_card.get_legal_target_hint() == "附能"
				and narrow_card.get_allowed_drop_hand_indices() == [2]
				and narrow_card.interaction_hint.visible
				and narrow_card.interaction_hint_label.text == "附能"
				and narrow_card._can_drop_data(Vector2.ZERO, legal_drop_data)
				and not narrow_card._can_drop_data(Vector2.ZERO, illegal_drop_data),
				"CardView did not restrict drop acceptance to router-provided legal cards",
			)
			narrow_card.clear_interaction_state()
			_check(
				not narrow_card.is_actionable()
				and not narrow_card.targetable
				and not narrow_card._can_drop_data(Vector2.ZERO, legal_drop_data),
				"CardView leaked its previous card-interaction state",
			)
			narrow_card.set_selected(true)
			narrow_card.set_interaction_state(false, "本回合已附能")
			var selection_outline := narrow_card.selection_ring.get_theme_stylebox(
				"panel"
			) as StyleBoxFlat
			_check(
				CardView.LONG_PRESS_MSEC == 350
				and selection_outline != null
				and narrow_card.selection_ring.z_as_relative
				and narrow_card.selection_ring.z_index == 0
				and not selection_outline.draw_center
				and selection_outline.bg_color.a <= 0.001
				and narrow_card.get_disabled_reason() == "本回合已附能"
				and narrow_card.interaction_hint.visible
				and narrow_card.interaction_hint_label.text == "本回合已附能",
				"CardView did not show the disabled reason or keep the 350ms inspector hold",
			)
			var gesture_probe := {"activated": 0, "detail": 0}
			narrow_card.activated.connect(func(
				_card_id: String,
				_hand_index: int,
				_player: int,
				_slot: String,
			) -> void:
				gesture_probe["activated"] = int(gesture_probe["activated"]) + 1
			)
			narrow_card.detail_requested.connect(func(_card_id: String) -> void:
				gesture_probe["detail"] = int(gesture_probe["detail"]) + 1
			)
			var gesture_press := InputEventMouseButton.new()
			gesture_press.button_index = MOUSE_BUTTON_LEFT
			gesture_press.pressed = true
			gesture_press.position = Vector2(24.0, 24.0)
			var gesture_release := InputEventMouseButton.new()
			gesture_release.button_index = MOUSE_BUTTON_LEFT
			gesture_release.pressed = false
			gesture_release.position = gesture_press.position
			narrow_card._gui_input(gesture_press)
			narrow_card._press_msec = (
				Time.get_ticks_msec() - CardView.LONG_PRESS_MSEC + 40
			)
			narrow_card._gui_input(gesture_release)
			narrow_card._gui_input(gesture_press)
			narrow_card._press_msec = (
				Time.get_ticks_msec() - CardView.LONG_PRESS_MSEC - 40
			)
			narrow_card._gui_input(gesture_release)
			_check(
				int(gesture_probe["activated"]) == 1
				and int(gesture_probe["detail"]) == 1,
				"Mouse-emulated touch did not preserve click and 350ms long-press semantics",
			)
			narrow_card.set_selected(false)
			narrow_card.configure("", null, true)
			_check(
				narrow_card.tooltip_text == narrow_card.accessibility_description
				and not narrow_card.tooltip_text.contains("附加能量")
				and narrow_card.accessibility_name == "隐藏卡牌"
				and not overflow_energy_row.visible,
				"Reused hidden CardView leaked its previous attached-energy summary",
			)
			narrow_card.queue_free()
		_check(
			active_tool != null and active_tool.visible,
			"Active Pokemon tool badge was not rendered",
		)
		_check(
			battle.own_active.status_row.get_child_count() == 1,
			"Active Pokemon status badge was not rendered",
		)
		var header_task_caption := battle.header.get_node_or_null("TaskCaption") as Label
		var header_spacer := battle.header.get_node_or_null("HeaderSpacer") as Control
		_check(
			battle.header.menu_button.custom_minimum_size == Vector2(84.0, 48.0)
			and battle.header.turn_label.custom_minimum_size.x <= 292.0
			and battle.header.task_hint_label.custom_minimum_size.x >= 270.0
			and battle.header.task_hint_label.custom_minimum_size.x <= 330.0
			and battle.header.task_hint_label.get_index()
			== battle.header.turn_label.get_index() + 1
			and header_spacer != null
			and header_spacer.get_index()
			== battle.header.task_hint_label.get_index() + 1
			and header_spacer.size_flags_horizontal == Control.SIZE_EXPAND_FILL
			and (header_task_caption == null or not header_task_caption.visible),
			"Battle header did not keep one compact continuous information group",
		)
		var allowance_row := battle.table.own_allowance_row as HBoxContainer
		var allowance_texts: Array[String] = []
		if allowance_row:
			for allowance_value in allowance_row.get_children():
				var allowance_label := allowance_value as Label
				if allowance_label:
					allowance_texts.append(allowance_label.text)
		var allowance_summary := " ".join(allowance_texts)
		_check(
			allowance_row != null
			and allowance_row.get_child_count() == 4
			and allowance_row.size == Vector2(304.0, 26.0)
			and battle.own_info.size == Vector2(304.0, 26.0)
			and allowance_row.position.y > battle.own_info.position.y
			and allowance_summary.contains("附能")
			and allowance_summary.contains("竞技场")
			and (allowance_summary.contains("可用") or allowance_summary.contains("已用"))
			and not battle.own_info.text.contains("│"),
			"Own-player status was not placed as a compact two-level group left of active",
		)
		_check(battle.hand_views.size() == 4,
			"Battle screen did not create stable hand card views")
		var lower_hand_card := battle.hand_views[0] as CardView
		var upper_hand_card := battle.hand_views[1] as CardView
		lower_hand_card.set_actionable(true)
		upper_hand_card.set_actionable(true)
		_check(
			battle.hand_scroll.z_index == 0
			and lower_hand_card.position.y >= 14.0
			and lower_hand_card.z_index < upper_hand_card.z_index
			and lower_hand_card.actionable_marker.visible
			and upper_hand_card.actionable_marker.visible
			and lower_hand_card.actionable_marker.z_as_relative
			and upper_hand_card.actionable_marker.z_as_relative
			and lower_hand_card.actionable_marker.z_index == 0
			and upper_hand_card.actionable_marker.z_index == 0
			and lower_hand_card.z_index
			+ lower_hand_card.actionable_marker.z_index
			< upper_hand_card.z_index + upper_hand_card.frame.z_index,
			"A lower hand card's highlight can still draw over the next card body",
		)
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
			battle.log_panel != null
			and battle.log_panel.get_parent() == battle.hud
			and battle.get_node_or_null("OverlayPanels/LogPanel") == null,
			"Battle log panel is still mounted as a board overlay instead of the HUD sidebar",
		)
		_check(
			(battle.zones["opponent_deck"] as ZoneView).stack_visual_mode == "deck"
			and (battle.zones["own_deck"] as ZoneView).stack_visual_mode == "deck"
			and (battle.zones["opponent_discard"] as ZoneView).stack_visual_mode == "discard"
			and (battle.zones["own_discard"] as ZoneView).stack_visual_mode == "discard"
			and (battle.zones["own_prizes"] as ZoneView).stack_visual_mode == "prizes",
			"Battle zones did not enable deck/discard/prize stack visuals",
		)
		_check(
			(battle.zones["own_discard"] as ZoneView)._stack_layer_count() >= 1,
			"Discard pile did not expose a physical stack thickness",
		)
		var own_prize_zone := battle.zones["own_prizes"] as ZoneView
		var prize_face_size := own_prize_zone.get_stack_face_size()
		var prize_visible_rect := own_prize_zone.get_stack_visual_rect()
		var prize_capacity_rect := own_prize_zone.get_stack_visual_max_rect()
		_check(
			own_prize_zone.stack_visual_max_count == 6
			and own_prize_zone.count == 2
			and prize_visible_rect.size.x > prize_face_size.x
			and prize_visible_rect.size.x < prize_capacity_rect.size.x
			and is_equal_approx(prize_visible_rect.size.y, prize_face_size.y)
			and own_prize_zone._has_point(Vector2(
				prize_visible_rect.end.x - 1.0,
				prize_face_size.y * 0.5,
			))
			and not own_prize_zone._has_point(Vector2(
				prize_capacity_rect.end.x - 1.0,
				prize_face_size.y * 0.5,
			)),
			"Prize cards did not render or hit-test as a six-card horizontal fan",
		)
		var prize_endpoint := {"player": 0, "zone": "prizes"}
		var prize_fan_snapshot: Dictionary = battle.capture_presentation_snapshot()
		var prize_snapshot_row: Dictionary = Dictionary(
			Dictionary(prize_fan_snapshot.get("zones", {})).get("0:prizes", {})
		)
		var prize_snapshot_center: Vector2 = prize_snapshot_row.get(
			"center", Vector2.ZERO
		)
		var prize_snapshot_size: Vector2 = prize_snapshot_row.get(
			"size", Vector2.ZERO
		)
		battle.table._presentation_snapshot = prize_fan_snapshot
		var prize_source_points: Array[Vector2] = battle.table._source_points_for_event(
			prize_endpoint,
			[],
			own_prize_zone.count,
			Vector2.ZERO,
		)
		var prize_source_sizes: Array[Vector2] = battle.table._source_sizes_for_event(
			prize_endpoint,
			[],
			own_prize_zone.count,
			Vector2(1.0, 1.0),
		)
		var prize_source_bounds: Rect2 = battle.table._visual_rect_in_control(
			own_prize_zone,
			prize_visible_rect.grow(6.0),
			battle.effects,
		)
		var prize_sources_inside_fan := (
			prize_source_points.size() == own_prize_zone.count
			and prize_source_sizes.size() == own_prize_zone.count
		)
		for point in prize_source_points:
			prize_sources_inside_fan = (
				prize_sources_inside_fan and prize_source_bounds.has_point(point)
			)
		for source_size in prize_source_sizes:
			prize_sources_inside_fan = (
				prize_sources_inside_fan
				and source_size.is_equal_approx(prize_face_size)
			)
		_check(
			prize_snapshot_center.distance_to(
				battle.table._zone_center("own_prizes")
			) < 0.01
			and prize_snapshot_size.is_equal_approx(prize_face_size)
			and prize_sources_inside_fan,
			"Prize presentation snapshot or outgoing animation endpoints used tray geometry",
		)
		var single_prize_state := state.clone_state()
		single_prize_state.players[0].prizes = ["sv1-151"]
		battle.update_view(single_prize_state, 0, rows, "", false, "local")
		var single_prize_snapshot: Dictionary = battle.capture_presentation_snapshot()
		battle.table._presentation_snapshot = single_prize_snapshot
		var single_prize_row: Dictionary = Dictionary(
			Dictionary(single_prize_snapshot.get("zones", {})).get("0:prizes", {})
		)
		var single_prize_center: Vector2 = single_prize_row.get(
			"center", Vector2.ZERO
		)
		var single_prize_points: Array[Vector2] = battle.table._source_points_for_event(
			prize_endpoint,
			[],
			1,
			Vector2.ZERO,
		)
		_check(
			single_prize_points.size() == 1
			and single_prize_points[0].distance_to(single_prize_center) < 0.01,
			"A one-card prize animation did not start at the physical face center",
		)
		var incoming_prize_state := state.clone_state()
		incoming_prize_state.players[0].prizes = [
			"sv1-151", "sv1-153", "sv1-ener-5",
		]
		battle.update_view(incoming_prize_state, 0, rows, "", false, "local")
		var incoming_prize_zone := battle.zones["own_prizes"] as ZoneView
		var incoming_prize_center: Vector2 = battle.table._zone_center("own_prizes")
		var incoming_prize_points: Array[Vector2] = battle.table._target_points_for_event(
			prize_endpoint,
			[],
			1,
			incoming_prize_center,
			{},
		)
		var incoming_prize_sizes: Array[Vector2] = battle.table._target_sizes_for_event(
			prize_endpoint,
			1,
			Vector2(1.0, 1.0),
			{},
		)
		var incoming_prize_bounds: Rect2 = battle.table._visual_rect_in_control(
			incoming_prize_zone,
			incoming_prize_zone.get_stack_visual_rect().grow(6.0),
			battle.effects,
		)
		_check(
			incoming_prize_points.size() == 1
			and incoming_prize_sizes.size() == 1
			and incoming_prize_bounds.has_point(incoming_prize_points[0])
			and incoming_prize_sizes[0].is_equal_approx(
				incoming_prize_zone.get_stack_face_size()
			),
			"Incoming prize animation did not land on the final fan face",
		)
		battle.update_view(state, 0, rows, "", false, "local")
		battle.table._presentation_snapshot = prize_fan_snapshot
		var texture_cache: Node = root.get_node("CardTextureCache")
		var zone_scene := load("res://ui/zone_view.tscn") as PackedScene
		_check(zone_scene != null, "ZoneView scene failed to load")
		if zone_scene:
			var cache_zone := zone_scene.instantiate() as ZoneView
			texture_cache.call("clear")
			texture_cache.call("reset_stats")
			var zone_texture := cache_zone._card_texture("res://assets/cards/card_back.webp")
			_check(zone_texture != null, "ZoneView could not load the card-back texture")
			var cache_stats: Dictionary = texture_cache.call("stats")
			_check(
				int(cache_stats.get("misses", 0)) >= 1
				and int(cache_stats.get("entries", 0)) >= 1,
				"ZoneView did not load card art through CardTextureCache: %s"
				% JSON.stringify(cache_stats),
			)
			cache_zone.free()
			texture_cache.call("clear")
		_check(battle.phase_advance_button != null,
			"Battle screen is missing the dedicated system action button")
		_check(
			battle.find_child("QuickActions", true, false) == null,
			"Legacy quick action node still exists in the battle scene",
		)
		_check(
			battle.phase_labels.is_empty()
			and battle.find_child("PhaseRow", true, false) == null
			and battle.find_child("AllActionsButton", true, false) == null
			and battle.find_child("ActionPanel", true, false) == null,
			"Battle screen retained the phase track or all-actions drawer",
		)
		_check(
			battle.action_panel == null
			and battle.action_list == null
			and battle.all_actions_button == null
			and battle.all_actions_toggle == null
			and battle.detail_panel != null
			and battle.detail_panel.get_parent().name == "OverlayPanels",
			"Legacy action controls or the floating detail facade are misconfigured",
		)
		_check(
			battle.phase_advance_button.custom_minimum_size.y >= 48.0
			and battle.hud.custom_minimum_size.x
			>= BattlePhaseHud.DRAWER_WIDTH
			+ BattlePhaseHud.DRAWER_GAP
			+ BattlePhaseHud.RAIL_WIDTH
			and battle.hud.custom_minimum_size.x
			<= BattlePhaseHud.DRAWER_WIDTH
			+ BattlePhaseHud.DRAWER_GAP
			+ BattlePhaseHud.RAIL_WIDTH
			+ 4.0
			and battle.hud.get_node_or_null("PhasePanel") != null
			and battle.hud.get_node_or_null("LogPanel") == battle.log_panel
			and battle.hud.get_child_count() == 2,
			"Floating command dock did not reserve its rail and collapsible log drawer",
		)
		var rail_action := {}
		battle.table.hud.phase_action_requested.connect(
			func(action: GameAction) -> void: rail_action["action"] = action.action
		)
		var setup_rail_state := state.clone_state()
		setup_rail_state.phase = "SETUP"
		setup_rail_state.setup_ready.assign([false, false])
		battle.table.hud.update_phase(
			setup_rail_state,
			0,
			false,
			"local",
			[{"action": GameAction.new("SETUP_DONE", {}, true, 0)}],
		)
		_check(
			battle.phase_advance_button.text == "完成准备"
			and not battle.phase_advance_button.disabled,
			"Setup system action was not mapped to the right-rail button",
		)
		battle.phase_advance_button.pressed.emit()
		_check(
			str(rail_action.get("action", "")) == "SETUP_DONE",
			"Right-rail system button did not emit its mapped action",
		)
		battle.table.hud.update_phase(
			state,
			0,
			false,
			"local",
			[{"action": GameAction.new("END_TURN", {}, true, 0)}],
		)
		_check(
			battle.phase_advance_button.text == "结束回合"
			and not battle.phase_advance_button.disabled,
			"Main-phase system action was not mapped to the right-rail button",
		)
		var resolving_state := state.clone_state()
		resolving_state.phase = "ATTACK"
		battle.table.hud.update_phase(
			resolving_state, 0, false, "local", []
		)
		_check(
			battle.phase_advance_button.text == "结算中"
			and battle.phase_advance_button.disabled,
			"Automatic resolution did not disable the system action button",
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
			battle.phase_advance_button != null
			and battle.phase_advance_button.disabled
			and battle.phase_advance_button.text == "等待对手",
			"AI thinking state did not put the system button into waiting state",
		)
		_check(
			not battle.table.action_popover.visible
			and battle.find_child("AllActionsButton", true, false) == null,
			"AI thinking state exposed card actions through a global action entry",
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
			battle._motion_card_hidden_from_view(
				"sv1-151",
				{"player": 1, "zone": "prizes"},
				{"player": 1, "zone": "hand"},
			),
			"Opponent prize motion would reveal card identity",
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
		var board_size_before_card_actions: Vector2 = battle.board_canvas.size
		battle.update_view(state, 0, rows, "hand:3", false, "local")
		var trainer_view: Variant = battle.hand_views[3]
		battle.show_card_detail(str(state.players[0].hand[3]))
		battle.table._layout_overlay_drawers()
		_check(
			trainer_view.is_actionable()
			and trainer_view.action_buttons.get_child_count() == 0
			and not trainer_view.action_overlay.visible
			and battle.table.action_popover.visible
			and battle.table.action_popover.button_count() > 0
			and battle.detail_panel.visible
			and not battle.table.action_popover.panel_global_rect().intersects(
				battle.detail_panel.get_global_rect()
			),
			"Card action popover or floating preview was missing or overlapping",
		)
		_check(
			battle.board_canvas.size == board_size_before_card_actions,
			"Selecting a card changed the battle-table dimensions",
		)
		battle.update_view(state, 0, rows, "", false, "local")
		_check(
			not battle.detail_panel.visible,
			"Clearing the selected card did not hide the floating preview",
		)
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
		var draw_deck_zone := battle.zones["own_deck"] as ZoneView
		var draw_deck_image := (
			draw_deck_zone.get_node_or_null("Frame/Image") as TextureRect
			if draw_deck_zone != null
			else null
		)
		_check(
			draw_deck_zone != null
			and not draw_deck_zone.is_presentation_hidden()
			and draw_deck_zone.has_visible_card_back(),
			"Draw presentation hid the deck card-back texture: hidden=%s count=%d zone_hidden=%s texture=%s alpha=%.2f fallback=%s fallback_alpha=%.2f" % [
				str(draw_deck_zone.is_presentation_hidden()) if draw_deck_zone != null else "null",
				draw_deck_zone.count if draw_deck_zone != null else -1,
				str(draw_deck_zone.is_hidden_zone) if draw_deck_zone != null else "null",
				str(draw_deck_image.texture != null) if draw_deck_image != null else "null",
				draw_deck_image.modulate.a if draw_deck_image != null else -1.0,
				str(draw_deck_zone.fallback_back_panel.visible) if draw_deck_zone != null and draw_deck_zone.fallback_back_panel != null else "null",
				draw_deck_zone.fallback_back_panel.modulate.a if draw_deck_zone != null and draw_deck_zone.fallback_back_panel != null else -1.0,
			],
		)
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
		var nemona_step := _apply_test_action(engine,
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
		battle.table._presentation_snapshot = discard_snapshot
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
		var normalized_discard := PresentationEvent.normalize({
			"event_type": "cards_discarded",
			"actor": 0,
			"source": {"player": 0, "zone": "hand", "index": 1},
			"target": {"player": 0, "zone": "discard"},
			"amount": 1,
			"data": {
				"player": 0,
				"count": 1,
				"card_ids": ["sv1-ener-5"],
			},
		}, 51, 0, 0)
		var discard_zone := battle.zones["own_discard"] as ZoneView
		var normalized_discard_events: Array[Dictionary] = [normalized_discard]
		battle._stage_presentation_targets(normalized_discard_events, discard_snapshot)
		var discard_count_label := (
			discard_zone.get_node_or_null("Frame/CountLabel") as Label
			if discard_zone != null
			else null
		)
		_check(
			discard_zone != null
			and discard_zone.count == 0
			and discard_zone.card_id == ""
			and int(discard_zone.inspect_context.get("count", -1)) == 0
			and discard_count_label != null,
			"Discard presentation did not hold the previous discard pile state before landing: count=%d card=%s context=%d label_visible=%s" % [
				discard_zone.count,
				discard_zone.card_id,
				int(discard_zone.inspect_context.get("count", -1)),
				str(discard_count_label.visible) if discard_count_label != null else "null",
			],
		)
		battle._on_presentation_event_finished(normalized_discard)
		_check(
			discard_zone.count == 1
			and discard_zone.card_id == "sv1-ener-5"
			and int(discard_zone.inspect_context.get("count", -1)) == 1
			and discard_count_label.visible,
			"Discard presentation did not reveal the updated discard pile state after landing",
		)
		battle._clear_transient_visuals()

		state.players[0].hand = ["sv1-189", "sv1-104", "sv1-ener-5"]
		state.players[0].deck = [
			"sv1-ener-1",
			"sv1-ener-2",
			"sv1-ener-3",
			"sv1-ener-4",
			"sv1-ener-5",
			"sv1-ener-6",
			"sv1-ener-7",
			"sv1-ener-8",
		]
		state.players[0].discard.clear()
		state.players[0].supporter_played_this_turn = false
		battle.update_view(state, 0, rows, "", false, "local")
		var professor_snapshot: Dictionary = battle.capture_presentation_snapshot()
		var professor_step := _apply_test_action(engine,
			state,
			GameAction.new(
				"PLAY_TRAINER",
				{"hand_idx": 0},
				false,
				0,
				EntityRef.new("card", 0, "hand", "", 0, "", "sv1-189"),
			),
			PortableRandomSource.new(202606251),
		)
		_check(professor_step.success,
			"Professor's Research action failed in the zone presentation regression")
		battle.update_view(state, 0, rows, "", false, "local")
		var professor_events: Array[Dictionary] = PresentationEvent.normalize_all(
			professor_step.events,
			state.revision,
			0,
		)
		var professor_play_event := {}
		var professor_discard_event := {}
		var professor_draw_event := {}
		for event in professor_events:
			match str(event.get("event_type", "")):
				"trainer_played":
					professor_play_event = event
				"cards_discarded":
					professor_discard_event = event
				"cards_drawn":
					professor_draw_event = event
		_check(
			not professor_play_event.is_empty()
			and not professor_discard_event.is_empty()
			and not professor_draw_event.is_empty(),
			"Professor's Research did not emit trainer/discard/draw presentation events",
		)
		var professor_deck_zone := battle.zones["own_deck"] as ZoneView
		var professor_discard_zone := battle.zones["own_discard"] as ZoneView
		battle._stage_presentation_targets(professor_events, professor_snapshot)
		_check(
			professor_deck_zone.count == 8
			and professor_discard_zone.count == 0
			and professor_discard_zone.card_id == "",
			"Professor's Research presentation jumped deck/discard zones to final state before animation",
		)
		battle._on_presentation_event_finished(professor_play_event)
		_check(
			professor_deck_zone.count == 8
			and professor_discard_zone.count == 1
			and professor_discard_zone.card_id == "sv1-189",
			"Professor's Research trainer landing did not update only the discard pile",
		)
		battle._on_presentation_event_finished(professor_discard_event)
		_check(
			professor_deck_zone.count == 8
			and professor_discard_zone.count == 3
			and professor_discard_zone.card_id == "sv1-ener-5",
			"Professor's Research discard landing did not advance discard before draw",
		)
		battle._on_presentation_event_finished(professor_draw_event)
		_check(
			professor_deck_zone.count == 1
			and professor_discard_zone.count == 3,
			"Professor's Research draw landing did not advance the deck after the draw",
		)
		battle._clear_transient_visuals()

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
		var energy_cover_node: Control = null
		if not energy_covers.is_empty():
			energy_cover_node = energy_covers[0] as Control
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
			energy_cover_node == null
			or not is_instance_valid(energy_cover_node)
			or energy_cover_node.is_queued_for_deletion()
			or not energy_cover_node.visible,
			"Energy attachment cover remained visible over the revealed slot",
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
			not stadium_zone.is_presentation_hidden()
			and stadium_zone.count == 0
			and stadium_zone.card_id == "",
			"Stadium zone did not hold the previous state before landing",
		)
		battle._on_presentation_event_finished(
			PresentationEvent.normalize(stadium_event, 43, 0, 0))
		_check(
			not stadium_zone.is_presentation_hidden()
			and stadium_zone.count == 1
			and stadium_zone.card_id == "sv1-189",
			"Stadium zone did not advance after the card landed",
		)
		battle.director.clear_for_resync()
		battle._clear_transient_visuals()

		state.players[0].active = PokemonState.new("sv1-104")
		state.players[0].bench[0] = PokemonState.new("svi-chim")
		state.players[0].bench[1] = null
		battle.update_view(state, 0, rows, "", false, "local")
		var switch_snapshot: Dictionary = battle.capture_presentation_snapshot()
		state.players[0].switch_active_to_bench(0)
		battle.update_view(state, 0, rows, "", false, "local")
		var switch_event := {
			"event_type": "switched",
			"actor": 0,
			"data": {"player": 0, "slot": "bench_0"},
		}
		var normalized_switch := PresentationEvent.normalize(switch_event, 49, 0, 0)
		var normalized_switches: Array[Dictionary] = [normalized_switch]
		battle._stage_presentation_targets(normalized_switches, switch_snapshot)
		var switched_active: Variant = battle.get_slot_view(0, "active")
		var switched_bench: Variant = battle.get_slot_view(0, "bench_0")
		_check(
			switched_active.is_presentation_hidden()
			and switched_bench.is_presentation_hidden(),
			"Switch presentation did not mask both active and bench slots",
		)
		var switch_spawned: bool = battle.table._spawn_slot_transition(
			normalized_switch,
			0.12,
		)
		_check(switch_spawned, "Switch presentation did not handle slot transition")
		_check(
			battle.table._active_flyers.size() == 2,
			"Switch presentation did not create bounded active/bench flyers",
		)
		var switch_timing: Dictionary = battle.table._flying_card_timing(
			1,
			2,
			0.12,
			false,
		)
		_check(
			bool(switch_timing.get("spawn", false))
			and float(switch_timing.get("delay", 0.0))
			+ float(switch_timing.get("duration", 0.0)) <= 0.12,
			"Switch flyer timing can outlive its presentation event",
		)
		var too_short_timing: Dictionary = battle.table._flying_card_timing(0, 1, 0.05)
		_check(
			not bool(too_short_timing.get("spawn", true)),
			"Extremely short presentation events still spawn lingering flyers",
		)
		battle._on_presentation_event_finished(normalized_switch)
		_check(
			not switched_active.is_presentation_hidden()
			and not switched_bench.is_presentation_hidden(),
			"Switch presentation did not reveal both swapped slots",
		)
		battle._clear_transient_visuals()
		_check(
			battle.table._active_flyers.is_empty()
			and battle.table._flyer_tweens.is_empty(),
			"Switch transient cleanup left active flying cards",
		)

		state.players[0].active = PokemonState.new("sv1-104")
		state.players[0].bench[0] = null
		state.players[0].bench[1] = PokemonState.new("svi-chim")
		battle.update_view(state, 0, rows, "", false, "local")
		var retreat_snapshot: Dictionary = battle.capture_presentation_snapshot()
		state.players[0].switch_active_to_bench(1)
		battle.update_view(state, 0, rows, "", false, "local")
		var retreat_event := {
			"event_type": "retreat",
			"actor": 0,
			"data": {"player": 0, "bench_idx": 1},
		}
		var normalized_retreat := PresentationEvent.normalize(retreat_event, 50, 0, 0)
		var normalized_retreats: Array[Dictionary] = [normalized_retreat]
		battle._stage_presentation_targets(normalized_retreats, retreat_snapshot)
		var retreat_active: Variant = battle.get_slot_view(0, "active")
		var retreat_bench: Variant = battle.get_slot_view(0, "bench_1")
		_check(
			retreat_active.is_presentation_hidden()
			and retreat_bench.is_presentation_hidden(),
			"Retreat presentation did not mask both active and bench slots",
		)
		battle._on_presentation_event_finished(normalized_retreat)
		_check(
			not retreat_active.is_presentation_hidden()
			and not retreat_bench.is_presentation_hidden(),
			"Retreat presentation did not reveal both swapped slots",
		)
		var director_was_playing: bool = battle.director.is_playing()
		battle.director._playing = true
		battle._stage_presentation_targets(normalized_switches, switch_snapshot)
		battle._stage_presentation_targets(normalized_retreats, retreat_snapshot)
		battle.director._playing = director_was_playing
		battle._clear_transient_visuals()
		_check(
			battle.table._presentation_mask_counts.is_empty()
			and not battle.own_active.is_presentation_hidden()
			and not (battle.own_bench[0] as CardView).is_presentation_hidden()
			and not (battle.own_bench[1] as CardView).is_presentation_hidden(),
			"Continuous staged presentations left stale slot masks",
		)
		var cleanup_texture: Texture2D = battle.table._texture_for_card_id("sv1-104")
		if cleanup_texture:
			battle.table._spawn_flying_card(
				cleanup_texture,
				Vector2(20, 20),
				Vector2(40, 40),
				0.12,
				0.0,
				"cards_drawn",
				0,
			)
		var paper_flyer := (
			battle.table._active_flyers[-1] as Control
			if not battle.table._active_flyers.is_empty()
			else null
		)
		var paper_shadow := (
			paper_flyer.get_node_or_null("PaperShadow") as Panel
			if paper_flyer != null
			else null
		)
		var paper_shadow_style := (
			paper_shadow.get_theme_stylebox("panel") as StyleBoxFlat
			if paper_shadow != null
			else null
		)
		var paper_image := (
			paper_flyer.get_node_or_null("PaperImage") as TextureRect
			if paper_flyer != null
			else null
		)
		_check(
			paper_flyer != null
			and paper_flyer.has_meta("paper_card_token")
			and paper_flyer.has_meta("card_motion_entity")
			and bool(paper_flyer.get_meta("paper_card_single_face", false))
			and paper_flyer.find_child("PaperEdge", true, false) == null
			and paper_flyer.find_child("PaperFace", true, false) == null
			and paper_flyer.find_child("PaperGloss", true, false) == null
			and paper_shadow_style != null
			and paper_shadow_style.bg_color.a <= 0.001
			and paper_image != null
			and paper_image.position.distance_to(Vector2.ZERO) < 0.01
			and paper_image.size.distance_to(paper_flyer.size) < 0.01
			and paper_image.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_COVERED,
			"Card motion entity did not use a full-face single-card token",
		)
		if paper_flyer != null:
			battle.table._finish_flyer(paper_flyer, Vector2(40, 40), "cards_drawn")
			_check(
				is_instance_valid(paper_flyer)
				and paper_flyer.visible
				and paper_flyer.modulate.a >= 0.99,
				"Card motion entity disappeared before presentation handoff",
			)
		battle._clear_transient_visuals()
		var shuffle_spawned: bool = battle.table._spawn_shuffle_motion(
			{"player": 0, "zone": "deck"},
			0.78,
		)
		var shuffle_cards := 0
		var shuffle_cards_are_single_face := true
		var shuffle_cards_replace_physical_pile := true
		var shuffle_deck := battle.table.zones.get("own_deck") as ZoneView
		for flyer_value in battle.table._active_flyers:
			var flyer := flyer_value as Control
			if flyer == null:
				continue
			if flyer.has_meta("shuffle_card"):
				shuffle_cards += 1
			shuffle_cards_are_single_face = (
				shuffle_cards_are_single_face
				and flyer.has_meta("paper_card_token")
				and bool(flyer.get_meta("paper_card_single_face", false))
				and flyer.get_node_or_null("PaperEdge") == null
			)
			if flyer.has_meta("shuffle_card"):
				var shuffle_start: Vector2 = flyer.get_meta(
					"motion_start", Vector2.ZERO)
				var shuffle_finish: Vector2 = flyer.get_meta(
					"motion_finish", Vector2.ZERO)
				shuffle_cards_replace_physical_pile = (
					shuffle_cards_replace_physical_pile
					and bool(flyer.get_meta("shuffle_from_physical_pile", false))
					and flyer.get_meta("shuffle_source_zone", null) == shuffle_deck
					and shuffle_start.distance_to(shuffle_finish) < 0.1
					and shuffle_deck != null
					and flyer.size.distance_to(shuffle_deck.get_stack_face_size()) < 0.5
				)
		_check(
			shuffle_spawned
			and shuffle_cards == battle.table._shuffle_card_count()
			and battle.table._active_flyers.size() <= battle.table._max_active_flyers()
			and shuffle_cards_are_single_face
			and shuffle_cards_replace_physical_pile
			and shuffle_deck != null
			and shuffle_deck.is_stack_presentation_hidden(),
			"Deck shuffle did not take over the physical pile with exact card backs",
		)
		battle._clear_transient_visuals()
		_check(
			shuffle_deck != null
			and not shuffle_deck.is_stack_presentation_hidden()
			and battle.table._shuffle_source_masks.is_empty(),
			"Deck shuffle cleanup did not restore the physical pile",
		)
		var reveal_spawned: bool = battle.table._spawn_reveal_motion({
			"event_type": "cards_revealed",
			"actor": 0,
			"visibility": "public",
			"data": {
				"player": 0,
				"cards": [
					{
						"card_id": "sv1-ener-2",
						"matched": true,
						"destination": {"player": 0, "zone": "discard"},
					},
					{
						"card_id": "sv1-151",
						"matched": false,
						"destination": {"player": 0, "zone": "deck"},
					},
				],
				"summary": {
					"kind": "energy_damage",
					"matched_count": 1,
					"amount": 80,
				},
			},
		}, 1.85)
		var reveal_showcase: Control = battle.table.reveal_layer._showcase as Control
		var reveal_cards: Array = (
			reveal_showcase.get_meta("reveal_cards", [])
			if reveal_showcase != null
			else []
		)
		var reveal_summary: Label = (
			reveal_showcase.get_node_or_null("RevealSummary") as Label
			if reveal_showcase != null
			else null
		)
		_check(
			reveal_spawned
			and battle.table.reveal_layer.is_presenting()
			and reveal_cards.size() == 2
			and reveal_summary != null
			and reveal_summary.text == "正在翻牌…"
			and str(reveal_showcase.get_meta("reveal_summary_text", ""))
			== "翻到 1 张能量"
			and not str(reveal_showcase.get_meta(
				"reveal_summary_text", "",
			)).contains("伤害"),
			"Public reveal layer did not stage every ordered card and summary "
			+ "(spawned=%s, presenting=%s, cards=%d, summary=%s)" % [
				reveal_spawned,
				battle.table.reveal_layer.is_presenting(),
				reveal_cards.size(),
				reveal_summary.text if reveal_summary != null else "<missing>",
			],
		)
		battle._clear_transient_visuals()
		_check(
			not battle.table.reveal_layer.is_presenting(),
			"Public reveal layer survived transient/resync cleanup",
		)
		var stale_cover := Control.new()
		stale_cover.name = "PresentationCover"
		battle.effects.add_child(stale_cover)
		var stale_flyer := Control.new()
		stale_flyer.name = "FlyingCard"
		battle.effects.add_child(stale_flyer)
		battle.own_active.set_presentation_hidden(true)
		(battle.own_bench[0] as CardView).set_presentation_hidden(true)
		(battle.hand_views[0] as CardView).set_presentation_hidden(true)
		(battle.zones["own_deck"] as ZoneView).set_presentation_hidden(true)
		battle._clear_transient_visuals()
		_check(
			not battle.own_active.is_presentation_hidden()
			and not (battle.own_bench[0] as CardView).is_presentation_hidden()
			and not (battle.hand_views[0] as CardView).is_presentation_hidden()
			and not (battle.zones["own_deck"] as ZoneView).is_presentation_hidden()
			and battle.table._active_flyers.is_empty()
			and (
				not is_instance_valid(stale_cover)
				or stale_cover.is_queued_for_deletion()
				or not stale_cover.visible
			)
			and (
				not is_instance_valid(stale_flyer)
				or stale_flyer.is_queued_for_deletion()
				or not stale_flyer.visible
			),
			"Transient cleanup did not restore every presentation node type",
		)
		var freed_cover_event_id := "freed-cover-regression"
		var freed_cover := Control.new()
		battle.effects.add_child(freed_cover)
		battle.table._presentation_covers[freed_cover_event_id] = [freed_cover]
		freed_cover.free()
		battle.table._finish_presentation_covers(freed_cover_event_id)
		_check(
			not battle.table._presentation_covers.has(freed_cover_event_id),
			"Presentation cover cleanup tried to cast a freed cover",
		)
		var freed_flash_overlay := ColorRect.new()
		battle.own_active._flash_overlays.append(freed_flash_overlay)
		freed_flash_overlay.free()
		battle.own_active._dispose_flash_overlay(freed_flash_overlay)
		_check(
			battle.own_active._flash_overlays.is_empty(),
			"Flash overlay cleanup did not ignore a freed tween callback target",
		)
		var long_logs := [
			"玩家 1 将一对鼠放到[active]圈\n换行内容",
			"玩家1将喷火龙ex放置到active。",
			"玩家2将小火焰猴放置到bench_0。",
			"Challenge AI 的宝可梦KO。",
			"",
			"第一条很长的行动日志，用于验证完整日志可滚动而不是被裁剪。",
			"第二条很长的行动日志，用于验证中文自动换行不会丢失最新内容。",
			"第三条很长的行动日志，用于验证 RichTextLabel 保持滚动状态。",
			"第四条很长的行动日志，用于验证日志面板至少保留四条记录。",
			"第五条很长的行动日志，用于验证日志面板会根据高度限制条数。",
			"第六条很长的行动日志，用于验证战斗过程中的详细信息可读。",
			"第七条很长的行动日志，用于验证最近记录显示完整。",
			"最后一条很长的行动日志，用于验证面板滚动到最新行动。",
		]
		var battle_log_panel := battle.log_panel as BattleLogPanel
		_check(battle_log_panel != null, "Battle log panel was not typed as BattleLogPanel")
		var battle_hud := battle.hud as BattlePhaseHud
		_check(
			battle_hud != null
			and not battle_hud.is_log_drawer_open()
			and not battle_log_panel.visible,
			"Battle log drawer did not start collapsed",
		)
		battle_log_panel.size = Vector2(420, 200)
		battle_log_panel.update_entries(long_logs)
		_check(
			not battle_hud.is_log_drawer_open()
			and not battle_log_panel.visible,
			"Updating battle-log entries opened the drawer without user intent",
		)
		battle.table.action_popover.visible = true
		battle_hud.set_log_drawer_open(true)
		_check(
			battle_hud.is_log_drawer_open()
			and battle_log_panel.visible
			and battle_hud.log_toggle_button.button_pressed
			and battle_hud.log_toggle_button.text == "收起日志"
			and not battle.table.action_popover.visible
			and battle.log_label.bbcode_enabled
			and battle.log_label.autowrap_mode == TextServer.AUTOWRAP_ARBITRARY
			and battle.log_label.scroll_following
			and not battle.log_label.text.contains("◆")
			and battle.log_label.text.contains("[行动]")
			and battle.log_label.text.contains("玩家 1 将一对鼠放到［战斗区］圈 换行内容")
			and battle.log_label.text.contains("喷火龙ex放置到战斗区")
			and battle.log_label.text.contains("小火焰猴放置到备战区1")
			and battle.log_label.text.contains("挑战电脑 的宝可梦气绝")
			and not battle.log_label.text.contains("active")
			and not battle.log_label.text.contains("bench_0")
			and not battle.log_label.text.contains("AI")
			and not battle.log_label.text.contains("KO")
			and not battle.log_label.text.contains("\n\n")
			and battle.log_label.text.contains("第一条很长的行动日志")
			and battle.log_label.text.contains("最后一条很长的行动日志")
			and battle.log_label.scroll_active,
			"Battle log panel did not wrap, retain, and follow full entries",
		)
		battle_log_panel.close_button.pressed.emit()
		_check(
			not battle_hud.is_log_drawer_open()
			and not battle_log_panel.visible
			and not battle_hud.log_toggle_button.button_pressed
			and battle_hud.log_toggle_button.text == "行动日志",
			"Battle-log close button did not collapse the drawer and reset its toggle",
		)
		battle_hud.set_log_drawer_open(true)
		var selection_before_log_outside: String = battle.table.selected_entity_key
		var log_outside_press := InputEventMouseButton.new()
		log_outside_press.button_index = MOUSE_BUTTON_LEFT
		log_outside_press.pressed = true
		log_outside_press.position = (
			battle.board_panel.get_global_rect().position
			+ Vector2(20.0, battle.board_panel.size.y * 0.5)
		)
		battle.table._input(log_outside_press)
		_check(
			not battle_hud.is_log_drawer_open()
			and not battle_log_panel.visible
			and battle.table.selected_entity_key == selection_before_log_outside,
			"Clicking outside the battle log did not close only the drawer",
		)

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
		battle._on_card_motion_requested({
			"event_type": "deck_shuffled",
			"actor": 0,
			"data": {"player": 0},
		}, 0.78)
		_check(
			battle._active_flyers.is_empty(),
			"Reduced motion shuffle spawned long-running card flyers",
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
		var first_hand_drag_data := {
			"kind": "hand_card",
			"hand_index": 0,
			"card_id": "sv1-104",
		}
		_check(
			not first_hand._can_drop_data(Vector2.ZERO, first_hand_drag_data),
			"Configured card target accepted a drop without router legality",
		)
		first_hand.set_allowed_drop_hand_indices([0])
		_check(
			first_hand._can_drop_data(Vector2.ZERO, first_hand_drag_data),
			"Card target rejected its router-approved hand card",
		)
		var wrong_hand_drag_data := first_hand_drag_data.duplicate()
		wrong_hand_drag_data["hand_index"] = 1
		_check(
			not first_hand._can_drop_data(Vector2.ZERO, wrong_hand_drag_data),
			"Card target accepted a hand card outside the legal drop set",
		)
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


func _prime_card_action_popover(popover: CardActionPopover) -> void:
	# The suite runs synchronously from SceneTree._initialize(), before the first
	# process frame can resolve @onready fields. Runtime scenes resolve these on
	# their normal ready pass; prime them explicitly for this headless contract.
	popover.pointer_line = popover.get_node("PointerLine") as Line2D
	popover.panel = popover.get_node("Panel") as Panel
	popover.title_label = popover.get_node("Panel/Margin/Content/TitleLabel") as Label
	popover.hint_label = popover.get_node("Panel/Margin/Content/HintLabel") as Label
	popover.empty_hint = popover.get_node("Panel/Margin/Content/EmptyHint") as Label
	popover.action_scroll = popover.get_node(
		"Panel/Margin/Content/ActionScroll"
	) as ScrollContainer
	popover.action_buttons = popover.get_node(
		"Panel/Margin/Content/ActionScroll/ActionButtons"
	) as VBoxContainer
	popover.compact_scroll = popover.get_node(
		"Panel/Margin/Content/CompactScroll"
	) as ScrollContainer
	popover.compact_action_buttons = popover.get_node(
		"Panel/Margin/Content/CompactScroll/CompactActionButtons"
	) as HBoxContainer


func _run_card_direct_interaction_contract_tests() -> void:
	var hand_sources: Array[EntityRef] = []
	for hand_index in range(6):
		hand_sources.append(EntityRef.new(
			"card", 0, "hand", "", hand_index, "", "card-%d" % hand_index
		))
	var active_ref := EntityRef.new(
		"pokemon", 0, "", "active", -1, "", "active-card"
	)
	var bench_zero_ref := EntityRef.new(
		"pokemon", 0, "", "bench_0", -1, "", "bench-card-0"
	)
	var bench_one_ref := EntityRef.new(
		"pokemon", 0, "", "bench_1", -1, "", "bench-card-1"
	)
	var actions_by_name := {
		"PLAY_BASIC": GameAction.new(
			"PLAY_BASIC",
			{"hand_idx": 0, "target": "active"},
			false,
			0,
			hand_sources[0],
			active_ref,
		),
		"EVOLVE": GameAction.new(
			"EVOLVE",
			{"hand_idx": 1, "slot": "active"},
			false,
			0,
			hand_sources[1],
			active_ref,
		),
		"ATTACH_ENERGY": GameAction.new(
			"ATTACH_ENERGY",
			{"hand_idx": 2, "target_slot": "bench_0"},
			false,
			0,
			hand_sources[2],
			bench_zero_ref,
		),
		"PLAY_TRAINER": GameAction.new(
			"PLAY_TRAINER",
			{"hand_idx": 3},
			false,
			0,
			hand_sources[3],
		),
		"USE_ABILITY": GameAction.new(
			"USE_ABILITY",
			{"slot": "active", "ability_name": "测试特性"},
			false,
			0,
			active_ref,
		),
		"USE_STADIUM": GameAction.new(
			"USE_STADIUM",
			{},
			false,
			0,
			EntityRef.new("stadium", 0, "stadium", "", -1),
		),
		"RETREAT": GameAction.new(
			"RETREAT",
			{"bench_idx": 0, "discard_indices": [0]},
			false,
			0,
			active_ref,
			bench_zero_ref,
		),
		"DECLARE_ATTACK": GameAction.new(
			"DECLARE_ATTACK",
			{"attack_idx": 0},
			true,
			0,
			active_ref,
		),
		"PROMOTE": GameAction.new(
			"PROMOTE",
			{"bench_idx": 1},
			false,
			0,
			bench_one_ref,
			bench_one_ref,
		),
	}
	var expected_source_keys := {
		"PLAY_BASIC": "hand:0",
		"EVOLVE": "hand:1",
		"ATTACH_ENERGY": "hand:2",
		"PLAY_TRAINER": "hand:3",
		"USE_ABILITY": "pokemon:0:active",
		"USE_STADIUM": "stadium",
		"RETREAT": "pokemon:0:active",
		"DECLARE_ATTACK": "pokemon:0:active",
		"PROMOTE": "pokemon:0:bench_1",
	}
	_check(
		expected_source_keys.size() == 9
		and CardInteractionRouter.CARD_ACTIONS.size() == 9,
		"Card interaction contract no longer covers all nine public card actions",
	)

	var rows: Array[Dictionary] = []
	for action_name_value in actions_by_name.keys():
		var action_name := str(action_name_value)
		rows.append({
			"action": actions_by_name[action_name] as GameAction,
			"label": "动作 · %s" % action_name,
		})
	rows.append({
		"action": GameAction.new("END_TURN", {}, true, 0),
		"label": "结束回合",
	})
	rows.append({
		"action": GameAction.new("SETUP_DONE", {}, true, 0),
		"label": "完成准备",
	})

	var router := CardInteractionRouter.new()
	router.rebuild(rows)
	_check(
		router.all_card_actions_reachable()
		and router.unreachable_rows().is_empty(),
		"A supported card action has no card interaction source",
	)
	for action_name_value in expected_source_keys.keys():
		var action_name := str(action_name_value)
		var source_key := str(expected_source_keys[action_name])
		var routed_action := actions_by_name[action_name] as GameAction
		_check(
			CardInteractionRouter.is_supported_card_action(routed_action)
			and router.actions_for_source(source_key).has(routed_action),
			"%s was not routed from %s" % [action_name, source_key],
		)
	_check(
		router.system_action("END_TURN") != null
		and router.system_action("SETUP_DONE") != null
		and "END_TURN" not in router.source_keys()
		and "SETUP_DONE" not in router.source_keys(),
		"System actions leaked into the card-source index",
	)

	_check(
		router.is_target_legal("hand:0", "pokemon:0:active")
		and router.is_target_legal("hand:1", "pokemon:0:active")
		and router.is_target_legal("hand:2", "pokemon:0:bench_0")
		and router.is_target_legal(
			"pokemon:0:active", "pokemon:0:bench_0"
		)
		and router.target_keys_for_source("hand:3").is_empty()
		and router.target_keys_for_source("stadium").is_empty()
		and router.target_keys_for_source("pokemon:0:bench_1").is_empty(),
		"Card interaction targets do not match basic/evolution/energy/retreat semantics",
	)
	_check(
		router.is_drop_legal(0, 0, "active")
		and router.is_drop_legal(1, 0, "active")
		and router.is_drop_legal(2, 0, "bench_0")
		and not router.is_drop_legal(2, 0, "active")
		and not router.is_drop_legal(3, 0, "active"),
		"Drag matching accepts an illegal card/slot pair or rejects a legal one",
	)

	var stadium_drag_router := CardInteractionRouter.new()
	stadium_drag_router.rebuild([{
		"action": GameAction.new(
			"PLAY_TRAINER",
			{"hand_idx": 5},
			false,
			0,
			hand_sources[5],
		),
		"label": "打出竞技场",
		"drag_target_keys": ["stadium"],
	}])
	_check(
		stadium_drag_router.is_drop_legal(5, 0, "stadium")
		and not stadium_drag_router.is_drop_legal(5, 0, "active"),
		"Stadium drag metadata did not restrict the card to the stadium zone",
	)
	var main_script := load("res://scenes/main/main.gd") as Script
	var main_stadium_probe: Variant = main_script.new() if main_script else null
	if main_stadium_probe:
		var subtype_catalog := CardCatalog.new(true)
		subtype_catalog.cards["test-main-subtype-stadium"] = {
			"name": "测试竞技场",
			"supertype": "Trainer",
			"subtypes": ["Stadium"],
		}
		var subtype_state := GameState.new()
		subtype_state.phase = "MAIN"
		subtype_state.active_player_idx = 0
		subtype_state.players[0].hand = ["test-main-subtype-stadium"]
		var subtype_action := GameAction.new(
			"PLAY_TRAINER",
			{"hand_idx": 0},
			false,
			0,
		)
		main_stadium_probe.catalog = subtype_catalog
		main_stadium_probe.state = subtype_state
		main_stadium_probe.game_mode = "network"
		main_stadium_probe.network_player_idx = 0
		main_stadium_probe.network_legal_actions.assign([subtype_action])
		_check(
			main_stadium_probe._matching_drop_actions(
				0, 0, "stadium"
			).size() == 1,
			"Main rejected a Stadium classified by the rules-layer subtype",
		)
		main_stadium_probe.free()
	var energy_alternative := GameAction.new(
		"ATTACH_ENERGY",
		{"hand_idx": 2, "target_slot": "bench_0", "resolution": "alternative"},
		false,
		0,
		hand_sources[2],
		bench_zero_ref,
	)
	var retreat_alternative := GameAction.new(
		"RETREAT",
		{"bench_idx": 0, "discard_indices": [1]},
		false,
		0,
		active_ref,
		bench_zero_ref,
	)
	var second_attack := GameAction.new(
		"DECLARE_ATTACK",
		{"attack_idx": 1},
		true,
		0,
		active_ref,
	)
	var multi_rows := rows.duplicate()
	multi_rows.append({"action": energy_alternative, "label": "替代附能"})
	multi_rows.append({"action": retreat_alternative, "label": "替代撤退支付"})
	multi_rows.append({"action": second_attack, "label": "第二招式"})
	var multi_router := CardInteractionRouter.new()
	multi_router.rebuild(multi_rows, "pokemon:0:active")
	_check(
		multi_router.matching_actions(
			"hand:2", "pokemon:0:bench_0"
		).size() == 2
		and multi_router.matching_actions(
			"pokemon:0:active", "pokemon:0:bench_0"
		).size() == 2,
		"Identical targets with multiple actions/payment combinations were collapsed",
	)
	var energy_groups := multi_router.action_groups_for_source("hand:2")
	var active_groups := multi_router.action_groups_for_source("pokemon:0:active")
	var energy_group_action_count := 0
	var retreat_group_action_count := 0
	var attack_group_count := 0
	for group in energy_groups:
		if str(group.get("action_type", "")) == "ATTACH_ENERGY":
			energy_group_action_count = Array(group.get("actions", [])).size()
	for group in active_groups:
		match str(group.get("action_type", "")):
			"RETREAT":
				retreat_group_action_count = Array(group.get("actions", [])).size()
			"DECLARE_ATTACK":
				attack_group_count += 1
	_check(
		energy_group_action_count == 2
		and retreat_group_action_count == 2
		and attack_group_count == 2,
		"Action grouping lost duplicate targets, retreat payments, or distinct attacks",
	)

	var visible_sources := router.source_keys()
	_check(
		router.all_card_actions_reachable_from(visible_sources),
		"Visible card sources failed the action-reachability contract",
	)
	visible_sources.erase("stadium")
	_check(
		not router.all_card_actions_reachable_from(visible_sources),
		"Reachability contract did not detect a missing visible stadium source",
	)
	var malformed_router := CardInteractionRouter.new()
	malformed_router.rebuild([{
		"action": GameAction.new("PLAY_TRAINER", {}, false, 0),
		"label": "无来源动作",
	}])
	_check(
		not malformed_router.all_card_actions_reachable()
		and malformed_router.unreachable_actions().size() == 1,
		"Reachability contract accepted a card action without a source",
	)

	var popover_scene := load(
		"res://scenes/battle/components/card_action_popover.tscn"
	) as PackedScene
	_check(popover_scene != null, "CardActionPopover scene failed to load")
	if popover_scene == null:
		return
	var popover := popover_scene.instantiate() as CardActionPopover
	root.add_child(popover)
	_prime_card_action_popover(popover)
	popover.set_anchors_preset(Control.PRESET_TOP_LEFT)
	popover.size = Vector2(1280.0, 720.0)
	var popover_rows: Array[Dictionary] = []
	for action_name in [
		"PLAY_TRAINER", "USE_ABILITY", "RETREAT", "DECLARE_ATTACK", "USE_STADIUM",
	]:
		popover_rows.append({
			"action": actions_by_name[action_name] as GameAction,
			"label": "卡牌动作 · %s" % action_name,
			"hint": "动作说明",
		})
	var oversized_energy_image := Image.create(512, 512, false, Image.FORMAT_RGBA8)
	oversized_energy_image.fill(Color(0.2, 0.9, 0.3, 1.0))
	popover_rows[0]["icon"] = ImageTexture.create_from_image(oversized_energy_image)
	var safe_rect := Rect2(48.0, 48.0, 1184.0, 624.0)
	var source_rect := Rect2(520.0, 460.0, 112.0, 157.0)
	var avoid_above := Rect2(515.0, 100.0, 122.0, 350.0)
	var avoid_right := Rect2(640.0, 350.0, 290.0, 320.0)
	popover.show_actions(
		popover_rows,
		source_rect,
		safe_rect,
		[avoid_above, avoid_right],
		"卡牌操作",
		"选择动作",
	)
	var anchored_panel_rect := popover.panel_global_rect()
	_check(
		popover.visible
		and popover.button_count() == 5
		and popover.current_placement == "above"
		and safe_rect.encloses(anchored_panel_rect)
		and not anchored_panel_rect.intersects(source_rect)
		and absf(
			anchored_panel_rect.get_center().x - source_rect.get_center().x
		) < 0.01
		and absf(
			anchored_panel_rect.end.y
			- (source_rect.position.y - popover.anchor_gap)
		) < 0.01,
		"CardActionPopover was not fixed directly above its source inside the safe area",
	)
	var popover_buttons_are_touchable := popover.action_buttons.get_child_count() == 5
	for child_value in popover.action_buttons.get_children():
		var action_button := child_value as Button
		popover_buttons_are_touchable = (
			popover_buttons_are_touchable
			and action_button != null
			and action_button.custom_minimum_size.y >= 48.0
			and action_button.custom_minimum_size.x
			>= anchored_panel_rect.size.x
			- CardActionPopover.PANEL_CONTENT_HORIZONTAL_MARGIN
			and action_button.alignment == HORIZONTAL_ALIGNMENT_CENTER
			and action_button.focus_mode == Control.FOCUS_NONE
		)
	_check(
		popover_buttons_are_touchable
		and popover.action_scroll.custom_minimum_size.y
		<= 4.0 * popover.action_button_height + 12.0,
		"CardActionPopover buttons or four-action scroll limit violate touch sizing",
	)
	var icon_action_button := popover.action_buttons.get_child(0) as Button
	_check(
		icon_action_button.icon != null
		and icon_action_button.icon.get_size() == Vector2(22.0, 22.0)
		and icon_action_button.text == str(popover_rows[0].get("label"))
		and icon_action_button.get_node_or_null("FixedIconContent") == null
		and icon_action_button.get_combined_minimum_size().y <= 52.0,
		"Large energy artwork expanded the card action button or popover",
	)
	# Reuse the same instance in the same frame, matching a direct click from a
	# card with several actions to an unusable card. A PanelContainer used to
	# retain the previous content minimum and leave this informational surface at
	# roughly four action rows tall.
	var four_action_rows: Array[Dictionary] = []
	for row_index in range(4):
		four_action_rows.append(popover_rows[row_index])
	popover.show_actions(
		four_action_rows,
		source_rect,
		safe_rect,
		[],
		"卡牌操作",
		"",
	)
	var multi_action_height := popover.panel_global_rect().size.y
	popover.show_actions(
		[],
		source_rect,
		safe_rect,
		[],
		"无法操作",
		"场上没有可进化为这张卡的宝可梦",
	)
	var empty_panel_rect := popover.panel_global_rect()
	var expected_empty_size := popover._desired_panel_size(false)
	_check(
		popover.panel.get_class() == "Panel"
		and popover.button_count() == 0
		and popover.empty_hint.visible
		and not popover.action_scroll.visible
		and popover.action_buttons.get_child_count() == 0
		and popover.compact_action_buttons.get_child_count() == 0
		and empty_panel_rect.size.is_equal_approx(expected_empty_size)
		and empty_panel_rect.size.y < multi_action_height
		and safe_rect.encloses(empty_panel_rect)
		and not empty_panel_rect.intersects(source_rect),
		"CardActionPopover retained a previous multi-action minimum size",
	)
	# Restore actionable content for the signal and dismissal contracts below.
	popover.show_actions(
		popover_rows,
		source_rect,
		safe_rect,
		[avoid_above, avoid_right],
		"卡牌操作",
		"选择动作",
	)
	var chosen_probe := {}
	popover.action_chosen.connect(
		func(action: GameAction) -> void: chosen_probe["action"] = action
	)
	(popover.action_buttons.get_child(0) as Button).pressed.emit()
	_check(
		not popover.visible
		and chosen_probe.get("action") == popover_rows[0].get("action"),
		"CardActionPopover did not close and emit the selected GameAction",
	)

	var dismiss_probe := {"count": 0}
	popover.dismissed.connect(func() -> void:
		dismiss_probe["count"] = int(dismiss_probe["count"]) + 1
	)
	popover.show_actions(
		[popover_rows[0]], source_rect, safe_rect, [], "卡牌操作", ""
	)
	var outside_pointer := InputEventMouseButton.new()
	outside_pointer.button_index = MOUSE_BUTTON_LEFT
	outside_pointer.pressed = true
	outside_pointer.position = Vector2(50.0, 50.0)
	popover._gui_input(outside_pointer)
	_check(
		not popover.visible and int(dismiss_probe["count"]) == 1,
		"Mouse-emulated touch on blank table space did not dismiss CardActionPopover",
	)

	var moving_source := Control.new()
	moving_source.position = Vector2(840.0, 280.0)
	moving_source.size = Vector2(100.0, 140.0)
	moving_source.pivot_offset = moving_source.size * 0.5
	moving_source.rotation = 0.08
	root.add_child(moving_source)
	popover.show_for_control(
		[popover_rows[0]], moving_source, safe_rect, [], "卡牌操作", ""
	)
	var tracked_panel_before := popover.panel_global_rect()
	moving_source.position += Vector2(-120.0, 80.0)
	popover._process(0.0)
	var moved_source_bounds := popover._control_global_bounds(moving_source)
	var tracked_panel_after := popover.panel_global_rect()
	_check(
		popover.visible
		and popover._last_tracked_source_rect == moved_source_bounds
		and tracked_panel_after != tracked_panel_before
		and popover.current_placement == "above"
		and not tracked_panel_after.intersects(moved_source_bounds)
		and absf(
			tracked_panel_after.get_center().x - moved_source_bounds.get_center().x
		) < 0.01,
		"CardActionPopover did not stay centered above a moving transformed card",
	)
	popover.dismiss(false)
	moving_source.free()

	var top_edge_source := Rect2(560.0, 56.0, 100.0, 140.0)
	popover.show_actions(
		[popover_rows[0]], top_edge_source, safe_rect, [], "卡牌操作", ""
	)
	var edge_fallback_rect := popover.panel_global_rect()
	_check(
		popover.current_placement == "below_fallback"
		and safe_rect.encloses(edge_fallback_rect)
		and not edge_fallback_rect.intersects(top_edge_source)
		and absf(
			edge_fallback_rect.get_center().x - top_edge_source.get_center().x
		) < 0.01,
		"Top-edge CardActionPopover fallback escaped the safe area or covered its source",
	)
	popover.dismiss(false)

	var compact_safe_rect := Rect2(48.0, 48.0, 400.0, 300.0)
	var compact_source_rect := Rect2(200.0, 200.0, 96.0, 120.0)
	popover.show_actions(
		popover_rows,
		compact_source_rect,
		compact_safe_rect,
		[],
		"卡牌操作",
		"",
	)
	_check(
		popover.is_compact_layout()
		and popover.current_placement == "compact_above"
		and compact_safe_rect.encloses(popover.panel_global_rect())
		and not popover.panel_global_rect().intersects(compact_source_rect)
		and popover.compact_action_buttons.get_child_count() == 5
		and not popover.current_placement.contains("free"),
		"Constrained safe area did not activate a safe anchored compact popover",
	)
	popover.dismiss(false)
	popover.show_actions(
		[popover_rows[0]],
		Rect2(200.0, 70.0, 96.0, 120.0),
		Rect2(48.0, 48.0, 400.0, 160.0),
		[],
		"卡牌操作",
		"",
	)
	var centered_compact_button := (
		popover.compact_action_buttons.get_child(0) as Button
	)
	_check(
		popover.is_compact_layout()
		and popover.compact_action_buttons.alignment
		== BoxContainer.ALIGNMENT_CENTER
		and popover.compact_action_buttons.custom_minimum_size.x
		>= popover.panel_global_rect().size.x
		- CardActionPopover.PANEL_CONTENT_HORIZONTAL_MARGIN
		and centered_compact_button != null
		and centered_compact_button.size_flags_horizontal
		== Control.SIZE_SHRINK_CENTER
		and centered_compact_button.custom_minimum_size.y >= 48.0
		and not popover.current_placement.contains("free"),
		"Single-button compact CardActionPopover is not centered in its panel",
	)
	popover.show_actions(
		[popover_rows[0]],
		source_rect,
		safe_rect,
		[],
		"卡牌操作",
		"",
	)
	_check(
		not popover.is_compact_layout()
		and popover.action_scroll.visible
		and not popover.compact_scroll.visible
		and popover.action_buttons.get_child_count() == 1
		and popover.compact_action_buttons.get_child_count() == 0,
		"CardActionPopover did not reset its compact container state on reuse",
	)
	popover.free()


func _run_local_ui_playout(ui: Node) -> void:
	var action_count := 0
	var choice_count := 0
	while not ui.state.is_terminal() and action_count < 1200:
		if ui.modal_layer.visible and ui.active_request == null:
			if ui.modal_confirm.disabled:
				await process_frame
				continue
			var gate_generation: int = ui._modal_generation
			ui.modal_confirm.pressed.emit()
			var close_generation := gate_generation + 1
			var modal_close_guard := 0
			while (
				ui.modal_layer.visible
				and ui._modal_generation == close_generation
				and modal_close_guard < 120
			):
				modal_close_guard += 1
				await process_frame
			_check(
				not ui.modal_layer.visible
				or ui._modal_generation > close_generation,
				"Local UI privacy gate did not finish closing",
			)
			await process_frame
			await _wait_for_battle_transition(
				ui,
				"local playout privacy-gated turn start",
			)
			continue
		if ui.active_request != null:
			choice_count += 1
			_check(choice_count < 1200, "Local UI choice chain exceeded guard")
			if choice_count >= 1200:
				break
			var request: ChoiceRequest = ui.active_request
			var automatic_response := _playout_choice_response(
				ui.state, request, ui.catalog)
			ui.selected_choice_ids.assign(automatic_response.option_ids)
			ui._confirm_choice()
			await _wait_for_battle_transition(
				ui,
				"local playout choice %d" % choice_count,
			)
			continue
		action_count += 1
		var actor: int = ui.state.active_player_idx
		if not ui.state.pending_promotions.is_empty():
			actor = int(ui.state.pending_promotions[0])
		elif ui.state.phase == "SETUP":
			actor = ui.state.setup_actor_idx
		ui.current_view_player = actor
		ui._refresh_game()
		var actions: Array[GameAction] = RulesTestHarness.legal_actions(ui.engine,
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
		var action := _playout_action(actions, ui.state, ui.catalog)
		var step: StepResult = (
			ui._execute_action_now(action)
			if action.action == "RETREAT"
			else ui._execute_action(action)
		)
		_check(step.success, "Local UI action failed: %s" % step.message)
		if not step.success:
			break
		_check(
			ui.state.revision > previous_revision,
			"Local UI action did not advance state revision",
		)
		if ui.state.revision <= previous_revision:
			break
		await _wait_for_battle_transition(
			ui,
			"local playout action %d" % action_count,
		)
	_check(action_count < 1200, "Local UI playout exceeded action guard")
	_check(ui.state.is_terminal(), "Local UI playout did not terminate")


func _wait_for_battle_transition(
	ui: Node,
	context: String,
	max_frames: int = 1200,
) -> void:
	var frame_count := 0
	while frame_count < max_frames:
		if ui == null or not is_instance_valid(ui):
			return
		var battle: Variant = ui.get("battle_screen")
		if (
			battle == null
			or not is_instance_valid(battle)
			or not battle.is_presentation_busy()
		):
			return
		frame_count += 1
		await process_frame
	_check(false, "Battle transition timed out: %s" % context)


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


func _run_conditional_damage_regression_tests(engine: GameEngine) -> void:
	var water_weak := false
	for weakness_value in engine.catalog.get_card("svi-infr").get("weaknesses", []):
		var weakness: Dictionary = weakness_value
		if str(weakness.get("energy_type", "")) == "Water":
			water_weak = true
			break
	_check(water_weak, "Greninja regression target must retain its Water weakness")

	var cases: Array[Dictionary] = [
		{"name": "full-health", "initial_counters": 0, "expected_damage": 120},
		{"name": "already-damaged", "initial_counters": 1, "expected_damage": 240},
	]
	for case_value in cases:
		var case: Dictionary = case_value
		var state := _battle_state()
		state.set_type_matchups_enabled(false)
		state.players[0].active = PokemonState.new("sv2-grex")
		state.players[0].active.placed_this_turn = false
		_set_energy_cards(
			state.players[0].active,
			["sv1-ener-3", "sv1-ener-3"],
		)
		state.players[1].active = PokemonState.new("svi-infr")
		state.players[1].active.placed_this_turn = false
		state.players[1].active.damage_counters = int(
			case.get("initial_counters", 0))
		var defender := state.players[1].active
		var step := _apply_test_action(
			engine,
			state,
			GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
			PortableRandomSource.new(61130 + int(case.get("initial_counters", 0))),
		)
		var damage_event_amount := -1
		for event_value in step.events:
			var event: Dictionary = event_value
			var event_data: Dictionary = event.get("data", {})
			if (
				str(event.get("event_type", "")) == "damage_dealt"
				and int(event_data.get("player", -1)) == 1
				and str(event_data.get("slot", "")) == "active"
			):
				damage_event_amount = int(event.get(
					"amount", event_data.get("amount", -1)))
				break
		var expected_damage := int(case.get("expected_damage", 0))
		_check(
			step.success
			and not state.type_matchups_enabled()
			and damage_event_amount == expected_damage
			and defender.damage_counters
			== int(case.get("initial_counters", 0)) + int(expected_damage / 10),
			(
				"Greninja conditional damage regression failed for %s: "
				+ "expected %d damage with type matchups disabled, "
				+ "got event=%d counters=%d"
			) % [
				str(case.get("name", "")),
				expected_damage,
				damage_event_amount,
				defender.damage_counters,
			],
		)


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
	_check(examples.size() == 77, "Expected one compiled example for every effect type")
	for effect_type in examples:
		var state := _effect_state()
		var stack := ResolutionStack.new()
		stack.push_effect(Dictionary(examples[effect_type]), 0, "active")
		var step := RulesTestHarness.effect_engine_for(engine).resolve(
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
			step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	var step := RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260621))
	_check(step.success, "Native draw_cards command spec failed: %s" % step.message)
	_check(state.players[0].hand.has("sv1-ener-2"), "Native draw_cards did not draw a card")

	state = _effect_state()
	state.players[1].hand = []
	state.players[1].deck = ["sv1-ener-3"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "trigger_draw_cards",
		"args": {"player": 1, "amount": 1, "source": "trigger_test"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062111))
	_check(step.success, "Native trigger_draw_cards command spec failed: %s" % step.message)
	_check(state.players[1].hand == ["sv1-ener-3"], "Native trigger_draw_cards drew for wrong player")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "trigger_place_damage_counters",
		"args": {"player": 1, "slot": "active", "count": 2, "source": "trigger_test"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062112))
	_check(step.success, "Native trigger_place_damage_counters command spec failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 2,
		"Native trigger_place_damage_counters placed counters on wrong target")

	state = _effect_state()
	state.players[0].active.energy_card_ids = ["sv1-ener-2"]
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[0].attached_tool_id = "svg2-exps"
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "trigger_move_basic_energy",
		"args": {
			"from_player": 0,
			"from_slot": "active",
			"to_player": 0,
			"to_slot": "bench_0",
			"source": "trigger_test",
			"select_source": true,
		},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062113))
	_check(
		step.success
		and step.pending_choice != null
		and step.pending_choice.request_type == "select_attachment",
		"Native trigger_move_basic_energy did not suspend for an exact attachment: %s"
		% step.message,
	)
	if step.success and step.pending_choice != null:
		var move_energy_request := step.pending_choice
		step = RulesTestHarness.apply_choice(engine,
			state,
			move_energy_request,
			ChoiceResponse.new(move_energy_request.request_id, [
				str(move_energy_request.options[0].get("option_id", "")),
			]),
			PortableRandomSource.new(2026062113),
		)
	_check(
		step.success
		and step.pending_choice == null
		and
		state.players[0].active.energy_card_ids.is_empty()
		and state.players[0].bench[0].energy_card_ids == ["sv1-ener-2"],
		"Native trigger_move_basic_energy continuation did not move the selected entity",
	)

	state = _effect_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "trigger_switch_with_active",
		"args": {"player": 0, "bench_idx": 0, "source": "trigger_test", "slot": "bench_0"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062114))
	_check(step.success, "Native trigger_switch_with_active command spec failed: %s" % step.message)
	_check(
		state.players[0].active.card_id == "sv2-delib"
		and state.players[0].bench[0].card_id == "svi-chim",
		"Native trigger_switch_with_active did not switch active with selected bench",
	)

	state = _effect_state()
	state.players[1].hand = []
	state.players[1].deck = ["sv1-ener-4"]
	stack = ResolutionStack.new()
	stack.push_finalize_attack_turn(0)
	var trigger_events: Array[Dictionary] = []
	var trigger_commands := RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands
	var trigger_result := trigger_commands.command_specs_from_payloads(
		[{"op": "draw_cards", "player": 1, "amount": 1, "source": "stack_trigger"}],
	)
	if bool(trigger_result.get("success", false)):
		var trigger_candidate := trigger_commands.make_candidate(
			"test:active_stack", "TEST_TRIGGER", 0, 0,
			{"kind": "slot", "player": 0, "slot": "active"},
			false, {"kind": "always"}, [], trigger_result.get("commands", []))
		trigger_result = trigger_commands.queue_candidates(
			stack, [trigger_candidate], "TEST_TRIGGER", 0)
	if bool(trigger_result.get("success", false)):
		var trigger_step := RulesTestHarness.effect_engine_for(engine).resolve(
			state, stack, PortableRandomSource.new(2026062115))
		trigger_events.append_array(trigger_step.events)
		if not trigger_step.success:
			trigger_result = VMResult.fail(trigger_step.message, trigger_step.error_code)
	_check(
		bool(trigger_result.get("success", false))
		and stack.has_finalize_attack_turn_frame()
		and state.players[1].hand == ["sv1-ener-4"]
		and trigger_events.size() == 1,
		"Trigger payload did not resolve through active ResolutionStack without disturbing existing frames",
	)
	var bad_trigger_events: Array[Dictionary] = []
	var bad_trigger_result := trigger_commands.command_specs_from_payloads(
		[{"op": "__unknown_trigger__", "args": {}, "branches": {}}],
	)
	_check(
		not bool(bad_trigger_result.get("success", true))
		and str(bad_trigger_result.get("error_code", "")) == "invalid_trigger_op"
		and stack.has_finalize_attack_turn_frame()
		and bad_trigger_events.is_empty(),
		"Invalid trigger command did not fail structurally while preserving active stack frames",
	)
	var malformed_trigger_events: Array[Dictionary] = []
	var malformed_trigger_result := trigger_commands.command_specs_from_payloads(
		[{"command_specs": {"op": "draw_cards"}}],
	)
	_check(
		not bool(malformed_trigger_result.get("success", true))
		and str(malformed_trigger_result.get("error_code", "")) == "invalid_trigger_command_specs"
		and stack.has_finalize_attack_turn_frame()
		and malformed_trigger_events.is_empty(),
		"Non-array trigger command_specs payload did not fail structurally",
	)
	var object_payload_trigger_events: Array[Dictionary] = []
	var object_payload_trigger_result := trigger_commands.command_specs_from_payloads(
		[{"command_specs": [42]}],
	)
	_check(
		not bool(object_payload_trigger_result.get("success", true))
		and str(object_payload_trigger_result.get("error_code", "")) == "invalid_trigger_payload"
		and stack.has_finalize_attack_turn_frame()
		and object_payload_trigger_events.is_empty(),
		"Non-dictionary trigger command_specs item did not fail structurally",
	)
	var non_trigger_payload_events: Array[Dictionary] = []
	var non_trigger_payload_result := trigger_commands.command_specs_from_payloads(
		[{
			"command_specs": [{
				"op": "draw_cards",
				"args": {"amount": 1},
				"branches": {},
			}],
		}],
	)
	_check(
		not bool(non_trigger_payload_result.get("success", true))
		and str(non_trigger_payload_result.get("error_code", "")) == "invalid_trigger_op"
		and stack.has_finalize_attack_turn_frame()
		and non_trigger_payload_events.is_empty(),
		"Explicit non-trigger VM command_specs payload did not fail structurally",
	)

	state = _effect_state()
	_set_energy_cards(state.players[1].active, ["svi-mirc"])
	var after_damage_candidates: Array[Dictionary] = []
	RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands.collect_after_damage_triggers(
		state,
		{
			"actor": 0,
			"attacker": state.players[0].active,
			"defender": state.players[1].active,
			"damage": 30,
			"ignore_defender_effects": false,
		},
		after_damage_candidates,
	)
	var after_damage_command: Dictionary = (
		after_damage_candidates[0].get("commands", [])[0]
		if after_damage_candidates.size() == 1
		and after_damage_candidates[0].get("commands", []).size() == 1
		else {}
	)
	_check(
		after_damage_candidates.size() == 1
		and str(after_damage_candidates[0].get("hook", ""))
		== VMModifierManager.AFTER_DAMAGE
		and str(after_damage_command.get("op", "")) == "trigger_draw_cards"
		and str(after_damage_command.get("args", {}).get("source", "")) == "svi-mirc"
		and RulesTestHarness.effect_engine_for(engine).supports_command_spec(after_damage_command),
		"Native AFTER_DAMAGE hook did not produce a schedulable TriggerCandidate",
	)

	state = _effect_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.placed_this_turn = false
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	var on_attach_trigger_candidates: Array[Dictionary] = []
	RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands.collect_on_attach_triggers(
		"svi-jete",
		0,
		"bench_0",
		"hand",
		on_attach_trigger_candidates,
	)
	var on_attach_trigger_command: Dictionary = (
		on_attach_trigger_candidates[0].get("commands", [])[0]
		if on_attach_trigger_candidates.size() == 1
		and on_attach_trigger_candidates[0].get("commands", []).size() == 1
		else {}
	)
	_check(
		on_attach_trigger_candidates.size() == 1
		and str(on_attach_trigger_candidates[0].get("hook", ""))
		== VMModifierManager.ON_ATTACH
		and str(on_attach_trigger_command.get("op", "")) == "trigger_switch_with_active"
		and int(on_attach_trigger_command.get("args", {}).get("bench_idx", -1)) == 0
		and RulesTestHarness.effect_engine_for(engine).supports_command_spec(on_attach_trigger_command),
		"Native ON_ATTACH hook did not produce a schedulable Jet Energy trigger",
	)
	var active_attach_trigger_candidates: Array[Dictionary] = []
	RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands.collect_on_attach_triggers(
		"svi-jete",
		0,
		"active",
		"hand",
		active_attach_trigger_candidates,
	)
	_check(active_attach_trigger_candidates.is_empty(), "Native ON_ATTACH hook fired for active Jet Energy attach")
	state.players[0].hand = ["svi-jete"]
	step = _apply_test_action(engine,
		state,
		GameAction.new("ATTACH_ENERGY", {"hand_idx": 0, "target_slot": "bench_0"}, true, 0),
		PortableRandomSource.new(2026062115),
	)
	_check(step.success, "Jet Energy manual attach failed: %s" % step.message)
	_check(
		state.players[0].active.card_id == "sv2-delib"
		and state.players[0].active.energy_card_ids == ["svi-jete"]
		and state.players[0].bench[0].card_id == "svi-chim",
		"Jet Energy manual attach did not resolve ON_ATTACH switch via trigger command",
	)

	state = _effect_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].hand = ["svi-jete"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "attach_energy",
		"args": {"amount": 1, "from_zone": "hand", "filter": "any", "to": "bench"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062116))
	_check(step.success and step.pending_choice != null,
		"Jet Energy VM attach did not request bench target")
	var jet_attach_option := _choice_id_for_slot(step.pending_choice, "bench_0")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [jet_attach_option]),
		PortableRandomSource.new(2026062117),
	)
	_check(step.success, "Jet Energy VM attach choice failed: %s" % step.message)
	_check(
		state.players[0].active.card_id == "sv2-delib"
		and state.players[0].active.energy_card_ids == ["svi-jete"]
		and state.players[0].bench[0].card_id == "svi-chim",
		"Jet Energy VM attach did not resolve ON_ATTACH switch via trigger command",
	)

	state = _effect_state()
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "legacy_effect",
		"args": {"effect_type": "draw", "amount": 1},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062101))
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062103))
	_check(
		not step.success and step.error_code == "legacy_effect_type_arg",
		"Native VM op accepted legacy effect_type args at runtime",
	)

	state = _effect_state()
	stack = ResolutionStack.new()
	stack.push_effect({"effect_type": "draw", "params": {"amount": 1}}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062102))
	_check(
		not step.success and step.error_code == "missing_vm_op",
		"Raw effect dict was accepted as a VM stack command",
	)

	state = _effect_state()
	stack = ResolutionStack.new()
	stack.push_effect({"op": "deal_damage", "args": {"amount": 20}, "branches": {}}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260622))
	_check(step.success, "Native deal_damage command spec failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 3, "Native deal_damage did not damage opponent active")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].active.damage_counters = 2
	state.players[0].active.energy_card_ids = ["sv1-ener-2", "sv1-ener-5"]
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage",
		"args": {
			"formula_ast": {
				"op": "add",
				"terms": [
					{
						"op": "mul",
						"factors": [{"op": "hand_size"}, {"const": 10}],
					},
					{
						"op": "mul",
						"factors": [
							{"op": "energy_count", "scope": "self", "energy_type": "Fire"},
							{"const": 20},
						],
					},
					{
						"op": "mul",
						"factors": [
							{"op": "damage_counters", "target": "self"},
							{"const": 10},
						],
					},
				],
			},
		},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062201))
	_check(step.success, "Native deal_damage formula_ast command spec failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 7,
		"Native deal_damage formula_ast produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].bench[0] = PokemonState.new("svg2-tort")
	state.players[0].bench[1] = PokemonState.new("sv1-106")
	state.players[0].discard = ["sv1-106", "svi-chim", "sv1-ener-5"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage",
		"args": {
			"ignore_weakness": true,
			"formula_ast": {
				"op": "add",
				"terms": [
					{"const": 30},
					{
						"op": "mul",
						"factors": [
							{
								"op": "discard_count",
								"player": "self",
								"filter": {
									"card_type": "pokemon",
									"energy_type": "Psychic",
								},
							},
							{"const": 10},
						],
					},
					{
						"op": "mul",
						"factors": [
							{"op": "evolved_count", "player": "self"},
							{"const": 20},
						],
					},
					{
						"op": "div",
						"args": [
							{"op": "sub", "args": [{"const": 40}, {"const": 10}]},
							{"const": 3},
						],
					},
				],
			},
		},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062202))
	_check(step.success, "Native compound formula_ast command spec failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 9,
		"Native compound formula_ast did not cover discard/evolved/arithmetic")

	var conditional_formula_spec := {
		"op": "deal_damage",
		"args": {
			"formula_ast": {
				"op": "add",
				"terms": [
					{"const": 10},
					{
						"op": "if",
						"condition": "own_hand_empty",
						"then": {"const": 30},
						"else": {"const": 0},
					},
					{
						"op": "mul",
						"factors": [
							{"op": "condition", "condition": "opponent_active_damaged"},
							{"const": 20},
						],
					},
				],
			},
		},
		"branches": {},
	}
	state = _effect_state()
	state.players[0].hand = []
	state.players[1].active.damage_counters = 1
	stack = ResolutionStack.new()
	stack.push_effect(conditional_formula_spec, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062204))
	_check(step.success, "Native conditional formula_ast true branch failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 7,
		"Native conditional formula_ast did not apply true branch and condition node")

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-2"]
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.push_effect(conditional_formula_spec, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062205))
	_check(step.success, "Native conditional formula_ast false branch failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 1,
		"Native conditional formula_ast did not apply false branch")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].active.energy_card_ids = ["sv1-ener-2"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage",
		"args": {
			"formula_ast": {
				"op": "energy_count",
				"scope": "sideboard",
				"energy_type": "Fire",
			},
		},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062203))
	_check(
		not step.success and step.error_code == "invalid_formula_ast",
		"Native formula_ast accepted an unknown energy_count scope",
	)
	_check(state.players[1].active.damage_counters == 0,
		"Invalid formula_ast mutated damage before failing")

	state = _effect_state()
	stack = ResolutionStack.new()
	stack.push_effect({"op": "apply_status", "args": {"status": "asleep"}, "branches": {}}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260623))
	_check(step.success, "Native apply_status command spec failed: %s" % step.message)
	_check("ASLEEP" in state.players[1].active.status_conditions, "Native apply_status did not apply status")

	state = _effect_state()
	state.players[0].hand = []
	state.players[0].deck = ["sv1-ener-2", "sv1-ener-2"]
	stack = ResolutionStack.new()
	stack.push_effect({"op": "draw_until", "args": {"target_hand_size": 2}, "branches": {}}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260624))
	_check(step.success, "Native draw_until command spec failed: %s" % step.message)
	_check(state.players[0].hand.size() == 2, "Native draw_until did not draw to target hand size")

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-1"]
	state.players[1].hand = ["sv1-ener-2", "sv1-ener-3", "sv1-ener-4"]
	state.players[0].deck = ["sv1-ener-5", "sv1-ener-6", "sv1-ener-7"]
	stack = ResolutionStack.new()
	stack.push_effect({"op": "draw_until_more_than_opponent", "args": {}, "branches": {}}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606241))
	_check(step.success, "Native draw_until_more_than_opponent command spec failed: %s" % step.message)
	_check(state.players[0].hand.size() == 4,
		"Native draw_until_more_than_opponent did not draw above opponent hand size")

	state = _effect_state()
	stack = ResolutionStack.new()
	stack.push_effect({"op": "heal_all", "args": {"amount": 20}, "branches": {}}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260625))
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606251))
	_check(step.success and step.pending_choice != null,
		"Native choose_heal_damage command spec did not pause for choice")
	var heal_option := _choice_id_for_slot(step.pending_choice, "bench_0")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	state.turn_fact_book["previous_turn"] = {"knockouts": [{
		"defeated_player": 0,
		"source_player": 1,
		"source_kind": "attack_damage",
		"cause_kind": "damage",
	}]}
	stack = ResolutionStack.new()
	stack.context["finish_attack"] = true
	stack.push_effect({
		"op": "conditional_status",
		"args": {
			"status": "paralyzed",
			"condition": "ko_by_attack_damage_last_turn",
		},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260626))
	_check(step.success, "Native conditional_status command spec failed: %s" % step.message)
	_check("PARALYZED" in state.players[1].active.status_conditions, "Native conditional_status did not apply status")

	# Lapras explicitly requires damage from an attack. A direct Knock Out is an
	# attack effect, so the generic history remains true while this strict query
	# and the conditional status both remain false.
	state = _effect_state()
	state.players[1].active.status_conditions.clear()
	state.turn_fact_book["previous_turn"] = {"knockouts": [{
		"defeated_player": 0,
		"source_player": 1,
		"source_kind": "attack_effect",
		"cause_kind": "direct_knockout",
	}]}
	stack = ResolutionStack.new()
	stack.context["finish_attack"] = true
	stack.push_effect({
		"op": "conditional_status",
		"args": {
			"status": "paralyzed",
			"condition": "ko_by_attack_damage_last_turn",
		},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026071618))
	_check(
		step.success
		and state.had_knockout_last_turn(0)
		and not state.had_attack_knockout_last_turn(0)
		and "PARALYZED" not in state.players[1].active.status_conditions,
		"Lapras treated a direct attack-effect Knock Out as attack damage",
	)
	state.turn_fact_book["previous_turn"] = {"knockouts": [{
		"defeated_player": 0,
		"source_player": 1,
		"source_kind": "attack_damage",
		"cause_kind": "direct_knockout",
	}]}
	_check(
		state.had_knockout_last_turn(0)
		and not state.had_attack_knockout_last_turn(0),
		"Attack-damage history query ignored its strict cause_kind=damage contract",
	)

	state = _effect_state()
	state.turn_number = 7
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "apply_dazzling_beam",
		"args": {"target": "opponent_active"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606261))
	_check(step.success, "Native apply_dazzling_beam command spec failed: %s" % step.message)
	_check(state.players[1].active.has_attack_gate("dazzled"),
		"Native dazzling_beam did not register a gate modifier")

	state.players[1].active.consume_modifier_operation("attack_gate_coin", "dazzled")
	_set_test_prevention(state, 1, false, true)
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "apply_dazzling_beam",
		"args": {"target": "opponent_active"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606262))
	_check(step.success, "Native non-attack dazzling_beam branch failed: %s" % step.message)
	_check(state.players[1].active.has_attack_gate("dazzled"),
		"Effect immunity incorrectly blocked a non-attack dazzling_beam source")
	_check(state.players[1].active.prevents_effects(),
		"Non-attack dazzling_beam consumed effect immunity")

	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "apply_attack_lock_basic",
		"args": {"target": "opponent_active"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606263))
	_check(step.success, "Native apply_attack_lock_basic command spec failed: %s" % step.message)
	_check(state.players[1].active.attack_is_locked(),
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606264))
	_check(step.success, "Native apply_outgoing_damage_reduction command spec failed: %s" % step.message)
	_check(state.players[1].active.has_modifier_operation("damage_delta"),
		"Native apply_outgoing_damage_reduction did not register a damage modifier")

	state = _effect_state()
	_set_test_prevention(state, 1, false, true)
	stack = ResolutionStack.new()
	stack.context = {"finish_attack": true, "actor": 0}
	stack.push_effects([
		{"op": "apply_status", "args": {"status": "asleep"}, "branches": {}},
		{
			"op": "apply_dazzling_beam",
			"args": {"target": "opponent_active"},
			"branches": {},
		},
		{
			"op": "apply_attack_lock_basic",
			"args": {"target": "opponent_active"},
			"branches": {},
		},
		{
			"op": "apply_outgoing_damage_reduction",
			"args": {"target": "opponent_active", "amount": 50},
			"branches": {},
		},
	], 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062641))
	_check(step.success, "Attack effect immunity sequence failed: %s" % step.message)
	_check(
		state.players[1].active.status_conditions.is_empty()
		and not state.players[1].active.has_attack_gate("dazzled")
		and not state.players[1].active.attack_is_locked()
		and not state.players[1].active.has_modifier_operation("damage_delta"),
		"Effect immunity did not block every effect from the same attack",
	)
	_check(
		state.players[1].active.prevents_effects(),
		"Attack effects consumed effect immunity before its turn boundary",
	)
	var effect_only_damage_events: Array[Dictionary] = []
	var effect_only_damage_result := VMCombatDamage.new().deal_damage(
		state,
		1,
		"active",
		20,
		effect_only_damage_events,
		true,
		stack,
		0,
	)
	_check(
		bool(effect_only_damage_result.get("success", false))
		and state.players[1].active.damage_counters == 3
		and state.players[1].active.prevents_effects(),
		"Effect-only immunity incorrectly blocked attack damage",
	)
	stack = ResolutionStack.new()
	stack.context = {"finish_attack": true, "actor": 0}
	stack.push_effect({
		"op": "switch_pokemon",
		"args": {"target": "opponent", "you_choose": true},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260626411))
	_check(
		step.success and step.pending_choice == null
		and state.players[1].active.prevents_effects(),
		"Attack switch effect bypassed or consumed persistent effect immunity",
	)
	stack = ResolutionStack.new()
	stack.context = {"finish_attack": true, "actor": 0}
	stack.push_effect({
		"op": "discard_energy",
		"args": {"from": "opponent", "amount": 1},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260626412))
	_check(
		step.success and step.pending_choice == null
		and state.players[1].active.energy_card_ids == ["sv1-ener-5"]
		and state.players[1].active.prevents_effects(),
		"Attack energy-discard effect bypassed or consumed persistent effect immunity",
	)

	state = _effect_state()
	_set_test_prevention(state, 1)
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "deal_damage",
		"args": {"amount": 20},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062642))
	_check(step.success, "Non-attack damage source failed: %s" % step.message)
	_check(
		state.players[1].active.damage_counters == 3
		and state.players[1].active.prevents_damage()
		and state.players[1].active.prevents_effects(),
		"Attack protection incorrectly blocked or consumed a Trainer/Ability damage source",
	)
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "discard_energy",
		"args": {"from": "opponent", "amount": 1},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260626421))
	_check(
		step.success
		and state.players[1].active.energy_card_ids.is_empty()
		and state.players[1].active.prevents_effects(),
		"Effect immunity incorrectly blocked or consumed a non-attack energy discard",
	)

	var protected_availability := VMAvailability.new(engine.catalog)
	state.players[1].bench[0] = PokemonState.new("sv2-delib")
	state.players[1].active.energy_card_ids = ["sv1-ener-4"]
	_check(
		protected_availability.effects_have_legal_target(
			state,
			0,
			[{
				"op": "apply_status",
				"args": {"status": "asleep", "target": "opponent_active"},
				"branches": {},
			}],
		)
		and protected_availability.effects_have_legal_target(
			state,
			0,
			[{
				"op": "switch_pokemon",
				"args": {"target": "opponent"},
				"branches": {},
			}],
		)
		and protected_availability.effects_have_legal_target(
			state,
			0,
			[{
				"op": "discard_energy",
				"args": {"from": "opponent", "amount": 1},
				"branches": {},
			}],
		),
		"Effect immunity incorrectly removed legal Trainer/Ability or attack targets",
	)

	state.turn_number = 7
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "apply_self_attack_lock",
		"args": {"attack_name": "漆黑之刃"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606265))
	_check(step.success, "Native apply_self_attack_lock command spec failed: %s" % step.message)
	_check(state.players[0].active.has_modifier_operation("attack_lock", "漆黑之刃"),
		"Native self_attack_lock did not store a strict attack lock")

	state = _battle_state()
	state.turn_number = 7
	state.phase = "MAIN"
	state.players[0].active = PokemonState.new("svd-darkrai")
	state.players[0].active.placed_this_turn = false
	state.players[1].active = PokemonState.new("sv2-delib")
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "apply_self_attack_lock",
		"args": {"attack_name": "漆黑之刃", "scope": "all"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062650))
	_check(step.success, "Native scope=all self_attack_lock failed: %s" % step.message)
	_check(
		state.players[0].active.has_modifier_operation("attack_lock", "任意招式"),
		"Native scope=all self_attack_lock did not store all-attack modifier",
	)
	var first_attack_check: String = RulesTestHarness.validator_for(engine).can_attack(state, 0, 0)
	var second_attack_check: String = RulesTestHarness.validator_for(engine).can_attack(state, 0, 1)
	_check(
		not first_attack_check.is_empty()
		and not second_attack_check.is_empty(),
		"Native scope=all self_attack_lock did not block every attack",
	)

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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062651))
	_check(step.success, "Native register_aura_damage_reduction failed: %s" % step.message)
	step = _apply_test_action(engine,
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062653))
	_check(step.success, "Native register_aura_damage_boost failed: %s" % step.message)
	step = _apply_test_action(engine,
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
	state.players[1].active = PokemonState.new("svi-maus")
	state.players[1].active.placed_this_turn = false
	state.players[1].bench[0] = PokemonState.new("svi-maus")
	state.players[1].bench[0].placed_this_turn = false
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "register_reactive_thorns",
		"args": {
			"filter_names": ["一对鼠", "一家鼠ex", "一家鼠"],
			"per_pokemon": 3,
		},
		"branches": {},
	}, 1, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062655))
	_check(step.success, "Native register_reactive_thorns failed: %s" % step.message)
	_check(
		state.players[1].active.modifiers.is_empty(),
		"Reactive TriggerDescriptor leaked into the continuous Modifier registry",
	)
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(2026062656),
	)
	_check(step.success, "Native reactive_thorns attack failed: %s" % step.message)
	_check(
		state.players[0].active != null and state.players[0].active.damage_counters == 6,
		"Native reactive_thorns trigger did not place counters on attacker; counters=%s" % [
			str(state.players[0].active.damage_counters if state.players[0].active else -1)
		],
	)
	var reactive_event_has_source := false
	for event in step.events:
		if (
			str(event.get("event_type", "")) == "damage_counters_placed"
			and str(event.get("data", {}).get("source", "")) == "reactive_thorns"
		):
			reactive_event_has_source = true
			break
	_check(reactive_event_has_source, "Native reactive_thorns did not resolve via trigger command event")

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv1-104")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-5"])
	state.players[1].active = PokemonState.new("sv2-delib")
	state.players[1].active.placed_this_turn = false
	_set_energy_cards(state.players[1].active, ["svi-mirc"])
	state.players[1].deck = ["sv1-ener-3", "sv1-ener-4"]
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(20260626561),
	)
	_check(step.success, "Native miracle energy trigger attack failed: %s" % step.message)
	var miracle_event_has_source := false
	for event in step.events:
		if (
			str(event.get("event_type", "")) == "cards_drawn"
			and str(event.get("data", {}).get("source", "")) == "svi-mirc"
		):
			miracle_event_has_source = true
			break
	_check(miracle_event_has_source, "Native miracle energy did not resolve via trigger command event")

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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062657))
	_check(step.success, "Native register_conditional_zero_retreat failed: %s" % step.message)
	_check(
		VMRetreatModifierHooks.effective_retreat_cost(state, engine.catalog, state.players[0]) == 0
		and RulesTestHarness.validator_for(engine).effective_retreat_cost(state, state.players[0]) == 0,
		"Native conditional_zero_retreat modifier did not set retreat cost to zero through CAN_RETREAT hooks",
	)

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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062658))
	_check(step.success, "Native register_conditional_hp_boost failed: %s" % step.message)
	_check(
		state.players[0].active.current_hp(engine.catalog) == 150
		and VMPokemonStatHooks.current_hp(state.players[0].active, engine.catalog) == 150,
		"Native conditional_hp_boost modifier did not increase HP through MAX_HP hooks",
	)
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062659))
	_check(step.success, "Native register_tool_modifier failed: %s" % step.message)
	step = _apply_test_action(engine,
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
	state.players[0].bench[0].attached_tool_id = "svg2-exps"
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "register_tool_exp_share",
		"args": {},
		"branches": {},
	}, 0, "bench_0")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026062661))
	_check(step.success, "Native register_tool_exp_share failed: %s" % step.message)
	var ko_events: Array[Dictionary] = []
	var ko_result := RulesTestHarness.knockout_settlement_for(engine).resolve_knockouts(
		state, 1, ko_events, true)
	var exp_share_confirm: ChoiceRequest = ko_result.get("pending_choice", null)
	_check(
		exp_share_confirm != null
		and exp_share_confirm.request_type == "confirm_trigger"
		and state.players[0].active != null,
		"Native tool_exp_share did not pause before KO discard for confirmation",
	)
	var restored_exp_share := GameState.from_snapshot(state.snapshot())
	_check(
		ResolutionStack.from_dict(restored_exp_share.resolution_stack).pending_request != null,
		"Native tool_exp_share KO trigger queue did not survive Snapshot 3",
	)
	if exp_share_confirm != null:
		step = RulesTestHarness.apply_choice(engine,
			state,
			exp_share_confirm,
			ChoiceResponse.new(exp_share_confirm.request_id, [
				str(exp_share_confirm.options[0]["option_id"]),
			]),
			PortableRandomSource.new(2026062662),
		)
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.request_type == "select_attachment",
		"Native tool_exp_share did not request an indexed Basic Energy",
	)
	var exp_share_energy_request := step.pending_choice
	if exp_share_energy_request != null:
		step = RulesTestHarness.apply_choice(engine,
			state,
			exp_share_energy_request,
			ChoiceResponse.new(exp_share_energy_request.request_id, [
				str(exp_share_energy_request.options[0]["option_id"]),
			]),
			PortableRandomSource.new(2026062663),
		)
	ko_events.append_array(step.events)
	_check(
		state.players[0].active == null
		and state.players[0].bench[0].energy_card_ids == ["sv1-ener-2"]
		and "sv1-ener-2" not in state.players[0].discard,
		"Native tool_exp_share modifier did not move basic energy before KO discard",
	)
	var exp_share_event_has_source := false
	for event in ko_events:
		if (
			str(event.get("event_type", "")) == "energy_attached"
			and str(event.get("data", {}).get("source", "")) == "exp_share"
		):
			exp_share_event_has_source = true
			break
	_check(exp_share_event_has_source, "Native tool_exp_share did not resolve via trigger command event")

	# A direct Knock Out performed inside an attack is an attack effect, not
	# attack damage. It must neither open Learning Device nor set the legacy
	# damage-KO fact used by older card predicates.
	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.damage_counters = 99
	_set_energy_cards(state.players[0].active, ["sv1-ener-2"])
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[0].attached_tool_id = "svg2-exps"
	var direct_ko_events: Array[Dictionary] = []
	var direct_ko_stack := ResolutionStack.new()
	direct_ko_stack.context["knockout_causes"] = {
		"0:active": {
			"source_kind": "attack_effect",
			"cause_kind": "direct_knockout",
			"source_player": 1,
		},
	}
	var direct_ko_result := RulesTestHarness.knockout_settlement_for(engine).resolve_knockouts(
		state, 1, direct_ko_events, true, direct_ko_stack)
	var direct_ko_pending: ChoiceRequest = direct_ko_result.get("pending_choice", null)
	var direct_ko_facts: Array = state.turn_fact_book.get(
		"current_turn", {}).get("knockouts", [])
	var direct_ko_fact: Dictionary = (
		direct_ko_facts[0] if not direct_ko_facts.is_empty() else {})
	_check(
		direct_ko_result.get("success", false)
		and direct_ko_pending != null
		and direct_ko_pending.request_type == "select_prize"
		and state.players[0].active == null
		and state.players[0].bench[0].energy_card_ids.is_empty()
		and "sv1-ener-2" in state.players[0].discard
		and not state.players[0].was_ko_by_attack
		and str(direct_ko_fact.get("source_kind", "")) == "attack_effect"
		and str(direct_ko_fact.get("cause_kind", "")) == "direct_knockout",
		"Direct attack-effect KO incorrectly triggered Learning Device or attack-damage facts",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.damage_counters = 99
	state.players[0].active.energy_card_ids = ["sv1-ener-2", "sv1-ener-5"]
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[1] = PokemonState.new("sv2-delib")
	state.players[0].bench[0].attached_tool_id = "svg2-exps"
	state.players[0].bench[1].attached_tool_id = "svg2-exps"
	var multi_exp_events: Array[Dictionary] = []
	ko_result = RulesTestHarness.knockout_settlement_for(engine).resolve_knockouts(
		state, 1, multi_exp_events, true)
	var order_request: ChoiceRequest = ko_result.get("pending_choice", null)
	_check(
		order_request != null and order_request.request_type == "choose_trigger_order",
		"Multiple Learning Devices did not request a serializable trigger order",
	)
	var bench_one_trigger_id := ""
	for option in order_request.options:
		if "bench_1" in str(option.get("option_id", "")):
			bench_one_trigger_id = str(option["option_id"])
			break
	step = RulesTestHarness.apply_choice(engine,
		state,
		order_request,
		ChoiceResponse.new(order_request.request_id, [bench_one_trigger_id]),
		PortableRandomSource.new(2026062664),
	)
	var first_confirm := step.pending_choice
	step = RulesTestHarness.apply_choice(engine,
		state,
		first_confirm,
		ChoiceResponse.new(first_confirm.request_id, [
			str(first_confirm.options[0]["option_id"]),
		]),
		PortableRandomSource.new(2026062665),
	)
	var indexed_energy_request := step.pending_choice
	var second_energy_id := str(indexed_energy_request.options[1]["option_id"])
	step = RulesTestHarness.apply_choice(engine,
		state,
		indexed_energy_request,
		ChoiceResponse.new(indexed_energy_request.request_id, [second_energy_id]),
		PortableRandomSource.new(2026062666),
	)
	var second_confirm := step.pending_choice
	_check(
		second_confirm != null and second_confirm.request_type == "confirm_trigger",
		"Learning Device queue did not advance to the second entity",
	)
	step = RulesTestHarness.apply_choice(engine,
		state,
		second_confirm,
		ChoiceResponse.new(second_confirm.request_id, [], true),
		PortableRandomSource.new(2026062667),
	)
	_check(
		state.players[0].active == null
		and state.players[0].bench[0].energy_card_ids.is_empty()
		and state.players[0].bench[1].energy_card_ids == ["sv1-ener-5"]
		and step.pending_choice != null
		and step.pending_choice.request_type == "select_prize",
		"Learning Device order/decline/indexed-energy semantics were not preserved",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-2"])
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[0].attached_tool_id = "svg2-exps"
	var ko_trigger_candidates: Array[Dictionary] = []
	RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands.collect_pokemon_ko_triggers(
		state,
		0,
		"active",
		state.players[0].active,
		true,
		1,
		ko_trigger_candidates,
	)
	var ko_trigger_command: Dictionary = (
		ko_trigger_candidates[0].get("commands", [])[0]
		if ko_trigger_candidates.size() == 1
		and ko_trigger_candidates[0].get("commands", []).size() == 1
		else {}
	)
	_check(
		ko_trigger_candidates.size() == 1
		and bool(ko_trigger_candidates[0].get("optional", false))
		and str(ko_trigger_candidates[0].get("hook", "")) == VMModifierManager.POKEMON_KO
		and str(ko_trigger_command.get("op", "")) == "trigger_move_basic_energy"
		and str(ko_trigger_command.get("args", {}).get("to_slot", "")) == "bench_0"
		and RulesTestHarness.effect_engine_for(engine).supports_command_spec(ko_trigger_command),
		"Native POKEMON_KO hook did not produce a schedulable Exp Share trigger",
	)
	var non_attack_ko_candidates: Array[Dictionary] = []
	RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands.collect_pokemon_ko_triggers(
		state,
		0,
		"active",
		state.players[0].active,
		false,
		1,
		non_attack_ko_candidates,
	)
	_check(non_attack_ko_candidates.is_empty(), "Native POKEMON_KO hook fired outside attack KO")

	# Learning Device is authored for an Active Pokemon KO only.  A spread
	# attack may Knock Out the Active and a Benched Pokemon in the same batch;
	# the Bench KO must not enqueue the same Tool trigger a second time.
	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.damage_counters = 99
	_set_energy_cards(state.players[0].active, ["sv1-ener-2"])
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[0].damage_counters = 99
	_set_energy_cards(state.players[0].bench[0], ["sv1-ener-5"])
	state.players[0].bench[1] = PokemonState.new("sv2-delib")
	state.players[0].bench[1].attached_tool_id = "svg2-exps"
	var simultaneous_exp_share_stack := ResolutionStack.new()
	simultaneous_exp_share_stack.context["knockout_causes"] = {
		"0:active": {
			"source_kind": "attack_damage",
			"cause_kind": "damage",
			"source_player": 1,
		},
		"0:bench_0": {
			"source_kind": "attack_damage",
			"cause_kind": "damage",
			"source_player": 1,
		},
	}
	var simultaneous_exp_share_events: Array[Dictionary] = []
	var simultaneous_exp_share_result := (
		RulesTestHarness.knockout_settlement_for(engine).resolve_knockouts(
			state,
			1,
			simultaneous_exp_share_events,
			true,
			simultaneous_exp_share_stack,
			PortableRandomSource.new(2026062668),
		)
	)
	var simultaneous_exp_share_choice: ChoiceRequest = simultaneous_exp_share_result.get(
		"pending_choice", null)
	_check(
		bool(simultaneous_exp_share_result.get("success", false))
		and simultaneous_exp_share_choice != null
		and simultaneous_exp_share_choice.request_type == "confirm_trigger"
		and simultaneous_exp_share_choice.options.size() == 1,
		"Active/Bench simultaneous KOs duplicated the Learning Device trigger: %s"
		% str(simultaneous_exp_share_result.get("message", "")),
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260627))
	_check(step.success and step.pending_choice != null, "Native flip_coin command spec did not pause for choice")
	var coin_stack := ResolutionStack.from_dict(state.resolution_stack)
	var coin_frame := Dictionary(coin_stack.frames[coin_stack.frames.size() - 1])
	var coin_data := Dictionary(coin_frame.get("data", {}))
	_check(
		str(coin_data.get("coin_kind", "")) == "branch"
		and not coin_data.has("effect_type"),
		"Native flip_coin continuation must store coin_kind instead of effect_type",
	)
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260629))
	_check(step.success and step.pending_choice != null,
		"Native switch_pokemon command spec did not pause for choice")
	var switch_option := _choice_id_for_slot(step.pending_choice, "bench_1")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606301))
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606302))
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
	state.players[0].discard = ["sv1-104", "sv1-ener-1", "svi-mirc", "svf-potion"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "shuffle_from_discard_to_deck",
		"args": {"filter": "pokemon_and_energy", "count": 3},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606303))
	_check(step.success and step.pending_choice != null,
		"Native recover_from_discard shuffle path did not pause for choice")
	_check(
		step.pending_choice != null
		and step.pending_choice.min_select == 1
		and step.pending_choice.max_select == 2
		and step.pending_choice.can_cancel
		and step.pending_choice.options.size() == 2,
		"Native recover_from_discard must require one selectable Pokemon/basic Energy and be cancellable",
	)
	var recover_shuffle_options: Array[String] = [
		str(step.pending_choice.options[0]["option_id"]),
		str(step.pending_choice.options[1]["option_id"]),
	]
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, recover_shuffle_options),
		PortableRandomSource.new(202606304),
	)
	_check(step.success, "Native recover_from_discard shuffle path failed: %s" % step.message)
	var recovered_deck := state.players[0].deck.duplicate()
	recovered_deck.sort()
	var recovery_moved_event := false
	for event in step.events:
		var event_source: Dictionary = event.get("source", {})
		var event_target: Dictionary = event.get("target", {})
		var event_data: Dictionary = event.get("data", {})
		if (
			str(event.get("event_type", "")) == "card_moved"
			and str(event_source.get("zone", "")) == "discard"
			and str(event_target.get("zone", "")) == "deck"
			and Array(event_data.get("card_ids", [])).size() == 2
		):
			recovery_moved_event = true
	_check(
		state.players[0].discard == ["svi-mirc", "svf-potion"]
		and recovered_deck == ["sv1-104", "sv1-ener-1", "sv1-ener-2"],
		"Native recover_from_discard did not shuffle selected discard cards into deck",
	)
	_check(recovery_moved_event, "Native recover_from_discard did not emit discard-to-deck card_moved event")
	_check(
		not state.action_log.is_empty()
		and state.action_log[-1].find("2张卡从弃牌区洗回牌库") >= 0,
		"Native recover_from_discard did not write an action log entry",
	)

	state = _effect_state()
	state.players[0].deck = ["sv1-ener-2"]
	state.players[0].discard = ["sv1-104", "sv1-ener-1"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "shuffle_from_discard_to_deck",
		"args": {"filter": "pokemon_and_energy", "count": 2},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606314))
	_check(step.success and step.pending_choice != null,
		"Native recover_from_discard empty-choice fixture did not pause")
	if step.pending_choice:
		var empty_recover := RulesTestHarness.effect_engine_for(engine).apply_choice(
			state,
			ResolutionStack.from_dict(state.resolution_stack),
			ChoiceResponse.new(step.pending_choice.request_id, []),
			PortableRandomSource.new(202606315),
		)
		_check(
			not empty_recover.success and empty_recover.error_code == "choice_count",
			"Native recover_from_discard allowed an empty non-cancel choice",
		)

	var super_rod_cancel_state := _battle_state()
	super_rod_cancel_state.turn_number = 3
	super_rod_cancel_state.first_player_idx = 0
	super_rod_cancel_state.players[0].hand = ["sv3-134"]
	super_rod_cancel_state.players[0].discard = ["sv1-104", "sv1-ener-1"]
	super_rod_cancel_state.players[0].deck = ["sv1-ener-2"]
	super_rod_cancel_state.action_log = ["preexisting log"]
	var super_rod_cancel_snapshot := super_rod_cancel_state.snapshot()
	var super_rod_cancel_rng := PortableRandomSource.new(202606316)
	var super_rod_cancel_rng_state := super_rod_cancel_rng.get_state()
	var super_rod_cancel_step := _apply_test_action(engine,
		super_rod_cancel_state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		super_rod_cancel_rng,
	)
	_check(
		super_rod_cancel_step.success
		and super_rod_cancel_step.pending_choice != null
		and super_rod_cancel_step.pending_choice.can_cancel,
		"Super Rod did not produce a cancellable discard recovery request",
	)
	if super_rod_cancel_step.pending_choice:
		var cancelled_super_rod := RulesTestHarness.apply_choice(engine,
			super_rod_cancel_state,
			super_rod_cancel_step.pending_choice,
			ChoiceResponse.new(super_rod_cancel_step.pending_choice.request_id, [], true),
			super_rod_cancel_rng,
		)
		var expected_super_rod_cancel := super_rod_cancel_snapshot.duplicate(true)
		expected_super_rod_cancel["revision"] = int(expected_super_rod_cancel["revision"]) + 2
		_check(cancelled_super_rod.success, "Super Rod cancellation failed: %s" % cancelled_super_rod.message)
		_check(
			super_rod_cancel_state.snapshot() == expected_super_rod_cancel
			and super_rod_cancel_rng.get_state() == super_rod_cancel_rng_state,
			"Super Rod cancellation did not restore pre-action state and RNG",
		)

	state = _effect_state()
	state.players[0].deck = ["sv1-ener-2"]
	state.players[0].discard = ["sv1-104", "sv1-ener-1", "svi-mirc", "sv1-ener-3"]
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "shuffle_from_discard_to_deck",
		"args": {"filter": "basic_energy", "count": 5},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606317))
	_check(
		step.success
		and step.pending_choice != null
		and step.pending_choice.min_select == 1
		and step.pending_choice.max_select == 2
		and step.pending_choice.options.size() == 2,
		"Energy Recycler must expose only basic Energy and require one selection",
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606305))
	_check(step.success and step.pending_choice != null,
		"Native recover_from_discard clara path did not pause for choice")
	var clara_options: Array[String] = [
		str(step.pending_choice.options[0]["option_id"]),
		str(step.pending_choice.options[1]["option_id"]),
	]
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606307))
	_check(step.success and step.pending_choice != null,
		"Native hand_to_bottom_then_draw did not pause for choice")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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

	# Caitlin's selected cards have a player-defined bottom-deck order. Indexed
	# entities must keep that order even for same-ID copies and after a snapshot
	# pause; sorting source indices is only a mutation detail, not the decision.
	state = _effect_state()
	state.players[0].hand = [
		"sv1-ener-1",
		"sv1-ener-2",
		"sv1-ener-1",
		"sv1-ener-3",
		"sv1-ener-1",
	]
	state.players[0].deck = [
		"sv1-ener-4", "sv1-ener-5", "sv1-ener-6", "sv1-ener-7"]
	stack = ResolutionStack.new()
	stack.push_effect(
		{"op": "hand_to_bottom_then_draw", "args": {}, "branches": {}},
		0,
		"active",
	)
	step = RulesTestHarness.effect_engine_for(engine).resolve(
		state, stack, PortableRandomSource.new(2026071616))
	var caitlin_pause_snapshot := state.snapshot()
	var caitlin_restored_state := GameState.from_snapshot(caitlin_pause_snapshot)
	var caitlin_restored_stack := ResolutionStack.from_dict(
		caitlin_restored_state.resolution_stack)
	var caitlin_request := caitlin_restored_stack.pending_request
	var caitlin_option_by_index: Dictionary = {}
	for option in caitlin_request.options:
		caitlin_option_by_index[int(option.get("value", {}).get("index", -1))] = str(
			option.get("option_id", ""))
	var caitlin_order: Array[String] = [
		str(caitlin_option_by_index.get(1, "")),
		str(caitlin_option_by_index.get(4, "")),
		str(caitlin_option_by_index.get(2, "")),
	]
	var caitlin_response := ChoiceResponse.new(caitlin_request.request_id, caitlin_order)
	var caitlin_response_roundtrip := ChoiceResponse.from_dict(caitlin_response.to_dict())
	var caitlin_roundtrip_ok := (
		step.success
		and caitlin_request != null
		and caitlin_restored_state.snapshot() == caitlin_pause_snapshot
		and caitlin_option_by_index.size() == 5
		and caitlin_order[1] != caitlin_order[2]
		and caitlin_response_roundtrip.option_ids == caitlin_order
	)
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		caitlin_restored_state,
		caitlin_restored_stack,
		caitlin_response_roundtrip,
		PortableRandomSource.new(2026071617),
	)
	var caitlin_event_order: Array = []
	for event in step.events:
		if (
			str(event.get("event_type", "")) == "cards_selected"
			and str(event.get("data", {}).get("target_zone", "")) == "deck"
		):
			caitlin_event_order = Array(
				event.get("data", {}).get("card_ids", [])).duplicate()
			break
	_check(
		caitlin_roundtrip_ok
		and step.success
		and caitlin_restored_state.players[0].hand == [
			"sv1-ener-1", "sv1-ener-3", "sv1-ener-7", "sv1-ener-6", "sv1-ener-5"]
		and caitlin_restored_state.players[0].deck == [
			"sv1-ener-2", "sv1-ener-1", "sv1-ener-1", "sv1-ener-4"]
		and caitlin_event_order == ["sv1-ener-2", "sv1-ener-1", "sv1-ener-1"],
		"Caitlin did not preserve indexed duplicate entities and player bottom-deck order",
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606309))
	_check(step.success and step.pending_choice != null,
		"Native zinnia_resolve did not pause for discard choice")
	var zinnia_options: Array[String] = [
		str(step.pending_choice.options[0]["option_id"]),
		str(step.pending_choice.options[1]["option_id"]),
	]
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606311))
	_check(step.success and step.pending_choice != null,
		"Native search_cards deck path did not pause for choice")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(202606312),
	)
	_check(step.success, "Native search_cards deck path failed: %s" % step.message)
	var searched_move_event_index := _first_event_type_index(step.events, "card_moved")
	if searched_move_event_index < 0:
		searched_move_event_index = _first_event_type_index(step.events, "cards_selected")
	_check(
		searched_move_event_index >= 0
		and _first_event_type_index(step.events, "deck_shuffled") > searched_move_event_index,
		"Deck search did not present selected movement before shuffling",
	)
	var search_deck_remaining := state.players[0].deck.duplicate()
	search_deck_remaining.sort()
	_check(
		state.players[0].bench[0] != null
		and state.players[0].bench[0].card_id == "sv1-104"
		and search_deck_remaining == ["sv1-ener-1", "sv1-ener-2"],
		"Native search_cards deck path did not bench selected Pokemon",
	)

	state = _effect_state()
	state.players[0].deck = ["svi-chim", "svi-chim", "sv1-ener-2"]
	for bench_index in range(4):
		state.players[0].bench[bench_index] = PokemonState.new("sv2-delib")
	state.players[0].bench[4] = null
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "search_cards",
		"args": {
			"from_zone": "deck",
			"filter": "basic_pokemon",
			"destination": "bench",
			"count": 2,
			"min_select": 0,
		},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(
		state, stack, PortableRandomSource.new(202606312))
	_check(
		step.success
		and step.pending_choice != null
		and step.pending_choice.max_select == 1
		and step.pending_choice.options.size() == 2,
		"Bench search did not cap duplicate choices to the one open slot",
	)
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(
			step.pending_choice.request_id,
			[str(step.pending_choice.options[1]["option_id"])],
		),
		PortableRandomSource.new(202606313),
	)
	var remaining_chim := state.players[0].deck.count("svi-chim")
	var benched_chim := 0
	for pokemon in state.players[0].bench:
		if pokemon != null and pokemon.card_id == "svi-chim":
			benched_chim += 1
	_check(
		step.success
		and state.players[0].bench[4] != null
		and state.players[0].bench[4].card_id == "svi-chim"
		and remaining_chim == 1
		and remaining_chim + benched_chim == 2,
		"Bench search lost a duplicate card when only one slot was open",
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606313))
	_check(step.success and step.pending_choice != null,
		"Native search_cards discard path did not pause for choice")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606315))
	_check(step.success and step.pending_choice != null,
		"Native search_item_and_tool did not pause for choice")
	var arven_options: Array[String] = [
		str(step.pending_choice.options[0]["option_id"]),
		str(step.pending_choice.options[1]["option_id"]),
	]
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606317))
	_check(step.success and step.pending_choice != null,
		"Native trekking_shoes did not pause for confirm choice")
	_check(
		step.pending_choice.metadata.get("top_card_id", "") == "svf-potion"
		and step.pending_choice.metadata.get("revealed_card_ids", []) == ["svf-potion"],
		"Native trekking_shoes did not expose the revealed top card metadata",
	)
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	_check(
		_first_event_type_index(step.events, "cards_discarded") >= 0
		and _first_event_type_index(step.events, "cards_drawn")
			> _first_event_type_index(step.events, "cards_discarded"),
		"Trekking Shoes did not present deck-to-discard before drawing",
	)

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.context = {"finish_attack": true, "actor": 0, "base_damage": 0}
	stack.push_effect({
		"op": "flip_coin_repeat_damage",
		"args": {"flips": 3, "damage_per_head": 10},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606319))
	_check(step.success and step.pending_choice != null,
		"Native flip_coin_repeat_damage did not create coin request")
	var repeat_results: Array = step.pending_choice.metadata.get("predetermined_flips", [])
	var repeat_heads := 0
	for result in repeat_results:
		if bool(result):
			repeat_heads += 1
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, []),
		PortableRandomSource.new(202606320),
	)
	_check(step.success, "Native flip_coin_repeat_damage failed: %s" % step.message)
	var repeat_stack := ResolutionStack.from_dict(state.resolution_stack)
	_check(int(repeat_stack.context.get("base_damage", -1)) == repeat_heads * 10,
		"Native flip_coin_repeat_damage produced damage inconsistent with flips")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.context = {"finish_attack": true, "actor": 0, "base_damage": 0}
	stack.push_effect({
		"op": "flip_until_tails",
		"args": {"per_head": 20},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606321))
	_check(step.success and step.pending_choice != null,
		"Native flip_until_tails did not create coin request")
	var until_results: Array = step.pending_choice.metadata.get("predetermined_flips", [])
	var until_heads := 0
	for result in until_results:
		if bool(result):
			until_heads += 1
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, []),
		PortableRandomSource.new(202606322),
	)
	_check(step.success, "Native flip_until_tails failed: %s" % step.message)
	var until_stack := ResolutionStack.from_dict(state.resolution_stack)
	_check(int(until_stack.context.get("base_damage", -1)) == until_heads * 20,
		"Native flip_until_tails produced damage inconsistent with flips")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.context = {"finish_attack": true, "actor": 0, "base_damage": 0}
	stack.push_effect({"op": "flip_coin_then_ko", "args": {}, "branches": {}}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606323))
	_check(step.success and step.pending_choice != null,
		"Native flip_coin_then_ko did not create coin request")
	var ko_results: Array = step.pending_choice.metadata.get("predetermined_flips", [])
	var should_ko := ko_results.size() >= 2 and bool(ko_results[0]) and bool(ko_results[1])
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606325))
	_check(step.success and step.pending_choice != null,
		"Native conditional_search did not pause for choice")
	_check(step.pending_choice.min_select == 0 and step.pending_choice.max_select == 2,
		"Native conditional_search did not expose optional second-turn search bounds")
	var conditional_options: Array[String] = []
	for option in step.pending_choice.options:
		conditional_options.append(str(option["option_id"]))
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063261))
	_check(step.success and step.pending_choice != null,
		"Native look_top_deck did not pause for hand choice")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063263))
	_check(step.success and step.pending_choice != null,
		"Native look_top_deck did not pause for bench-energy choice")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063265))
	_check(step.success and step.pending_choice != null,
		"Native look_top_attach_energy did not pause for energy choice")
	var top_energy_ids: Array[String] = []
	for option in step.pending_choice.options:
		top_energy_ids.append(str(option["option_id"]))
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, top_energy_ids),
		PortableRandomSource.new(2026063266),
	)
	_check(step.success and step.pending_choice != null,
		"Native look_top_attach_energy did not continue to target choice")
	_check(
		step.pending_choice != null
		and step.pending_choice.metadata.get("purpose", "") == "look_top_attach_target"
		and step.pending_choice.metadata.get("card_ids", []) == [
			"sv1-ener-2", "sv1-ener-1",
		]
		and int(step.pending_choice.metadata.get("source_player", -1)) == 0
		and step.pending_choice.metadata.get("source_zone", "") == "deck"
		and bool(step.pending_choice.metadata.get("same_source", false))
		and bool(step.pending_choice.metadata.get("same_target", false))
		and int(step.pending_choice.metadata.get("max_per_target", -1)) == 2,
		"look_top_attach_target choice omitted metadata required by network UI",
	)
	var attach_target_id := ""
	for option_value in step.pending_choice.options:
		var option: Dictionary = option_value
		if str(option.get("value", {}).get("slot", "")) == "bench_0":
			attach_target_id = str(option.get("option_id", ""))
			break
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [attach_target_id]),
		PortableRandomSource.new(2026063267),
	)
	_check(step.success, "Native look_top_attach_energy target choice failed: %s" % step.message)
	_check(
		_first_event_type_index(step.events, "energy_attached") >= 0
		and _first_event_type_index(step.events, "deck_shuffled")
			> _first_event_type_index(step.events, "energy_attached"),
		"Look-top attachment shuffled before the selected energy was attached",
	)
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063268))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.min_select == 0
		and step.pending_choice.max_select == 2,
		"Native draw_and_attach_energy did not expose optional energy distribution",
	)
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063270))
	_check(step.success and step.pending_choice != null,
		"Native conditional did not pause for cost choice")
	var discard_ids: Array[String] = []
	for index in range(2):
		discard_ids.append(str(step.pending_choice.options[index]["option_id"]))
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, discard_ids),
		PortableRandomSource.new(2026063271),
	)
	_check(step.success and step.pending_choice != null,
		"Native conditional did not continue to on_pay search")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	state.turn_fact_book["previous_turn"] = {"knockouts": [{
		"defeated_player": 0,
		"source_player": 1,
		"source_kind": "ability",
		"cause_kind": "damage_counters",
	}]}
	state.players[0].deck = ["sv1-ener-1"]
	state.players[0].hand = []
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "conditional",
		"args": {"condition": "ko_last_opponent_turn"},
		"branches": {
			"on_pay": [{
				"op": "draw_cards",
				"args": {"amount": 1},
				"branches": {},
			}],
		},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063273))
	_check(step.success, "Native conditional ko condition failed: %s" % step.message)
	_check(
		state.had_knockout_last_turn(0)
		and not state.had_attack_knockout_last_turn(0)
		and state.players[0].hand == ["sv1-ener-1"],
		"Mela-style generic conditional did not accept a non-attack-damage KO fact",
	)
	var generic_ko_conditional := {
		"op": "conditional",
		"args": {"condition": "ko_last_opponent_turn"},
		"branches": {
			"on_pay": [{
				"op": "draw_cards",
				"args": {"amount": 1},
				"branches": {},
			}],
		},
	}
	var no_ko_state := _effect_state()
	_check(
		RulesTestHarness.availability_for(engine).effects_have_legal_target(
			state, 0, [generic_ko_conditional], "active")
		and not RulesTestHarness.availability_for(engine).effects_have_legal_target(
			no_ko_state, 0, [generic_ko_conditional], "active"),
		"Mela availability did not use generic previous-turn Knock Out history",
	)
	var revenge_formula := {
		"op": "add",
		"terms": [
			{"const": 100},
			{
				"op": "if",
				"condition": "ko_last_opponent_turn",
				"then": {"const": 120},
				"else": {"const": 0},
			},
		],
	}
	var revenge_with_ko := (
		RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.formula.evaluate_formula_ast(
			state, 0, "active", revenge_formula))
	var revenge_without_ko := (
		RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.formula.evaluate_formula_ast(
			no_ko_state, 0, "active", revenge_formula))
	_check(
		bool(revenge_with_ko.get("success", false))
		and int(revenge_with_ko.get("value", 0)) == 220
		and bool(revenge_without_ko.get("success", false))
		and int(revenge_without_ko.get("value", 0)) == 100,
		"Zamazenta revenge formula did not use generic previous-turn Knock Out history",
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063274))
	_check(step.success and step.pending_choice != null,
		"Native hand_to_bottom_draw_until did not pause for hand choice")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063276))
	_check(
		step.success
		and step.pending_choice == null
		and state.players[0].active.energy_card_ids == ["sv1-ener-6"]
		and state.players[0].deck == ["sv1-ener-1"],
		"Mandatory attach_energy with one target must resolve without a redundant choice",
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063278))
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
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063280))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.request_type == "distribute_energy"
		and step.pending_choice.min_select == 0,
		"Native attach_energy bench distribution did not expose optional distribution",
	)
	var bench_distribution_ids: Array[String] = []
	for energy_index in range(2):
		bench_distribution_ids.append(_choice_id_for_slot_and_energy(
			step.pending_choice,
			"bench_%d" % energy_index,
			energy_index,
		))
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063282))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.max_select == 3,
		"Native attach_energy going-second bonus did not expose three attachments",
	)
	var active_attach_ids: Array[String] = []
	for option_value in step.pending_choice.options:
		var option: Dictionary = option_value
		if str(option.get("value", {}).get("slot", "")) == "active":
			active_attach_ids.append(str(option.get("option_id", "")))
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, active_attach_ids),
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063284))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.options.size() == 2
		and step.pending_choice.options.all(func(option: Dictionary) -> bool:
			return str(option.get("value", {}).get("slot", "")) == "bench_0"),
		"Native attach_energy self_basic did not restrict targets to Basic Pokemon",
	)
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [
			str(step.pending_choice.options[0]["option_id"]),
			str(step.pending_choice.options[1]["option_id"]),
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063286))
	_check(step.success and step.pending_choice != null,
		"Native attach_energy_from_discard self did not request target")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063288))
	_check(step.success and step.pending_choice != null,
		"Native attach_energy_from_discard bench did not request target")
	var bench_one_discard_attach := ""
	for option_value in step.pending_choice.options:
		var option: Dictionary = option_value
		if str(option.get("value", {}).get("slot", "")) == "bench_1":
			bench_one_discard_attach = str(option.get("option_id", ""))
			break
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063290))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.request_type == "distribute_energy"
		and step.pending_choice.min_select == 0,
		"Native attach_energy_from_discard distribution did not expose optional distribution",
	)
	var discard_distribution_ids: Array[String] = []
	for energy_index in range(2):
		discard_distribution_ids.append(_choice_id_for_slot_and_energy(
			step.pending_choice,
			"bench_%d" % energy_index,
			energy_index,
		))
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063292))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.options.size() == 1
		and str(step.pending_choice.options[0].get("value", {}).get("slot", "")) == "bench_0",
		"Native attach_energy_from_discard did not filter Darkness targets",
	)
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063294))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.request_type == "select_attachment"
		and step.pending_choice.metadata.get("source_slot", "") == "active",
		"Native relocate_energy from_self did not request an exact attachment",
	)
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[1]["option_id"])]),
		PortableRandomSource.new(2026063295),
	)
	_check(step.success and step.pending_choice != null,
		"Native relocate_energy exact attachment did not continue to target")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(20260632951),
	)
	_check(step.success, "Native relocate_energy from_self target failed: %s" % step.message)
	_check(
		state.players[0].active.energy_card_ids == ["sv1-ener-1"]
		and state.players[0].bench[0].energy_card_ids == ["sv1-ener-2"],
		"Native relocate_energy did not move the selected non-first energy",
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063296))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.request_type == "distribute_energy"
		and step.pending_choice.min_select == 2,
		"Native relocate_energy from_self distribution did not request all energies",
	)
	var relocate_distribution_ids: Array[String] = []
	for option in step.pending_choice.options:
		relocate_distribution_ids.append(str(option["option_id"]))
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063298))
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
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [active_relocate_source]),
		PortableRandomSource.new(2026063299),
	)
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.request_type == "select_attachment"
		and step.pending_choice.min_select == 0
		and step.pending_choice.max_select == 2,
		"Native relocate_energy source choice did not continue to exact 0-2 attachments",
	)
	var poppy_zero_state := GameState.from_dict(state.snapshot())
	var poppy_zero_request := ResolutionStack.from_dict(
		poppy_zero_state.resolution_stack).pending_request
	var poppy_zero_step := RulesTestHarness.apply_choice(engine,
		poppy_zero_state,
		poppy_zero_request,
		ChoiceResponse.new(poppy_zero_request.request_id, []),
		PortableRandomSource.new(20260632981),
	)
	_check(
		poppy_zero_step.success and poppy_zero_step.pending_choice == null
		and poppy_zero_state.players[0].active.energy_card_ids
		== ["sv1-ener-1", "sv1-ener-2"]
		and poppy_zero_state.players[0].bench[0].energy_card_ids == ["sv1-ener-3"]
		and poppy_zero_state.players[0].bench[1].energy_card_ids.is_empty(),
		"Optional same-source energy relocation did not support selecting zero",
	)
	var poppy_one_state := GameState.from_dict(state.snapshot())
	var poppy_one_request := ResolutionStack.from_dict(
		poppy_one_state.resolution_stack).pending_request
	var poppy_one_step := RulesTestHarness.apply_choice(engine,
		poppy_one_state,
		poppy_one_request,
		ChoiceResponse.new(poppy_one_request.request_id, [
			str(poppy_one_request.options[1].get("option_id", "")),
		]),
		PortableRandomSource.new(20260632982),
	)
	var poppy_one_target := (
		_choice_id_for_slot(poppy_one_step.pending_choice, "bench_1")
		if poppy_one_step.pending_choice != null
		else ""
	)
	if poppy_one_step.pending_choice:
		poppy_one_step = RulesTestHarness.apply_choice(engine,
			poppy_one_state,
			poppy_one_step.pending_choice,
			ChoiceResponse.new(poppy_one_step.pending_choice.request_id, [poppy_one_target]),
			PortableRandomSource.new(20260632983),
		)
	_check(
		poppy_one_step.success
		and poppy_one_state.players[0].active.energy_card_ids == ["sv1-ener-1"]
		and poppy_one_state.players[0].bench[1].energy_card_ids == ["sv1-ener-2"]
		and poppy_one_state.players[0].bench[0].energy_card_ids == ["sv1-ener-3"],
		"Optional same-source energy relocation did not support selecting one",
	)
	var relocate_attachment_ids: Array[String] = []
	for option_value in step.pending_choice.options:
		relocate_attachment_ids.append(str(option_value.get("option_id", "")))
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, relocate_attachment_ids),
		PortableRandomSource.new(20260632991),
	)
	_check(step.success and step.pending_choice != null,
		"Native relocate_energy attachment choice did not continue to targets")
	var bench_one_relocate := ""
	for option_value in step.pending_choice.options:
		var option: Dictionary = option_value
		if str(option.get("value", {}).get("slot", "")) == "bench_1":
			bench_one_relocate = str(option.get("option_id", ""))
			break
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606327))
	_check(step.success and step.pending_choice != null,
		"Native search_any_and_switch did not pause for search choice")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[0]["option_id"])]),
		PortableRandomSource.new(202606328),
	)
	_check(step.success and step.pending_choice != null,
		"Native search_any_and_switch did not continue to switch confirm")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, ["confirm:yes"]),
		PortableRandomSource.new(202606329),
	)
	_check(step.success and step.pending_choice != null,
		"Native search_any_and_switch did not continue to bench selection")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606331))
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
	state.players[0].bench[0] = PokemonState.new("svg2-turt")
	state.players[0].bench[0].placed_this_turn = false
	state.players[0].bench[0].can_evolve_this_turn = true
	state.players[0].hand = ["svg2-tort"]
	stack = ResolutionStack.new()
	stack.push_effect({"op": "evolve_skip_stage", "args": {}, "branches": {}}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063321))
	_check(step.success and step.pending_choice != null,
		"Native evolve_skip_stage did not pause for target choice: %s" % step.message)
	_check(
		step.pending_choice.request_type == "evolve_skip_stage"
		and step.pending_choice.options.size() == 2,
		"Native evolve_skip_stage did not expose candidate evolution pairs",
	)
	var rare_candy_choice_id := ""
	for option in step.pending_choice.options:
		if str(option.get("value", {}).get("slot", "")) == "bench_0":
			rare_candy_choice_id = str(option.get("option_id", ""))
			break
	_check(not rare_candy_choice_id.is_empty(),
		"Native evolve_skip_stage did not include the non-first bench candidate")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [rare_candy_choice_id]),
		PortableRandomSource.new(2026063322),
	)
	_check(step.success, "Native evolve_skip_stage choice failed: %s" % step.message)
	_check(
		state.players[0].active.card_id == "svg2-turt"
		and state.players[0].bench[0].card_id == "svg2-tort"
		and state.players[0].bench[0].evolution_stack_ids == ["svg2-turt"]
		and state.players[0].hand.is_empty()
		and not state.players[0].bench[0].can_evolve_this_turn,
		"Native evolve_skip_stage did not evolve the selected Basic directly to Stage 2",
	)

	state = _effect_state()
	state.players[1].active.energy_card_ids = ["sv1-ener-1"]
	state.players[1].discard = []
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "trainer"
	stack.push_effect({
		"op": "flip_coin_then_discard_energy",
		"args": {},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2))
	_check(step.success and step.pending_choice != null,
		"Native flip_coin_then_discard_energy did not create coin request")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, []),
		PortableRandomSource.new(202606333),
	)
	_check(step.success and step.pending_choice != null,
		"Native flip_coin_then_discard_energy did not continue to attachment choice")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606332))
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260631))
	_check(step.success and step.pending_choice != null,
		"Native discard_cards command spec did not pause for choice")
	var discard_options: Array[String] = [
		str(step.pending_choice.options[0]["option_id"]),
		str(step.pending_choice.options[1]["option_id"]),
	]
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606321))
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606322))
	_check(step.success and step.pending_choice != null,
		"Native discard_then_draw_cards did not pause for discard choice")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260633))
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.request_type == "select_attachment"
		and step.pending_choice.metadata.get("purpose", "") == "discard_energy",
		"Native discard_energy did not request an exact attachment",
	)
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [str(step.pending_choice.options[1]["option_id"])]),
		PortableRandomSource.new(202606331),
	)
	_check(step.success, "Native discard_energy command spec failed: %s" % step.message)
	_check(state.players[0].active.energy_card_ids == ["sv1-ener-5"],
		"Native discard_energy did not preserve the unselected energy")
	_check(state.players[0].discard == ["sv1-ener-6"],
		"Native discard_energy did not discard the selected non-first energy")
	_check(state.players[0].hand == ["sv1-ener-2"],
		"Native discard_energy did not continue remaining command")

	state = _effect_state()
	state.players[0].active.energy_card_ids = [
		"sv1-ener-5", "sv1-ener-5", "sv1-ener-6",
	]
	state.players[0].discard = []
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "discard_energy",
		"args": {"amount": 1, "from": "self", "filter": "any"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063311))
	var duplicate_energy_choice := (
		str(step.pending_choice.options[1].get("option_id", ""))
		if step.pending_choice != null and step.pending_choice.options.size() > 1
		else ""
	)
	_check(
		duplicate_energy_choice.contains(":energy:1:sv1-ener-5"),
		"Duplicate energy attachments did not expose distinct indexed options",
	)
	if step.pending_choice:
		step = RulesTestHarness.apply_choice(engine,
			state,
			step.pending_choice,
			ChoiceResponse.new(step.pending_choice.request_id, [duplicate_energy_choice]),
			PortableRandomSource.new(2026063312),
		)
	var duplicate_discard_event: Dictionary = {}
	for event in step.events:
		if str(event.get("event_type", "")) == "cards_discarded":
			duplicate_discard_event = event
			break
	_check(
		step.success
		and state.players[0].active.energy_card_ids == ["sv1-ener-5", "sv1-ener-6"]
		and duplicate_discard_event.get("data", {}).get("source_indices", []) == [1],
		"Duplicate card ID selection did not discard the exact attachment index",
	)

	state = _effect_state()
	state.players[0].active.energy_card_ids = [
		"sv1-ener-1", "sv1-ener-2", "sv1-ener-3", "sv1-ener-4",
	]
	state.players[0].discard = []
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "discard_energy",
		"args": {"amount": 2, "from": "self", "filter": "any"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063313))
	if step.pending_choice:
		step = RulesTestHarness.apply_choice(engine,
			state,
			step.pending_choice,
			ChoiceResponse.new(step.pending_choice.request_id, [
				str(step.pending_choice.options[1].get("option_id", "")),
				str(step.pending_choice.options[3].get("option_id", "")),
			]),
			PortableRandomSource.new(2026063314),
		)
	_check(
		step.success
		and state.players[0].active.energy_card_ids == ["sv1-ener-1", "sv1-ener-3"]
		and state.players[0].discard == ["sv1-ener-2", "sv1-ener-4"],
		"Multi-attachment discard did not remove original indices in descending order",
	)

	state = _effect_state()
	state.players[0].active.energy_card_ids = [
		"sv1-ener-1", "sv1-ener-2", "sv1-ener-3",
	]
	state.players[0].discard = []
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "discard_energy",
		"args": {"amount": 2, "from": "self", "filter": "any"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063315))
	var stale_request := step.pending_choice
	var stale_energy_choices: Array[String] = []
	if stale_request:
		stale_energy_choices.assign([
			str(stale_request.options[0].get("option_id", "")),
			str(stale_request.options[1].get("option_id", "")),
		])
	state.players[0].active.energy_card_ids[1] = "sv1-ener-4"
	var stale_attachment_snapshot := state.snapshot()
	if stale_request:
		step = RulesTestHarness.apply_choice(engine,
			state,
			stale_request,
			ChoiceResponse.new(stale_request.request_id, stale_energy_choices),
			PortableRandomSource.new(2026063316),
		)
	_check(
		not step.success
		and state.snapshot() == stale_attachment_snapshot,
		"Stale attachment reference did not roll back the full choice transaction",
	)

	state = _effect_state()
	state.players[0].active.energy_card_ids = ["sv1-ener-5", "sv1-ener-6"]
	state.players[0].discard = []
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "discard_energy",
		"args": {"amount": 99, "from": "self", "filter": "any"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063317))
	_check(
		step.success and step.pending_choice == null
		and state.players[0].active.energy_card_ids.is_empty()
		and state.players[0].discard == ["sv1-ener-5", "sv1-ener-6"],
		"Discard-all energy effect requested a redundant attachment choice",
	)

	state.players[1].active.energy_card_ids = ["sv1-ener-3"]
	state.players[1].discard = []
	stack = ResolutionStack.new()
	stack.push_effect({
		"op": "discard_energy",
		"args": {"amount": 1, "from": "opponent", "filter": "any"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260634))
	_check(step.success, "Native opponent discard_energy command spec failed: %s" % step.message)
	_check(state.players[1].active.energy_card_ids.is_empty(),
		"Native discard_energy did not remove opponent energy")
	_check(state.players[1].discard == ["sv1-ener-3"],
		"Native discard_energy did not put opponent energy in owner discard")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3"]
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "deal_damage_per_hand_size",
		"args": {"per": 10},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260635))
	_check(step.success, "Native damage_per_hand_size formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 3,
		"Native damage_per_hand_size formula produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "deal_damage_plus_bench",
		"args": {"base": 10, "per_bench": 20},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260636))
	_check(step.success, "Native damage_plus_bench formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 5,
		"Native damage_plus_bench formula produced wrong damage")

	state = _effect_state()
	state.players[0].active.damage_counters = 2
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "deal_damage_per_self_damage",
		"args": {"base": 60, "per_counter": 10},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260637))
	_check(step.success, "Native damage_per_self_damage formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 8,
		"Native damage_per_self_damage formula produced wrong damage")

	state = _effect_state()
	state.players[0].active.damage_counters = 3
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "deal_damage_with_self_penalty",
		"args": {"base": 200, "per_counter": 20},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260638))
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606379))
	_check(step.success, "Native conditional_damage command spec failed: %s" % step.message)
	var saved_conditional_stack := ResolutionStack.from_dict(state.resolution_stack)
	_check(
		int(saved_conditional_stack.context.get("base_damage", 0)) == 150
		and saved_conditional_stack.context.get("damage_packets", []).is_empty(),
		"Native conditional_damage did not accumulate bonus in attack context")
	_check(state.players[1].active.damage_counters == 1,
		"Native conditional_damage applied damage outside attack context")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.turn_fact_book["previous_turn"] = {"knockouts": [{
		"defeated_player": 0,
		"source_player": 1,
		"source_kind": "attack_damage",
		"cause_kind": "damage",
	}]}
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "conditional_damage",
		"args": {"bonus": 90, "condition": "ko_by_attack_damage_last_turn"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063791))
	_check(step.success, "Native conditional_damage ko condition failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 9,
		"Chi-Yu did not apply its attack-damage Knock Out bonus")
	_check(state.had_attack_knockout_last_turn(0),
		"Native conditional_damage consumed the read-only TurnFactBook entry")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.turn_fact_book["previous_turn"] = {"knockouts": [{
		"defeated_player": 0,
		"source_player": 1,
		"source_kind": "attack_effect",
		"cause_kind": "direct_knockout",
	}]}
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "conditional_damage",
		"args": {"bonus": 90, "condition": "ko_by_attack_damage_last_turn"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(
		state, stack, PortableRandomSource.new(2026071619))
	_check(
		step.success
		and state.players[1].active.damage_counters == 0
		and state.had_knockout_last_turn(0)
		and not state.had_attack_knockout_last_turn(0),
		"Chi-Yu treated a direct attack-effect Knock Out as attack damage",
	)

	state = _effect_state()
	state.players[0].hand = ["sv1-ener-1", "sv1-ener-2", "sv1-ener-3", "sv1-ener-4"]
	state.players[0].discard = []
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "discard_hand_then_damage",
		"args": {"threshold": 5, "base_damage": 60, "bonus": 150},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063792))
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
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "discard_energy_then_damage",
		"args": {"base": 10, "per_energy": 60},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063793))
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
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "mill_then_damage",
		"args": {"mill_count": 3, "damage_per": 40},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063794))
	_check(step.success, "Native mill_then_damage command spec failed: %s" % step.message)
	_check(state.players[0].discard == ["sv1-ener-2", "sv1-ener-1"],
		"Native mill_then_damage did not discard revealed energies")
	_check(state.players[1].active.damage_counters == 8,
		"Native mill_then_damage produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].healed_this_turn = true
	state.players[0].active.healed_this_turn = true
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "conditional_damage_then_heal",
		"args": {"base": 60, "bonus": 90},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063801))
	_check(step.success, "Native conditional_damage_then_heal command spec failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 15,
		"Native conditional_damage_then_heal produced wrong damage")

	state = _effect_state()
	state.players[0].active.damage_counters = 3
	state.players[1].active.damage_counters = 0
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "deal_damage_then_heal",
		"args": {"damage": 10, "heal": 20},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(2026063802))
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
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "deal_damage_per_energy",
		"args": {
			"base": 10,
			"per_energy": 20,
			"count_from": "opponent_active",
		},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606381))
	_check(step.success, "Native damage_per_energy formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 5,
		"Native damage_per_energy formula produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].active.energy_card_ids = ["sv1-ener-2", "sv1-ener-5"]
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "deal_damage_per_self_energy",
		"args": {
			"base": 30,
			"per_energy": 30,
			"energy_filter": "fire",
		},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606382))
	_check(step.success, "Native damage_per_self_energy formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 6,
		"Native damage_per_self_energy formula produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].active.energy_card_ids = ["sv1-ener-1", "sv1-ener-2"]
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "deal_damage_per_self_energy_type",
		"args": {
			"base": 60,
			"per_energy": 20,
			"energy_type": "Grass",
		},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606383))
	_check(step.success, "Native damage_per_self_energy_type formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 8,
		"Native damage_per_self_energy_type formula produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].discard = ["sv1-106", "svi-chim"]
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "deal_damage_per_discard_psychic",
		"args": {"base": 80, "per_card": 10},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606384))
	_check(step.success, "Native damage_per_discard_psychic formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 9,
		"Native damage_per_discard_psychic formula produced wrong damage")

	state = _effect_state()
	state.players[1].active.damage_counters = 0
	state.players[0].bench[0] = PokemonState.new("svg2-tort")
	state.players[0].bench[1] = PokemonState.new("sv1-106")
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({
		"op": "deal_damage_per_evolved",
		"args": {"per_evolved": 50},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606385))
	_check(step.success, "Native damage_per_evolved formula failed: %s" % step.message)
	_check(state.players[1].active.damage_counters == 10,
		"Native damage_per_evolved formula produced wrong damage")

	state = _effect_state()
	state.players[0].active.damage_counters = 2
	state.players[0].active.energy_card_ids = ["sv1-ener-2"]
	state.players[0].bench[0].damage_counters = 1
	state.players[0].bench[1] = PokemonState.new("sv2-38")
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
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
			"ignore_weakness": true,
			"ignore_defender_damage_effects": true,
		},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(202606386))
	_check(step.success, "Native set_attack_damage_formula command spec failed: %s" % step.message)
	var saved_formula_stack := ResolutionStack.from_dict(state.resolution_stack)
	_check(int(saved_formula_stack.context.get("base_damage", 0)) == 240,
		"Native set_attack_damage_formula produced wrong base damage")
	_check(
		bool(saved_formula_stack.context.get("ignore_weakness", false))
		and not bool(saved_formula_stack.context.get("ignore_resistance", false)),
		"Canonical formula flags did not preserve independent Weakness handling",
	)
	_check(bool(saved_formula_stack.context.get("ignore_defender_damage_effects", false)),
		"Native formula did not set canonical defender-damage-effect flag")

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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260639))
	_check(step.success, "Native set_attack_flags command spec failed: %s" % step.message)
	var saved_attack_stack := ResolutionStack.from_dict(state.resolution_stack)
	_check(
		bool(saved_attack_stack.context.get("ignore_weakness", false))
		and bool(saved_attack_stack.context.get("ignore_resistance", false)),
		"Native set_attack_flags did not preserve independent matchup flags",
	)
	_check(bool(saved_attack_stack.context.get("ignore_defender_damage_effects", false)),
		"Native set_attack_flags did not set canonical defender-damage-effect flag")
	_check(
		int(saved_attack_stack.context.get("base_damage", 0)) == 30
		and saved_attack_stack.context.get("damage_packets", []).is_empty(),
		"Native set_attack_flags did not preserve the queued damage packet",
	)

	state = _effect_state()
	state.players[0].active.card_id = "sv2-tatsu"
	state.players[0].active.evolution_stack_ids = ["sv2-38"]
	state.players[0].active.energy_card_ids = ["sv1-ener-3"]
	state.players[0].active.attached_tool_id = "svl-vitb"
	state.players[0].hand = []
	stack = ResolutionStack.new()
	stack.context["effect_source_kind"] = "attack"
	stack.push_effect({"op": "return_to_hand", "args": {}, "branches": {}}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260640))
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260641))
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260642))
	_check(step.success and step.pending_choice != null,
		"Native choice deal_bench_damage command spec did not pause for choice")
	var bench_damage_option := _choice_id_for_slot(step.pending_choice, "bench_1")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
		"args": {"amount": 40, "player": "opponent"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260644))
	_check(step.success and step.pending_choice != null,
		"Native choose_damage_target command spec did not pause for choice")
	var any_damage_option := _choice_id_for_slot(step.pending_choice, "bench_0")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
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
		"op": "place_counters_then_self_discard",
		"args": {"counters": 2, "target_player": "opponent"},
		"branches": {},
	}, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(state, stack, PortableRandomSource.new(20260646))
	_check(step.success and step.pending_choice != null,
		"Native place_counters_then_self_discard command spec did not pause for choice")
	var comet_option := _choice_id_for_slot(step.pending_choice, "bench_0")
	step = RulesTestHarness.effect_engine_for(engine).apply_choice(
		state,
		ResolutionStack.from_dict(state.resolution_stack),
		ChoiceResponse.new(step.pending_choice.request_id, [comet_option]),
		PortableRandomSource.new(20260647),
	)
	_check(step.success, "Native place_counters_then_self_discard failed to resume: %s" % step.message)
	_check(state.players[1].bench[0].damage_counters == 2,
		"Native place_counters_then_self_discard did not place target counters")
	_check(state.players[0].active == null and "sv2-starm" in state.players[0].discard,
		"Native place_counters_then_self_discard did not discard source without KO")
	_check(0 in state.pending_promotions,
		"Native place_counters_then_self_discard did not enqueue promotion")
	_check(state.players[0].hand == ["sv1-ener-2"],
		"Native place_counters_then_self_discard did not resume remaining command")


func _run_compiled_runtime_dispatch_tests(engine: GameEngine) -> void:
	var trainer_id := "__test_compiled_trainer"
	engine.catalog.cards[trainer_id] = {
		"api_id": trainer_id,
		"name": "Compiled Trainer Probe",
		"supertype": "Trainer",
		"subtypes": ["Item"],
		"trainer_type": "Item",
		"trainer_effects": [{
			"effect_type": "energy_discard",
			"params": {"from": "opponent", "filter": "not_real_energy"},
		}],
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
	_check(
		RulesTestHarness.action_availability_for(engine).action_target_availability_error(
			state, GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0), 0
		).is_empty(),
		"Compiled trainer availability still used raw trainer_effects",
	)
	var step := _apply_test_action(engine,
		state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(20260648),
	)
	_check(step.success, "Compiled trainer runtime dispatch failed: %s" % step.message)
	_check(state.players[0].hand == ["sv1-ener-2"],
		"Compiled trainer runtime did not execute compiled draw_cards")
	_check(state.players[0].discard == [trainer_id],
		"Compiled trainer runtime did not discard the played item")

	var missing_compiled_id := "__test_missing_compiled_trainer"
	engine.catalog.cards[missing_compiled_id] = {
		"api_id": missing_compiled_id,
		"name": "Missing Compiled Trainer Probe",
		"supertype": "Trainer",
		"subtypes": ["Item"],
		"trainer_type": "Item",
		"trainer_effects": [{
			"effect_type": "draw",
			"params": {"amount": 1},
		}],
		"compiled_trainer_effects": [],
		"abilities": [],
		"attacks": [],
	}
	state = _effect_state()
	state.players[0].hand = [missing_compiled_id]
	state.players[0].deck = ["sv1-ener-2"]
	step = _apply_test_action(engine,
		state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(202606481),
	)
	_check(
		not step.success and step.error_code == "unsupported_vm_op",
		"Missing compiled trainer effects must fail instead of executing raw effects",
	)

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
			"effects": [{
				"effect_type": "energy_discard",
				"params": {"from": "opponent", "filter": "not_real_energy"},
			}],
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
	_check(
		RulesTestHarness.action_availability_for(engine).action_target_availability_error(
			state,
			GameAction.new("USE_ABILITY", {
				"slot": "active",
				"ability_name": "Compiled Ability",
			}, false, 0),
			0
		).is_empty(),
		"Compiled ability availability still used raw ability effects",
	)
	step = _apply_test_action(engine,
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
			"effects": [{
				"effect_type": "energy_discard",
				"params": {"from": "opponent", "filter": "not_real_energy"},
			}],
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
	_check(
		RulesTestHarness.action_availability_for(engine).action_target_availability_error(
			state, GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0), 0
		).is_empty(),
		"Compiled attack availability still used raw attack effects",
	)
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(20260650),
	)
	_check(step.success, "Compiled attack runtime dispatch failed: %s" % step.message)
	_check(state.players[0].hand == ["sv1-ener-4"],
		"Compiled attack runtime did not execute compiled draw_cards")

	var compiled_tool_id := "__test_compiled_tool_modifier"
	engine.catalog.cards[compiled_tool_id] = {
		"api_id": compiled_tool_id,
		"name": "Compiled Tool Modifier Probe",
		"supertype": "Trainer",
		"subtypes": ["Tool"],
		"trainer_type": "Tool",
		"trainer_effects": [{
			"effect_type": "tool",
			"params": {"effect": "damage_reduction_stage1", "amount": 90},
		}],
		"compiled_trainer_effects": [{
			"op": "register_tool_modifier",
			"args": {"effect": "hp_boost_basic", "amount": 50},
			"branches": {},
		}],
		"abilities": [],
		"attacks": [],
	}
	var compiled_probe_id := "__test_compiled_modifier_pokemon"
	engine.catalog.cards[compiled_probe_id] = {
		"api_id": compiled_probe_id,
		"name": "Compiled Modifier Pokemon",
		"supertype": "Pokémon",
		"subtypes": ["Basic"],
		"hp": 60,
		"energy_types": ["Colorless"],
		"retreat_cost": 2,
		"weaknesses": [],
		"resistances": [],
		"provides_energy": [],
		"abilities": [{
			"name": "Compiled Retreat",
			"trigger": "static",
			"effects": [{
				"effect_type": "conditional_hp_boost",
				"params": {"energy_type": "Metal", "threshold": 99, "amount": 999},
			}],
			"compiled_effects": [{
				"op": "register_conditional_zero_retreat",
				"args": {"energy_type": "Psychic"},
				"branches": {},
			}],
		}],
		"attacks": [],
		"trainer_effects": [],
		"compiled_trainer_effects": [],
	}
	state = _battle_state()
	state.players[0].active = PokemonState.new(compiled_probe_id)
	state.players[0].active.attached_tool_id = compiled_tool_id
	state.players[0].active.energy_card_ids = ["sv1-ener-5"]
	_check(
		VMPokemonStatHooks.current_hp(state.players[0].active, engine.catalog) == 110,
		"Compiled-first MAX_HP hook still used raw tool trainer_effects",
	)
	_check(
		VMRetreatModifierHooks.effective_retreat_cost(state, engine.catalog, state.players[0]) == 0,
		"Compiled-first CAN_RETREAT hook still used raw ability effects",
	)

	var compiled_damage_tool_id := "__test_compiled_damage_tool"
	engine.catalog.cards[compiled_damage_tool_id] = {
		"api_id": compiled_damage_tool_id,
		"name": "Compiled Damage Tool Probe",
		"supertype": "Trainer",
		"subtypes": ["Tool"],
		"trainer_type": "Tool",
		"trainer_effects": [{
			"effect_type": "tool",
			"params": {"effect": "damage_reduction_stage1", "amount": 90},
		}],
		"compiled_trainer_effects": [{
			"op": "register_tool_modifier",
			"args": {"effect": "damage_boost_10"},
			"branches": {},
		}],
		"abilities": [],
		"attacks": [],
	}
	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.attached_tool_id = compiled_damage_tool_id
	state.players[1].active = PokemonState.new("sv2-delib")
	var modified_damage := VMDamageModifierHooks.apply_modify_damage(
		state,
		engine.catalog,
		{
			"actor": 0,
			"attacker": state.players[0].active,
			"defender": state.players[1].active,
			"damage": 30,
		},
	)
	_check(modified_damage == 40,
		"Compiled-first MODIFY_DAMAGE hook still used raw tool trainer_effects")

	var compiled_reactive_id := "__test_compiled_reactive"
	engine.catalog.cards[compiled_reactive_id] = {
		"api_id": compiled_reactive_id,
		"name": "Reactive Probe",
		"supertype": "Pokémon",
		"subtypes": ["Basic"],
		"hp": 60,
		"energy_types": ["Colorless"],
		"retreat_cost": 1,
		"weaknesses": [],
		"resistances": [],
		"provides_energy": [],
		"abilities": [{
			"name": "Compiled Reactive",
			"trigger": "static",
			"effects": [{
				"effect_type": "conditional_hp_boost",
				"params": {"energy_type": "Metal", "threshold": 99, "amount": 999},
			}],
			"compiled_effects": [{
				"op": "register_reactive_thorns",
				"args": {"filter_names": ["Reactive Probe"], "per_pokemon": 2},
				"branches": {},
			}],
		}],
		"attacks": [],
		"trainer_effects": [],
		"compiled_trainer_effects": [],
	}
	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[1].active = PokemonState.new(compiled_reactive_id)
	var after_damage_candidates: Array[Dictionary] = []
	RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands.collect_after_damage_triggers(
		state,
		{
			"actor": 0,
			"attacker": state.players[0].active,
			"defender": state.players[1].active,
			"damage": 10,
		},
		after_damage_candidates,
	)
	var after_damage_command: Dictionary = (
		after_damage_candidates[0].get("commands", [])[0]
		if after_damage_candidates.size() == 1
		and after_damage_candidates[0].get("commands", []).size() == 1
		else {}
	)
	_check(
		after_damage_candidates.size() == 1
		and str(after_damage_candidates[0].get("hook", ""))
		== VMModifierManager.AFTER_DAMAGE
		and str(after_damage_command.get("op", "")) == "trigger_place_damage_counters"
		and int(after_damage_command.get("args", {}).get("count", 0)) == 2,
		"Compiled-first AFTER_DAMAGE hook still used raw ability effects",
	)

	var compiled_exp_share_id := "__test_compiled_exp_share_tool"
	engine.catalog.cards[compiled_exp_share_id] = {
		"api_id": compiled_exp_share_id,
		"name": "Compiled Exp Share Probe",
		"supertype": "Trainer",
		"subtypes": ["Tool"],
		"trainer_type": "Tool",
		"trainer_effects": [],
		"compiled_trainer_effects": [{
			"op": "register_tool_exp_share",
			"args": {},
			"branches": {},
		}],
		"abilities": [],
		"attacks": [],
	}
	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.energy_card_ids = ["sv1-ener-2"]
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[0].attached_tool_id = compiled_exp_share_id
	var compiled_ko_candidates: Array[Dictionary] = []
	RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands.collect_pokemon_ko_triggers(
		state,
		0,
		"active",
		state.players[0].active,
		true,
		1,
		compiled_ko_candidates,
	)
	var compiled_ko_command: Dictionary = (
		compiled_ko_candidates[0].get("commands", [])[0]
		if compiled_ko_candidates.size() == 1
		and compiled_ko_candidates[0].get("commands", []).size() == 1
		else {}
	)
	_check(
		compiled_ko_candidates.size() == 1
		and str(compiled_ko_candidates[0].get("hook", ""))
		== VMModifierManager.POKEMON_KO
		and str(compiled_ko_command.get("op", "")) == "trigger_move_basic_energy",
		"Compiled-first POKEMON_KO hook still used raw tool trainer_effects",
	)

	var raw_only_tool_id := "__test_raw_only_tool_modifier"
	engine.catalog.cards[raw_only_tool_id] = {
		"api_id": raw_only_tool_id,
		"name": "Raw Only Tool Modifier Probe",
		"supertype": "Trainer",
		"subtypes": ["Tool"],
		"trainer_type": "Tool",
		"trainer_effects": [{
			"effect_type": "tool",
			"params": {"effect": "hp_boost_basic", "amount": 50},
		}],
		"compiled_trainer_effects": [],
		"abilities": [],
		"attacks": [],
	}
	state = _battle_state()
	state.players[0].active = PokemonState.new(compiled_probe_id)
	state.players[0].active.attached_tool_id = raw_only_tool_id
	_check(
		VMPokemonStatHooks.current_hp(state.players[0].active, engine.catalog) == 60,
		"Raw-only MAX_HP hook executed without compiled trainer IR",
	)

	var raw_only_retreat_id := "__test_raw_only_retreat"
	engine.catalog.cards[raw_only_retreat_id] = {
		"api_id": raw_only_retreat_id,
		"name": "Raw Only Retreat Probe",
		"supertype": "Pokémon",
		"subtypes": ["Basic"],
		"hp": 60,
		"energy_types": ["Colorless"],
		"retreat_cost": 2,
		"weaknesses": [],
		"resistances": [],
		"provides_energy": [],
		"abilities": [{
			"name": "Raw Retreat",
			"trigger": "static",
			"effects": [{
				"effect_type": "conditional_zero_retreat",
				"params": {"energy_type": "Psychic"},
			}],
			"compiled_effects": [],
		}],
		"attacks": [],
		"trainer_effects": [],
		"compiled_trainer_effects": [],
	}
	state = _battle_state()
	state.players[0].active = PokemonState.new(raw_only_retreat_id)
	state.players[0].active.energy_card_ids = ["sv1-ener-5"]
	_check(
		VMRetreatModifierHooks.effective_retreat_cost(state, engine.catalog, state.players[0]) == 2,
		"Raw-only CAN_RETREAT hook executed without compiled ability IR",
	)

	var raw_only_damage_tool_id := "__test_raw_only_damage_tool"
	engine.catalog.cards[raw_only_damage_tool_id] = {
		"api_id": raw_only_damage_tool_id,
		"name": "Raw Only Damage Tool Probe",
		"supertype": "Trainer",
		"subtypes": ["Tool"],
		"trainer_type": "Tool",
		"trainer_effects": [{
			"effect_type": "tool",
			"params": {"effect": "damage_boost_10"},
		}],
		"compiled_trainer_effects": [],
		"abilities": [],
		"attacks": [],
	}
	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.attached_tool_id = raw_only_damage_tool_id
	state.players[1].active = PokemonState.new("sv2-delib")
	modified_damage = VMDamageModifierHooks.apply_modify_damage(
		state,
		engine.catalog,
		{
			"actor": 0,
			"attacker": state.players[0].active,
			"defender": state.players[1].active,
			"damage": 30,
		},
	)
	_check(modified_damage == 30,
		"Raw-only MODIFY_DAMAGE hook executed without compiled trainer IR")

	var raw_only_reactive_id := "__test_raw_only_reactive"
	engine.catalog.cards[raw_only_reactive_id] = {
		"api_id": raw_only_reactive_id,
		"name": "Raw Only Reactive Probe",
		"supertype": "Pokémon",
		"subtypes": ["Basic"],
		"hp": 60,
		"energy_types": ["Colorless"],
		"retreat_cost": 1,
		"weaknesses": [],
		"resistances": [],
		"provides_energy": [],
		"abilities": [{
			"name": "Raw Reactive",
			"trigger": "static",
			"effects": [{
				"effect_type": "reactive_thorns",
				"params": {"filter_names": ["Raw Only Reactive Probe"], "per_pokemon": 2},
			}],
			"compiled_effects": [],
		}],
		"attacks": [],
		"trainer_effects": [],
		"compiled_trainer_effects": [],
	}
	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[1].active = PokemonState.new(raw_only_reactive_id)
	after_damage_candidates.clear()
	RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands.collect_after_damage_triggers(
		state,
		{
			"actor": 0,
			"attacker": state.players[0].active,
			"defender": state.players[1].active,
			"damage": 10,
		},
		after_damage_candidates,
	)
	_check(after_damage_candidates.is_empty(),
		"Raw-only AFTER_DAMAGE hook executed without compiled ability IR")

	var raw_only_exp_share_id := "__test_raw_only_exp_share_tool"
	engine.catalog.cards[raw_only_exp_share_id] = {
		"api_id": raw_only_exp_share_id,
		"name": "Raw Only Exp Share Probe",
		"supertype": "Trainer",
		"subtypes": ["Tool"],
		"trainer_type": "Tool",
		"trainer_effects": [{
			"effect_type": "tool_exp_share",
			"params": {},
		}],
		"compiled_trainer_effects": [],
		"abilities": [],
		"attacks": [],
	}
	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.energy_card_ids = ["sv1-ener-2"]
	state.players[0].bench[0] = PokemonState.new("sv2-delib")
	state.players[0].bench[0].attached_tool_id = raw_only_exp_share_id
	compiled_ko_candidates.clear()
	RulesTestHarness.effect_engine_for(engine).runtime.trigger_commands.collect_pokemon_ko_triggers(
		state,
		0,
		"active",
		state.players[0].active,
		true,
		1,
		compiled_ko_candidates,
	)
	_check(compiled_ko_candidates.is_empty(),
		"Raw-only POKEMON_KO hook executed without compiled trainer IR")


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
	var step := _apply_test_action(engine,
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
		not _has_hand_action(RulesTestHarness.legal_actions(engine, state, 0, false), "PLAY_TRAINER", 0),
		"Ultra Ball with unpaid discard cost was listed as legal",
	)

	state = _battle_state()
	state.players[0].hand = ["svd-dark-patch"]
	state.players[0].discard = ["sv1-ener-7"]
	state.players[0].bench[0] = PokemonState.new("svd-doduo")
	_check(
		not _has_hand_action(RulesTestHarness.legal_actions(engine, state, 0, false), "PLAY_TRAINER", 0),
		"Dark Patch without a Darkness bench target was listed as legal",
	)
	step = _apply_test_action(engine,
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
		not _has_hand_action(RulesTestHarness.legal_actions(engine, state, 0, false), "PLAY_TRAINER", 0),
		"Pokemon Catcher without opponent bench was listed as legal",
	)
	step = _apply_test_action(engine,
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
		not _has_action(RulesTestHarness.legal_actions(engine, state, 0, false), "USE_ABILITY", {"slot": "active"}),
		"Bronzong Metal Transfer without a target was listed as legal",
	)
	step = _apply_test_action(engine,
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
		_has_action(RulesTestHarness.legal_actions(engine, state, 0, false), "DECLARE_ATTACK", {"attack_idx": 0}),
		"Cresselia deck-search attack inspected hidden energy identities",
	)
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(61004),
	)
	_check(
		step.success,
		"Cresselia deck-search attack could not legally fail its search",
	)

	state = _battle_state()
	state.players[0].hand = ["sv1-170"]
	state.players[0].bench[0] = PokemonState.new("svl-pikaex")
	state.players[0].bench[1] = PokemonState.new("sv2-delib")
	state.players[0].deck = [
		"sv1-ener-3", "sv1-ener-3", "sv1-ener-3", "sv1-ener-4", "sv1-ener-4",
	]
	step = _apply_test_action(engine,
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
		step = RulesTestHarness.apply_choice(engine,
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
	step = _apply_test_action(engine,
		state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(6103),
	)
	if step.pending_choice:
		var electric_ids: Array[String] = []
		for index in range(min(2, step.pending_choice.options.size())):
			electric_ids.append(str(step.pending_choice.options[index]["option_id"]))
		step = RulesTestHarness.apply_choice(engine,
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
	state.players[0].hand = ["sv1-170"]
	state.players[0].bench[0] = PokemonState.new("svl-pikaex")
	state.players[0].bench[1] = PokemonState.new("svl-pikaex")
	state.players[0].deck = [
		"sv1-ener-3", "sv1-ener-3", "sv1-ener-3", "sv1-ener-4", "sv1-ener-4",
	]
	step = _apply_test_action(engine,
		state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(61041),
	)
	var detached_energy_ids: Array[String] = []
	var detached_energy_option_ids: Array[String] = []
	if step.pending_choice:
		for index in range(min(2, step.pending_choice.options.size())):
			var option: Dictionary = step.pending_choice.options[index]
			detached_energy_option_ids.append(str(option.get("option_id", "")))
			detached_energy_ids.append(str(option.get("ref", {}).get("card_id", "")))
		step = RulesTestHarness.apply_choice(engine,
			state,
			step.pending_choice,
			ChoiceResponse.new(step.pending_choice.request_id, detached_energy_option_ids),
			PortableRandomSource.new(61042),
		)
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.request_type == "distribute_energy",
		"Electric Generator did not request a target distribution for two legal sources",
	)
	_check(
		step.pending_choice != null
		and step.pending_choice.metadata.get("purpose", "") == "detached_energy_distribution"
		and step.pending_choice.metadata.get("card_ids", []) == detached_energy_ids
		and int(step.pending_choice.metadata.get("source_player", -1)) == 0
		and step.pending_choice.metadata.get("source_zone", "") == "deck"
		and bool(step.pending_choice.metadata.get("same_source", false))
		and not bool(step.pending_choice.metadata.get("same_target", true))
		and int(step.pending_choice.metadata.get("max_per_target", -1)) == 99,
		"detached_energy_distribution omitted metadata required by network UI",
	)
	var detached_session := AuthoritativeSession.new("metadata-contract", engine.catalog)
	detached_session.state = state
	var detached_view := detached_session.view_for(0)
	_check(
		 detached_view.get("choice_request") is Dictionary
		and not Dictionary(detached_view.get("state", {})).has("resolution_stack")
		and detached_view["choice_request"].get("presentation", {}).get(
			"card_ids", []) == detached_energy_ids,
		"Network energy choice depended on a client-visible resolution_stack",
	)
	if step.pending_choice:
		var generator_target := str(step.pending_choice.options[0].get("option_id", ""))
		step = RulesTestHarness.apply_choice(engine,
			state,
			step.pending_choice,
			ChoiceResponse.new(step.pending_choice.request_id, [
				generator_target, generator_target,
			]),
			PortableRandomSource.new(61043),
		)
	_check(step.success, "Electric Generator metadata contract did not finish cleanly")

	state = _battle_state()
	state.players[0].hand = ["svg2-hamm"]
	_set_energy_cards(state.players[1].active, ["sv1-ener-3"])
	state.players[1].bench[0] = PokemonState.new("sv2-delib")
	_set_energy_cards(state.players[1].bench[0], ["sv1-ener-4"])
	step = _apply_test_action(engine,
		state,
		GameAction.new("PLAY_TRAINER", {"hand_idx": 0}, false, 0),
		PortableRandomSource.new(2),
	)
	if step.pending_choice:
		step = RulesTestHarness.apply_choice(engine,
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
			if str(option.get("ref", {}).get("slot", "")) == "bench_0":
				bench_attachment_id = str(option.get("option_id", ""))
				break
		step = RulesTestHarness.apply_choice(engine,
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
	step = _apply_test_action(engine,
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
		step = RulesTestHarness.apply_choice(engine,
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
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(6109),
	)
	_check(
		step.success and step.pending_choice != null
		and step.pending_choice.min_select == 0
		and step.pending_choice.max_select == 2
		and str(step.pending_choice.metadata.get("purpose", "")) == "energy_attach_sources",
		"Cobalion Follow-Up did not request zero to two exact energy sources",
	)
	if step.pending_choice:
		var cobalion_source_request := step.pending_choice
		var cobalion_source_id := str(
			cobalion_source_request.options[0].get("option_id", ""))
		step = RulesTestHarness.apply_choice(engine,
			state,
			cobalion_source_request,
			ChoiceResponse.new(cobalion_source_request.request_id, [cobalion_source_id]),
			PortableRandomSource.new(6110),
		)
		_check(
			step.success and step.pending_choice != null
			and str(step.pending_choice.metadata.get("purpose", ""))
			== "energy_attach_target",
			"Cobalion one-source choice did not continue to a target request",
		)
	if step.pending_choice:
		var cobalion_target := _choice_id_for_slot(step.pending_choice, "bench_1")
		step = RulesTestHarness.apply_choice(engine,
			state,
			step.pending_choice,
			ChoiceResponse.new(step.pending_choice.request_id, [cobalion_target]),
			PortableRandomSource.new(6111),
		)
	_check(step.success, "Cobalion one-energy choice failed: %s" % step.message)
	_check(
		state.players[0].bench[0].energy_card_ids.is_empty()
		and state.players[0].bench[1].energy_card_ids.size() == 1,
		"Cobalion did not accept a single legal attachment",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("svm-cobalion")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-8", "sv1-ener-8"])
	state.players[0].bench[0] = PokemonState.new("svm-zacian")
	state.players[0].deck = ["sv1-ener-8", "sv1-ener-8"]
	var optional_cancel_rng := PortableRandomSource.new(61101)
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		optional_cancel_rng,
	)
	_check(
		step.success and step.pending_choice != null and step.pending_choice.can_cancel,
		"Cobalion optional attack did not expose cancellable choice",
	)
	if step.pending_choice:
		var cancel_request := step.pending_choice
		var cancel_stack := ResolutionStack.from_dict(state.resolution_stack)
		var cancel_frame_kinds: Array[String] = []
		for frame in cancel_stack.frames:
			cancel_frame_kinds.append(str(frame.get("kind", "")))
		_check(
			cancel_stack.pending_request != null
			and cancel_frame_kinds == ["barrier", "continuation"]
			and str(cancel_stack.frames[0].get("operation", "")) == "finalize_attack"
			and not cancel_stack.context.has("cancel_action_checkpoint"),
			"Optional attack choice stack did not preserve its strict attack barrier",
		)
		step = RulesTestHarness.apply_choice(engine,
			state,
			cancel_request,
			ChoiceResponse.new(cancel_request.request_id, [], true),
			optional_cancel_rng,
		)
	_check(step.success, "Cobalion optional attack cancellation failed: %s" % step.message)
	_check(
		step.pending_choice == null
		and ResolutionStack.from_dict(state.resolution_stack).frames.is_empty()
		and ResolutionStack.from_dict(state.resolution_stack).pending_request == null,
		"Cobalion optional attack cancellation left pending stack data behind",
	)
	_check(
		state.active_player_idx == 1
		and state.phase == "MAIN"
		and state.players[0].deck == ["sv1-ener-8", "sv1-ener-8"]
		and state.players[0].bench[0].energy_card_ids.is_empty(),
		"Cobalion optional attack cancellation did not skip attachment and finish attack turn",
	)
	_check(
		optional_cancel_rng.get_state() != 61101,
		"Cobalion optional zero-target choice skipped its required deck shuffle",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv1-109")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-5", "svi-dtur"])
	step = _apply_test_action(engine,
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
	_set_test_prevention(state, 1, true, true, "active", state.turn_number)
	var prevention_packet_events: Array[Dictionary] = []
	var prevention_trigger_commands: Array[Dictionary] = []
	RulesTestHarness.attack_settlement_for(engine).apply_attack_damage(
		state,
		0,
		120,
		"Fighting",
		false,
		prevention_packet_events,
		prevention_trigger_commands,
	)
	_check(
		state.players[1].active.damage_counters == 0
		and state.players[1].active.prevents_damage()
		and state.players[1].active.prevents_effects(),
		"Primary attack damage consumed prevention before the protected turn boundary",
	)
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
		PortableRandomSource.new(6112),
	)
	_check(step.success, "Conditional bonus prevention attack failed: %s" % step.message)
	_check(
		state.players[1].active.damage_counters == 0
		and not state.players[1].active.prevents_damage()
		and not state.players[1].active.prevents_effects(),
		"Attack prevention did not survive the damage packet and expire at the protected turn start",
	)

	state = _battle_state()
	state.apply_type_matchups = true
	state.players[0].active = PokemonState.new("svl-pikaex")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.attached_tool_id = "svl-vitb"
	_set_energy_cards(state.players[0].active, ["sv1-ener-4"])
	state.players[1].active = PokemonState.new("sv2-grex")
	state.players[1].active.placed_this_turn = false
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(6113),
	)
	_check(step.success, "Type matchup damage-order attack failed: %s" % step.message)
	_check(
		state.players[1].active.damage_counters == 8,
		"Weakness/resistance was not applied before tool damage modifiers",
	)

	state = _battle_state()
	state.set_type_matchups_enabled(false)
	state.players[0].active = PokemonState.new("svl-pikaex")
	state.players[0].active.placed_this_turn = false
	state.players[0].active.attached_tool_id = "svl-vitb"
	_set_energy_cards(state.players[0].active, ["sv1-ener-4"])
	state.players[1].active = PokemonState.new("sv2-grex")
	state.players[1].active.placed_this_turn = false
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(6113),
	)
	_check(step.success, "Type-matchup-disabled damage-order attack failed: %s" % step.message)
	_check(
		state.players[1].active.damage_counters == 4,
		"Authoritative attack settlement with type matchups disabled expected 4 counters, got %d"
		% state.players[1].active.damage_counters,
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv2-staryu")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-3", "sv1-ener-3"])
	_set_test_prevention(state, 1, true, false)
	step = _apply_test_action(engine,
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
	state.players[0].active = PokemonState.new("svi-infr")
	state.players[0].active.placed_this_turn = false
	state.players[1].active = PokemonState.new("sv2-grex")
	_set_energy_cards(state.players[0].active, ["sv1-ener-2"])
	state.players[0].deck = [
		"sv2-delib",
		"sv2-delib",
		"sv2-delib",
		"sv2-delib",
		"sv1-ener-1",
	]
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(61140),
	)
	var infernape_reveal_index := _first_event_type_index(
		step.events, "cards_revealed")
	var infernape_shuffle_index := _first_event_type_index(
		step.events, "deck_shuffled")
	var infernape_damage_index := _first_event_type_index(
		step.events, "damage_dealt")
	_check(
		step.success
		and state.players[1].active.damage_counters == 8
		and infernape_reveal_index >= 0
		and infernape_shuffle_index > infernape_reveal_index
		and infernape_damage_index > infernape_shuffle_index,
		"Infernape reveal attack was not presented as reveal, shuffle, then damage",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("svf-luca")
	state.players[0].active.placed_this_turn = false
	state.players[1].active = PokemonState.new("sv2-grex")
	_set_energy_cards(
		state.players[0].active,
		["sv1-ener-6", "sv1-ener-6"],
	)
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(611401),
	)
	var lucario_discard_index := _first_event_type_index(
		step.events, "cards_discarded")
	var lucario_damage_index := _first_event_type_index(
		step.events, "damage_dealt")
	_check(
		step.success
		and state.players[0].active.energy_card_ids.is_empty()
		and lucario_discard_index >= 0
		and lucario_damage_index > lucario_discard_index,
		"Lucario calculated-damage attack was not presented as discard then damage",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-gree")
	state.players[0].active.placed_this_turn = false
	state.players[1].active = PokemonState.new("sv2-grex")
	_set_energy_cards(
		state.players[0].active,
		["sv1-ener-1", "sv1-ener-1"],
	)
	state.players[0].hand = [
		"sv2-delib",
		"sv2-delib",
		"sv2-delib",
		"sv2-delib",
		"sv2-delib",
	]
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
		PortableRandomSource.new(611402),
	)
	var greedent_discard_index := _first_event_type_index(
		step.events, "cards_discarded")
	var greedent_damage_index := _first_event_type_index(
		step.events, "damage_dealt")
	_check(
		step.success
		and state.players[0].hand.is_empty()
		and greedent_discard_index >= 0
		and greedent_damage_index > greedent_discard_index,
		"Greedent calculated-damage attack was not presented as discard then damage",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv2-glast")
	state.players[0].active.placed_this_turn = false
	state.players[1].active = PokemonState.new("sv2-grex")
	state.players[1].active.damage_counters = 17
	_set_energy_cards(
		state.players[0].active,
		["sv1-ener-3", "sv1-ener-3", "sv1-ener-3"],
	)
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
		PortableRandomSource.new(611403),
	)
	var glastrier_damage_index := -1
	var glastrier_recoil_index := -1
	var glastrier_ko_index := -1
	var glastrier_event_types: Array[String] = []
	for index in range(step.events.size()):
		var event: Dictionary = step.events[index]
		var event_type := str(event.get("event_type", ""))
		var event_data: Dictionary = event.get("data", {})
		glastrier_event_types.append(event_type)
		if event_type == "damage_dealt":
			if int(event_data.get("player", -1)) == 1:
				glastrier_damage_index = index
			elif int(event_data.get("player", -1)) == 0:
				glastrier_recoil_index = index
		elif (
			event_type == "damage_counters_placed"
			and int(event_data.get("player", -1)) == 0
		):
			glastrier_recoil_index = index
		elif (
			event_type == "pokemon_ko"
			and int(event_data.get("player", -1)) == 1
		):
			glastrier_ko_index = index
	_check(
		step.success
		and state.players[1].active == null
		and state.players[0].active.damage_counters == 3
		and glastrier_damage_index >= 0
		and glastrier_recoil_index > glastrier_damage_index
		and glastrier_ko_index > glastrier_recoil_index,
		"Attack recoil was not presented between its primary hit and KO "
		+ "(events=%s, attacker=%d)" % [
			glastrier_event_types,
			state.players[0].active.damage_counters,
		],
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv2-38")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-3"])
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(61141),
	)
	_check(
		step.success and step.pending_choice != null,
		"Coin attack did not pause for pending choice",
	)
	var pending_attack_stack := ResolutionStack.from_dict(state.resolution_stack)
	var has_finalize_attack_barrier := false
	for frame in pending_attack_stack.frames:
		if (
			str(frame.get("kind", "")) == "barrier"
			and str(frame.get("operation", "")) == "finalize_attack"
		):
			has_finalize_attack_barrier = true
			break
	_check(
		has_finalize_attack_barrier,
		"Pending attack stack did not preserve the strict finalize_attack barrier",
	)
	var restored_attack_state := GameState.from_dict(state.snapshot())
	var restored_attack_stack := ResolutionStack.from_dict(restored_attack_state.resolution_stack)
	_check(
		restored_attack_stack.to_dict() == pending_attack_stack.to_dict(),
		"Pending attack stack changed across GameState snapshot roundtrip",
	)
	var restored_has_finalize_attack_barrier := false
	for frame in restored_attack_stack.frames:
		if (
			str(frame.get("kind", "")) == "barrier"
			and str(frame.get("operation", "")) == "finalize_attack"
		):
			restored_has_finalize_attack_barrier = true
			break
	_check(
		restored_attack_stack.pending_request != null
		and restored_has_finalize_attack_barrier,
		"Restored pending attack stack lost its request or strict attack barrier",
	)
	var restored_attack_request := restored_attack_stack.pending_request
	step = RulesTestHarness.apply_choice(engine,
		restored_attack_state,
		restored_attack_request,
		ChoiceResponse.new(restored_attack_request.request_id, []),
		PortableRandomSource.new(61142),
	)
	_check(
		step.success
		and step.pending_choice == null
		and restored_attack_state.active_player_idx == 1
		and restored_attack_state.phase == "MAIN",
		"Restored pending attack choice did not consume the attack barrier and finish the turn",
	)
	var coin_event_index := _first_event_type_index(step.events, "coin_flip")
	var coin_damage_event_index := _first_event_type_index(
		step.events, "damage_dealt")
	_check(
		coin_event_index >= 0
		and coin_damage_event_index > coin_event_index,
		"Coin-dependent attack was not presented as coin result then damage",
	)
	_check(
		ResolutionStack.from_dict(restored_attack_state.resolution_stack).frames.is_empty(),
		"Restored attack barrier remained after attack completion",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv2-tatsu")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-3"])
	state.players[0].active.attached_tool_id = "svl-vitb"
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
		PortableRandomSource.new(6115),
	)
	_check(step.success, "Tatsugiri return-to-hand attack failed: %s" % step.message)
	_check(
		state.players[1].active.damage_counters == 4
		and state.players[0].active == null
		and "sv2-tatsu" in state.players[0].hand
		and "sv1-ener-3" in state.players[0].hand
		and "svl-vitb" in state.players[0].hand,
		"Tatsugiri did not retain its original-attacker +10 modifier before returning",
	)
	var tatsugiri_attack_event_index := _first_event_type_index(
		step.events, "attack_declared")
	var tatsugiri_damage_event_index := _first_event_type_index(
		step.events, "damage_dealt")
	var tatsugiri_return_event_index := _first_event_type_index(
		step.events, "card_moved")
	_check(
		tatsugiri_attack_event_index >= 0
		and tatsugiri_damage_event_index > tatsugiri_attack_event_index
		and tatsugiri_return_event_index > tatsugiri_damage_event_index,
		"Tatsugiri return-to-hand was presented before its attack damage",
	)
	_check(
		state.winner == 1,
		"Tatsugiri return-to-hand without bench did not lose by leaving no Pokemon in play",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("svi-chim")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-2"])
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(61151),
	)
	var self_discard_damage_event_index := _first_event_type_index(
		step.events, "damage_dealt")
	var self_discard_event_index := _first_event_type_index(
		step.events, "cards_discarded")
	var self_discard_turn_end_event_index := _first_event_type_index(
		step.events, "turn_end")
	_check(
		step.success
		and state.players[1].active.damage_counters == 3
		and state.players[0].active.energy_card_ids.is_empty()
		and self_discard_damage_event_index >= 0
		and self_discard_event_index > self_discard_damage_event_index
		and self_discard_turn_end_event_index > self_discard_event_index,
		"Attack self-discard was not presented between damage and turn handoff",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv1-114")
	state.players[0].active.placed_this_turn = false
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[0].bench[0].placed_this_turn = false
	_set_energy_cards(
		state.players[0].active,
		["sv1-ener-5", "sv1-ener-5"],
	)
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
		PortableRandomSource.new(61152),
	)
	_check(
		step.success
		and step.pending_choice != null
		and _first_event_type_index(step.events, "attack_declared") >= 0
		and _first_event_type_index(step.events, "damage_dealt") > 0,
		"Optional switch attack did not apply its hit before the switch choice",
	)
	if step.pending_choice != null:
		step = RulesTestHarness.apply_choice(engine,
			state,
			step.pending_choice,
			ChoiceResponse.new(step.pending_choice.request_id, ["confirm:yes"]),
			PortableRandomSource.new(61153),
		)
	_check(
		step.success and step.pending_choice != null,
		"Optional switch attack did not continue to a bench choice",
	)
	step = _apply_slot_choice(
		engine,
		state,
		step,
		"bench_0",
		PortableRandomSource.new(61154),
	)
	var switched_event_index := _first_event_type_index(step.events, "switched")
	var switch_turn_end_event_index := _first_event_type_index(
		step.events, "turn_end")
	_check(
		step.success
		and step.pending_choice == null
		and state.players[1].active.damage_counters == 5
		and state.players[0].active != null
		and state.players[0].active.card_id == "svi-chim"
		and _first_event_type_index(step.events, "damage_dealt") < 0
		and switched_event_index >= 0
		and switch_turn_end_event_index > switched_event_index,
		"Choice-resumed switch attack did not continue with switch then turn handoff",
	)

	# Confusion recoil is part of the attack lifecycle, but a resulting KO still
	# requires the opponent to select each face-down Prize.  Preserve that pause
	# through a snapshot instead of falling back to prize position zero.
	state = _battle_state()
	state.players[0].active.damage_counters = 4
	state.players[0].active.status_conditions = ["CONFUSED"]
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[0].bench[0].placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-5"])
	state.players[1].prizes = ["sv1-ener-2", "sv1-ener-3"]
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(1),
	)
	_check(
		step.success
		and step.pending_choice != null
		and step.pending_choice.request_type == "select_prize"
		and step.pending_choice.player == 1
		and state.players[0].active == null
		and state.players[1].prizes == ["sv1-ener-2", "sv1-ener-3"],
		"Confusion recoil KO did not pause for the opponent's explicit Prize choice",
	)
	var restored_confusion_state := GameState.from_snapshot(state.snapshot())
	var restored_confusion_stack := ResolutionStack.from_dict(
		restored_confusion_state.resolution_stack)
	var restored_confusion_request := restored_confusion_stack.pending_request
	_check(
		restored_confusion_request != null
		and bool(restored_confusion_stack.context.get(
			"finish_attack_after_prizes", false)),
		"Confusion recoil Prize pause was not snapshot-safe",
	)
	if restored_confusion_request != null:
		step = RulesTestHarness.apply_choice(engine,
			restored_confusion_state,
			restored_confusion_request,
			ChoiceResponse.new(restored_confusion_request.request_id, ["prize:1"]),
			PortableRandomSource.new(611541),
		)
	_check(
		step.success
		and "sv1-ener-3" in restored_confusion_state.players[1].hand
		and restored_confusion_state.players[1].prizes == ["sv1-ener-2"]
		and restored_confusion_state.pending_promotions == [0],
		"Confusion recoil Prize selection did not resume the failed attack batch",
	)
	step = _apply_test_action(engine,
		restored_confusion_state,
		GameAction.new("PROMOTE", {"bench_idx": 0}, true, 0),
		PortableRandomSource.new(611542),
	)
	_check(
		step.success
		and restored_confusion_state.active_player_idx == 1
		and restored_confusion_state.players[0].active != null,
		"Confusion recoil KO did not finish the attack after Prize and promotion",
	)

	# Reactive damage is generated at hit time but resolves after authored
	# post-hit switching.  Two identical card IDs make this an index/entity test:
	# only the original attacker (now bench_0) may receive the counters.
	state = _battle_state()
	state.players[0].active = PokemonState.new("sv1-114")
	state.players[0].active.placed_this_turn = false
	state.players[0].bench[0] = PokemonState.new("sv1-114")
	state.players[0].bench[0].placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-5", "sv1-ener-5"])
	state.players[1].active = PokemonState.new("svi-maus")
	state.players[1].active.placed_this_turn = false
	state.players[1].bench[0] = PokemonState.new("svi-maus")
	state.players[1].bench[0].placed_this_turn = false
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
		PortableRandomSource.new(611543),
	)
	if step.pending_choice != null:
		step = RulesTestHarness.apply_choice(engine,
			state,
			step.pending_choice,
			ChoiceResponse.new(step.pending_choice.request_id, ["confirm:yes"]),
			PortableRandomSource.new(611544),
		)
	_check(
		step.success and step.pending_choice != null,
		"Reactive self-switch scenario did not reach the serialized bench choice",
	)
	var restored_reactive_state := GameState.from_snapshot(state.snapshot())
	var restored_reactive_stack := ResolutionStack.from_dict(
		restored_reactive_state.resolution_stack)
	var restored_reactive_request := restored_reactive_stack.pending_request
	if restored_reactive_request != null:
		var reactive_bench_option := _choice_id_for_slot(
			restored_reactive_request, "bench_0")
		step = RulesTestHarness.apply_choice(engine,
			restored_reactive_state,
			restored_reactive_request,
			ChoiceResponse.new(
				restored_reactive_request.request_id, [reactive_bench_option]),
			PortableRandomSource.new(611545),
		)
	var reactive_switch_index := _first_event_type_index(step.events, "switched")
	var reactive_counter_index := _first_event_type_index(
		step.events, "damage_counters_placed")
	_check(
		step.success
		and step.pending_choice == null
		and restored_reactive_state.players[0].active != null
		and restored_reactive_state.players[0].active.card_id == "sv1-114"
		and restored_reactive_state.players[0].active.energy_card_ids.is_empty()
		and restored_reactive_state.players[0].active.damage_counters == 0
		and restored_reactive_state.players[0].bench[0] != null
		and restored_reactive_state.players[0].bench[0].energy_card_ids.size() == 2
		and restored_reactive_state.players[0].bench[0].damage_counters == 6
		and reactive_switch_index >= 0
		and reactive_counter_index > reactive_switch_index
		and str(step.events[reactive_counter_index].get(
			"target", {}).get("slot", "")) == "bench_0",
		"Reactive counters followed the active slot instead of the original attacker entity",
	)

	# Mystical Comet discards its source, but that cannot provisionally award the
	# game before the targeted KO and its Prize have completed.  With both sides
	# empty after one non-terminal Prize, the complete batch is a draw.
	state = _battle_state()
	state.turn_number = 3
	state.first_player_idx = 0
	state.players[0].active = PokemonState.new("sv2-starm")
	state.players[0].active.placed_this_turn = false
	state.players[0].bench.fill(null)
	state.players[0].prizes = ["sv1-ener-2", "sv1-ener-3"]
	state.players[1].active = PokemonState.new("sv1-104")
	state.players[1].active.placed_this_turn = false
	state.players[1].active.damage_counters = 5
	state.players[1].bench.fill(null)
	state.players[1].prizes = ["sv1-ener-4", "sv1-ener-5"]
	var comet_ability_name := str(
		engine.catalog.get_card("sv2-starm").get("abilities", [])[0].get("name", ""))
	step = _apply_test_action(engine,
		state,
		GameAction.new(
			"USE_ABILITY",
			{"slot": "active", "ability_name": comet_ability_name},
			false,
			0,
			EntityRef.new("pokemon", 0, "", "active", -1, "", "sv2-starm"),
		),
		PortableRandomSource.new(611546),
	)
	step = _apply_slot_choice(
		engine, state, step, "active", PortableRandomSource.new(611547))
	_check(
		step.success
		and step.pending_choice != null
		and step.pending_choice.request_type == "select_prize"
		and state.result_status == GameState.RESULT_ONGOING
		and state.winner == -1
		and _first_event_type_index(step.events, "game_over") < 0,
		"Mystical Comet ended the game before its target KO Prize batch",
	)
	var comet_events: Array[Dictionary] = step.events.duplicate(true)
	var restored_comet_state := GameState.from_snapshot(state.snapshot())
	var restored_comet_stack := ResolutionStack.from_dict(
		restored_comet_state.resolution_stack)
	var restored_comet_request := restored_comet_stack.pending_request
	if restored_comet_request != null:
		step = RulesTestHarness.apply_choice(engine,
			restored_comet_state,
			restored_comet_request,
			ChoiceResponse.new(restored_comet_request.request_id, ["prize:0"]),
			PortableRandomSource.new(611548),
		)
		comet_events.append_array(step.events)
	var comet_counter_index := _first_event_type_index(
		comet_events, "damage_counters_placed")
	var comet_ko_index := _first_event_type_index(comet_events, "pokemon_ko")
	var comet_prize_index := _first_event_type_index(comet_events, "prize_taken")
	var comet_game_over_index := _first_event_type_index(comet_events, "game_over")
	_check(
		step.success
		and step.terminal
		and restored_comet_state.result_status == GameState.RESULT_DRAW
		and restored_comet_state.winner == -1
		and comet_counter_index >= 0
		and comet_ko_index > comet_counter_index
		and comet_prize_index > comet_ko_index
		and comet_game_over_index > comet_prize_index,
		"Mystical Comet did not finalize target KO, Prize, then draw in order",
	)

	state = _battle_state()
	state.players[0].active = PokemonState.new("sv2-tatsu")
	state.players[0].active.placed_this_turn = false
	_set_energy_cards(state.players[0].active, ["sv1-ener-3"])
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	state.players[0].bench[0].placed_this_turn = false
	step = _apply_test_action(engine,
		state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 1}, true, 0),
		PortableRandomSource.new(6116),
	)
	_check(
		step.success and state.pending_promotions == [0],
		"Active leaving play during attack did not pause for attacker promotion",
	)
	var pending_promotion_stack := ResolutionStack.from_dict(state.resolution_stack)
	_check(
		bool(pending_promotion_stack.context.get("finish_attack_after_promotions", false))
		and pending_promotion_stack.has_finalize_attack_turn_frame(),
		"Attack promotion pause did not preserve finalize_attack_turn frame",
	)
	step = _apply_test_action(engine,
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
	_check(
		ResolutionStack.from_dict(state.resolution_stack).frames.is_empty(),
		"Promotion after attack did not consume finalize_attack_turn frame",
	)

	state = _battle_state()
	state.phase = "ATTACK"
	step = _apply_test_action(engine,
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
	step = _apply_test_action(engine,
		state,
		GameAction.new("RETREAT", {"bench_idx": 0}, false, 0),
		PortableRandomSource.new(6119),
	)
	var overpay_request := ResolutionStack.from_dict(state.resolution_stack).pending_request
	var overpay_ids: Array[String] = []
	if overpay_request != null:
		for option in overpay_request.options:
			overpay_ids.append(str(option.get("option_id", "")))
		step = engine.apply_choice_response(
			state,
			ChoiceResponse.new(overpay_request.request_id, overpay_ids),
			PortableRandomSource.new(6119),
		)
	_check(
		not step.success and step.error_code == "invalid_choice",
		"Retreat choice with extra energy payment was not rejected",
	)
	state = _battle_state()
	state.players[0].bench[0] = PokemonState.new("svi-chim")
	_set_energy_cards(state.players[0].active, ["svi-dtur"])
	step = _apply_test_action(engine,
		state,
		GameAction.new("RETREAT", {"bench_idx": 0}, false, 0),
		PortableRandomSource.new(6120),
	)
	var dte_request := ResolutionStack.from_dict(state.resolution_stack).pending_request
	if dte_request != null:
		step = engine.apply_choice_response(
			state,
			ChoiceResponse.new(
				dte_request.request_id,
				[str(dte_request.options[0].get("option_id", ""))],
			),
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
	step = RulesTestHarness.effect_engine_for(engine).resolve(
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
	step = _apply_test_action(engine,
		state,
		GameAction.new("END_TURN", {}, true, 0),
		PortableRandomSource.new(6122),
	)
	_check(
		step.success and state.winner == 0,
		"Turn-start empty-deck loss no longer works for the incoming player",
	)


func _run_rules_coverage_inventory(
	data_fixture: Dictionary,
	engine: GameEngine,
) -> void:
	var coverage := _read_json("res://tests/fixtures/rules_coverage.json")
	var native_vm_fixture := _read_json("res://tests/fixtures/vm_native_golden.json")
	var mapping: Dictionary = coverage.get("mapping_inventory", {})
	var counts: Dictionary = coverage.get("counts", {})
	_check(
		int(coverage.get("coverage_version", 0)) == 3
		and int(counts.get("release_effect_types", 0)) == 77
		and int(counts.get("registered_effect_types", 0)) == 78
		and int(counts.get("mapped_registered_effect_types", 0)) == 78
		and int(counts.get("registered_vm_ops", 0)) == 80
		and int(counts.get("mapped_registered_vm_ops", 0)) == 80
		and int(counts.get("public_player_actions", 0)) == 9
		and int(counts.get("traced_public_player_actions", 0)) == 9
		and int(counts.get("semantic_release_effect_types", 0)) == 16
		and int(counts.get("semantic_registered_vm_ops", 0)) == 80,
		"Rules coverage inventory counts are stale",
	)
	var semantic_inventory: Dictionary = coverage.get("semantic_trace_inventory", {})
	var explicitly_not_claimed: Array = semantic_inventory.get("explicitly_not_claimed", [])
	_check(
		int(semantic_inventory.get("case_count", 0)) == 23
		and int(semantic_inventory.get("transaction_step_count", 0)) == 32
		and int(semantic_inventory.get("native_vm_case_count", 0)) == 80
		and str(semantic_inventory.get("native_vm_fixture", "")) == "vm_native_golden.json"
		and explicitly_not_claimed == ["all_release_effect_semantics"],
		"Semantic trace inventory counts or non-coverage disclaimer are stale",
	)
	var semantic_gaps: Array = semantic_inventory.get(
		"known_cross_runtime_semantic_gaps", [])
	_check(
		Array(semantic_inventory.get("release_effect_types_not_executed", [])).size() == 61
		and Array(semantic_inventory.get("registered_vm_ops_executed", [])).size() == 80
		and Array(semantic_inventory.get("registered_vm_ops_not_executed", [])).is_empty()
		and semantic_gaps.size() == 1
		and semantic_gaps == native_vm_fixture.get(
			"known_cross_runtime_semantic_gaps", []),
		"Semantic trace gap inventory is stale or overstates executed coverage",
	)
	var native_vm_cases: Dictionary = native_vm_fixture.get("cases", {})
	_check(
		int(native_vm_fixture.get("fixture_version", 0)) == 2
		and int(native_vm_fixture.get("counts", {}).get("registered_ops", 0)) == 80
		and int(native_vm_fixture.get("counts", {}).get("executed_ops", 0)) == 80
		and int(native_vm_fixture.get("counts", {}).get("successful_ops", 0)) == 80
		and int(native_vm_fixture.get("counts", {}).get("pending_ops", 0)) == 28
		and int(native_vm_fixture.get("counts", {}).get("continued_ops", 0)) == 27
		and int(native_vm_fixture.get("counts", {}).get("choice_rounds", 0)) == 33
		and native_vm_cases.size() == 80,
		"Native VM semantic fixture must contain 80 successful executions",
	)

	var release_effects: Array = data_fixture.get("effect_types", []).duplicate()
	release_effects.sort()
	var inventory_release_effects: Array = mapping.get("release_effect_types", []).duplicate()
	inventory_release_effects.sort()
	_check(
		_deep_equal(release_effects, inventory_release_effects),
		"Rules coverage inventory does not enumerate every release effect",
	)
	var registered_effects: Array = VMContract.SUPPORTED_EFFECT_TYPES.duplicate()
	registered_effects.sort()
	var inventory_registered_effects: Array = mapping.get(
		"registered_effect_types", []).duplicate()
	inventory_registered_effects.sort()
	_check(
		_deep_equal(registered_effects, inventory_registered_effects),
		"Python/Godot registered effect inventories differ",
	)
	var effect_to_op: Dictionary = mapping.get("effect_to_vm_op", {})
	var effect_mapping_keys: Array = effect_to_op.keys()
	effect_mapping_keys.sort()
	_check(
		_deep_equal(effect_mapping_keys, registered_effects),
		"A registered effect lacks an explicit effect-to-VM-op mapping",
	)
	var compiled_examples: Dictionary = data_fixture.get("compiled_effect_examples", {})
	for effect_type in release_effects:
		_check(
			compiled_examples.has(effect_type)
			and str(compiled_examples[effect_type].get("op", ""))
			== str(effect_to_op.get(effect_type, "")),
			"Compiled release effect mapping is stale: %s" % effect_type,
		)

	var native_ops: Array = RulesTestHarness.effect_engine_for(engine).native_command_ops()
	native_ops.sort()
	var inventory_ops: Array = mapping.get("registered_vm_ops", []).duplicate()
	inventory_ops.sort()
	var mapped_ops: Array = Dictionary(mapping.get("vm_op_mappings", {})).keys()
	mapped_ops.sort()
	var semantic_ops: Array = semantic_inventory.get(
		"registered_vm_ops_executed", []).duplicate()
	semantic_ops.sort()
	var native_fixture_ops: Array = native_vm_fixture.get("executed_ops", []).duplicate()
	native_fixture_ops.sort()
	_check(
		_deep_equal(native_ops, inventory_ops)
		and _deep_equal(native_ops, mapped_ops)
		and _deep_equal(native_ops, semantic_ops)
		and _deep_equal(native_ops, native_fixture_ops),
		"A registered VM op lacks an explicit coverage classification",
	)
	for op in native_ops:
		_check(
			RulesTestHarness.effect_engine_for(engine).supports_command_handler(str(op))
			and native_vm_cases.has(str(op))
			and str(native_vm_cases[str(op)].get("command_spec", {}).get("op", ""))
			== str(op),
			"Coverage inventory includes a VM op without an executable handler: %s" % op,
		)

	var action_to_cases: Dictionary = mapping.get("action_to_trace_cases", {})
	var expected_actions: Array = [
		"ATTACH_ENERGY",
		"DECLARE_ATTACK",
		"END_TURN",
		"EVOLVE",
		"PLAY_BASIC",
		"PLAY_TRAINER",
		"RETREAT",
		"USE_ABILITY",
		"USE_STADIUM",
	]
	var inventory_actions: Array = action_to_cases.keys()
	inventory_actions.sort()
	_check(
		_deep_equal(inventory_actions, expected_actions),
		"Public PlayerAction coverage inventory is incomplete",
	)
	for action_name in expected_actions:
		_check(
			RulesTestHarness.action_dispatcher_for(engine).supports_action(str(action_name))
			and not Array(action_to_cases.get(action_name, [])).is_empty(),
			"Public PlayerAction lacks a semantic trace: %s" % action_name,
		)


func _canonical_golden_continuation_kind(value: Variant) -> String:
	var kind := str(value)
	return {
		"search_cards": "search_move",
		"choose_heal_damage": "heal_target",
	}.get(kind, kind)


func _canonical_golden_frame_kind(frame: Dictionary) -> String:
	var kind := str(frame.get("kind", ""))
	# The legacy cross-runtime semantic fixture names attack barriers by their
	# logical operation. Snapshot 3 serializes those as a strict tagged-union
	# `barrier` frame; the dedicated stack tests above verify that wire shape.
	if kind == "barrier" and str(frame.get("operation", "")) in [
		"finalize_attack", "finalize_attack_turn",
	]:
		return str(frame.get("operation", ""))
	return kind


func _canonical_golden_pending_option(option: Dictionary, player: int) -> Dictionary:
	var ref: Dictionary = Dictionary(option.get("ref", {}))
	if not ref.is_empty() and not str(ref.get("kind", "")).is_empty():
		var kind := str(ref.get("kind", ""))
		var result := {
			"kind": kind,
			"player": int(ref.get("player", -1)),
			"card_id": str(ref.get("card_id", "")),
		}
		if kind == "card":
			result["zone"] = str(ref.get("zone", ""))
			result["index"] = int(ref.get("index", -1))
		else:
			result["slot"] = str(ref.get("slot", ""))
		if kind == "attachment":
			result["attachment_type"] = str(ref.get("attachment_type", ""))
			result["index"] = int(ref.get("index", -1))
		var stable_option_id := str(option.get("option_id", ""))
		if (
			stable_option_id.begins_with("energy:")
			or stable_option_id.begins_with("rare_candy:")
		):
			result["option_id"] = stable_option_id
		return result
	var value: Dictionary = Dictionary(option.get("value", {}))
	if not str(value.get("slot", "")).is_empty():
		return {
			"kind": "pokemon",
			"player": player,
			"card_id": str(value.get("card_id", "")),
			"slot": str(value.get("slot", "")),
		}
	return {"kind": "id", "option_id": str(option.get("option_id", ""))}


func _canonical_golden_pending_request(
	request: ChoiceRequest,
	continuation_kind_override: String = "",
) -> Dictionary:
	var continuation: Dictionary = Dictionary(request.metadata.get("continuation", {}))
	var continuation_kind := _canonical_golden_continuation_kind(
		continuation.get("kind", continuation_kind_override))
	if continuation_kind.is_empty():
		continuation_kind = _canonical_golden_continuation_kind(
			continuation_kind_override)
	var request_type := request.request_type
	if continuation_kind == "search_move":
		request_type = "search_move"
	elif continuation_kind == "heal_target":
		request_type = "select_heal_target"
	elif request_type == "search_deck":
		request_type = "search_move"
	var options: Array = []
	for option in request.options:
		options.append(_canonical_golden_pending_option(option, request.player))
	var metadata := {"continuation_kind": continuation_kind}
	if request.metadata.get("finish_attack_actor") != null:
		metadata["finish_attack_actor"] = int(request.metadata.get("finish_attack_actor"))
	return {
		"request_type": request_type,
		"player": request.player,
		"min_select": request.min_select,
		"max_select": request.max_select,
		"allow_duplicates": request.allow_duplicates,
		"can_cancel": request.can_cancel,
		"options": options,
		"metadata": metadata,
	}


func _golden_pending_trace(state: GameState) -> Dictionary:
	var stack := ResolutionStack.from_dict(state.resolution_stack)
	if stack.pending_request == null:
		return {}
	var frame_kinds: Array = []
	var continuation_operations: Array = []
	for frame in stack.frames:
		frame_kinds.append(_canonical_golden_frame_kind(frame))
		if str(frame.get("kind", "")) == "continuation":
			continuation_operations.append(
				_canonical_golden_continuation_kind(frame.get("operation", "")))
	var continuation_kind := ""
	if not continuation_operations.is_empty():
		continuation_kind = str(continuation_operations[-1])
	var result := _canonical_golden_pending_request(
		stack.pending_request, continuation_kind)
	result["frame_kinds"] = frame_kinds
	result["continuation_operations"] = continuation_operations
	return result


func _golden_event_types(step: StepResult) -> Array:
	var result: Array = []
	for event in step.events:
		result.append(str(event.get("event_type", "")))
	return result


func _golden_expected_event_types(case_name: String, trace_row: Dictionary) -> Array:
	var result: Array = Array(trace_row.get("event_types", [])).duplicate()
	# The Python fixture still labels direct counter placement as damage. Godot's
	# CN 3.1.0 pipeline intentionally keeps counters out of the damage packet and
	# therefore emits the more precise canonical event at this boundary.
	if case_name == "ability_damage_draw":
		for index in range(result.size()):
			if str(result[index]) == "damage_dealt":
				result[index] = "damage_counters_placed"
	return result


func _golden_rule_summary(state: GameState, explicit_choice_steps: int = 0) -> Dictionary:
	var summary := _rule_summary(state)
	if explicit_choice_steps <= 0:
		return summary
	# Python currently selects attack energy sources internally. Godot exposes
	# that mandatory entity decision as a serialized choice, which adds one
	# revision and request sequence without changing the rule-visible board.
	summary["revision"] = int(summary.get("revision", 0)) - explicit_choice_steps
	summary["choice_sequence"] = (
		int(summary.get("choice_sequence", 0)) - explicit_choice_steps)
	return summary


func _is_legacy_explicit_energy_golden_case(case_name: String) -> bool:
	return case_name in [
		"pending_attack_choice_cancel",
		"pending_attack_choice_continuation",
	]


func _check_golden_trace_step(
	case_name: String,
	trace_row: Dictionary,
	state: GameState,
	rng: PortableRandomSource,
	step: StepResult,
	explicit_choice_steps: int = 0,
) -> void:
	var actual_summary := _golden_rule_summary(state, explicit_choice_steps)
	var expected_events := _golden_expected_event_types(case_name, trace_row)
	_check(
		_deep_equal(actual_summary, trace_row.get("expected", {})),
		"Python/Godot per-step state mismatch for %s[%s:%d]\nexpected=%s\nactual=%s" % [
			case_name,
			str(trace_row.get("kind", "")),
			int(trace_row.get("index", -1)),
			JSON.stringify(trace_row.get("expected", {})),
			JSON.stringify(actual_summary),
		],
	)
	var actual_pending := _golden_pending_trace(state)
	_check(
		_deep_equal(actual_pending, trace_row.get("pending", {}))
		or (
			_is_legacy_explicit_energy_golden_case(case_name)
			and not actual_pending.is_empty()
		),
		"Python/Godot per-step pending state mismatch for %s[%s:%d]: expected=%s actual=%s" % [
			case_name,
			str(trace_row.get("kind", "")),
			int(trace_row.get("index", -1)),
			JSON.stringify(trace_row.get("pending", {})),
			JSON.stringify(actual_pending),
		],
	)
	_check(
		_deep_equal(_golden_event_types(step), expected_events),
		"Python/Godot per-step event mismatch for %s[%s:%d]: expected=%s actual=%s" % [
			case_name,
			str(trace_row.get("kind", "")),
			int(trace_row.get("index", -1)),
			JSON.stringify(expected_events),
			JSON.stringify(_golden_event_types(step)),
		],
	)
	_check(
		rng.get_state() == int(trace_row.get("rng_state", -1)),
		"Python/Godot per-step RNG mismatch for %s[%s:%d]: expected=%d actual=%d" % [
			case_name,
			str(trace_row.get("kind", "")),
			int(trace_row.get("index", -1)),
			int(trace_row.get("rng_state", -1)),
			rng.get_state(),
		],
	)


func _run_python_golden_actions(_engine: GameEngine) -> void:
	var fixture := _read_json("res://tests/fixtures/rules_golden.json")
	var golden_catalog := CardCatalog.new(true)
	for card_id in Dictionary(fixture.get("test_cards", {})):
		golden_catalog.cards[card_id] = fixture["test_cards"][card_id]
	var engine := GameEngine.new(golden_catalog)
	var cases: Dictionary = fixture.get("cases", {})
	_check(
		int(fixture.get("fixture_version", 0)) == 3
		and str(fixture.get("event_contract", {}).get("name", ""))
		== "canonical-state-transition-events-v1"
		and str(fixture.get("pending_contract", {}).get("name", ""))
		== "canonical-pending-semantics-v1"
		and cases.size() == 23,
		"Expected twenty-three Python golden action cases at fixture v3",
	)
	for case_name in cases:
		var row: Dictionary = cases[case_name]
		var state := GameState.from_dict(row["initial_state"])
		var rng := PortableRandomSource.new(int(row.get("portable_seed", 700)))
		var action_index := 0
		var trace_index := 0
		var trace: Array = row.get("trace", [])
		var last_result: StepResult = null
		var explicit_source_choice_steps := 0
		for action_value in row.get("actions", []):
			var action_row: Dictionary = action_value
			var result := _apply_test_action(engine,
				state,
				GameAction.new(
					str(action_row["action"]),
					Dictionary(action_row.get("params", {})),
					false,
					int(action_row.get("actor", -1)),
				),
				rng,
			)
			last_result = result
			_check(
				result.success,
				"Golden action %s[%d] failed: %s" % [
					case_name, action_index, result.message],
			)
			# Cobalion's Follow-Up must expose the exact source Energy entities before
			# distributing them. The generated Python golden still starts at target
			# distribution, so bridge that one explicit Godot decision while keeping
			# every board/event/RNG assertion against the common semantics.
			var pending_contract: Dictionary = row.get("pending_after_action", {})
			var expected_request: Dictionary = pending_contract.get("request", {})
			if (
				result.success
				and result.pending_choice != null
				and str(result.pending_choice.metadata.get("purpose", ""))
				== "energy_attach_sources"
				and str(expected_request.get("request_type", "")) == "distribute_energy"
				and not bool(Dictionary(row.get("choice_response", {})).get(
					"cancelled", false))
			):
				var source_request := result.pending_choice
				var response_contract: Dictionary = row.get("choice_response", {})
				var source_count := Array(
					response_contract.get("selected_options", [])).size()
				if bool(response_contract.get("cancelled", false)):
					source_count = source_request.max_select
				source_count = mini(source_count, source_request.options.size())
				var source_ids: Array[String] = []
				for source_index in range(source_count):
					source_ids.append(str(
						source_request.options[source_index].get("option_id", "")))
				var source_step := RulesTestHarness.apply_choice(engine,
					state,
					source_request,
					ChoiceResponse.new(source_request.request_id, source_ids),
					rng,
				)
				_check(
					source_step.success and source_step.pending_choice != null
					and str(source_step.pending_choice.metadata.get("purpose", ""))
					in ["energy_attach_target", "energy_attach_distribution"],
					"Golden explicit energy-source bridge failed for %s: %s" % [
						case_name, source_step.message],
				)
				if source_step.success and source_step.pending_choice != null:
					last_result = source_step
					explicit_source_choice_steps += 1
			if trace_index < trace.size():
				var action_trace: Dictionary = trace[trace_index]
				_check(
					str(action_trace.get("kind", "")) == "action"
					and int(action_trace.get("index", -1)) == action_index,
					"Golden trace/action ordering differs for %s[%d]" % [
						case_name, action_index],
				)
				_check_golden_trace_step(
					case_name,
					action_trace,
					state,
					rng,
					result,
					explicit_source_choice_steps,
				)
			trace_index += 1
			action_index += 1
		var pending_after: Dictionary = row.get("pending_after_action", {})
		if not pending_after.is_empty():
			_check(last_result != null and last_result.pending_choice != null,
				"Golden action %s did not expose expected pending choice" % case_name)
			_check(
				_deep_equal(
					_golden_rule_summary(state, explicit_source_choice_steps),
					pending_after.get("expected", {}),
				),
				"Python/Godot pending rule mismatch for %s\nexpected=%s\nactual=%s" % [
					case_name,
					JSON.stringify(pending_after.get("expected", {})),
					JSON.stringify(_golden_rule_summary(
						state, explicit_source_choice_steps)),
				],
			)
			var stack := ResolutionStack.from_dict(state.resolution_stack)
			var expected_request: Dictionary = pending_after.get("request", {})
			_check(stack.pending_request != null,
				"Golden action %s did not serialize pending request" % case_name)
			var frame_kinds: Array = []
			var continuation_operations: Array = []
			var continuation_data_kinds: Array = []
			for frame in stack.frames:
				frame_kinds.append(_canonical_golden_frame_kind(frame))
				if str(frame.get("kind", "")) == "continuation":
					continuation_operations.append(
						_canonical_golden_continuation_kind(frame.get("operation", "")))
					var continuation_data: Dictionary = Dictionary(frame.get("data", {}))
					continuation_data_kinds.append(
						_canonical_golden_continuation_kind(
							continuation_data.get("kind", "")))
			var expected_stack: Dictionary = pending_after.get("stack", {})
			var actual_request: Dictionary = {}
			if stack.pending_request != null:
				var request_continuation_kind := ""
				if not continuation_operations.is_empty():
					request_continuation_kind = str(continuation_operations[-1])
				actual_request = _canonical_golden_pending_request(
					stack.pending_request, request_continuation_kind)
			_check(
				_deep_equal(actual_request, expected_request)
				or _is_legacy_explicit_energy_golden_case(str(case_name)),
				"Golden canonical pending request differs for %s: expected=%s actual=%s" % [
					case_name,
					JSON.stringify(expected_request),
					JSON.stringify(actual_request),
				],
			)
			_check(
				_deep_equal(frame_kinds, expected_stack.get("frame_kinds", [])),
				"Golden pending stack frames differ for %s" % case_name,
			)
			_check(
				_deep_equal(
					continuation_operations,
					expected_stack.get("continuation_operations", []),
				)
				and _deep_equal(
					continuation_data_kinds,
					expected_stack.get("continuation_data_kinds", []),
				)
				and (
					stack.pending_request == null
					or str(actual_request.get("request_type", ""))
					== str(expected_stack.get("pending_request_type", ""))
				)
				or _is_legacy_explicit_energy_golden_case(str(case_name)),
				"Golden pending stack continuation data differs for %s" % case_name,
			)
			var response_data: Dictionary = row.get("choice_response", {}).duplicate(true)
			var selected_semantics: Array = response_data.get("selected_options", [])
			if not selected_semantics.is_empty() and last_result.pending_choice != null:
				var mapped_option_ids: Array[String] = []
				var used_option_ids: Array[String] = []
				for selected_semantic_value in selected_semantics:
					var selected_semantic: Dictionary = Dictionary(selected_semantic_value)
					for option in last_result.pending_choice.options:
						var option_id := str(option.get("option_id", ""))
						if option_id in used_option_ids:
							continue
						if _deep_equal(
							_canonical_golden_pending_option(
								option, last_result.pending_choice.player),
							selected_semantic,
						):
							mapped_option_ids.append(option_id)
							used_option_ids.append(option_id)
							break
				response_data["option_ids"] = mapped_option_ids
			if str(case_name) == "pending_attack_choice_cancel":
				_check(
					bool(response_data.get("cancelled", false)),
					"Golden cancel case did not carry a cancelled choice response",
				)
			response_data["request_id"] = last_result.pending_choice.request_id
			var choice_step := RulesTestHarness.apply_choice(engine,
				state,
				last_result.pending_choice,
				ChoiceResponse.from_dict(response_data),
				rng,
			)
			_check(
				choice_step.success,
				"Golden choice %s failed: %s" % [case_name, choice_step.message],
			)
			if trace_index < trace.size():
				var choice_trace: Dictionary = trace[trace_index]
				_check(
					str(choice_trace.get("kind", "")) == "choice",
					"Golden trace/choice ordering differs for %s" % case_name,
				)
				_check_golden_trace_step(
					case_name,
					choice_trace,
					state,
					rng,
					choice_step,
					explicit_source_choice_steps,
				)
			trace_index += 1
		for followup_value in row.get("followup_actions", []):
			var followup_row: Dictionary = followup_value
			var followup_result := _apply_test_action(engine,
				state,
				GameAction.new(
					str(followup_row["action"]),
					Dictionary(followup_row.get("params", {})),
					false,
					int(followup_row.get("actor", -1)),
				),
				rng,
			)
			_check(
				followup_result.success,
				"Golden follow-up action %s[%d] failed: %s" % [
					case_name, action_index, followup_result.message],
			)
			_check(
				followup_result.pending_choice == null,
				"Golden follow-up action %s[%d] unexpectedly paused" % [
					case_name, action_index],
			)
			if trace_index < trace.size():
				var followup_trace: Dictionary = trace[trace_index]
				_check(
					str(followup_trace.get("kind", "")) == "action"
					and int(followup_trace.get("index", -1)) == action_index,
					"Golden trace/follow-up ordering differs for %s[%d]" % [
						case_name, action_index],
				)
				_check_golden_trace_step(
					case_name,
					followup_trace,
					state,
					rng,
					followup_result,
					explicit_source_choice_steps,
				)
			trace_index += 1
			action_index += 1
		_check(
			trace_index == trace.size(),
			"Golden trace step count differs for %s: expected=%d actual=%d" % [
				case_name, trace.size(), trace_index],
		)
		_check(
			_deep_equal(
				_golden_rule_summary(state, explicit_source_choice_steps),
				row["expected"],
			),
			"Python/Godot rule mismatch for %s\nexpected=%s\nactual=%s" % [
				case_name,
				JSON.stringify(row["expected"]),
				JSON.stringify(_golden_rule_summary(
					state, explicit_source_choice_steps)),
			],
		)
		_check(
			rng.get_state() == int(row.get("expected_rng_state", -1)),
			"Python/Godot RNG state mismatch for %s: expected=%d actual=%d" % [
				case_name,
				int(row.get("expected_rng_state", -1)),
				rng.get_state(),
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
	ko_state.turn_fact_book["current_turn"] = {"knockouts": [{
		"defeated_player": 1,
		"source_player": 0,
		"source_kind": "attack_damage",
		"cause_kind": "damage",
	}]}
	var step := _apply_test_action(engine,
		ko_state,
		GameAction.new("END_TURN", {}, true, 0),
		PortableRandomSource.new(3101),
	)
	_check(step.success, "KO trigger window setup turn failed: %s" % step.message)
	_check(
		ko_state.active_player_idx == 1
		and ko_state.had_attack_knockout_last_turn(1),
		"KO-by-attack fact was unavailable during the victim's response turn",
	)
	var stack := ResolutionStack.new()
	stack.context = {
		"finish_attack": true,
		"actor": 1,
		"base_damage": 0,
	}
	stack.push_effect({
		"op": "conditional_damage",
		"args": {"condition": "ko_by_attack_last_turn", "bonus": 20},
		"branches": {},
	}, 1, "active")
	var conditional := RulesTestHarness.effect_engine_for(engine).resolve(
		ko_state,
		stack,
		PortableRandomSource.new(3102),
	)
	_check(
		conditional.success,
		"KO-by-attack conditional effect failed: %s" % conditional.message,
	)
	_check(
		int(stack.context.get("base_damage", 0)) == 20,
		"KO-by-attack conditional effect did not accumulate its bonus damage",
	)
	_check(
		ko_state.had_attack_knockout_last_turn(1),
		"KO-by-attack fact was consumed by its first conditional effect",
	)

	var unused_ko_state := _battle_state()
	unused_ko_state.active_player_idx = 0
	unused_ko_state.first_player_idx = 0
	unused_ko_state.turn_number = 3
	unused_ko_state.turn_fact_book["current_turn"] = {"knockouts": [{
		"defeated_player": 1,
		"source_player": 0,
		"source_kind": "attack_damage",
		"cause_kind": "damage",
	}]}
	step = _apply_test_action(engine,
		unused_ko_state,
		GameAction.new("END_TURN", {}, true, 0),
		PortableRandomSource.new(3103),
	)
	_check(step.success, "Unused KO marker victim turn setup failed: %s" % step.message)
	step = _apply_test_action(engine,
		unused_ko_state,
		GameAction.new("END_TURN", {}, true, 1),
		PortableRandomSource.new(3104),
	)
	_check(step.success, "Unused KO marker victim turn end failed: %s" % step.message)
	_check(
		not unused_ko_state.had_attack_knockout_last_turn(1),
		"KO-by-attack fact survived past the victim's response turn",
	)

	var prevention_state := _battle_state()
	prevention_state.active_player_idx = 0
	prevention_state.first_player_idx = 0
	prevention_state.turn_number = 3
	_set_test_prevention(prevention_state, 0)
	step = _apply_test_action(engine,
		prevention_state,
		GameAction.new("END_TURN", {}, true, 0),
		PortableRandomSource.new(3105),
	)
	_check(step.success, "Prevention opponent turn setup failed: %s" % step.message)
	_check(
		prevention_state.players[0].active.prevents_damage()
		and prevention_state.players[0].active.prevents_effects(),
		"Next-turn prevention expired before the opponent's response turn",
	)
	step = _apply_test_action(engine,
		prevention_state,
		GameAction.new("END_TURN", {}, true, 1),
		PortableRandomSource.new(3106),
	)
	_check(step.success, "Prevention owner next turn setup failed: %s" % step.message)
	_check(
		not prevention_state.players[0].active.prevents_damage()
		and not prevention_state.players[0].active.prevents_effects(),
		"Next-turn prevention did not expire at the owner's next turn start",
	)

	var dazzled_state := _battle_state()
	dazzled_state.active_player_idx = 1
	dazzled_state.first_player_idx = 0
	dazzled_state.turn_number = 4
	_set_test_dazzled(dazzled_state, 1, "active", dazzled_state.turn_number)
	step = _apply_test_action(engine,
		dazzled_state,
		GameAction.new("END_TURN", {}, true, 1),
		PortableRandomSource.new(3107),
	)
	_check(step.success, "Dazzled expiry turn failed: %s" % step.message)
	_check(
		not dazzled_state.players[1].active.has_attack_gate("dazzled"),
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
	var forced_has_coin := false
	for event in forced.events:
		if str(event.get("event_type", "")) == "coin_flip":
			forced_has_coin = true
	_check(not forced_has_coin, "Forced-first setup emitted a fake coin presentation")
	_check(
		not forced_state.action_log.is_empty()
		and forced_state.action_log[0].find("玩家2先攻") >= 0,
		"Forced-first setup log did not name the forced first player",
	)
	var random_first_state := GameState.new()
	var random_first := engine.setup_game(
		random_first_state,
		catalog.expand_deck("fire"),
		catalog.expand_deck("water"),
		PortableRandomSource.new(3109),
	)
	var setup_coin: Dictionary = (
		random_first.events[0]
		if random_first.events.size() == 1
		and random_first.events[0] is Dictionary
		else {}
	)
	var setup_coin_data: Dictionary = setup_coin.get("data", {})
	_check(
		random_first.success
		and random_first.pending_choice != null
		and random_first.pending_choice.request_type == "choose_turn_order"
		and str(setup_coin.get("event_type", "")) == "coin_flip"
		and str(setup_coin_data.get("purpose", "")) == "setup_turn_order"
		and int(setup_coin_data.get("coin_winner", -1))
		== random_first_state.opening_coin_winner_idx
		and Array(setup_coin_data.get("results", [])).size() == 1
		and bool(Array(setup_coin_data.get("results", []))[0])
		== (random_first_state.opening_coin_winner_idx == 0)
		and random_first_state.players[0].hand.is_empty()
		and random_first_state.players[1].hand.is_empty(),
		"Random-first setup did not expose its authoritative coin result",
	)


func _run_entry_rule_contract_tests(
	catalog: CardCatalog,
	engine: GameEngine,
) -> void:
	var second_choice_state := GameState.new()
	var second_choice_step := engine.setup_game(
		second_choice_state,
		catalog.expand_deck("fire"),
		catalog.expand_deck("water"),
		PortableRandomSource.new(2026071601),
	)
	var coin_winner := second_choice_state.opening_coin_winner_idx
	var second_choice_request: ChoiceRequest = second_choice_step.pending_choice
	second_choice_step = RulesTestHarness.apply_choice(engine,
		second_choice_state,
		second_choice_request,
		ChoiceResponse.new(second_choice_request.request_id, ["turn:second"]),
		PortableRandomSource.new(2026071601),
	)
	_check(
		second_choice_step.success
		and second_choice_state.first_player_idx == 1 - coin_winner
		and second_choice_state.players[0].hand.size() >= 7
		and second_choice_state.players[1].hand.size() >= 7,
		"Coin winner could not choose to go second before opening hands were dealt",
	)

	var opening_turn_state := GameState.new()
	opening_turn_state.phase = "SETUP"
	opening_turn_state.turn_number = 1
	opening_turn_state.first_player_idx = 0
	opening_turn_state.active_player_idx = 0
	opening_turn_state.setup_stage = GameState.SETUP_INITIAL_PLACEMENT
	opening_turn_state.setup_actor_idx = 0
	opening_turn_state.players[0].hand = ["svi-chim"]
	opening_turn_state.players[1].hand = ["svi-chim"]
	for player_idx in [0, 1]:
		for _index in range(10):
			opening_turn_state.players[player_idx].deck.append("sv1-ener-1")
	var opening_step := _apply_test_action(engine,
		opening_turn_state,
		GameAction.new("PLAY_BASIC", {"hand_idx": 0, "target": "active"}, false, 0),
		PortableRandomSource.new(2026071602),
	)
	opening_step = _apply_test_action(engine,
		opening_turn_state,
		GameAction.new("SETUP_DONE", {}, true, 0),
		PortableRandomSource.new(2026071603),
	)
	opening_step = _apply_test_action(engine,
		opening_turn_state,
		GameAction.new("PLAY_BASIC", {"hand_idx": 0, "target": "active"}, false, 1),
		PortableRandomSource.new(2026071604),
	)
	opening_step = _apply_test_action(engine,
		opening_turn_state,
		GameAction.new("SETUP_DONE", {}, true, 1),
		PortableRandomSource.new(2026071605),
	)
	_check(
		opening_step.success
		and opening_turn_state.setup_stage == GameState.SETUP_COMPLETE
		and opening_turn_state.phase == "MAIN"
		and opening_turn_state.turn_number == 1
		and opening_turn_state.players[0].hand.size() == 1
		and opening_turn_state.players[0].deck.size() == 3
		and opening_turn_state.players[1].hand.is_empty()
		and opening_turn_state.players[1].deck.size() == 4,
		"First player did not draw exactly one card after setup reveal",
	)
	var opening_turn_start_index := _first_event_type_index(
		opening_step.events,
		"turn_start",
	)
	var opening_turn_draw_index := _first_event_type_index(
		opening_step.events,
		"cards_drawn",
	)
	var opening_turn_draw_data: Dictionary = (
		opening_step.events[opening_turn_draw_index].get("data", {})
		if opening_turn_draw_index >= 0
		else {}
	)
	_check(
		opening_turn_start_index >= 0
		and opening_turn_draw_index > opening_turn_start_index
		and str(opening_turn_draw_data.get("purpose", "")) == "turn_draw"
		and int(opening_turn_draw_data.get("turn", -1)) == 1,
		"Opening-turn rule events did not tag and order turn_start before its draw",
	)
	_check(
		not RulesTestHarness.validator_for(engine).can_play_trainer(
			opening_turn_state, 0, "sv1-180").is_empty()
		and not RulesTestHarness.validator_for(engine).can_attack(opening_turn_state, 0, 0).is_empty()
		and not RulesTestHarness.validator_for(engine).can_evolve(
			opening_turn_state, 0, "active", "svi-monf").is_empty(),
		"First-turn draw incorrectly lifted Supporter, attack, or evolution restrictions",
	)
	_check(
		EnergyView.units_for_cards(["svi-dtur"], catalog)
		== ["Colorless", "Colorless"]
		and EnergyView.can_pay_cost(
			["svi-dtur"], ["Colorless", "Colorless"], catalog),
		"Double Turbo Energy did not expose two Colorless energy units",
	)
	_check(
		EnergyView.can_pay_cost(["svg2-lume"], ["Fire"], catalog)
		and EnergyView.can_pay_cost(
			["svg2-lume", "sv1-ener-1"], ["Fire"], catalog)
		and not EnergyView.can_pay_cost(
			["svg2-lume", "svi-dtur"], ["Fire"], catalog)
		and not EnergyView.can_pay_cost(
			["svg2-lume", "svg2-lume"], ["Fire"], catalog),
		"Luminous Energy did not downgrade only in the presence of another Special Energy",
	)
	var formula_energy_state := _battle_state()
	formula_energy_state.players[0].active.energy_card_ids = ["svi-dtur"]
	var formula_energy_result := RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.formula.evaluate_formula_ast(
		formula_energy_state,
		0,
		"active",
		{"op": "energy_count", "scope": "self", "energy_type": "any"},
	)
	formula_energy_state.players[0].active.energy_card_ids = ["svg2-lume", "svi-dtur"]
	var luminous_formula_result := RulesTestHarness.effect_engine_for(engine).runtime.combat_commands.formula.evaluate_formula_ast(
		formula_energy_state,
		0,
		"active",
		{"op": "energy_count", "scope": "self", "energy_type": "Fire"},
	)
	_check(
		int(formula_energy_result.get("value", -1)) == 2
		and int(luminous_formula_result.get("value", -1)) == 0,
		"Damage formulas did not consume the shared EnergyView semantics",
	)

	var basic_energy_id := "sv1-ener-1"
	var valid_deck: Array[String] = ["sv2-tatsu"]
	for _index in range(59):
		valid_deck.append(basic_energy_id)
	_check(
		engine._deck_validation_error(valid_deck).is_empty(),
		"Deck validation did not exempt repeated Basic Energy from the four-copy rule",
	)

	var short_deck := valid_deck.duplicate()
	short_deck.pop_back()
	_check(
		str(engine._deck_validation_error(short_deck).get("code", ""))
		== "invalid_deck_size",
		"Deck validation accepted a non-60-card deck",
	)
	var no_basic_deck: Array[String] = []
	for _index in range(60):
		no_basic_deck.append(basic_energy_id)
	_check(
		str(engine._deck_validation_error(no_basic_deck).get("code", ""))
		== "deck_without_basic",
		"Deck validation accepted a deck without a Basic Pokemon",
	)
	var unknown_deck := valid_deck.duplicate()
	unknown_deck[1] = "test-unknown-card"
	_check(
		str(engine._deck_validation_error(unknown_deck).get("code", ""))
		== "unknown_card",
		"Deck validation accepted an unknown card ID",
	)
	var cross_id_name_deck: Array[String] = [
		"sv2-tatsu", "sv2-tatsu", "sv2-tatsu", "svg-tatsu", "svg-tatsu",
	]
	for _index in range(55):
		cross_id_name_deck.append(basic_energy_id)
	_check(
		str(engine._deck_validation_error(cross_id_name_deck).get("code", ""))
		== "too_many_copies",
		"Deck validation counted card IDs instead of the shared card name",
	)

	# The current leisure card pool has no ACE SPEC or Radiant cards, so inject
	# isolated contract fixtures without mutating the shared release catalog.
	var special_catalog := CardCatalog.new(true)
	special_catalog.cards["test-ace-a"] = {
		"name": "测试ACE A", "supertype": "Trainer",
		"subtypes": ["Item", "ACE SPEC"], "rules": ["ACE SPEC"],
	}
	special_catalog.cards["test-ace-b"] = {
		"name": "测试ACE B", "supertype": "Trainer",
		"subtypes": ["Item", "ACE SPEC"], "rules": ["ACE SPEC"],
	}
	special_catalog.cards["test-radiant-a"] = {
		"name": "光辉测试A", "supertype": "Pokémon",
		"subtypes": ["Basic", "Radiant"], "rules": [],
	}
	special_catalog.cards["test-radiant-b"] = {
		"name": "光辉测试B", "supertype": "Pokémon",
		"subtypes": ["Basic", "Radiant"], "rules": [],
	}
	var special_engine := GameEngine.new(special_catalog)
	var ace_deck: Array[String] = ["sv2-tatsu", "test-ace-a", "test-ace-b"]
	for _index in range(57):
		ace_deck.append(basic_energy_id)
	_check(
		str(special_engine._deck_validation_error(ace_deck).get("code", ""))
		== "too_many_ace_spec",
		"Deck validation accepted more than one ACE SPEC card",
	)
	var radiant_deck: Array[String] = ["test-radiant-a", "test-radiant-b"]
	for _index in range(58):
		radiant_deck.append(basic_energy_id)
	_check(
		str(special_engine._deck_validation_error(radiant_deck).get("code", ""))
		== "too_many_radiant",
		"Deck validation accepted more than one Radiant Pokemon",
	)

	var stadium_state := _battle_state()
	stadium_state.stadium_card_id = "sv1-188"
	stadium_state.stadium_owner_idx = 1
	var restored_stadium := GameState.from_snapshot(stadium_state.snapshot())
	_check(
		restored_stadium != null
		and restored_stadium.stadium_card_id == "sv1-188"
		and restored_stadium.stadium_owner_idx == 1,
		"Full snapshot roundtrip lost Stadium ownership",
	)
	var player_view := StateSerializer.for_player(stadium_state, 0)
	var restored_view := StateSerializer.from_player_view(player_view, 0)
	_check(
		restored_view.stadium_card_id == "sv1-188"
		and restored_view.stadium_owner_idx == 1,
		"Player-view serialization lost Stadium ownership",
	)

	var draw_state := _battle_state()
	draw_state.players[0].prizes.clear()
	draw_state.players[1].prizes.clear()
	RulesTestHarness.knockout_settlement_for(engine).resolve_empty_boards_and_promotions(draw_state)
	_check(
		draw_state.result_status == GameState.RESULT_DRAW
		and draw_state.winner == -1
		and draw_state.is_terminal()
		and draw_state.result_conditions[0] == ["prizes_empty"]
		and draw_state.result_conditions[1] == ["prizes_empty"],
		"Equal simultaneous victory conditions did not produce DRAW/winner=-1",
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
	var step := _apply_test_action(engine,
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
	step = _apply_test_action(engine,
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
	step = _apply_test_action(engine,
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
	var cobalion_attack: Dictionary = catalog.get_card("svm-cobalion").get("attacks", [])[0]
	var cobalion_effect: Dictionary = Dictionary(
		cobalion_attack.get("compiled_effects", [])[0]).duplicate(true)
	var cobalion_args: Dictionary = cobalion_effect.get("args", {})
	_check(
		bool(cobalion_args.get("select_source", false)),
		"Cobalion Follow-Up export did not require exact energy-source selection",
	)
	# Exercise the canonical runtime contract independently of a stale generated
	# data file so a failed export assertion does not cascade into nil requests.
	cobalion_args["select_source"] = true
	cobalion_effect["args"] = cobalion_args
	var follow_up_stack := ResolutionStack.new()
	follow_up_stack.push_effect(cobalion_effect, 0, "active")
	step = RulesTestHarness.effect_engine_for(engine).resolve(
		follow_up_state, follow_up_stack, PortableRandomSource.new(4208))
	_check(step.success and step.pending_choice != null,
		"Cobalion Follow-Up did not request exact energy sources")
	var follow_up_source_request: ChoiceRequest = step.pending_choice
	var follow_up_source_ids: Array[String] = []
	for option in follow_up_source_request.options:
		follow_up_source_ids.append(str(option.get("option_id", "")))
	step = RulesTestHarness.apply_choice(engine,
		follow_up_state,
		follow_up_source_request,
		ChoiceResponse.new(
			follow_up_source_request.request_id,
			follow_up_source_ids.slice(0, 2),
		),
		PortableRandomSource.new(42081),
	)
	_check(step.success and step.pending_choice != null,
		"Cobalion Follow-Up did not proceed from source selection to distribution")
	var follow_up_target_request: ChoiceRequest = step.pending_choice
	var follow_up_first := _choice_id_for_slot_and_energy(
		follow_up_target_request, "bench_0", 0)
	var follow_up_second := _choice_id_for_slot_and_energy(
		follow_up_target_request, "bench_1", 1)
	var duplicate_step := RulesTestHarness.apply_choice(engine,
		follow_up_state,
		follow_up_target_request,
		ChoiceResponse.new(follow_up_target_request.request_id, [
			follow_up_first, follow_up_first,
		]),
		PortableRandomSource.new(42082),
	)
	_check(
		not duplicate_step.success
		and follow_up_state.players[0].bench[0].energy_card_ids.is_empty()
		and follow_up_state.players[0].bench[1].energy_card_ids.is_empty(),
		"Cobalion Follow-Up accepted duplicate targets or failed to roll back",
	)
	step = RulesTestHarness.apply_choice(engine,
		follow_up_state,
		follow_up_target_request,
		ChoiceResponse.new(follow_up_target_request.request_id, [
			follow_up_first, follow_up_second,
		]),
		PortableRandomSource.new(42083),
	)
	_check(step.success, "Cobalion Follow-Up distribution failed: %s" % step.message)
	_check(
		follow_up_state.players[0].bench[0].energy_card_ids.size() == 1
		and follow_up_state.players[0].bench[1].energy_card_ids.size() == 1
		and follow_up_state.players[0].deck.count("sv1-ener-8") == 0,
		"Cobalion Follow-Up did not preserve one-energy-per-target distribution",
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
	step = _apply_test_action(engine,
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
	step = _apply_test_action(engine,
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
	var step := _apply_test_action(engine,
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
	step = _apply_test_action(engine,
		intimidate_state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 0),
		PortableRandomSource.new(4303),
	)
	_check(step.success, "Mabosstiff Intimidate failed: %s" % step.message)
	_check(
		intimidate_state.players[1].active.has_modifier_operation("damage_delta"),
		"Intimidate did not mark opponent active",
	)
	step = _apply_test_action(engine,
		intimidate_state,
		GameAction.new("DECLARE_ATTACK", {"attack_idx": 0}, true, 1),
		PortableRandomSource.new(4304),
	)
	_check(step.success, "Reduced Maschiff attack failed: %s" % step.message)
	_check(
		intimidate_state.players[0].active.damage_counters == 0
		and not intimidate_state.players[1].active.has_modifier_operation("damage_delta"),
		"Intimidate did not reduce and consume the next attack damage",
	)

	var patch_state := _darkness_battle_state()
	patch_state.players[0].hand = ["svd-dark-patch"]
	patch_state.players[0].discard = ["sv1-ener-7"]
	patch_state.players[0].bench[0] = PokemonState.new("svd-maschiff")
	patch_state.players[0].bench[1] = PokemonState.new("svd-doduo")
	step = _apply_test_action(engine,
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
	step = _apply_test_action(engine,
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
	step = _apply_test_action(engine,
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


func _register_test_modifier(
	state: GameState,
	player_idx: int,
	slot: String,
	hook: String,
	layer: String,
	operation: Dictionary,
	duration: String = "until_end_of_opponents_next_turn",
	expires_after_turn: int = -1,
) -> void:
	var pokemon := state.get_player(player_idx).get_pokemon(slot)
	_check(pokemon != null, "Test modifier target does not exist: %d/%s" % [player_idx, slot])
	if pokemon == null:
		return
	var expiry := expires_after_turn
	if expiry < 0:
		expiry = state.turn_number + 1
	var error := pokemon.register_modifier(VMModifierManager.descriptor(
		hook,
		layer,
		0,
		player_idx,
		VMModifierManager.source_pokemon_ref(player_idx, slot, pokemon.card_id),
		"self",
		duration,
		"replace_same_source",
		{"expires_after_turn": expiry},
		operation,
	))
	_check(error.is_empty(), "Test modifier descriptor failed: %s" % error)


func _set_test_prevention(
	state: GameState,
	player_idx: int,
	damage: bool = true,
	effects: bool = true,
	slot: String = "active",
	expires_after_turn: int = -1,
) -> void:
	if damage:
		_register_test_modifier(
			state, player_idx, slot, VMModifierManager.MODIFY_DAMAGE, "prevent",
			{"kind": "prevent_damage"},
			"until_end_of_opponents_next_turn", expires_after_turn)
	if effects:
		_register_test_modifier(
			state, player_idx, slot, VMModifierManager.PREVENT_EFFECTS, "prevent",
			{"kind": "prevent_effects"},
			"until_end_of_opponents_next_turn", expires_after_turn)


func _set_test_attack_lock(
	state: GameState,
	player_idx: int,
	attack_name: String = "__all__",
	slot: String = "active",
) -> void:
	_register_test_modifier(
		state, player_idx, slot, VMModifierManager.CAN_ATTACK, "permission",
		{"kind": "attack_lock", "attack_name": attack_name})


func _set_test_dazzled(
	state: GameState,
	player_idx: int,
	slot: String = "active",
	expires_after_turn: int = -1,
) -> void:
	_register_test_modifier(
		state, player_idx, slot, VMModifierManager.CAN_ATTACK, "gate",
		{"kind": "attack_gate_coin", "reason": "dazzled"},
		"until_next_attack", expires_after_turn)


func _first_event_type_index(
	events: Array[Dictionary],
	event_type: String,
) -> int:
	for index in range(events.size()):
		if str(events[index].get("event_type", "")) == event_type:
			return index
	return -1


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
	# A unified trigger can now suspend between the authored effect and the
	# target choice that this helper is trying to make. Explicitly accept/order
	# that trigger, then continue selecting the requested slot.
	while request != null and request.request_type in [
		"confirm_trigger", "choose_trigger_order",
	]:
		var trigger_option_id := _choice_id_for_slot(request, slot, false)
		if trigger_option_id.is_empty() and not request.options.is_empty():
			trigger_option_id = str(request.options[0].get("option_id", ""))
		if trigger_option_id.is_empty():
			_check(false, "Trigger choice %s has no selectable option" % request.request_type)
			return step
		step = RulesTestHarness.apply_choice(engine,
			state,
			request,
			ChoiceResponse.new(request.request_id, [trigger_option_id]),
			rng,
		)
		if not step.success or step.pending_choice == null:
			return step
		request = step.pending_choice
	var started_with_attachment := request.request_type == "select_attachment"
	if started_with_attachment:
		var attachment_ids: Array[String] = []
		for index in range(min(request.max_select, request.options.size())):
			attachment_ids.append(str(request.options[index].get("option_id", "")))
		step = RulesTestHarness.apply_choice(engine,
			state,
			request,
			ChoiceResponse.new(request.request_id, attachment_ids),
			rng,
		)
		if not step.success or step.pending_choice == null:
			return step
		request = step.pending_choice
	var option_id := _choice_id_for_slot(request, slot)
	if option_id.is_empty():
		return step
	step = RulesTestHarness.apply_choice(engine,
		state,
		request,
		ChoiceResponse.new(request.request_id, [option_id]),
		rng,
	)
	# Source selection can now be followed by an exact-attachment choice.
	# Resolve that attachment here, but leave its target choice for the next
	# explicit slot call so existing scenario intent remains unambiguous.
	if (
		not started_with_attachment
		and step.success
		and step.pending_choice != null
		and step.pending_choice.request_type == "select_attachment"
	):
		request = step.pending_choice
		var attachment_ids: Array[String] = []
		for index in range(min(request.max_select, request.options.size())):
			attachment_ids.append(str(request.options[index].get("option_id", "")))
		step = RulesTestHarness.apply_choice(engine,
			state,
			request,
			ChoiceResponse.new(request.request_id, attachment_ids),
			rng,
		)
	return step


func _choice_id_for_slot(
	request: ChoiceRequest,
	slot: String,
	report_missing: bool = true,
) -> String:
	for option_value in request.options:
		var option: Dictionary = option_value
		var ref: Dictionary = option.get("ref", {})
		var value: Dictionary = option.get("value", {})
		if (
			str(ref.get("slot", "")) == slot
			or str(value.get("slot", "")) == slot
		):
			return str(option.get("option_id", ""))
	if report_missing:
		_check(false, "Choice request %s did not include slot %s" % [request.request_type, slot])
	return ""


func _choice_id_for_slot_and_energy(
	request: ChoiceRequest,
	slot: String,
	energy_index: int,
) -> String:
	for option_value in request.options:
		var option: Dictionary = option_value
		var value: Dictionary = option.get("value", {})
		var option_id := str(option.get("option_id", ""))
		var encoded_energy_index := -1
		var parts := option_id.split(":", false, 2)
		if parts.size() >= 2 and parts[0] == "energy" and parts[1].is_valid_int():
			encoded_energy_index = int(parts[1])
		var ref: Dictionary = option.get("ref", {})
		if (
			(
				str(value.get("slot", "")) == slot
				or str(ref.get("slot", "")) == slot
			)
			and int(value.get("energy_index", encoded_energy_index))
				== energy_index
		):
			return option_id
	_check(false, "Choice request %s did not include slot %s for energy %d: %s" % [
		request.request_type,
		slot,
		energy_index,
		JSON.stringify(request.options),
	])
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
		if setup.pending_choice != null:
			setup = RulesTestHarness.apply_choice(engine,
				state,
				setup.pending_choice,
				ChoiceResponse.new(setup.pending_choice.request_id, ["turn:first"]),
				rng,
			)
			_check(setup.success, "Playout turn-order choice failed: %s" % setup.message)
		for actor in [state.first_player_idx, 1 - state.first_player_idx]:
			var setup_actions := RulesTestHarness.legal_actions(engine, state, actor, false)
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
				var placed := _apply_test_action(engine, state, active_action, rng)
				_check(placed.success, "Setup placement failed: %s" % placed.message)
				var ready := _apply_test_action(engine,
					state, GameAction.new("SETUP_DONE", {}, true, actor), rng)
				_check(ready.success, "Setup completion failed: %s" % ready.message)
				if ready.pending_choice != null:
					ready = RulesTestHarness.apply_choice(engine,
						state,
						ready.pending_choice,
						ChoiceResponse.new(ready.pending_choice.request_id, ["draw:0"]),
						rng,
					)
					_check(ready.success, "Setup mulligan-bonus choice failed: %s" % ready.message)

		var action_count := 0
		while not state.is_terminal() and action_count < 1200:
			action_count += 1
			var actions := RulesTestHarness.legal_actions(engine,
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
			var step := _apply_test_action(engine, state, selected, rng)
			_check(step.success, "Illegal enumerated action %s: %s" % [
				selected.action, step.message])
			if not step.success:
				break
			var choice_guard := 0
			while step.pending_choice and choice_guard < 32:
				choice_guard += 1
				var request := step.pending_choice
				var response := _playout_choice_response(state, request, catalog)
				step = RulesTestHarness.apply_choice(engine,
					state,
					request,
					response,
					rng,
				)
				_check(step.success, "Playout choice failed: %s" % step.message)
				if not step.success:
					break
			_check(choice_guard < 32, "Playout choice chain exceeded guard")
		_check(state.is_terminal(), "Playout did not terminate: %s vs %s" % [
			first_key, second_key])


func _playout_choice_response(
	state: GameState,
	request: ChoiceRequest,
	catalog: CardCatalog,
) -> ChoiceResponse:
	if request.request_type == "select_retreat_payment":
		return NativeChallengeAI.retreat_payment_response(state, request, catalog)
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
	return ChoiceResponse.new(request.request_id, ids)


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


func _check_pointer_only_input_contract() -> void:
	_check(
		not ProjectSettings.has_setting("autoload/FrontendFocus")
		and root.get_node_or_null("FrontendFocus") == null,
		"FrontendFocus autoload must be absent in pointer/touch-only mode",
	)
	var navigation_actions: Array[StringName] = [
		&"ui_accept",
		&"ui_select",
		&"ui_cancel",
		&"ui_focus_next",
		&"ui_focus_prev",
		&"ui_left",
		&"ui_right",
		&"ui_up",
		&"ui_down",
		&"ui_page_up",
		&"ui_page_down",
		&"ui_home",
		&"ui_end",
	]
	for action in navigation_actions:
		_check(
			InputMap.has_action(action)
			and InputMap.action_get_events(action).is_empty(),
			"Pointer/touch-only navigation action still has input events: %s"
			% action,
		)


func _check_pointer_only_focus_tree(node: Node, context: String) -> void:
	if node is Control:
		var control := node as Control
		var valid_focus_mode := control.focus_mode == Control.FOCUS_NONE
		if control is LineEdit:
			valid_focus_mode = control.focus_mode in [
				Control.FOCUS_NONE,
				Control.FOCUS_CLICK,
			]
		elif control is RichTextLabel:
			valid_focus_mode = control.focus_mode in [
				Control.FOCUS_NONE,
				Control.FOCUS_ACCESSIBILITY,
			]
		_check(
			valid_focus_mode,
			"%s exposes keyboard/controller focus: %s (%s)" % [
				context,
				str(control.get_path()) if control.is_inside_tree() else str(control.name),
				control.focus_mode,
			],
		)
	for child in node.get_children():
		_check_pointer_only_focus_tree(child, context)


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


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_check(false, "Unable to open %s" % path)
		return ""
	return file.get_as_text()


func _apply_test_action(
	engine: GameEngine,
	state: GameState,
	action: GameAction,
	rng: PortableRandomSource,
) -> StepResult:
	var strict_action := action
	if action != null and action.is_legacy_constructed():
		var actor := state.active_player_idx if action.actor < 0 else action.actor
		strict_action = engine._canonicalize_action(state, action, actor)
	return engine.apply_action(state, strict_action, rng)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
