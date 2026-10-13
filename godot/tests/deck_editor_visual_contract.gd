extends SceneTree

const Harness = preload("res://tests/ui_preview_harness.gd")
var failures: Array[String] = []
var harness: RefCounted

func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("run")

func run() -> void:
	harness = Harness.new()
	harness.configure(self)
	harness._enable_deterministic_preview_mode()
	Input.use_accumulated_input = false
	Input.emulate_mouse_from_touch = true
	var ui: Control = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(ui)
	ui.initialize_ui()
	await harness._settle_rendered(5)
	# Exercise a compact Android-sized surface below the desktop window minimum.
	root.min_size = Vector2i.ZERO
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://../build/deck-editor-preview"))
	for dimensions in [Vector2i(1600,900),Vector2i(900,540),Vector2i(1280,800),Vector2i(800,480)]:
		root.size = dimensions
		await harness._settle_rendered(4)
		ui.shell_view.show_deck_editor()
		var page := ui.screen_host.get_child(0) as DeckEditorPage
		page._load_deck("fire")
		await harness._settle_rendered(5)
		for node_name in ["BackButton","DeckPicker","Search","SaveButton","DeleteButton","PoolScroll","DeckScroll"]:
			var control: Control = page.get_node("%"+node_name)
			if not Rect2(Vector2.ZERO,ui.size).grow(2).encloses(control.get_global_rect()): failures.append("Editor overflow: %s %s" % [dimensions,node_name])
			if node_name in ["BackButton","DeckPicker","Search","SaveButton","DeleteButton"] and harness._physical_control_rect(control).size.y < 48: failures.append("Editor touch target below 48px: " + node_name)
		page.search.text = "喷火龙"
		page._filter()
		await harness._settle_rendered(3)
		if page._filtered.size() < 1: failures.append("Chinese search returned no cards")
		for cell in page.grid.get_children():
			var tile: Control = cell.get_child(0)
			var add: Control = cell.get_child(1)
			if tile.get_global_rect().end.y > add.get_global_rect().position.y + 1: failures.append("Card artwork overlaps add button")
		var first_add: Button = page.grid.get_child(0).get_child(1)
		if not (page.get_node("%PoolScroll") as Control).get_global_rect().grow(1).encloses(first_add.get_global_rect()):
			failures.append("First row Add button is below the fold: " + str(dimensions))
		var scroll: ScrollContainer = page.get_node("%DeckScroll")
		if scroll.get_v_scroll_bar().max_value > scroll.size.y:
			await swipe(scroll.get_global_rect().get_center(),Vector2(0,-120))
			if scroll.scroll_vertical <= 0 or page.is_dirty() or ui.modal_layer.visible: failures.append("Editor touch scroll failed or triggered a card button")
			scroll.scroll_vertical = 0
			await harness._settle_rendered(2)
		root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://../build/deck-editor-preview/editor-%d.png" % dimensions.x))
		var card_id := str(page._filtered[0])
		var add_id := first_add.get_instance_id()
		for _index in 3: await click(first_add)
		if page._count(card_id) != 3 or first_add.get_instance_id() != add_id: failures.append("Repeated mouse add lost clicks or replaced controls")
		await harness._settle_rendered(3)
		var plus: Button = page._row_controls[card_id].plus
		for _index in 2: await click(plus)
		if page._count(card_id) != 5: failures.append("Repeated deck quantity clicks failed")
		await click(page.get_node("%ValidationButton"))
		if not ui.modal_layer.visible or not "最多 4 张" in (ui.modal_body.get_child(0) as Label).text:
			failures.append("Full validation issues are not accessible by tap")
		ui.modal_host_controller.close()
		await harness._settle_rendered(3)
		page.handle_back()
		await harness._settle_rendered(3)
		if not ui.modal_layer.visible: failures.append("Unsaved return did not ask to discard edits")
		ui.modal_host_controller.close()
		await harness._settle_rendered(3)
	ui.shell_view.show_deck_select("local")
	var picker: DeckSelectPage = ui.screen_host.get_child(0)
	picker.select_deck(0, "water")
	picker.select_deck(1, "steel")
	picker.matchup_toggle.set_pressed_no_signal(true)
	picker._on_deck_tile_pressed("water")
	picker.get_node("%EditDecksButton").pressed.emit()
	await harness._settle_rendered(4)
	var editor: DeckEditorPage = ui.screen_host.get_child(0)
	if editor.selected_key != "water": failures.append("Edit entry did not open the previewed deck")
	editor.handle_back()
	await harness._settle_rendered(4)
	picker = ui.screen_host.get_child(0)
	if picker.selected_deck_key(0) != "water" or picker.selected_deck_key(1) != "steel" or not picker.matchup_toggle.button_pressed:
		failures.append("Editor round trip lost match selections")
	for failure in failures: push_error(failure)
	if failures.is_empty(): print("DECK_EDITOR_VISUAL_CONTRACT_OK")
	harness._finish(0 if failures.is_empty() else 1)

func click(control: Control) -> void:
	var point: Vector2 = harness._physical_control_rect(control).get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	Input.parse_input_event(motion)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = point
		event.global_position = point
		Input.parse_input_event(event)
		await process_frame
	await harness._settle_rendered(3)

func swipe(point: Vector2, delta: Vector2) -> void:
	var press := InputEventScreenTouch.new()
	press.position = root.get_final_transform() * point
	press.pressed = true
	Input.parse_input_event(press)
	await process_frame
	for index in range(1,7):
		var drag := InputEventScreenDrag.new()
		drag.position = root.get_final_transform() * (point + delta * float(index) / 6.0)
		drag.relative = root.get_final_transform().basis_xform(delta / 6.0)
		Input.parse_input_event(drag)
		await process_frame
	var release := InputEventScreenTouch.new()
	release.position = root.get_final_transform() * (point+delta)
	release.pressed = false
	Input.parse_input_event(release)
	await harness._settle_rendered(3)
