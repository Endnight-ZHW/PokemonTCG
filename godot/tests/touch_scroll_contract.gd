extends SceneTree

var failures: Array[String] = []
var router: Node
var pointer := Vector2.ZERO
var mouse_first := true


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func settle(frames: int = 3) -> void:
	for _frame in range(frames):
		await process_frame


func touch_button(pressed: bool, point: Vector2, cancelled: bool = false, index: int = 0) -> void:
	pointer = point
	var physical := root.get_final_transform() * point
	var touch := InputEventScreenTouch.new()
	touch.index = index
	touch.position = physical
	touch.pressed = pressed
	touch.canceled = cancelled
	var mouse := InputEventMouseButton.new()
	mouse.device = InputEvent.DEVICE_ID_EMULATION
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	mouse.pressed = pressed
	mouse.canceled = cancelled
	mouse.position = physical
	mouse.global_position = physical
	Input.parse_input_event(touch)
	if not mouse_first and index == 0:
		# Direct viewport delivery avoids emulating this companion back to touch.
		root.push_input(mouse)


func move_touch(point: Vector2) -> void:
	var physical := root.get_final_transform() * point
	var relative := root.get_final_transform().basis_xform(point - pointer)
	pointer = point
	var drag := InputEventScreenDrag.new()
	drag.position = physical
	drag.relative = relative
	var mouse := InputEventMouseMotion.new()
	mouse.device = InputEvent.DEVICE_ID_EMULATION
	mouse.position = physical
	mouse.global_position = physical
	mouse.relative = relative
	mouse.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(drag)
	if not mouse_first:
		root.push_input(mouse)


func tap(control: Control) -> void:
	var point := control.get_global_rect().get_center()
	touch_button(true, point)
	touch_button(false, point)
	await settle()


func swipe(point: Vector2, displacement: Vector2) -> void:
	touch_button(true, point)
	for step in range(1, 6):
		move_touch(point + displacement * float(step) / 5.0)
		await settle(1)
	touch_button(false, pointer)
	await settle()


func run() -> void:
	Input.use_accumulated_input = false
	router = root.get_node("TouchInput")
	root.get_node("AppSettings").animation_mode = "reduced"
	root.size = Vector2i(1280, 720)
	for order in [true, false]:
		mouse_first = order
		Input.emulate_mouse_from_touch = order
		await check_scroll_controls()
	mouse_first = true
	Input.emulate_mouse_from_touch = true
	await check_hand()
	await check_choices()
	await check_log()
	await check_nested_scroll()
	if failures.is_empty():
		print("TOUCH_SCROLL_CONTRACT_OK")
	for failure in failures:
		push_error(failure)
	quit(0 if failures.is_empty() else 1)


func check_scroll_controls() -> void:
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(60, 60)
	scroll.size = Vector2(480, 300)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)
	var card := load("res://ui/card_view.tscn").instantiate() as CardView
	card.custom_minimum_size = Vector2(130, 184)
	column.add_child(card)
	card.configure("sv1-ener-1")
	var button := Button.new()
	button.text = "可滚动按钮"
	button.custom_minimum_size = Vector2(0, 64)
	column.add_child(button)
	var slider := HSlider.new()
	slider.custom_minimum_size = Vector2(0, 64)
	slider.value = 50
	column.add_child(slider)
	var option := OptionButton.new()
	option.custom_minimum_size = Vector2(0, 64)
	option.add_item("选项一")
	option.add_item("选项二")
	column.add_child(option)
	for index in range(12):
		var extra := Button.new()
		extra.text = "更多内容 %d" % index
		extra.custom_minimum_size.y = 64
		column.add_child(extra)
	root.add_child(scroll)
	var clicks := [0, 0, 0]
	card.activated.connect(func(_a, _b, _c, _d): clicks[0] += 1)
	card.detail_requested.connect(func(_a): clicks[1] += 1)
	button.pressed.connect(func(): clicks[2] += 1)
	await settle()
	await tap(card)
	check(clicks[0] == 1, "Card touch must activate once, order=%s counts=%s" % [mouse_first, clicks])
	await swipe(card.get_global_rect().get_center(), Vector2(0, -90))
	check(scroll.scroll_vertical > 20, "Dragging a card did not scroll its list, order=%s" % mouse_first)
	check(clicks == [1, 0, 0], "Card scrolling activated a card or long press")
	check(router._scrolling.has(scroll.get_instance_id()), "Swipe fixture did not retain native inertia")
	var brake_point := card.get_global_rect().intersection(scroll.get_global_rect()).get_center()
	touch_button(true, brake_point)
	touch_button(false, brake_point)
	await settle()
	check(clicks == [1, 0, 0] and not router._scrolling.has(scroll.get_instance_id()), "Braking inertia activated a card or failed to stop")
	scroll.scroll_vertical = 0
	await settle()
	await tap(button)
	check(clicks[2] == 1, "Native button touch was lost")
	await swipe(button.get_global_rect().get_center(), Vector2(0, -80))
	check(scroll.scroll_vertical > 20 and clicks[2] == 1, "Button scroll clicked or did not move")
	scroll.scroll_vertical = 0
	await settle()
	var start := button.get_global_rect().get_center()
	touch_button(true, start)
	move_touch(start + Vector2(24, 0))
	move_touch(start)
	touch_button(false, start)
	await settle()
	check(clicks[2] == 1, "Moving out and returning restored a button tap")
	scroll.scroll_vertical = 190
	await settle()
	var before := slider.value
	await swipe(slider.get_global_rect().get_center() + Vector2(80, 0), Vector2(0, -70))
	check(is_equal_approx(slider.value, before), "Vertical slider swipe changed its value")
	check(scroll.scroll_vertical > 210, "Vertical slider swipe did not scroll")
	scroll.scroll_vertical = 190
	await settle()
	await swipe(slider.get_global_rect().get_center(), Vector2(100, 0))
	check(slider.value > before + 10, "Horizontal slider drag failed")
	check(scroll.scroll_vertical == 190, "Horizontal slider drag scrolled the list")
	start = slider.get_global_rect().position + Vector2(70, 30)
	before = slider.value
	touch_button(true, start)
	check(is_equal_approx(slider.value, before), "Slider committed before touch release")
	touch_button(false, start)
	await settle()
	check(slider.value < before, "Slider track tap did not commit on release")
	scroll.scroll_vertical = 270
	await settle()
	start = option.get_global_rect().get_center()
	touch_button(true, start)
	check(not option.get_popup().visible, "OptionButton opened on touch down, order=%s" % mouse_first)
	move_touch(start + Vector2(0, -65))
	touch_button(false, pointer)
	await settle()
	check(not option.get_popup().visible, "OptionButton opened after scrolling")
	scroll.scroll_vertical = 270
	await settle()
	await tap(option)
	check(option.get_popup().visible, "OptionButton did not open on a valid tap, order=%s" % mouse_first)
	option.get_popup().hide()
	scroll.scroll_vertical = 0
	await settle()
	start = card.get_global_rect().get_center()
	touch_button(true, start)
	touch_button(false, start, true)
	await settle()
	check(clicks[0] == 1, "Cancelled touch activated a card")
	touch_button(true, start)
	touch_button(true, button.get_global_rect().get_center(), false, 1)
	touch_button(false, button.get_global_rect().get_center(), false, 1)
	touch_button(false, start)
	await settle()
	check(clicks[0] == 2 and clicks[2] == 1, "A second finger stole the active gesture")
	touch_button(true, start)
	router.cancel_gesture()
	touch_button(false, start)
	await settle()
	check(clicks[0] == 2, "Lifecycle cancellation leaked a click")
	touch_button(true, start)
	await create_timer(0.4).timeout
	check(clicks[1] == 1, "Stationary touch lost its 350ms long press")
	touch_button(false, start)
	await settle()
	check(clicks[0] == 2, "Long-press release also clicked")
	await swipe(start, Vector2(0, 70))
	check(scroll.scroll_vertical == 0 and clicks[0] == 2, "Swiping at a scroll boundary became a tap")
	touch_button(true, start)
	for step in range(1, 7):
		move_touch(start + Vector2(0, -5 * step))
		await create_timer(0.05).timeout
	touch_button(false, pointer)
	await settle()
	check(scroll.scroll_vertical > 0 and clicks == [2, 1, 1], "Slow scrolling became a long press or click")
	scroll.scroll_vertical = 0
	await settle()
	touch_button(true, start)
	root.size += Vector2i(1, 0)
	touch_button(false, start)
	await settle()
	check(clicks[0] == 2, "Resizing during a press activated its stale target")
	root.size -= Vector2i(1, 0)
	await settle()
	touch_button(true, start)
	router._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	# No release: Android can lose it while the application is backgrounded.
	await settle()
	await tap(card)
	check(clicks[0] == 3, "Returning from background left touch input stuck")
	check(not router.is_processing(), "Idle touch router continues polling")
	scroll.queue_free()
	await settle()


func check_hand() -> void:
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(80, 350)
	scroll.size = Vector2(480, 220)
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var row := HBoxContainer.new()
	scroll.add_child(row)
	var cards: Array[CardView] = []
	var drags := [0]
	for index in range(8):
		var card := load("res://ui/card_view.tscn").instantiate() as CardView
		card.custom_minimum_size = Vector2(120, 175)
		row.add_child(card)
		card.configure("sv1-ener-1", null, false, index, 0)
		card.drag_started.connect(func(_index): drags[0] += 1)
		cards.append(card)
	root.add_child(scroll)
	await settle()
	var start := cards[1].get_global_rect().get_center()
	touch_button(true, start)
	move_touch(start + Vector2(-55, -2))
	await settle()
	move_touch(start + Vector2(-58, -90))
	touch_button(false, pointer)
	await settle()
	check(scroll.scroll_horizontal > 10 and drags[0] == 0, "Horizontal hand browsing turned into card drag")
	scroll.scroll_horizontal = 0
	await settle()
	start = cards[1].get_global_rect().get_center()
	touch_button(true, start)
	move_touch(start + Vector2(0, -15))
	check(drags[0] == 0, "Hand drag started below 24px")
	move_touch(start + Vector2(0, -45))
	await settle()
	check(drags[0] == 1 and root.gui_is_dragging(), "Intentional upward hand drag did not start")
	router.cancel_gesture()
	touch_button(false, pointer)
	await settle()
	check(not root.gui_is_dragging(), "Cancelled hand gesture left a native drag active")
	var target := load("res://ui/card_view.tscn").instantiate() as CardView
	target.position = Vector2(230, 80)
	target.size = Vector2(120, 175)
	root.add_child(target)
	target.configure("")
	target.configure_target(0, "active")
	target.set_interaction_state(false, "", "放置卡牌", [1])
	var drops := [0]
	target.card_dropped.connect(func(index, _id, player, slot):
		check(index == 1 and player == 0 and slot == "active", "Touch drop changed the legal target or card identity")
		drops[0] += 1
	)
	await settle()
	start = cards[1].get_global_rect().get_center()
	touch_button(true, start)
	move_touch(start + Vector2(0, -40))
	await settle()
	move_touch(target.get_global_rect().get_center())
	await settle()
	touch_button(false, pointer)
	await settle()
	check(drops[0] == 1 and not root.gui_is_dragging(), "Legal touch drop was lost, duplicated or left a drag active")
	target.queue_free()
	scroll.queue_free()
	await settle()


func check_choices() -> void:
	var main := load("res://scenes/main/main.tscn").instantiate() as Control
	root.add_child(main)
	await settle(8)
	var options: Array[Dictionary] = []
	for index in range(40):
		options.append({"option_id": "card:%d" % index, "label": "草苗龟 %d" % index,
			"ref": EntityRef.new("card", 0, "deck", "", index, "", "svg2-turt").to_dict()})
	var choice := ChoiceView.new("touch-choice", 1, "select_card", 0, "请选择卡牌。", options, 0, 2, false, true, {})
	main._show_choice_overlay(choice)
	for dimensions in [Vector2i(900, 540), Vector2i(640, 960), Vector2i(1600, 900), Vector2i(2560, 1392)]:
		root.size = dimensions
		await settle(8)
		var panel := main.active_choice_panel as ChoicePanel
		var scroll := panel._choice_scroll_container()
		scroll.scroll_vertical = 0
		await settle()
		var tile := panel._option_tiles["card:0"] as Control
		var point := tile.get_global_rect().intersection(scroll.get_global_rect()).get_center()
		await swipe(point, Vector2(0, -100))
		check(scroll.scroll_vertical > 20, "Actual choice list did not scroll at %s" % dimensions)
		check(main.selected_choice_ids.is_empty(), "Choice scrolling selected a card at %s" % dimensions)
		scroll.scroll_vertical = 0
		await settle()
		# Tile padding has its own handler; it must obey the same tap contract.
		point = tile.get_global_rect().position + Vector2(8, 8)
		touch_button(true, point)
		touch_button(false, point)
		await settle()
		check(main.selected_choice_ids == ["card:0"], "Tile padding tap failed at %s: %s" % [dimensions, main.selected_choice_ids])
		main._toggle_choice("card:0")
	var recovery_panel := main.active_choice_panel as ChoicePanel
	var recovery_tile := recovery_panel._option_tiles["card:0"] as Control
	var recovery_point := recovery_tile.get_global_rect().position + Vector2(8, 8)
	touch_button(true, recovery_point)
	router._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	touch_button(true, recovery_point, false, 1)
	touch_button(false, recovery_point, false, 1)
	await settle()
	check(main.selected_choice_ids == ["card:0"], "A tile rejected a fresh finger after a lost release")
	touch_button(false, recovery_point, true)
	await settle()
	main._toggle_choice("card:0")
	await check_energy(main)
	main.queue_free()
	await settle()


func check_energy(main: Control) -> void:
	root.size = Vector2i(900, 540)
	var state := UIPreviewStateFactory.battle_state()
	main.state = state
	main.current_view_player = 0
	var energies: Array[String] = ["svi-jete", "svi-dtur"]
	var targets := ["active", "bench_0", "bench_1", "bench_2", "bench_3", "bench_4"]
	var options: Array[Dictionary] = []
	for slot_value in targets:
		var slot := str(slot_value)
		for index in range(2):
			options.append({
				"option_id": "energy:%d:%s->pokemon:0:%s:svi-chim" % [index, energies[index], slot],
				"label": "小火焰猴",
				"ref": EntityRef.new("pokemon", 0, "", slot, -1, "", "svi-chim").to_dict(),
			})
	var choice := ChoiceView.new("touch-energy", state.revision, "distribute_energy", 0,
		"为每张能量选择目标。", options, 0, 2, false, false,
		{"card_ids": energies, "max_per_target": 2, "same_target": true, "source_player": 0, "source_zone": "hand"})
	main._show_choice_overlay(choice)
	await settle(8)
	var panel := main.active_choice_panel as ChoicePanel
	var scroll := panel._choice_scroll_container()
	var tile := panel.energy_distribution._energy_target_tiles["0:active"] as Control
	scroll.ensure_control_visible(tile)
	await settle()
	var point := tile.get_global_rect().intersection(scroll.get_global_rect()).get_center()
	var before := scroll.scroll_vertical
	await swipe(point, Vector2(0, -70))
	check(scroll.scroll_vertical > before and main.selected_choice_ids.is_empty(), "Energy target swipe allocated energy or failed to scroll")
	scroll.scroll_vertical = before
	await settle()
	touch_button(true, point)
	touch_button(false, point)
	await settle()
	check(main.selected_choice_ids.size() == 1, "Energy target tap did not allocate exactly once")
	# Placeholder energy cards share the real panel's layout and input route.
	var indices := [0]
	panel.energy_index_requested.connect(func(_index): indices[0] += 1)
	panel.energy_distribution.add_energy_preview([""], panel.catalog)
	scroll.scroll_vertical = 0
	await settle(5)
	var placeholder := panel.energy_grid.get_child(0).get_child(0) as Control
	point = placeholder.get_global_rect().get_center()
	await swipe(point, Vector2(0, -50))
	check(indices[0] == 0, "Swiping an energy placeholder selected its index")
	scroll.scroll_vertical = 0
	await settle()
	await tap(placeholder)
	check(indices[0] == 1, "Energy placeholder tap was lost or duplicated")


func check_log() -> void:
	root.size = Vector2i(900, 540)
	var log_panel := load("res://scenes/battle/components/battle_log_panel.tscn").instantiate() as BattleLogPanel
	log_panel.position = Vector2(100, 80)
	log_panel.size = Vector2(380, 320)
	log_panel.show()
	root.add_child(log_panel)
	var entries: Array = []
	for index in range(50):
		entries.append("玩家1抽取一张卡牌，行动记录 %d" % index)
	log_panel.update_entries(entries)
	await settle(8)
	var scroll := log_panel.log_scroll
	check(scroll.get_v_scroll_bar().max_value > scroll.size.y, "Log fixture is not scrollable")
	var bar := scroll.get_v_scroll_bar()
	check(bar.value >= bar.max_value - bar.page - 2.0, "New log did not start at the latest entry")
	scroll.scroll_vertical = 0
	await settle()
	await swipe(scroll.get_global_rect().get_center(), Vector2(0, -90))
	check(scroll.scroll_vertical > 20, "Swiping log text did not scroll")
	scroll.scroll_vertical = 80
	await settle()
	entries.append("玩家2使用了支援者")
	log_panel.update_entries(entries)
	await settle()
	check(scroll.scroll_vertical == 80, "Updating the log lost the history reading position")
	scroll.scroll_vertical = int(bar.max_value)
	await settle()
	entries.append("玩家2结束回合")
	log_panel.update_entries(entries)
	await settle()
	check(bar.value >= bar.max_value - bar.page - 2.0, "Log stopped following new entries while at the bottom")
	check(log_panel.close_button.size.x >= 48 and log_panel.close_button.size.y >= 48, "Log close target is too small")
	log_panel.queue_free()
	await settle()


func check_nested_scroll() -> void:
	var outer := ScrollContainer.new()
	outer.position = Vector2(80, 80)
	outer.size = Vector2(400, 180)
	outer.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var inner := ScrollContainer.new()
	inner.custom_minimum_size = Vector2(380, 600)
	inner.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	inner.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(inner)
	var button := Button.new()
	button.custom_minimum_size = Vector2(360, 600)
	button.text = "内层不滚动，外层负责浏览"
	inner.add_child(button)
	root.add_child(outer)
	var clicks := [0]
	button.pressed.connect(func(): clicks[0] += 1)
	await settle()
	await swipe(outer.get_global_rect().get_center(), Vector2(0, -70))
	check(outer.scroll_vertical > 20 and clicks[0] == 0, "A non-scrolling inner container swallowed its parent's touch gesture")
	outer.queue_free()
	await settle()
