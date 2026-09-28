extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("_run")


func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)


func settle() -> void:
	for _frame in range(4):
		await process_frame


func choose_button(table: BattleTable, kind: String) -> void:
	for row in table.action_popover._rows:
		var action := row.get("action") as GameAction
		if action != null and action.kind == kind:
			table.action_popover._on_action_button_pressed(action)
			return
	check(false, "Missing button: " + kind)


func _run() -> void:
	root.get_node("AppSettings").set("animation_mode", "reduced")
	root.size = Vector2i(1600, 900)
	var table := load("res://scenes/battle/components/battle_table.tscn").instantiate() as BattleTable
	root.add_child(table)
	await settle()
	var state := UIPreviewStateFactory.battle_state()
	var rows := UIPreviewStateFactory.action_rows(state)
	rows.append({"action": GameAction.create("ATTACH_ENERGY", {}, 0,
		EntityRef.new("card", 0, "hand", "", 0), EntityRef.new("pokemon", 0, "", "bench_0"))})
	var submitted: Array[GameAction] = []
	table.action_requested.connect(func(action: GameAction) -> void: submitted.append(action))
	table.selection_clear_requested.connect(func(_key: String) -> void: table.update_view(state, 0, rows, "", false, "local"))
	table.update_view(state, 0, rows, "hand:0", false, "local")
	await settle()
	check(table.action_popover.visible and table.action_popover.button_count() == 1, "Targets must be grouped into one energy button")
	check(not table.board_view.is_selecting_action_target() and not table.own_active.targetable, "Selecting a card entered target mode before pressing its button")
	table.board_view._on_card_activated(state.players[0].active.card_id, -1, 0, "active")
	check(submitted.is_empty(), "Card selection alone submitted an energy action")
	choose_button(table, "ATTACH_ENERGY")
	check(table.own_active.targetable and table.own_bench[0].targetable and not table.opponent_active.targetable, "Button failed to expose exactly its legal targets")
	check(not table.hand_views[1].actionable, "Unrelated playable cards distract from target selection")
	check("要赋能" in table.header.task_hint_label.text and table.header.get_node("RightInset/BackActionButton").visible, "Target guidance or return action is missing")
	table.board_view._on_card_activated(state.players[1].active.card_id, -1, 1, "active")
	check(submitted.is_empty() and table.board_view.is_selecting_action_target(), "Illegal target submitted or abandoned the selected action")
	var source_changes: Array[int] = []
	table.hand_card_selected.connect(func(index: int, _card: String) -> void: source_changes.append(index))
	for hand_index in [0, 1]:
		table.board_view._on_card_activated(state.players[0].hand[hand_index], hand_index, 0, "")
	check(source_changes.is_empty() and table.selected_entity_key == "hand:0" and table.board_view.is_selecting_action_target(), "Tapping a hand card abandoned the pending target choice")
	var blank := Vector2(230, 365)
	check(table._is_blank_table_point(blank), "Target-preservation blank fixture intersects a control")
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = blank
		table._input(event)
	check(table.selected_entity_key == "hand:0" and table.board_view.is_selecting_action_target(), "Tapping blank space abandoned the pending target choice")
	table.header.back_requested.emit()
	check(table.action_popover.visible and not table.own_active.targetable, "Back did not return to the card menu")
	choose_button(table, "ATTACH_ENERGY")
	table.board_view._on_card_activated(state.players[0].bench[0].card_id, -1, 0, "bench_0")
	check(submitted.size() == 1 and submitted[0].target_slot() == "bench_0", "Target tap did not submit the exact selected action")
	table.header.cancel_requested.emit()
	check(table.selected_entity_key.is_empty() and not table.own_bench[0].targetable, "Cancel left the action or highlight active")
	check(table.hand_views[0]._get_drag_data(Vector2.ZERO) == null and not table.own_active._can_drop_data(Vector2.ZERO, {"kind": "hand_card", "hand_index": 0}), "Drag use remains reachable")

	# A lone legal target must still require both the button and target tap.
	rows.remove_at(rows.size() - 1)
	table.update_view(state, 0, rows, "hand:0", false, "local")
	check(table.action_popover.visible and not table.own_active.targetable, "Single target bypassed the button")
	choose_button(table, "ATTACH_ENERGY")
	table.update_view(state, 0, rows, "hand:0", false, "local")
	check(table.board_view.is_selecting_action_target(), "A stable refresh lost target selection")
	for dimensions in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(900, 540), Vector2i(2000, 900), Vector2i(640, 960)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		await settle()
		check(table.header.task_hint_label.get_global_rect().end.x <= table.get_global_rect().end.x, "Task bar overflow at %s" % dimensions)
		check(table.header.get_node("RightInset/BackActionButton").size.y >= 48, "Back button lost its touch size")
		check(table.board_view.is_selecting_action_target(), "Resize lost the selected action")
		table.update_view(state, 0, rows, "hand:0", false, "local")
		if table.is_compact_layout():
			check("\n奖励卡" in table.own_info.text, "A snapshot refresh lost compact prize counters")
		check(table.own_allowance_row.get_global_rect().end.y <= table.get_global_rect().end.y, "Turn allowances leave the safe viewport at %s" % dimensions)
		check(not table.own_allowance_row.get_global_rect().intersects((table.hud.get_node("PhasePanel") as Control).get_global_rect()), "Turn allowances overlap phase controls")
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://../build/battle-buttons-%dx%d.png" % [dimensions.x, dimensions.y])
	table.set_submission_pending(true)
	var before := submitted.size()
	table.board_view._on_card_activated(state.players[0].active.card_id, -1, 0, "active")
	check(submitted.size() == before and not table.own_active.targetable and "等待" in table.header.task_hint_label.text, "Pending submission still accepts targets or advertises actions")
	table.set_submission_pending(false)

	# Public mandatory choices override ordinary card menus and cannot be cancelled.
	var request := ChoiceView.new("button:prize", state.revision, "select_prize", 0, "请选择奖励卡", [{"option_id": "prize:0"}], 1, 1, false, false)
	table.set_choice_guidance(request)
	table.set_choice_targets({"prize:0:0": "prize:0"}, "请选择奖励卡")
	var choices: Array[String] = []
	table.choice_target_selected.connect(func(id: String) -> void: choices.append(id))
	table.header.cancel_requested.emit()
	check(table.active_choice == request and not table.header.get_node("RightInset/CancelSelectionButton").visible, "Mandatory choice acquired a cancel route")
	check("奖励卡" in table.header.task_hint_label.text and (table.zones.own_prizes as ZoneView).targetable, "Prize guidance or highlight is missing")
	table.board_view._on_card_activated(state.players[0].active.card_id, -1, 0, "active")
	check(submitted.size() == before, "Mandatory choice allowed an unrelated card action")
	table.board_view._on_card_activated(state.players[0].hand[0], 0, 0, "")
	check(table.active_choice == request and table.selected_entity_key == "hand:0", "Tapping the source reset a mandatory choice")
	table.board_view._on_prize_index_activated(1, true)
	table.board_view._on_prize_index_activated(0, true)
	check(choices == ["prize:0"], "Prize selection accepted an option outside the public choice")
	await settle()
	var prizes := table.zones.own_prizes as ZoneView
	var legal_prize := table.render3d.world.entities.get(table.render3d._key(prizes, "0")) as CardEntity3D
	var other_prize := table.render3d.world.entities.get(table.render3d._key(prizes, "1")) as CardEntity3D
	check(legal_prize.outline.visible and not other_prize.outline.visible, "Prize glow leaked beyond the authoritative options")
	check(legal_prize.face_down and legal_prize.face_texture == null, "Prize guidance exposed a hidden card face")
	table.clear_choice_targets()
	table.set_choice_guidance(null)
	table.update_view(state, 0, rows, "", false, "local")
	await settle()
	var entity := table.render3d.world.entities.get(table.render3d._key(table.hand_views[0])) as CardEntity3D
	check(entity != null and entity.outline.visible and entity._outline_tint.is_equal_approx(DesignTokens.STATE_SUCCESS), "Playable hand state never reached the physical card outline")
	check(not entity._outline_pulse, "Reduced motion still pulses card outlines")
	# Same-target variants remain explicit and stale button signals are ignored.
	var variants: Array[Dictionary] = []
	for payment in [0, 1]:
		variants.append({"action": GameAction.create("RETREAT", {"energy_indices": [payment]}, 0,
			EntityRef.new("pokemon", 0, "", "active"), EntityRef.new("pokemon", 0, "", "bench_0"))})
	table.update_view(state, 0, variants, "pokemon:0:active", false, "local")
	choose_button(table, "RETREAT")
	before = submitted.size()
	table.board_view._on_card_activated(state.players[0].bench[0].card_id, -1, 0, "bench_0")
	check(submitted.size() == before and table.action_popover.button_count() == 2, "Same-target payment variants were silently chosen")
	var stale_action := variants[0].action as GameAction
	var invalidated: Array[bool] = []
	table.interaction_invalidated.connect(func() -> void: invalidated.append(true))
	table.update_view(state, 0, [], "pokemon:0:active", false, "local")
	check(invalidated.size() == 1 and not table.board_view.is_selecting_action_target() and not table.own_bench[0].targetable,
		"Changed legal actions retained a target selection or omitted invalidation feedback")
	table.update_view(state, 0, [], "", false, "local")
	table.board_view._on_popover_action_chosen(stale_action)
	check(submitted.size() == before, "An obsolete button submitted after its source disappeared")
	var router := BattleInteractionController.new()
	router.rebuild([{"action": stale_action, "disabled": true}])
	check(router.source_keys().is_empty(), "Disabled actions still mark a card playable")
	table.queue_free()
	await settle()
	await _check_confirmations()
	if failures.is_empty():
		print("BATTLE_BUTTON_INTERACTION_OK")
	else:
		for message in failures:
			push_error(message)
	quit(0 if failures.is_empty() else 1)


func _check_confirmations() -> void:
	root.size = Vector2i(1280, 720)
	var main: Node = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	await settle()
	var state := UIPreviewStateFactory.battle_state()
	main.state = state
	main.current_view_player = 0
	main.game_mode = "network"
	main.network_player_idx = 0
	var attack := GameAction.create("DECLARE_ATTACK", {"attack_index": 0}, 0)
	main.network_legal_actions.assign([attack])
	main.shell_view.build_game_screen()
	await settle()
	main._execute_action(attack)
	check(main.modal_layer.visible and main.modal_title.text == "确认攻击" and main.modal_confirm.size.y >= 56, "Attack skipped its accessible confirmation")
	var confirmation := main.modal_body.get_child(0) as Label
	check(confirmation != null and "卡面伤害：100" in confirmation.text and "结束本回合" in confirmation.text,
		"Attack confirmation lost its printed damage or turn consequence")
	var revision := state.revision
	main.modal_cancel.pressed.emit()
	await settle()
	check(not main.modal_layer.visible and state.revision == revision and main.selected_entity_key == "pokemon:0:active", "Cancelling attack changed the match or lost its card menu")
	main._execute_action(attack)
	state.revision += 1
	main.modal_confirm.pressed.emit()
	await settle()
	check(state.revision == revision + 1 and not main.modal_layer.visible, "Stale attack confirmation submitted into a changed board")
	var prize := ChoiceView.new("button:rejected-prize", state.revision, "select_prize", 0, "选择奖励卡", [{"option_id": "prize:0"}], 1, 1, false, false)
	main.network_choice_view = prize
	main._show_choice_overlay(prize)
	main._on_battle_choice_target_selected("prize:0")
	await settle()
	check(main.active_request != null and main.active_request.request_id == prize.request_id and main.battle_screen.zones.own_prizes.targetable,
		"A rejected network submission stranded the mandatory prize choice")
	main.queue_free()
	await settle()
