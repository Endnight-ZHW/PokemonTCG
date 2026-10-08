extends SceneTree

const POPOVER := preload("res://scenes/battle/components/card_action_popover.tscn")
const OUTPUT := "res://../build/battle-interaction-review/vertical-actions"
var failures: Array[String] = []


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("run")


func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)


func settle(frames := 8) -> void:
	for _frame in range(frames):
		await process_frame


func rows(count: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(count):
		result.append({"action": GameAction.create("DECLARE_ATTACK", {"attack_index": index}, 0),
			"label": "[火无] 螺旋业火 · %d×\n攻击后结束回合" % (80 + index),
			"icon": EnergyIconCatalog.texture_for("Fire")})
	return result


func check_vertical(popover: CardActionPopover, safe: Rect2, context: String) -> void:
	check(popover.action_scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED,
		"Horizontal scrolling was enabled: " + context)
	check(not popover.action_scroll.get_h_scroll_bar().visible, "Horizontal scrollbar is visible: " + context)
	check(safe.grow(1).encloses(popover.panel_global_rect()), "Menu leaves its safe rectangle: " + context)
	var previous_end := -INF
	var viewport := popover.action_scroll.get_global_rect()
	var scrollbar := popover.action_scroll.get_v_scroll_bar()
	if scrollbar.visible:
		viewport.size.x -= scrollbar.size.x
	for child in popover.action_buttons.get_children():
		var button := child as Button
		var rect := button.get_global_rect()
		check(rect.position.y >= previous_end, "Buttons are side by side or overlap: " + context)
		check(rect.position.x >= viewport.position.x - 1 and rect.end.x <= viewport.end.x + 1,
			"Action is clipped horizontally: " + context)
		check(button.size.y >= 48 and button.size.x >= 48, "Action lost its touch size: " + context)
		previous_end = rect.end.y


func tap_visible(button: Button, scroll: ScrollContainer, touch: bool) -> void:
	var point := root.get_final_transform() * button.get_global_rect().intersection(scroll.get_global_rect()).get_center()
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


func swipe_up(scroll: ScrollContainer) -> void:
	var point := root.get_final_transform() * scroll.get_global_rect().get_center()
	var press := InputEventScreenTouch.new()
	press.position = point
	press.pressed = true
	Input.parse_input_event(press)
	for _step in range(5):
		var drag := InputEventScreenDrag.new()
		drag.relative = Vector2(0, -14)
		point += drag.relative
		drag.position = point
		Input.parse_input_event(drag)
		await settle(1)
	var release := InputEventScreenTouch.new()
	release.position = point
	Input.parse_input_event(release)
	await settle()


func check_crowded_menu() -> void:
	var popover := POPOVER.instantiate() as CardActionPopover
	popover.theme = load("res://ui/game_theme.tres")
	root.add_child(popover)
	var chosen: Array[GameAction] = []
	popover.action_chosen.connect(func(action: GameAction) -> void: chosen.append(action))
	var safe := Rect2(24, 24, 720, 360)
	var source := Rect2(270, 112, 100, 160)
	var avoids: Array[Rect2] = [Rect2(0, 0, 900, 500)]
	for touch in [false, true]:
		popover.show_actions(rows(8), source, safe, avoids, "烈焰猴")
		await settle()
		check_vertical(popover, safe, "crowded menu")
		check(popover.action_scroll.get_v_scroll_bar().visible, "Crowded menu did not scroll vertically")
		check(not popover.panel_global_rect().intersects(source), "Crowded menu hides its selected card")
		if touch:
			await swipe_up(popover.action_scroll)
			check(popover.action_scroll.scroll_vertical > 0 and chosen.size() == 1 and popover.visible,
				"Vertical touch swipe failed to scroll or accidentally executed an action")
		var last := popover.action_buttons.get_child(7) as Button
		popover.action_scroll.ensure_control_visible(last)
		await settle()
		check(popover.action_scroll.scroll_vertical > 0, "Last action could not be reached by vertical scrolling")
		await tap_visible(last, popover.action_scroll, touch)
		check(chosen.size() == (2 if touch else 1) and chosen.back().attack_index() == 7, "Scrolled action was not dispatched exactly once")
	popover.show_actions(rows(3), source, safe, [], "烈焰猴")
	await settle()
	check_vertical(popover, safe, "reused menu")
	check(popover.action_scroll.scroll_vertical == 0, "A new menu retained the previous scroll position")
	popover.queue_free()
	await settle()


func check_full_list_placement() -> void:
	var popover := POPOVER.instantiate() as CardActionPopover
	popover.theme = load("res://ui/game_theme.tres")
	root.add_child(popover)
	var safe := Rect2(24, 24, 960, 640)
	var source := Rect2(360, 380, 100, 160)
	var lower_obstacle := Rect2(470, 530, 380, 130)
	popover.show_actions(rows(3), source, safe, [lower_obstacle], "烈焰猴")
	await settle()
	check_vertical(popover, safe, "shifted full list")
	check(not popover.action_scroll.get_v_scroll_bar().visible, "Menu scrolled although shifting upward fits all actions")
	check(popover.current_placement == "right" and popover.panel_global_rect().end.y < lower_obstacle.position.y,
		"Full menu did not move above the lower obstacle")
	popover.show_actions(rows(7), source, Rect2(24, 24, 1100, 800), [], "完整动作列表")
	await settle()
	check(not popover.action_scroll.get_v_scroll_bar().visible, "Large window retained a fixed four-action cutoff")
	await capture("full-action-list")
	var hand := load("res://ui/card_view.tscn").instantiate() as CardView
	root.add_child(hand)
	hand.position = Vector2(360, 450)
	hand.size = Vector2(112, 156)
	hand.configure("sv1-151", null, false, 0, 0, "", true)
	await settle()
	popover.show_for_control(rows(7), hand, Rect2(24, 100, 960, 600))
	await settle()
	check(popover.panel_global_rect().end.y + popover.anchor_gap <= hand.visual_global_bounds().position.y + 1,
		"A tall hand menu was clamped over its source instead of scrolling")
	check(popover.action_scroll.get_v_scroll_bar().visible, "A hand menu without enough space failed to scroll vertically")
	hand.queue_free()
	popover.queue_free()
	await settle()


func check_battle_menu() -> void:
	var table := load("res://scenes/battle/components/battle_table.tscn").instantiate() as BattleTable
	table.theme = load("res://ui/game_theme.tres")
	root.add_child(table)
	await settle()
	var state := UIPreviewStateFactory.battle_state()
	state.players[0].active = PokemonState.new("svi-infr")
	state.players[0].active.energy_card_ids.assign(["sv1-ener-2", "sv1-ener-2", "sv1-ener-2"])
	var actions := rows(2)
	actions.push_front({"action": GameAction.create("RETREAT", {}, 0,
		EntityRef.new("pokemon", 0, "", "active"), EntityRef.new("pokemon", 0, "", "bench_0"))})
	actions.append({"action": GameAction.create("END_TURN", {}, 0)})
	for dimensions in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(1024, 768), Vector2i(900, 540)]:
		root.size = dimensions
		root.content_scale_size = dimensions
		table.update_view(state, 0, actions, "pokemon:0:active", false, "local")
		await settle(12)
		check_vertical(table.action_popover, table.board_view._safe_popover_rect(), str(dimensions))
		check(not table.action_popover.panel_global_rect().intersects(table.own_active.visual_global_bounds()), "Battle menu hides its source at " + str(dimensions))
		await capture("battle-actions-%dx%d" % [dimensions.x, dimensions.y])
		# Source changes and resizes reuse the same popover instance.
		var hand_rows: Array[Dictionary] = [{"action": GameAction.create("ATTACH_ENERGY", {}, 0,
			EntityRef.new("card", 0, "hand", "", 0), EntityRef.new("pokemon", 0, "", "active"))}]
		table.update_view(state, 0, hand_rows, "hand:0", false, "local")
		await settle()
		check_vertical(table.action_popover, table.board_view._safe_popover_rect(), "hand " + str(dimensions))
		check(table.action_popover.current_placement == "above", "Hand action lost its predictable anchor")
	table.queue_free()
	await settle()


func run() -> void:
	Input.use_accumulated_input = false
	root.get_node("AppSettings").animation_mode = "reduced"
	root.size = Vector2i(1600, 900)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	await check_crowded_menu()
	await check_full_list_placement()
	await check_battle_menu()
	for message in failures:
		push_error(message)
	if failures.is_empty():
		print("CARD_ACTION_POPOVER_LAYOUT_OK")
	quit(0 if failures.is_empty() else 1)
