extends SceneTree

var failures: Array[String] = []
var catalog := CardCatalog.shared()
const OUTPUT := "res://../build/battle-interaction-review/after"


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func settle(frames := 5) -> void:
	for _frame in range(frames):
		await process_frame


func tap(control: Control, touch := false) -> void:
	check(control.is_visible_in_tree(), "Attempted to tap a hidden control: " + str(control.name))
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


func capture(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OUTPUT + "/" + name + ".png")


func request_for(state: GameState, same_target := false, capacity := 3) -> ChoiceView:
	var energies: Array[String] = ["sv1-ener-2", "svi-dtur", "sv1-ener-2"]
	var options: Array[Dictionary] = []
	for slot in ["active", "bench_0", "bench_1", "bench_2", "bench_3", "bench_4"]:
		var pokemon := state.players[0].get_pokemon(slot)
		if pokemon == null:
			continue
		for index in range(energies.size()):
			options.append({"option_id": "energy:%d:%s->pokemon:0:%s:%s" % [index, energies[index], slot, pokemon.card_id],
				"ref": EntityRef.new("pokemon", 0, "", slot, -1, "", pokemon.card_id).to_dict()})
	return ChoiceView.new("redesign-energy", state.revision, "distribute_energy", 0,
		"为每张能量选择附着目标", options, 3, 3, false, true,
		{"card_ids": energies, "same_target": same_target, "max_per_target": capacity})


func check_draft() -> void:
	var state := UIPreviewStateFactory.battle_state()
	var selection := ChoiceSelectionModel.new(catalog)
	var request := request_for(state)
	selection.configure(request, state, catalog, 0)
	var draft := selection.energy_draft
	check(draft != null, "Missing distribution draft")
	var original := state.players[0].active.energy_card_ids.duplicate()
	for index in [2, 0, 1]:
		draft.select_energy(index)
		check(draft.assign(draft.option_for(index, "0:active")).is_empty(), "Out-of-order assignment failed")
	check(draft.is_complete() and draft.assignments.size() == 3, "Incomplete out-of-order draft")
	var previous := draft.assignments.duplicate()
	draft.select_energy(0)
	draft.assign(draft.option_for(0, "0:bench_0"))
	check(draft.assignments[1] == previous[1] and draft.assignments[2] == previous[2], "Reassignment discarded later energies")
	check(draft.undo() and draft.assignments == previous and draft.current_index == 0, "Reassignment undo lost focus or assignments")
	draft.remove_current()
	check(not draft.is_complete() and draft.assignments.size() == 2, "Removing one energy changed unrelated assignments")
	draft.undo()
	draft.clear_assignments()
	check(draft.assignments.is_empty() and draft.can_undo(), "Clear is not undoable")
	draft.undo()
	check(draft.assignments == previous, "Clear undo lost distribution")
	check(state.players[0].active.energy_card_ids == original, "Draft mutated the game")
	selection.configure(request_for(state, true), state, catalog, 0)
	draft = selection.energy_draft
	for index in range(3):
		draft.assign(draft.option_for(index, "0:active"))
	draft.select_energy(1)
	draft.assign(draft.option_for(1, "0:bench_0"))
	for index in range(3):
		check(draft.assignments[index] == draft.option_for(index, "0:bench_0"), "Common target was not changed atomically")
	draft.undo()
	check(draft.assignments[0] == draft.option_for(0, "0:active"), "Common-target undo failed")
	selection.configure(request_for(state, false, 1), state, catalog, 0)
	draft = selection.energy_draft
	draft.assign(draft.option_for(0, "0:active"))
	check(not draft.assign(draft.option_for(1, "0:active")).is_empty() and draft.assignments.size() == 1, "Target capacity was exceeded")
	draft.select_energy(0)
	check(draft.assign(draft.option_for(0, "0:active")).is_empty(), "Replacing a full target counted the old assignment twice")
	var legacy := ChoiceView.new("legacy", state.revision, "distribute_energy", 0, "", [
		{"option_id": "old-target", "ref": EntityRef.new("pokemon", 0, "", "active", -1, "", state.players[0].active.card_id).to_dict()}],
		0, 2, true, false, {})
	selection.configure(legacy, state, catalog, 0)
	draft = selection.energy_draft
	draft.assign("old-target")
	draft.assign("old-target")
	check(draft.response_ids() == ["old-target", "old-target"], "Legacy repeated option IDs changed")
	selection.configure(request, state, catalog, 0)
	check(selection.energy_draft.assignments.is_empty() and not selection.energy_draft.can_undo(), "New request inherited the old draft")
	var optional := request_for(state)
	optional.min_select = 0
	selection.configure(optional, state, catalog, 0)
	check(selection.energy_draft.is_complete(), "An optional empty distribution cannot be skipped")
	selection.selected_ids.assign([str(optional.options[0].option_id), str(optional.options[0].option_id)])
	check(not selection._choice_selection_is_complete(optional, selection.selected_ids), "Duplicate physical energy was accepted")


func check_target_controls() -> void:
	var table := load("res://scenes/battle/components/battle_table.tscn").instantiate() as BattleTable
	root.add_child(table)
	await settle()
	var state := UIPreviewStateFactory.battle_state()
	var rows: Array[Dictionary] = []
	var submitted: Array[GameAction] = []
	table.action_requested.connect(func(action: GameAction) -> void: submitted.append(action))
	table.selection_clear_requested.connect(func(_key: String) -> void: table.update_view(state, 0, rows, "", false, "local"))
	for dimensions in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(1024, 768)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		await settle()
		for touch in [false, true]:
			for kind in ["PLAY_BASIC", "ATTACH_ENERGY", "EVOLVE", "PLAY_TRAINER", "RETREAT"]:
				for target_count in [1, 2]:
					rows.clear()
					var source: String = "pokemon:0:active" if kind == "RETREAT" else "hand:0"
					for index in range(target_count):
						var target := "bench_%d" % index
						rows.append({"action": GameAction.create(kind, {}, 0,
							EntityRef.new("pokemon", 0, "", "active") if kind == "RETREAT" else EntityRef.new("card", 0, "hand", "", 0),
							EntityRef.new("pokemon", 0, "", target)), "source_key": source, "target_key": "pokemon:0:" + target})
					table.update_view(state, 0, rows, source, false, "local")
					await settle()
					var buttons: Container = table.action_popover.action_buttons
					await tap(buttons.get_child(0), touch)
					check(table.board_view.is_selecting_action_target(), "Pointer did not enter target selection: " + kind)
					check(table.phase_advance_button.disabled, "End turn remained active during targeting")
					check(table.own_bench[0].interaction_badge.visible, "Target lost its text badge")
					if kind == "ATTACH_ENERGY" and not touch and target_count == 2:
						await capture("target-%dx%d" % [dimensions.x, dimensions.y])
					await tap(table.header.get_node("RightInset/CancelSelectionButton"), touch)
					check(table.selected_entity_key.is_empty() and not table.own_bench[0].targetable, "Pointer cancellation failed: %s touch=%s size=%s" % [kind, touch, dimensions])
	check(submitted.is_empty(), "Cancellation submitted an action")
	rows.assign([{"action": GameAction.create("USE_ABILITY", {}, 0, EntityRef.new("pokemon", 0, "", "active")),
		"source_key": "pokemon:0:active", "target_key": "pokemon:0:active"}])
	table.update_view(state, 0, rows, "pokemon:0:active", false, "local")
	table.interaction_state.begin_target(str(table.interaction_router.action_groups_for_source("pokemon:0:active")[0].key))
	table.board_view._refresh_actions()
	table.board_view._refresh_target_hints()
	table.board_view._refresh_header()
	var settings := root.get_node("AppSettings")
	var previous_quality: String = settings.quality_profile
	settings.quality_profile = "low"
	await settle()
	var self_target := table.render3d.world.entities.get(table.render3d._key(table.own_active)) as CardEntity3D
	check(table.own_active.targetable and table.own_active.selected and "◆" in table.own_active.interaction_badge.text,
		"A source which is also a target lost one of its markers")
	check(self_target._outline_tint == table.own_active._target_accent and not self_target._outline_pulse,
		"Self target or reduced motion lost its static target border")
	await capture("target-low-reduced")
	settings.quality_profile = previous_quality
	rows.assign([{"action": GameAction.create("ATTACH_ENERGY", {}, 1, EntityRef.new("card", 1, "hand", "", 0), EntityRef.new("pokemon", 1, "", "bench_0")),
		"source_key": "hand:0", "target_key": "pokemon:1:bench_0"}])
	table.update_view(state, 1, rows, "hand:0", false, "local")
	table.interaction_state.begin_target(str(table.interaction_router.action_groups_for_source("hand:0")[0].key))
	table.board_view._refresh_actions()
	table.board_view._refresh_target_hints()
	table.board_view._refresh_header()
	await settle()
	check(table.own_bench[0].targetable and table.own_bench[0].interaction_badge.visible and not table.opponent_active.targetable,
		"Second player perspective targeted the wrong side")
	await capture("target-player2")
	table.update_view(state, 0, [], "", false, "local")
	var choice := ChoiceView.new("field-choice", state.revision, "select_pokemon", 0, "选择宝可梦", [], 1, 1, false, true)
	var cancelled := [0]
	table.choice_cancel_requested.connect(func() -> void: cancelled[0] += 1)
	table.set_choice_guidance(choice)
	check(table.handle_back() and cancelled[0] == 1, "System back missed cancellable field choice with no selected source")
	choice.can_cancel = false
	check(table.handle_back() and cancelled[0] == 1, "System back cancelled mandatory field choice")
	table.queue_free()
	await settle()


func check_distribution_workspace() -> void:
	var main: Control = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	await settle()
	var state := UIPreviewStateFactory.battle_state()
	for index in range(5):
		state.players[0].bench[index] = state.players[0].active.clone_state()
	main.state = state
	main.current_view_player = 0
	main.game_mode = "local"
	main.shell_view.build_game_screen()
	main.battle_screen.set_local_hand_privacy_hidden(false)
	main._show_choice_overlay(request_for(state))
	await settle(10)
	var panel := main.active_choice_panel as ChoicePanel
	var draft := main.choice_model.energy_draft as EnergyDistributionModel
	for dimensions in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(1024, 768), Vector2i(900, 540)]:
		root.size = dimensions
		await settle(12)
		check(not panel.preview_panel.visible, "Distribution opened a permanent detail column")
		check(main.modal_confirm.get_global_rect().end.y <= main.shell_view.safe_content_size().y + 1, "Confirmation escaped the viewport")
		check(panel.energy_actions.get_global_rect().end.y <= main.modal_confirm.get_global_rect().position.y, "Distribution tools escaped their fixed footer")
		await capture("energy-%dx%d" % [dimensions.x, dimensions.y])
	root.size = Vector2i(1600, 900)
	await settle(12)
	var first: CardView = panel.energy_distribution._energy_preview_cards[0]
	await tap(panel.energy_distribution._energy_preview_cards[2], true)
	await tap(panel.energy_distribution._energy_target_tiles["0:active"], true)
	check(draft.assignments.has(2) and not draft.assignments.has(0), "Pointer selected energy index was ignored")
	await tap(first)
	await tap(panel.energy_distribution._energy_target_tiles["0:bench_0"])
	await tap(panel.energy_distribution._energy_target_tiles["0:active"])
	check(main.selected_choice_ids.size() == 3 and not main.modal_confirm.disabled, "Complete distribution cannot be confirmed")
	await capture("energy-complete")
	await tap(first)
	await tap(panel.energy_distribution._energy_target_tiles["0:bench_1"])
	check(draft.assignments[2] == draft.option_for(2, "0:active"), "Pointer reassignment lost later energy")
	await tap(panel.undo_button)
	check(draft.assignments[0] == draft.option_for(0, "0:bench_0"), "Pointer undo failed")
	await tap(panel.clear_button)
	check(main.selected_choice_ids.is_empty() and not panel.undo_button.disabled, "Clear cannot be undone through the UI")
	await tap(panel.undo_button)
	check(main.selected_choice_ids.size() == 3, "Undo clear failed through the UI")
	var before := draft.assignments.duplicate()
	var selected_index := draft.current_index
	var scroll := panel._choice_scroll_container()
	scroll.scroll_vertical = 18
	await settle()
	var scroll_before := scroll.scroll_vertical
	await tap(panel.get_node("EnergyActions/EnergyDetailButton"))
	check(panel.preview_panel.visible, "Details button did not open details")
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	check(main.modal_layer.visible and not panel.preview_panel.visible and draft.assignments == before, "Back from energy details cancelled or changed the draft")
	check(draft.current_index == selected_index and scroll.scroll_vertical == scroll_before, "Details lost selected energy or reading position")
	var active_panel := panel
	main._show_choice_overlay(main.active_request)
	check(main.active_choice_panel == active_panel and draft.assignments == before, "Stable request refresh rebuilt the workspace")
	main.game_mode = "network"
	main.network_player_idx = 0
	main.network_choice_view = main.active_request
	main._confirm_choice()
	await settle()
	check(main.modal_layer.visible and main.choice_model.energy_draft != null and main.choice_model.energy_draft.assignments == before, "Rejected network response discarded the draft")
	main.modal_host_controller.close()
	await settle()
	# Use Main's real confirmation / cancel path; no network action should be sent.
	main.game_mode = "network"
	main.network_player_idx = 0
	for kind in ["DECLARE_ATTACK", "RETREAT"]:
		var action := GameAction.create(kind, {"attack_index": 0}, 0,
			EntityRef.new("pokemon", 0, "", "active"), EntityRef.new("pokemon", 0, "", "bench_0"))
		main.network_legal_actions.assign([action])
		main.selected_entity_key = "pokemon:0:active"
		main.selected_entity_identity = main._entity_identity_for_key(main.selected_entity_key)
		main._refresh_game()
		var group := ""
		if kind == "RETREAT":
			group = str(main.battle_screen.interaction_router.action_groups_for_source("pokemon:0:active")[0].key)
			main.battle_screen.interaction_state.begin_target(group)
		var revision := state.revision
		main._execute_action(action)
		await settle()
		await tap(main.modal_cancel, true)
		check(not main.modal_layer.visible and state.revision == revision and main.selected_entity_key == "pokemon:0:active", "Confirmation cancel changed the match or lost its source: " + kind)
		check(main.battle_screen._selected_action_group_key == group, "Confirmation cancel lost its previous target step: " + kind)
	main.queue_free()
	await settle()


func run() -> void:
	Input.use_accumulated_input = false
	root.get_node("AppSettings").animation_mode = "reduced"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	check_draft()
	await check_target_controls()
	await check_distribution_workspace()
	for message in failures:
		push_error(message)
	if failures.is_empty():
		print("BATTLE_INTERACTION_REDESIGN_OK")
	quit(0 if failures.is_empty() else 1)
