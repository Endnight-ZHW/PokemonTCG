extends SceneTree

const OUTPUT := "res://../build/choice-detail-integration"
var main: Control
var state: GameState
var harness := UIPreviewHarness.new()
var failures: Array[String] = []
var captures: Array[String] = []
var graphics := false
var catalog_checked := 0


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("run")


func run() -> void:
	graphics = DisplayServer.get_name() != "headless"
	Engine.max_fps = 60 if graphics else 0
	create_timer(180).timeout.connect(func() -> void:
		push_error("Choice card detail test timed out")
		quit(1))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	root.size = Vector2i(1600, 900)
	harness.configure(self)
	harness._enable_deterministic_preview_mode()
	root.get_node("AppSettings").muted = true
	main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	await settle()
	state = UIPreviewStateFactory.battle_state()
	main.state = state
	main.game_mode = "local"
	main.current_view_player = 0
	main.shell_view.build_game_screen()
	await settle()
	harness._update_battle_preview(main, state, [], "")
	# Observe public responses without submitting these UI fixtures to a match.
	for connection in main.choice_presenter.response_ready.get_connections():
		main.choice_presenter.response_ready.disconnect(connection.callable)
	await check_search()
	await check_discard_and_reveal()
	await check_distribution()
	await check_attack()
	# Rapidly replaced choices may still have pending layout/scroll callbacks.
	for index in 4:
		main._show_choice_overlay(search_request())
		main.active_choice_panel._preview_card("svi-maus")
	main.modal_host_controller.close()
	await settle()
	main.choice_presenter.clear()
	FileAccess.open(OUTPUT.path_join("validation-%s.json" % ("graphics" if graphics else "headless")), FileAccess.WRITE).store_string(JSON.stringify({
		"failures": failures, "captures": captures, "cards": catalog_checked,
		"has_reference": FileAccess.file_exists(OUTPUT.path_join("before-search.png")),
	}, "  "))
	main.queue_free()
	await settle(3)
	if failures.is_empty(): print("CHOICE_CARD_DETAIL_OK cards=%d captures=%d graphics=%s" % [catalog_checked, captures.size(), graphics])
	else:
		for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)


func search_request() -> ChoiceView:
	var refs: Array[Dictionary] = []
	var options: Array[Dictionary] = []
	var selected := {0: "svi-chiy", 3: "svi-chim", 23: "svi-chim", 34: "svi-chim", 45: "svi-ente"}
	for index in 46:
		var id := str(selected.get(index, "sv1-ener-2" if index % 2 == 0 else "sv1-189"))
		var ref := EntityRef.new("card", 0, "deck", "", index, "", id).to_dict()
		refs.append(ref)
		if selected.has(index):
			options.append({"option_id": "deck:%d" % index, "label": main.catalog.card_name(id), "ref": ref})
	return ChoiceView.new("detail-search", state.revision, "search_move", 0, "请选择要搜寻的卡牌。", options, 1, 1, false, false,
		{"domain": "search", "purpose": "search_move", "source_player": 0, "source_zone": "deck", "browse_card_refs": refs})


func check_search() -> void:
	main._show_choice_overlay(search_request())
	await settle()
	var panel := main.active_choice_panel as ChoicePanel
	await click(panel._option_tiles["deck:0"])
	check(main.selected_choice_ids == ["deck:0"], "Initial card click did not select Chi-Yu")
	for dimensions in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(1024, 768), Vector2i(3392, 2292)]:
		root.size = dimensions
		await settle(12)
		check_layout(panel)
		check(panel.preview_reader.art_button.size.y <= 80, "Large artwork still pushes rules below the fold")
		check(main.selected_choice_ids == ["deck:0"], "Resize changed the selected card")
		await capture("01-search-%dx%d" % [dimensions.x, dimensions.y])
	root.size = Vector2i(1600, 900)
	await settle()
	# Every catalog card must fit the embedded reading column without horizontal
	# overflow or a second scroll owner, including trainer/energy usage rules.
	for id in main.catalog.cards:
		panel._preview_card(id)
		await settle(4)
		check_content(panel.preview_reader.rule_contents, panel.preview_reader.rule_scroll.size.x)
		check(not panel.preview_reader.rule_scroll.get_h_scroll_bar().visible, "Horizontal preview scrollbar: " + str(id))
		catalog_checked += 1
	check(main.selected_choice_ids == ["deck:0"], "Reading other cards changed the selected card")
	await click(panel.browse_all_button)
	check(panel.card_option_count() == 46 and panel._read_only_option_keys.size() == 41, "All-card view changed legal selection rules")
	var read_only := str(panel._read_only_option_keys.keys()[0])
	panel._request_card_option(read_only, str(panel._option_card_ids[read_only]))
	check(main.selected_choice_ids == ["deck:0"], "Inspecting a read-only card selected it")
	panel._preview_card("svi-maus")
	root.size = Vector2i(900, 540)
	await settle(12)
	var reader := panel.preview_reader
	panel._choice_scroll_container().scroll_vertical = 120
	await settle(2)
	var list_position := panel._choice_scroll_container().scroll_vertical
	var header_position := reader.title_label.get_global_rect()
	await wheel(reader.rule_scroll, 6)
	var rules_position := reader.get_reading_position()
	check(rules_position > 0, "Wheel input cannot read long card effects")
	check(reader.title_label.get_global_rect().is_equal_approx(header_position), "Reading rules moved fixed card identity")
	check(panel._choice_scroll_container().scroll_vertical == list_position, "Reading rules scrolled card choices")
	panel._preview_card("svi-maus")
	await settle()
	check(reader.get_reading_position() == rules_position, "Refreshing same preview lost its reading position")
	await click(reader.art_button)
	check(reader.showing_art and reader.large_art.texture != null, "Artwork click did not open art view")
	await capture("02-artwork-900x540")
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	check(main.modal_layer.visible and not reader.showing_art and reader.get_reading_position() == rules_position,
		"System back cancelled the choice or lost the rule reading position")
	check(main.selected_choice_ids == ["deck:0"] and panel._choice_scroll_container().scroll_vertical == list_position,
		"Artwork return changed selection or list position")
	panel._preview_card("svi-chiy")
	await settle()
	check(reader.get_reading_position() == 0, "Different card retained the previous scroll position")
	await click(reader.art_button, true)
	check(reader.showing_art, "Touch cannot open the card art")
	await click(reader.art_return_button, true)
	check(not reader.showing_art and main.selected_choice_ids == ["deck:0"], "Touch art return changed the choice")
	panel._preview_card("__missing_card")
	await settle()
	check(reader.art_button.disabled and reader.art_image.texture == null, "Missing art has an active broken zoom action")
	check_layout(panel)
	panel._preview_card("svi-chiy")
	await settle()
	var responses: Array[ChoiceResponse] = []
	var recorder := func(_request: ChoiceView, response: ChoiceResponse) -> void: responses.append(response)
	main.choice_presenter.response_ready.connect(recorder)
	await click(main.modal_confirm)
	check(responses.size() == 1 and responses[0].option_ids == ["deck:0"] and not responses[0].cancelled, "Confirm submitted the previewed card instead of the selected card")
	main.choice_presenter.response_ready.disconnect(recorder)
	main.choice_presenter.clear()


func check_discard_and_reveal() -> void:
	root.size = Vector2i(1280, 720)
	var options: Array[Dictionary] = []
	for id in ["sv1-189", "svg2-lume", "svi-jete"]:
		options.append({"option_id": id, "label": main.catalog.card_name(id), "ref": EntityRef.new("card", 0, "discard", "", options.size(), "", id).to_dict()})
	var request := ChoiceView.new("detail-discard", state.revision, "select_cards", 0, "选择要回收的卡牌。", options, 0, 2, false, true)
	main._show_choice_overlay(request)
	await settle()
	var panel := main.active_choice_panel as ChoicePanel
	await click(panel._option_tiles["sv1-189"])
	check_layout(panel)
	await capture("03-discard-trainer")
	panel._preview_card("svg2-lume")
	await settle()
	check_layout(panel)
	await capture("04-discard-special-energy")
	var responses: Array[ChoiceResponse] = []
	var recorder := func(_request: ChoiceView, response: ChoiceResponse) -> void: responses.append(response)
	main.choice_presenter.response_ready.connect(recorder)
	await click(panel.preview_reader.art_button)
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	check(responses.is_empty() and main.modal_layer.visible, "Back from art cancelled optional choice")
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	check(responses.size() == 1 and responses[0].cancelled and responses[0].option_ids.is_empty(), "Optional choice cancellation failed after preview back")
	main.choice_presenter.response_ready.disconnect(recorder)
	main.choice_presenter.clear()
	request = ChoiceView.new("detail-revealed", state.revision, "select_cards", 0, "查看公开的卡牌。", options, 0, 2, false, true,
		{"revealed_card_ids": ["sv1-189", "svg2-lume", "svi-jete"]})
	main._show_choice_overlay(request)
	await settle()
	panel = main.active_choice_panel
	panel._preview_card("sv1-189")
	check_layout(panel)
	await capture("05-revealed-cards")
	main.modal_host_controller.close()
	await settle()
	main.choice_presenter.clear()


func check_distribution() -> void:
	root.size = Vector2i(1600, 900)
	var energies: Array[String] = ["sv1-ener-2", "svi-dtur", "sv1-ener-2"]
	var options: Array[Dictionary] = []
	for slot in ["active", "bench_0", "bench_1"]:
		var pokemon := state.players[0].get_pokemon(slot)
		if pokemon == null: continue
		for index in energies.size():
			options.append({"option_id": "energy:%d:%s->pokemon:0:%s:%s" % [index, energies[index], slot, pokemon.card_id],
				"ref": EntityRef.new("pokemon", 0, "", slot, -1, "", pokemon.card_id).to_dict()})
	var request := ChoiceView.new("detail-distribution", state.revision, "distribute_energy", 0, "为每张能量选择附着目标", options, 3, 3, false, true,
		{"card_ids": energies, "max_per_target": 3})
	main._show_choice_overlay(request)
	await settle()
	var panel := main.active_choice_panel as ChoicePanel
	await click(panel.energy_distribution._energy_preview_cards[1])
	await click(panel.energy_distribution._energy_target_tiles["0:active"])
	await click(panel.energy_distribution._energy_preview_cards[1])
	var draft := main.choice_model.energy_draft as EnergyDistributionModel
	var assignments := draft.assignments.duplicate()
	var index := draft.current_index
	await click(panel.get_node("EnergyActions/EnergyDetailButton"))
	check(panel.preview_panel.visible, "Energy detail did not open")
	await capture("06-distribution-energy-detail")
	await click(panel.preview_reader.art_button)
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	check(panel.preview_panel.visible and not panel.preview_reader.showing_art, "Back from energy art skipped the rule view")
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	check(not panel.preview_panel.visible and main.modal_layer.visible and draft.assignments == assignments and draft.current_index == index,
		"Energy detail back changed the distribution draft")
	await capture("07-distribution-return")
	main.modal_host_controller.close()
	await settle()
	main.choice_presenter.clear()


func check_attack() -> void:
	for id in ["svi-chiy", "svd-absol"]:
		state.players[0].active = PokemonState.new(id)
		var index := 1 if id == "svi-chiy" else 0
		var action := GameAction.create("DECLARE_ATTACK", {"attack_index": index}, 0)
		main.choice_presenter.show_attack_confirmation(action, state, main.catalog, func() -> void: pass)
		await settle()
		var block := main.modal_body.find_child("AttackRule", true, false) as VBoxContainer
		check(block != null, "Attack confirmation lacks the shared attack component")
		if id == "svd-absol":
			check(block.find_child("PrintedDamage", true, false) == null, "Attack confirmation invented Absol's printed damage")
		check(main.modal_confirm.get_global_rect().end.y <= main.get_global_rect().end.y + 1, "Attack confirmation footer overflow")
		check(not main.modal_scroll.get_v_scroll_bar().visible, "Normal attack confirmation requires scrolling")
		await capture("08-confirm-" + id)
		await click(main.modal_cancel)


func check_layout(panel: ChoicePanel) -> void:
	check(not panel.content_row.vertical, "Card choices and reading pane no longer sit side by side")
	check(not main.modal_scroll.get_v_scroll_bar().visible, "Modal introduced nested vertical scrolling")
	check(not panel.preview_reader.rule_scroll.get_h_scroll_bar().visible, "Card reading pane overflows horizontally")
	check(main.modal_confirm.get_global_rect().end.y <= main.get_global_rect().end.y + 1, "Confirmation escaped safe area")
	check(main.modal_panel.get_global_rect().grow(1).encloses(panel.get_global_rect()), "Choice body escaped modal")
	check_content(panel.preview_reader.rule_contents, panel.preview_reader.rule_scroll.size.x)


func check_content(node: Node, width: float) -> void:
	if node is RichTextLabel:
		check(not node.scroll_active and node.size.y + 2 >= node.get_content_height(), "Card text is clipped or nested-scrolling")
	for child in node.get_children():
		if child is Control and child.is_visible_in_tree():
			check(child.size.x <= width + 2, "Card content exceeds its reading pane")
		check_content(child, width)


func click(control: Control, touch := false) -> void:
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
			event.pressed = pressed
			event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
			root.push_input(event)
		await process_frame
	await settle()


func wheel(control: Control, count: int) -> void:
	var point := root.get_final_transform() * control.get_global_rect().get_center()
	for index in count:
		for pressed in [true, false]:
			var event := InputEventMouseButton.new()
			event.position = point
			event.global_position = point
			event.button_index = MOUSE_BUTTON_WHEEL_DOWN
			event.pressed = pressed
			root.push_input(event)
		await settle(1)


func capture(label: String) -> void:
	if not graphics: return
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(OUTPUT.path_join(label + ".png")) == OK, "Screenshot failed: " + label)
	captures.append(label + ".png")


func settle(frames := 8) -> void:
	for frame in frames: await process_frame
	if graphics: await RenderingServer.frame_post_draw


func check(ok: bool, message: String) -> void:
	if not ok and message not in failures: failures.append(message)
