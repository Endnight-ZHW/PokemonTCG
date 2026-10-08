extends SceneTree

const OUTPUT := "res://../build/card-detail-integration"
var main: Control
var table: BattleTable
var harness := UIPreviewHarness.new()
var failures: Array[String] = []
var captures: Array[String] = []
var audit: Dictionary = {}
var graphics := false


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("run")


func run() -> void:
	graphics = DisplayServer.get_name() != "headless"
	Engine.max_fps = 60 if graphics else 0
	create_timer(180).timeout.connect(func() -> void:
		push_error("Card detail integration timed out")
		quit(1))
	root.size = Vector2i(1600, 900)
	harness.configure(self)
	harness._enable_deterministic_preview_mode()
	root.get_node("AppSettings").muted = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	await settle()
	var title_page: Control = main.screen_host.get_child(0)
	title_page.showcase_timer.stop()
	title_page._deck_index = title_page._deck_keys.find("grass")
	title_page._refresh_featured_deck()
	await check_full_details()
	await check_sidebar()
	FileAccess.open(OUTPUT.path_join("validation-%s.json" % ("graphics" if graphics else "headless")), FileAccess.WRITE).store_string(
		JSON.stringify({"failures": failures, "captures": captures, "catalog": audit}, "  "))
	main.queue_free()
	await settle(3)
	if failures.is_empty():
		print("CARD_DETAIL_REDESIGN_OK graphics=%s cards=%d captures=%d" % [graphics, audit.get("cards", 0), captures.size()])
	else:
		for failure in failures: push_error(failure)
	quit(0 if failures.is_empty() else 1)


func specimen() -> PokemonState:
	var pokemon := PokemonState.new("svg2-tort")
	pokemon.damage_counters = 5
	pokemon.status_conditions.assign(["POISONED", "CONFUSED"])
	pokemon.evolution_stack_ids.assign(["svg2-turt", "svg2-grot"])
	pokemon.energy_card_ids.assign(["sv1-ener-1", "sv1-ener-1", "sv1-ener-1", "sv1-ener-1", "svg2-lume", "svi-jete"])
	pokemon.attached_tool_id = "svg2-exps"
	return pokemon


func inspector() -> CardInspectorPanel:
	return main.modal_body.get_child(0) as CardInspectorPanel


func check_full_details() -> void:
	main._show_card_inspector({"card_id": "svg2-tort"})
	await settle()
	await capture("01-front-1600")
	var pokemon := specimen()
	main._show_card_inspector({"card_id": pokemon.card_id, "pokemon": pokemon, "location": "我方战斗区"})
	await settle()
	var panel := inspector()
	check(panel.attachment_buttons.size() == 7, "Evolution order / duplicate energy grouping incorrect")
	var ids: Array[String] = []
	for button in panel.attachment_buttons: ids.append(str(button.get_meta("card_id")))
	check(ids == ["svg2-turt", "svg2-grot", "svg2-tort", "sv1-ener-1", "svg2-lume", "svi-jete", "svg2-exps"], "Attachment identities or evolution order changed")
	var art_rect := panel._image_button.get_global_rect()
	var footer_rect: Rect2 = main.modal_confirm.get_global_rect()
	await wheel(panel.rule_scroll, 5)
	check(panel.get_reading_position() > 0, "Wheel input did not scroll the right reading pane")
	check(panel._image_button.get_global_rect().is_equal_approx(art_rect), "Scrolling moved fixed artwork")
	check(main.modal_confirm.get_global_rect().is_equal_approx(footer_rect), "Scrolling moved fixed modal footer")
	var saved := panel.get_reading_position()
	await click(panel._zoom_button)
	check(main.modal_body.get_child(0) is CardArtPanel, "Zoom button did not open real art viewer")
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	check(absi(inspector().get_reading_position() - saved) <= 2, "Android back lost reading position after zoom")
	panel = inspector()
	panel.rule_scroll.scroll_vertical = int(panel.rule_scroll.get_v_scroll_bar().max_value)
	await settle()
	saved = panel.get_reading_position()
	await capture("02-attachments-bottom")
	await click(panel.attachment_buttons.back())
	check(main.modal_title.text == "学习装置", "Attachment click did not open its own detail")
	await click(inspector()._zoom_button)
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	check(main.modal_title.text == "学习装置" and inspector().get_reading_position() == 0, "Nested art return skipped a level")
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	check(main.modal_title.text == "土台龟" and absi(inspector().get_reading_position() - saved) <= 2, "Nested attachment return lost its parent position")
	await touch_click(inspector().attachment_buttons.back())
	check(main.modal_title.text == "学习装置", "Touch tap did not open attachment detail")
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await settle()
	panel = inspector()
	panel.configure(CardCatalog.shared(), {"card_id": pokemon.card_id, "pokemon": pokemon})
	await settle()
	panel.rule_scroll.scroll_vertical = 150
	await settle(2)
	saved = panel.get_reading_position()
	pokemon.damage_counters += 1
	panel.configure(CardCatalog.shared(), {"card_id": pokemon.card_id, "pokemon": pokemon})
	await settle()
	check(absi(panel.get_reading_position() - saved) <= 2, "Full inspector state refresh lost reading position")
	panel.configure(CardCatalog.shared(), {"card_id": pokemon.card_id, "pokemon": specimen()})
	await settle()
	check(panel.get_reading_position() == 0, "Full inspector reused reading position for another instance")
	for size_value in [Vector2i(1280, 720), Vector2i(1024, 768)]:
		root.size = size_value
		await settle()
		for id in ["svi-maus", "sv1-189", "svg2-lume"]:
			main._show_card_inspector({"card_id": id})
			await settle()
			check_full_geometry()
			await capture("03-%s-%dx%d" % [id, size_value.x, size_value.y])
	# Missing art and extended rule text must remain readable in the real panel.
	var isolated := CardCatalog.new(true)
	var long_card := Dictionary(isolated.get_card("sv1-189")).duplicate(true)
	long_card["image_path"] = ""
	long_card["rules"] = ["完整效果说明。".repeat(100), CardPresentation.TRAINER_USAGE_RULES[1]]
	isolated.cards["__detail_long"] = long_card
	panel = inspector()
	panel.configure(isolated, {"card_id": "__detail_long"})
	await settle()
	check(panel._image_button.icon == null, "Missing-art fixture did not exercise fallback")
	check_full_geometry()
	await touch_swipe(panel.rule_scroll, Vector2(0, -160))
	check(panel.get_reading_position() > 0, "Touch input did not scroll card rules")
	panel.rule_scroll.scroll_vertical = int(panel.rule_scroll.get_v_scroll_bar().max_value)
	await settle()
	var last := panel.rule_contents.get_child(panel.rule_contents.get_child_count() - 1) as Control
	check(last.get_global_rect().end.y <= panel.rule_scroll.get_global_rect().end.y + 2, "Long effects cannot be read to the end")
	await capture("04-long-missing-art")
	var long_pokemon := Dictionary(isolated.get_card("svg2-tort")).duplicate(true)
	long_pokemon.name = "守护伙伴的特别长名字土台龟"
	var attack: Dictionary = long_pokemon.attacks[0].duplicate(true)
	attack.name = "在风雨中守护伙伴的特别长招式名称"
	attack.text = "所有效果说明都应完整显示。".repeat(20)
	long_pokemon.attacks = [attack, attack.duplicate(true), attack.duplicate(true), attack.duplicate(true)]
	isolated.cards["__detail_attacks"] = long_pokemon
	panel.configure(isolated, {"card_id": "__detail_attacks"})
	await settle()
	check_full_geometry()
	panel.rule_scroll.scroll_vertical = int(panel.rule_scroll.get_v_scroll_bar().max_value)
	await settle()
	last = panel.rule_contents.get_child(panel.rule_contents.get_child_count() - 1) as Control
	check(last.get_global_rect().end.y <= panel.rule_scroll.get_global_rect().end.y + 2, "Long names / multiple attacks truncate the bottom")
	await capture("04-long-name-multiple-attacks")
	main.modal_host_controller.close()
	await settle()


func check_full_geometry() -> void:
	var panel := inspector()
	check(main.modal_host_controller.active_spec.body_owns_scroll and not main.modal_scroll.get_v_scroll_bar().visible, "Outer modal competes with reading pane")
	check(not panel.rule_scroll.get_h_scroll_bar().visible, "Full details overflow horizontally")
	check(main.modal_panel.get_global_rect().grow(1).encloses(panel.get_global_rect()), "Inspector expanded past modal")
	check(panel._content_grid.columns == 2, "Inspector changed the approved two-column layout")
	check(panel._zoom_button.size.x >= 48 and panel._zoom_button.size.y >= 48, "Zoom target too small")
	check_content(panel.rule_contents, panel.rule_scroll.size.x)


func check_sidebar() -> void:
	root.size = Vector2i(1600, 900)
	var state := UIPreviewStateFactory.battle_state()
	state.players[0].active = specimen()
	main.state = state
	main.current_view_player = 0
	main.game_mode = "local"
	main.shell_view.build_game_screen()
	await settle()
	table = main.battle_screen
	harness._update_battle_preview(main, state, UIPreviewStateFactory.action_rows(state), "pokemon:0:active")
	await settle()
	main._show_card_inspector({"card_id": "svg2-tort", "pokemon": state.players[0].active, "location": "我方战斗区"})
	await settle()
	check_full_geometry()
	await capture("05-battle-full-1600")
	main.modal_host_controller.close()
	await settle()
	var longest := 0.0
	var longest_id := ""
	var detail := table.detail_panel as BattleDetailPanel
	var anchors := prize_bounds()
	var field := table.render3d.layout.field_rect(table.own_active)
	for id in table.catalog.cards:
		var card: Dictionary = table.catalog.get_card(id)
		var pokemon := PokemonState.new(id) if card.supertype == "Pokémon" else null
		if pokemon != null:
			pokemon.energy_card_ids.assign(["sv1-ener-1", "sv1-ener-1", "svg2-lume", "svg2-lume", "svi-jete"])
			pokemon.attached_tool_id = "svg2-exps"
			pokemon.status_conditions.assign(["POISONED", "BURNED", "CONFUSED"])
		table.show_card_detail(id, pokemon)
		await settle(7)
		check(not detail.rule_scroll.get_v_scroll_bar().visible, "Wide sidebar scrolls: " + str(id))
		check(not detail.rule_scroll.get_h_scroll_bar().visible, "Sidebar overflows horizontally: " + str(id))
		check_content(detail.rule_contents, detail.rule_scroll.size.x)
		if pokemon != null:
			var visible_text: Array[String] = []
			for label in detail.rule_contents.find_children("*", "Label", true, false):
				if label.is_visible_in_tree(): visible_text.append(label.text)
			check("%s ×2" % table.catalog.card_name("svg2-lume") in visible_text
				and "%s ×1" % table.catalog.card_name("svi-jete") in visible_text,
				"Wide sidebar merged distinct special Energy identities: " + str(id))
		check(anchors == prize_bounds(), "Sidebar changed prize anchors: " + str(id))
		check(field.is_equal_approx(table.render3d.layout.field_rect(table.own_active)), "Sidebar shifted playing field")
		if detail.size.y > longest:
			longest = detail.size.y
			longest_id = id
	audit = {"cards": table.catalog.cards.size(), "longest_height": longest, "longest_card": longest_id}
	for dimensions in [Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(1280, 720), Vector2i(1024, 768)]:
		root.size = dimensions
		await settle()
		state.players[0].active = PokemonState.new("svi-maus")
		state.players[0].active.damage_counters = 3
		state.players[0].active.status_conditions.assign(["POISONED", "BURNED", "CONFUSED"])
		state.players[0].active.energy_card_ids.assign(["sv1-ener-2", "sv1-ener-2", "sv1-ener-2", "svg2-lume", "svi-jete"])
		state.players[0].active.attached_tool_id = "svg2-exps"
		harness._update_battle_preview(main, state, UIPreviewStateFactory.action_rows(state), "pokemon:0:active")
		table.show_card_detail("svi-maus", state.players[0].active)
		await settle()
		check(detail.hp_group.get_global_rect().position.x >= detail.detail_title.get_global_rect().end.x - 1, "HP/type moved left of name")
		check(detail.type_icons.get_child_count() == 1, "Pokemon attribute icon missing")
		check(detail.close_button.size.x >= 48 and detail.close_button.size.y >= 48, "Close target too small")
		for control in [table.zones.stadium, table.own_bench[0], table.opponent_bench[0]]:
			check(not detail.get_global_rect().grow(8).intersects(table.render3d.global_bounds(control)), "Sidebar shadow covers field")
		await capture("06-sidebar-%dx%d" % [dimensions.x, dimensions.y])
	# Same instance keeps its reading position across state projections; another
	# instance with the same card ID starts at the top.
	var saved := 90
	detail.rule_scroll.scroll_vertical = saved
	await settle(2)
	saved = detail.get_reading_position()
	check(saved > 0, "Small-screen fixture is not scrollable")
	state.players[0].active.damage_counters += 1
	state.revision += 1
	table.update_view(state, 0, [], "pokemon:0:active", false, "local")
	await settle()
	check(absi(detail.get_reading_position() - saved) <= 2, "State refresh reset sidebar reading position")
	state.players[0].bench[0] = PokemonState.new("svi-maus")
	table.show_read_only_card_detail("svi-maus", state.players[0].bench[0], 0, "bench_0")
	await settle()
	check(detail.get_reading_position() == 0, "Another instance of same card retained old reading position")
	await click(detail.close_button)
	table.update_view(state, 0, [], "pokemon:0:active", false, "local")
	await settle()
	check(not detail.visible, "State refresh reopened manually dismissed sidebar")
	root.size = Vector2i(1600, 900)
	await settle()
	await check_prizes(state)


func check_prizes(state: GameState) -> void:
	var emitted: Array[String] = []
	table.choice_target_selected.connect(func(value: String) -> void: emitted.append(value))
	var anchors := prize_bounds()
	for player in [0, 0, 1]:
		table.show_card_detail("svi-maus", state.players[0].active)
		var index := state.players[player].prizes.size() - 1
		var option_id := "prize:%d" % index
		var request := ChoiceView.new("detail-prize-%d" % emitted.size(), state.revision, "select_prize", player,
			"请选择奖励卡", [{"option_id": option_id}], 1, 1, false, false)
		table.set_choice_guidance(request)
		table.set_choice_targets({"prize:0:%d" % index: option_id} if player == 0 else {}, "请选择奖励卡")
		await settle()
		check(not table.detail_panel.visible, "Prize selection retained sidebar")
		table.show_card_detail("svi-maus", state.players[0].active)
		check(not table.detail_panel.visible, "Selecting a card during prize choice reopened sidebar")
		check(anchors == prize_bounds(), "Prize selection moved prize anchors")
		if player == 0:
			var before := emitted.size()
			var bounds: Rect2 = table.render3d.world.projection.project_pose_bounds(table.render3d.zone_pose(table.zones.own_prizes, index))
			await click_point(table.get_global_transform_with_canvas() * bounds.get_center())
			check(emitted.size() == before + 1 and emitted.back() == option_id, "Hidden sidebar intercepts prize input")
			state.players[player].hand.append(state.players[player].prizes.pop_at(index))
		await capture("07-prize-owner-%d-%d" % [player, emitted.size()])
		table.set_choice_targets({}, "")
		table.set_choice_guidance(null)
		table.update_view(state, 0, [], "pokemon:0:active", false, "local")
		await settle()
		check(not table.detail_panel.visible, "Ending prize choice reopened sidebar")
	table.show_card_detail("svi-maus", state.players[0].active)
	await settle()
	check(table.detail_panel.visible, "Explicit selection after prizes cannot reopen sidebar")


func prize_bounds() -> Array[Rect2]:
	return [table.render3d.layout.prize_capacity_rect(table.zones.own_prizes), table.render3d.layout.prize_capacity_rect(table.zones.opponent_prizes)]


func check_content(node: Node, width: float) -> void:
	if node is RichTextLabel:
		check(not node.scroll_active and node.size.y + 2 >= node.get_content_height(), "Clipped or nested-scrolling rule text")
	for child in node.get_children():
		if child is Control and child.is_visible_in_tree():
			check(child.size.x <= width + 2, "Reading content exceeds pane width")
		check_content(child, width)


func wheel(control: Control, count: int) -> void:
	var point := root.get_final_transform() * control.get_global_rect().get_center()
	for index in count:
		for pressed in [true, false]:
			var event := InputEventMouseButton.new()
			event.button_index = MOUSE_BUTTON_WHEEL_DOWN
			event.pressed = pressed
			event.position = point
			event.global_position = point
			root.push_input(event)
		await settle(1)


func click(control: Control) -> void:
	await click_point(control.get_global_rect().get_center())


func click_point(point: Vector2) -> void:
	point = root.get_final_transform() * point
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	root.push_input(motion)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.global_position = point
		event.pressed = pressed
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		root.push_input(event)
	await settle()


func touch_swipe(control: Control, displacement: Vector2) -> void:
	var start := root.get_final_transform() * control.get_global_rect().get_center()
	var end := start + root.get_final_transform().basis_xform(displacement)
	var press := InputEventScreenTouch.new()
	press.position = start
	press.pressed = true
	Input.parse_input_event(press)
	await settle(1)
	for index in 5:
		var drag := InputEventScreenDrag.new()
		drag.position = start.lerp(end, float(index + 1) / 5.0)
		drag.relative = (end - start) / 5.0
		Input.parse_input_event(drag)
		await settle(1)
	var release := InputEventScreenTouch.new()
	release.position = end
	release.pressed = false
	Input.parse_input_event(release)
	await settle()


func touch_click(control: Control) -> void:
	var point := root.get_final_transform() * control.get_global_rect().get_center()
	for pressed in [true, false]:
		var event := InputEventScreenTouch.new()
		event.position = point
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame
	await settle()


func capture(label: String) -> void:
	if not graphics: return
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(OUTPUT.path_join(label + ".png")) == OK, "Capture failed: " + label)
	captures.append(label + ".png")


func settle(frames := 10) -> void:
	for index in frames: await process_frame
	if graphics: await RenderingServer.frame_post_draw


func check(ok: bool, message: String) -> void:
	if not ok and message not in failures:
		failures.append(message)
