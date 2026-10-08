extends SceneTree

## Reading panes must not compete with a scrolling modal for the same gesture.
const SIZES := [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(900, 540),
	Vector2i(640, 960), Vector2i(2560, 1392)]
var main: Control
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func settle(frames: int = 8) -> void:
	for frame in range(frames):
		await process_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw


func capture(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var directory := "res://../build/ui-scroll"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var path := "%s/%s-%dx%d.png" % [directory, label, root.size.x, root.size.y]
	check(root.get_texture().get_image().save_png(path) == OK, "Could not capture " + path)


func check_scroll_tree(node: Node, scrolling_ancestor: bool = false) -> void:
	if node is Control and not (node as Control).is_visible_in_tree():
		return
	var scrolls := false
	if node is ScrollContainer:
		scrolls = (node as ScrollContainer).get_v_scroll_bar().is_visible_in_tree()
	elif node is RichTextLabel:
		scrolls = (node as RichTextLabel).get_v_scroll_bar().is_visible_in_tree()
	check(not (scrolls and scrolling_ancestor), "Nested vertical scrollbars: " + str(node.get_path()))
	for child in node.get_children():
		check_scroll_tree(child, scrolling_ancestor or scrolls)


func run() -> void:
	var settings := root.get_node("AppSettings")
	settings.animation_mode = "reduced"
	settings.muted = true
	root.size = SIZES[0]
	main = load("res://scenes/main/main.tscn").instantiate() as Control
	root.add_child(main)
	await settle()
	var pokemon := PokemonState.new("svg2-turt")
	pokemon.energy_card_ids.assign(["sv1-ener-1", "sv1-ener-1", "svi-jete", "sv1-ener-1",
		"sv1-ener-1", "sv1-ener-1", "sv1-ener-1", "sv1-ener-1", "sv1-ener-1"])
	pokemon.attached_tool_id = "sv1-202"
	main._show_card_inspector({"card_id": pokemon.card_id, "pokemon": pokemon, "location": "玩家 1 战斗区"})
	var inspector := main.modal_body.get_child(0) as CardInspectorPanel
	for dimensions in SIZES:
		root.size = dimensions
		inspector.rule_scroll.scroll_vertical = 0
		await settle()
		check_scroll_tree(main.modal_scroll)
		check(main.modal_scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED, "Inspector has two scroll owners")
		for text in inspector.find_children("*", "RichTextLabel", true, false):
			if (text as Control).is_visible_in_tree():
				check(text.size.y + 2 >= text.get_content_height(), "Inspector text was clipped at %s" % dimensions)
		check(inspector._image_button.size.y <= inspector._image_button.custom_minimum_size.y + 2,
			"Long text stretched the card artwork at %s" % dimensions)
		var confirm_rect: Rect2 = main.modal_confirm.get_global_rect()
		capture("inspector")
		inspector.rule_scroll.scroll_vertical = int(inspector.rule_scroll.get_v_scroll_bar().max_value)
		await settle()
		var last_section := inspector.rule_contents.get_child(inspector.rule_contents.get_child_count() - 1) as Control
		check(last_section.get_global_rect().end.y <= inspector.rule_scroll.get_global_rect().end.y + 2,
			"Last attachment cannot be reached at %s" % dimensions)
		check(main.modal_confirm.get_global_rect().is_equal_approx(confirm_rect), "Scrolling moved the footer")
		capture("inspector-bottom")
	root.size = SIZES[0]
	inspector.rule_scroll.scroll_vertical = 0
	await settle()
	var text_target: Control = inspector.rule_scroll
	for candidate in inspector.find_children("*", "RichTextLabel", true, false):
		if (candidate as Control).is_visible_in_tree():
			text_target = candidate
			break
	var text_rect := text_target.get_global_rect().intersection(inspector.rule_scroll.get_global_rect())
	var pointer := root.get_final_transform() * text_rect.get_center()
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	wheel.position = pointer
	wheel.global_position = pointer
	Input.parse_input_event(wheel)
	await settle()
	check(inspector.rule_scroll.scroll_vertical > 0, "Scrolling over card text did not move the reading page")
	var saved_scroll: int = inspector.rule_scroll.scroll_vertical
	inspector.art_requested.emit()
	await settle()
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	inspector = main.modal_body.get_child(0) as CardInspectorPanel
	check(abs(inspector.rule_scroll.scroll_vertical - saved_scroll) <= 2, "Art zoom lost the reading position")
	inspector = main.modal_body.get_child(0) as CardInspectorPanel
	inspector.card_requested.emit({"card_id": "svi-jete", "location": "附着能量"})
	await settle()
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	inspector = main.modal_body.get_child(0) as CardInspectorPanel
	check(abs(inspector.rule_scroll.scroll_vertical - saved_scroll) <= 2, "Nested inspection lost the reading position")
	await check_choices()
	for kind in ["settings", "help", "deck", "zone"]:
		match kind:
			"settings": main._show_settings()
			"help": main._show_help()
			"deck": main._show_deck_details("grass")
			"zone": main._show_zone_inspector({"player": 0, "zone": "discard", "card_ids": ["svg2-turt", "svi-jete"]})
		for dimensions in [SIZES[0], SIZES[2], SIZES[3]]:
			root.size = dimensions
			await settle()
			check_scroll_tree(main.modal_scroll)
	main.queue_free()
	# Let deferred GUI teardown and pending scene callbacks drain before quitting.
	await settle(3)
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("MODAL_SCROLL_CONTRACT_OK")
	quit(0 if failures.is_empty() else 1)


func check_choices() -> void:
	var options: Array[Dictionary] = []
	for index in range(40):
		options.append({"option_id": "card:%d" % index, "label": "草苗龟 %d" % index,
			"ref": EntityRef.new("card", 0, "deck", "", index, "", "svg2-turt").to_dict()})
	var choice := ChoiceView.new("scroll-choice", 1, "select_card", 0, "请选择要加入手牌的卡牌。",
		options, 0, 2, false, true, {"source_card_id": "svg2-tort"})
	main._show_choice_overlay(choice)
	var panel := main.active_choice_panel as ChoicePanel
	check(panel != null, "Choice fixture did not create a panel")
	if panel == null:
		return
	panel._preview_card("svg2-tort")
	main._toggle_choice("card:0")
	for dimensions in SIZES:
		root.size = dimensions
		await settle()
		check_scroll_tree(main.modal_scroll)
		capture("choice")
		check(not panel.content_row.vertical and panel.preview_panel.visible
			and (panel.get_node("%OptionsScroll") as Control).visible,
			"Choice options and explanation must stay side by side")
		check(not panel.preview_return_button.visible,
			"Choice must not introduce a separate preview page")
		var preview_scroll := panel.preview_reader.rule_scroll
		var options_scroll := panel._choice_scroll_container()
		options_scroll.scroll_vertical = 100
		await settle()
		var saved_scroll := options_scroll.scroll_vertical
		preview_scroll.scroll_vertical = int(preview_scroll.get_v_scroll_bar().max_value)
		await settle()
		check(options_scroll.scroll_vertical == saved_scroll,
			"Reading card text changed the option-list position")
		check(main.selected_choice_ids == ["card:0"], "Reading a choice changed its selection")
		panel._preview_card("svg2-tort" if panel.previewed_card_id() != "svg2-tort" else "svi-jete")
		await settle()
		check(preview_scroll.scroll_vertical == 0, "A new card retained the previous reading position")

	main.modal_host_controller.close()
	await settle()
