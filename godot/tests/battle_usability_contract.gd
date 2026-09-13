extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func settle(frames: int = 3) -> void:
	for _frame in range(frames):
		await process_frame


func mouse(pressed: bool, position := Vector2(28, 28), device: int = 0) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = position
	event.device = device
	return event


func touch(pressed: bool, index: int = 0, cancelled: bool = false) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.pressed = pressed
	event.index = index
	event.position = Vector2(28, 28)
	event.canceled = cancelled
	return event


func _run() -> void:
	root.size = Vector2i(1600, 900)
	root.get_node("AppSettings").set("reduced_motion", true)
	root.get_node("AppSettings").set("animation_mode", "reduced")
	await _check_gestures()
	await _check_zone_gestures()
	await _check_table()
	await _check_confirmations()
	if failures.is_empty():
		print("BATTLE_USABILITY_CONTRACT_OK")
		quit(0)
	else:
		for message in failures:
			push_error(message)
		quit(1)


func _check_gestures() -> void:
	var card := load("res://ui/card_view.tscn").instantiate() as CardView
	var other := load("res://ui/card_view.tscn").instantiate() as CardView
	root.add_child(card)
	root.add_child(other)
	card.configure("sv1-ener-2")
	other.configure("sv1-ener-1")
	var clicks: Array[int] = [0]
	var details: Array[int] = [0]
	card.activated.connect(func(_id: String, _hand: int, _player: int, _slot: String) -> void: clicks[0] += 1)
	other.activated.connect(func(_id: String, _hand: int, _player: int, _slot: String) -> void: clicks[0] += 100)
	card.detail_requested.connect(func(_id: String) -> void: details[0] += 1)
	card._gui_input(mouse(true))
	await create_timer(0.40).timeout
	check(details[0] == 1 and clicks[0] == 0, "Long press must open details before release")
	card._gui_input(mouse(false))
	check(details[0] == 1 and clicks[0] == 0, "Long-press release also activated the card")
	card._gui_input(mouse(true))
	card._gui_input(mouse(false))
	check(clicks[0] == 1, "Short mouse click was lost")
	card._gui_input(touch(true))
	other._gui_input(touch(true, 1))
	other._gui_input(touch(false, 1))
	card._gui_input(mouse(true, Vector2(28, 28), InputEvent.DEVICE_ID_EMULATION))
	card._gui_input(mouse(false, Vector2(28, 28), InputEvent.DEVICE_ID_EMULATION))
	card._gui_input(touch(false))
	check(clicks[0] == 2, "Extra finger or emulated mouse duplicated a physical touch")
	card._gui_input(touch(true))
	card._gui_input(touch(false, 0, true))
	check(clicks[0] == 2, "Cancelled touch activated a card")
	card._gui_input(touch(true))
	var drag := InputEventScreenDrag.new()
	drag.position = Vector2(72, 28)
	drag.relative = Vector2(44, 0)
	card._gui_input(drag)
	card._gui_input(touch(false))
	check(clicks[0] == 2, "Horizontal scrolling became a click")
	card._gui_input(touch(true))
	drag.position = Vector2(28, 78)
	drag.relative = Vector2(0, 50)
	card._gui_input(drag)
	card._gui_input(touch(false))
	check(clicks[0] == 2, "Dragging away and returning to a field card became a tap")
	card._gui_input(mouse(true))
	var mouse_move := InputEventMouseMotion.new()
	mouse_move.position = Vector2(78, 28)
	card._gui_input(mouse_move)
	card._gui_input(mouse(false))
	check(clicks[0] == 2, "A cancelled mouse movement became a field-card click")
	card._gui_input(mouse(true))
	card._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await create_timer(0.40).timeout
	card._gui_input(mouse(false))
	check(clicks[0] == 2 and details[0] == 1, "Focus loss did not cancel the pending gesture")
	card._gui_input(mouse(true))
	card.configure("sv1-ener-3")
	card._gui_input(mouse(false))
	check(clicks[0] == 2, "Rebinding a pressed card activated its replacement")
	card.queue_free()
	other.queue_free()
	await settle()


func _check_zone_gestures() -> void:
	var zone := load("res://ui/zone_view.tscn").instantiate() as ZoneView
	var card := load("res://ui/card_view.tscn").instantiate() as CardView
	root.add_child(zone)
	root.add_child(card)
	zone.configure("弃牌区", "sv1-ener-2", 1)
	card.configure("sv1-ener-1")
	var counts := [0, 0, 0]
	zone.inspected.connect(func(_context: Dictionary) -> void: counts[0] += 1)
	zone.detail_requested.connect(func(_id: String) -> void: counts[1] += 1)
	card.activated.connect(func(_id: String, _hand: int, _player: int, _slot: String) -> void: counts[2] += 1)
	zone._on_gui_input(touch(true))
	card._gui_input(touch(true, 1))
	card._gui_input(touch(false, 1))
	zone._on_gui_input(mouse(true, Vector2(28, 28), InputEvent.DEVICE_ID_EMULATION))
	zone._on_gui_input(mouse(false, Vector2(28, 28), InputEvent.DEVICE_ID_EMULATION))
	zone._on_gui_input(touch(false))
	check(counts == [1, 0, 0], "Zone touch duplicated via emulation or a second card finger")
	card._gui_input(touch(true))
	zone._on_gui_input(touch(true, 1))
	zone._on_gui_input(touch(false, 1))
	card._gui_input(touch(false))
	check(counts == [1, 0, 1], "A zone stole another card's active touch")
	zone._on_gui_input(touch(true))
	await create_timer(0.40).timeout
	check(counts == [1, 1, 1], "Zone long press did not open details at 350ms before release")
	zone._on_gui_input(touch(false))
	check(counts == [1, 1, 1], "Zone long-press release also inspected the stack")
	zone._on_gui_input(touch(true))
	zone._on_gui_input(touch(false, 0, true))
	zone._on_gui_input(mouse(true))
	zone._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	zone._on_gui_input(mouse(false))
	zone._on_gui_input(mouse(true))
	zone.configure("弃牌区", "sv1-ener-3", 2)
	zone._on_gui_input(mouse(false))
	check(counts == [1, 1, 1], "Cancelled, unfocused or rebound zone retained its press")
	zone.queue_free()
	card.queue_free()
	await settle()


func _check_table() -> void:
	var table := load("res://scenes/battle/components/battle_table.tscn").instantiate() as BattleTable
	root.add_child(table)
	await settle()
	var state := UIPreviewStateFactory.battle_state()
	var rows := UIPreviewStateFactory.action_rows(state)
	table.update_view(state, 0, rows, "hand:0", false, "local")
	check(table.opponent_hand_views[0].size.is_equal_approx(table.hand_view._current_opponent_hand_card_size()), "Refreshing the opponent hand ignored its responsive card size")
	var selected: Array[int] = [0]
	table.pokemon_selected.connect(func(_player: int, _slot: String, _id: String) -> void: selected[0] += 1)
	table.board_view._on_card_activated(state.players[1].active.card_id, -1, 1, "active")
	check(selected[0] == 0 and table.selected_entity_key == "hand:0", "An invalid target replaced the selected source")
	table.selection_clear_requested.connect(func(_key: String) -> void:
		table.update_view(state, 0, rows, "", false, "local")
	)
	table.update_view(state, 0, rows, "pokemon:0:active", false, "local")
	table.show_card_detail(state.players[0].active.card_id, state.players[0].active)
	table.hud.set_log_drawer_open(true)
	check(table.detail_panel.visible, "Wide selection lost its side detail panel")
	check(table.handle_back() and not table.detail_panel.visible and table.hud.is_log_drawer_open(), "Back must close details before the log")
	check(table.handle_back() and not table.hud.is_log_drawer_open() and not table.selected_entity_key.is_empty(), "Closing the log lost selection")
	check(table.handle_back() and table.selected_entity_key.is_empty(), "Back did not cancel selection")
	check(not table.handle_back(), "An idle table must allow the match menu")
	table.update_view(state, 0, rows, "hand:0", false, "local")
	var blank := Vector2(230, 365)
	check(table._is_blank_table_point(blank), "Blank-table fixture intersects a control")
	table._input(mouse(true, blank))
	table._input(mouse(false, blank))
	check(table.selected_entity_key.is_empty(), "Tapping blank table did not cancel selection")
	state.players[0].hand.clear()
	for index in range(25):
		state.players[0].hand.append("sv1-ener-2" if index % 2 == 0 else "sv1-ener-1")
	table.update_view(state, 0, [], "", false, "local")
	await settle()
	table.hand_scroll.scroll_horizontal = 55
	var anchor := table.hand_views[8]
	var identity := anchor.local_visual_id
	var previous_x := anchor.position.x - table.hand_scroll.scroll_horizontal
	state.players[0].hand.append("sv1-ener-3")
	state.revision += 1
	table.update_view(state, 0, [], "", false, "local")
	await settle()
	check(anchor.local_visual_id == identity and absf(anchor.position.x - table.hand_scroll.scroll_horizontal - previous_x) <= 2.0, "Drawing a card moved the retained hand browsing anchor")
	var browse_center := table.hand_scroll.scroll_horizontal + table.hand_scroll.size.x * 0.5
	var centered := table.hand_views[0]
	for view in table.hand_views:
		if absf(view.position.x + view.size.x * 0.5 - browse_center) < absf(centered.position.x + centered.size.x * 0.5 - browse_center):
			centered = view
	var center_fraction := (centered.position.x + centered.size.x * 0.5 - table.hand_scroll.scroll_horizontal) / table.hand_scroll.size.x
	root.size = Vector2i(900, 540)
	await settle(5)
	var resized_fraction := (centered.position.x + centered.size.x * 0.5 - table.hand_scroll.scroll_horizontal) / table.hand_scroll.size.x
	check(absf(center_fraction - resized_fraction) < 0.08, "Resizing lost the hand's visible browsing identity")
	root.size = Vector2i(1600, 900)
	table.queue_free()
	await settle()


func _check_confirmations() -> void:
	var main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	main.initialize_ui()
	var state := UIPreviewStateFactory.battle_state()
	state.revision = 20
	state.players[0].hand.assign(["sv1-ener-2", "sv1-171", "sv1-180"])
	main.state = state
	main.current_view_player = 0
	main.game_mode = "network"
	main.network_player_idx = 0
	main.network_legal_actions.assign([
		GameAction.create("ATTACH_ENERGY", {}, 0, EntityRef.new("card", 0, "hand", "", 0), EntityRef.new("pokemon", 0, "", "active")),
		GameAction.create("PLAY_TRAINER", {}, 0, EntityRef.new("card", 0, "hand", "", 1)),
		GameAction.create("PLAY_TRAINER", {}, 0, EntityRef.new("card", 0, "hand", "", 2)),
		GameAction.create("DECLARE_ATTACK", {"attack_index": 0}, 0),
		GameAction.create("USE_ABILITY", {"ability_index": 0}, 0),
	])
	main.shell_view.build_game_screen()
	await settle()
	main._select_hand_card(0, "sv1-ener-2")
	var selection: String = main.selected_entity_key
	main.battle_screen.header.detail_requested.emit()
	check(main.modal_layer.visible, "Details button did not open the inspector")
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	check(main.selected_entity_key == selection and not main.modal_layer.visible, "Inspector back did not restore the selected card")
	main._clear_battle_selection()
	main.battle_screen.hand_view._on_hand_drag_started(0)
	main._show_pause_overlay()
	await settle()
	check(main.battle_screen.active_drag_context().is_empty(), "Opening a modal stranded an unsubmitted drag")
	main.modal_confirm.pressed.emit()
	await settle()
	var mandatory := ChoiceView.new("usability:mandatory", state.revision, "confirm", 0, "必须完成的效果选择", [{"option_id": "yes", "label": "执行"}, {"option_id": "no", "label": "不执行"}], 1, 1, false, false)
	main._show_choice_overlay(mandatory)
	main._cancel_choice()
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	check(main.active_request == mandatory and main.modal_layer.visible, "A mandatory rules choice was cancelled by back or cancel")
	main.modal_host_controller.close()
	await settle()
	check(main._remaining_turn_action_labels() == ["附加能量", "使用支援者", "发动攻击"], "End-turn reminder must contain only the three legal opportunities: %s" % str(main._remaining_turn_action_labels()))
	var end_turn := GameAction.create("END_TURN", {}, 0)
	main._show_end_turn_confirmation(end_turn)
	var generation: int = main.modal_host_controller.generation
	main._execute_action(end_turn)
	check(main.modal_host_controller.generation == generation, "Repeated action replaced an open confirmation")
	state.revision += 1
	main.modal_confirm.pressed.emit()
	await settle()
	check(state.revision == 21 and not main.modal_layer.visible, "Stale confirmation changed the newer game state")
	main.game_mode = "local"
	main._show_pause_overlay()
	main.modal_cancel.pressed.emit()
	check(main.state == state and main.modal_title.text == "离开当前对局？", "Leaving the menu must ask before ending the match")
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	check(main.state == state and main.modal_title.text == "对局菜单", "Back from exit confirmation must restore the menu")
	main.modal_cancel.pressed.emit()
	main.modal_cancel.pressed.emit()
	check(main.state == state and main.modal_title.text == "对局菜单", "Cancelling exit ended the match")
	main.modal_cancel.pressed.emit()
	main.state = state.clone_state()
	main.modal_confirm.pressed.emit()
	await settle()
	check(main.state == null and main.current_screen == "title", "Confirmed local exit did not return to title")
	main.queue_free()
	await settle()
