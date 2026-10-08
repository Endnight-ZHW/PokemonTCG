extends SceneTree

const PSYCHIC := "sv1-ener-5"
const LIGHTNING := "sv1-ener-4"
const OUTPUT := "res://../build/battle-interaction-review/fixes"
var failures: Array[String] = []
var catalog := CardCatalog.shared()


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("run")


func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)


func settle(frames := 5) -> void:
	for _frame in range(frames):
		await process_frame


func tap(control: Control, touch := false) -> void:
	var point := root.get_final_transform() * control.get_global_rect().get_center()
	for pressed in [true, false]:
		if touch:
			var event := InputEventScreenTouch.new()
			event.position = point
			event.pressed = pressed
			Input.parse_input_event(event)
		else:
			var event := InputEventMouseButton.new()
			event.position = point
			event.global_position = point
			event.button_index = MOUSE_BUTTON_LEFT
			event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
			event.pressed = pressed
			Input.parse_input_event(event)
		await settle(1)
	await settle()


func miraidon_session() -> NativeRulesSessionAdapter:
	var state := GameState.new()
	state.revision = 100
	state.setup_stage = GameState.SETUP_COMPLETE
	state.phase = "MAIN"
	state.turn_number = 4
	state.active_player_idx = 0
	state.first_player_idx = 1
	for player in state.players:
		player.active = PokemonState.new("csvh4-023")
		player.prizes.assign([PSYCHIC, LIGHTNING, PSYCHIC])
		player.deck.assign([PSYCHIC, PSYCHIC, PSYCHIC, LIGHTNING, LIGHTNING, LIGHTNING])
	state.players[0].active.energy_card_ids.assign([LIGHTNING])
	state.players[0].bench[0] = PokemonState.new("csvh4-024")
	state.players[0].bench[1] = PokemonState.new("csvh4-010")
	var adapter := NativeRulesSessionAdapter.new(catalog)
	check(adapter.restore(state.snapshot(), 9123), "Could not restore Miraidon fixture")
	for action in adapter.legal_actions(0).concrete_actions():
		if action.kind == "DECLARE_ATTACK" and action.attack_index() == 0:
			action.action_id = "sparse-source-attack"
			var step := adapter.apply_action(action.to_dict())
			check(step.success and step.pending_choice != null and step.pending_choice.request_type == "distribute_energy", "Miraidon did not produce a real distribution choice")
			return adapter
	check(false, "Missing Miraidon Peak Acceleration attack")
	return adapter


func check_native_sources() -> void:
	# Engine suppresses the redundant third copy of each type. Public source
	# indices are 0,1,3,4, although metadata.card_ids is a four-element list.
	for display_index in range(4):
		var adapter := miraidon_session()
		var request := adapter.pending_choice(0)
		if request == null:
			continue
		request = ChoiceView.from_dict(request.to_dict())
		if display_index % 2 == 1:
			request.options.reverse()
		var selection := ChoiceSelectionModel.new(catalog)
		selection.configure(request, adapter.state, catalog, 0)
		var draft := selection.energy_draft
		check(draft.card_ids == [PSYCHIC, PSYCHIC, LIGHTNING, LIGHTNING], "Sparse sources created a phantom or mislabeled energy")
		check(draft.card_ids.size() > request.max_select, "Fixture does not test source pool larger than assignment limit")
		var id := draft.option_for(display_index, "0:bench_0")
		var native_index: int = [0, 1, 3, 4][display_index]
		check(id.begins_with("energy:%d:" % native_index), "Visible position was confused with original source identity")
		draft.select_energy(display_index)
		check(selection.toggle(id).is_empty(), "Visible source cannot be assigned: %d" % display_index)
		var result := adapter.apply_choice(selection.response().to_dict())
		check(result.success, "Native rules rejected mapped source: " + result.message)
		var energy := PSYCHIC if display_index < 2 else LIGHTNING
		check(adapter.state.players[0].bench[0].energy_card_ids == [energy], "Rules attached a different type than the selected card")
		check(adapter.state.players[0].deck.count(energy) == 2, "Rules removed the wrong physical energy from the deck")
	var adapter := miraidon_session()
	var request := adapter.pending_choice(0)
	var selection := ChoiceSelectionModel.new(catalog)
	selection.configure(request, adapter.state, catalog, 0)
	var draft := selection.energy_draft
	selection.toggle(draft.option_for(3, "0:bench_1"))
	selection.toggle(draft.option_for(2, "0:bench_0"))
	var assigned := draft.assignments.duplicate()
	check(not selection.toggle(draft.option_for(0, "0:active")).is_empty() and draft.assignments == assigned, "Distribution exceeded the two-card limit")
	draft.select_energy(2)
	selection.toggle(draft.option_for(2, "0:bench_1"))
	check(draft.assignments.size() == 2 and draft.assignments[3] == assigned[3], "Reassignment at capacity dropped another sparse source")
	selection.undo()
	check(draft.assignments == assigned, "Sparse reassignment undo changed identities")
	var result := adapter.apply_choice(selection.response().to_dict())
	check(result.success and adapter.state.players[0].bench[0].energy_card_ids == [LIGHTNING] and adapter.state.players[0].bench[1].energy_card_ids == [LIGHTNING], "Two identical energy sources were not independently attached")
	check(adapter.state.players[0].deck.count(LIGHTNING) == 1, "Two-card response removed too many source cards")


func check_sparse_metadata_and_targets() -> void:
	var state := UIPreviewStateFactory.battle_state()
	var options: Array[Dictionary] = []
	for row in [[7, LIGHTNING, "bench_0"], [2, PSYCHIC, "active"]]:
		var slot := str(row[2])
		var pokemon := state.players[0].get_pokemon(slot)
		options.append({"option_id": "energy:%d:%s->pokemon:0:%s:%s" % [row[0], row[1], slot, pokemon.card_id],
			"ref": EntityRef.new("pokemon", 0, "", slot, -1, "", pokemon.card_id).to_dict()})
	var request := ChoiceView.new("sparse-targets", state.revision, "distribute_energy", 0, "", options, 0, 2, false, false,
		{"card_ids": ["svi-dtur", "svi-dtur", "svi-dtur"]})
	var selection := ChoiceSelectionModel.new(catalog)
	selection.configure(request, state, catalog, 0)
	check(selection.energy_draft.card_ids == [PSYCHIC, LIGHTNING], "Presentation metadata overrode authoritative source card IDs")
	check(selection.energy_draft.option_for(0, "0:bench_0").is_empty() and not selection.energy_draft.option_for(1, "0:bench_0").is_empty(), "A target became legal for the wrong source")
	check(not selection.energy_draft.select_energy(2), "A nonexistent energy remains selectable")
	state.players[0].bench[0] = PokemonState.new("csvh4-024")
	selection.configure(request, state, catalog, 0)
	check(selection.energy_draft.card_ids == [PSYCHIC], "Stale Pokemon identity left an unusable source in the UI")


func check_pointer_flow() -> void:
	for touch in [false, true]:
		var adapter := miraidon_session()
		var request := adapter.pending_choice(0)
		var main: Control = load("res://scenes/main/main.tscn").instantiate()
		root.add_child(main)
		await settle()
		main.native_rules = adapter
		main.state = adapter.state
		main.current_view_player = 0
		main.game_mode = "local"
		main.shell_view.build_game_screen()
		main.battle_screen.set_local_hand_privacy_hidden(false)
		main._show_choice_overlay(request)
		await create_timer(0.3).timeout
		var panel := main.active_choice_panel as ChoicePanel
		check(panel.energy_distribution._energy_preview_cards.size() == 4, "Native request rendered phantom energies")
		panel.show_blocked_reason("先前选择不可用")
		await settle()
		await tap(panel.energy_distribution._energy_preview_cards[2], touch)
		check(not panel.blocked_reason_label.visible, "Switching energy kept an unrelated error message")
		await tap(panel.energy_distribution._energy_target_tiles["0:bench_0"], touch)
		check(main.selected_choice_ids.size() == 1 and main.selected_choice_ids[0].begins_with("energy:3:"), "Third visible energy failed through real pointer input")
		check(not panel.blocked_reason_label.visible, "Valid source displayed a missing-target error")
		if not touch and DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(OUTPUT + "/third-energy-assigned.png")
		await tap(main.modal_confirm, touch)
		await create_timer(0.3).timeout
		check(adapter.state.players[0].bench[0].energy_card_ids == [LIGHTNING], "Pointer confirmation did not attach the third visible energy through native rules")
		main.queue_free()
		await settle()
		await create_timer(0.05).timeout


func run() -> void:
	root.size = Vector2i(1600, 900)
	Input.use_accumulated_input = false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	root.get_node("AppSettings").animation_mode = "cinematic"
	check(MotionPolicy.mode() == "cinematic" and FrontendMotion.animation_mode() == "cinematic", "Battle and frontend defaults diverge")
	check_native_sources()
	check_sparse_metadata_and_targets()
	await check_pointer_flow()
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("ENERGY_SPARSE_SOURCE_OK")
	quit(0 if failures.is_empty() else 1)
