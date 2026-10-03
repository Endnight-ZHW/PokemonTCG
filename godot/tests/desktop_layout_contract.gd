extends SceneTree

const SIZES := [Vector2i(1600, 900), Vector2i(1024, 768), Vector2i(1280, 720),
	Vector2i(1280, 800), Vector2i(1920, 1080), Vector2i(2560, 1600), Vector2i(2000, 900)]
const OUTPUT := "res://../build/layout-unification/after"
var failures: Array[String] = []
var main: Control
var harness := UIPreviewHarness.new()
var capture_enabled := false
var geometries: Array[Dictionary] = []


func _initialize() -> void:
	capture_enabled = "--capture" in OS.get_cmdline_user_args()
	call_deferred("run")


func settle() -> void:
	for frame in range(8):
		await process_frame
	if capture_enabled:
		await RenderingServer.frame_post_draw


func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append("%s at %s" % [message, root.size])


func capture(label: String) -> void:
	if capture_enabled:
		await RenderingServer.frame_post_draw
		var path := "%s/%s-%dx%d.png" % [OUTPUT, label, root.size.x, root.size.y]
		check(root.get_texture().get_image().save_png(path) == OK, "Could not save " + path)


func inside(control: Control, label: String) -> void:
	check(control.is_visible_in_tree() and main.get_global_rect().grow(1).encloses(control.get_global_rect()),
		"%s escaped content: %s" % [label, control.get_global_rect()])


func run() -> void:
	root.size = SIZES[0]
	harness.configure(self)
	harness._enable_deterministic_preview_mode()
	root.get_node("AppSettings").muted = true
	if capture_enabled:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	await settle()
	for kind in ["title", "decks", "network"]:
		match kind:
			"title": main.shell_view.show_title()
			"decks": main.shell_view.show_deck_select("local")
			"network": main.shell_view.show_network_setup("relay")
		await settle()
		var page: Control = main.screen_host.get_child(0)
		var instance := page.get_instance_id()
		for target in SIZES:
			root.size = target
			await settle()
			check(page.get_instance_id() == instance, "Resize replaced " + kind)
			match kind:
				"title":
					check(page.body_grid.columns == 2, "Title changed column layout")
					inside(page.hero_panel, "Showcase")
					inside(page.modes_panel, "Modes")
				"decks":
					inside(page.gallery_panel, "Gallery")
					inside(page.detail_panel, "Deck details")
					inside(page.start_button, "Start")
					check(page.gallery_grid.columns == 2, "Gallery changed columns")
					check(not page.back_to_gallery_button.visible, "Deck introduced a second page")
					var assigned: String = page.selected_deck_key(0)
					page._on_deck_tile_pressed("water")
					await settle()
					check(page.selected_deck_key(0) == assigned, "Browsing assigned a deck")
					var scroll := page.get_node("%DetailScroll") as ScrollContainer
					for card: Control in page.detail_card_grid.get_children():
						check(card.get_global_rect().end.x <= scroll.get_global_rect().end.x + 1,
							"Core card clipped: card=%s minimum=%s grid=%s detail=%s" % [
								card.get_global_rect(), card.custom_minimum_size,
								page.detail_card_grid.size, page.detail_panel.size])
				"network":
					check(page.intro_panel.visible and page.deck_option.visible and page.rule_row.visible
						and page.address_input.get_parent().visible, "Network split its form into steps")
					inside(page.connect_button, "Connect")
					inside(page.status_panel, "Connection state")
			await capture(kind)
	var state := UIPreviewStateFactory.battle_state()
	state.players[0].active.damage_counters = 2
	state.players[0].active.attached_tool_id = "sv1-202"
	state.players[0].active.status_conditions.assign(["BURNED"])
	main.state = state
	main.current_view_player = 0
	main.game_mode = "local"
	main.shell_view.build_game_screen()
	await settle()
	for target in SIZES:
		root.size = target
		await settle()
		harness._update_battle_preview(main, state, UIPreviewStateFactory.action_rows(state), "pokemon:0:active")
		main.battle_screen.show_card_detail(state.players[0].active.card_id, state.players[0].active)
		await settle()
		_check_battle()
		await capture("battle")
		var table: BattleTable = main.battle_screen
		var field_before := table.render3d.layout.field_rect(table.own_active)
		var counters_before := table.own_info.get_global_rect()
		table.hide_card_detail()
		await settle()
		check(field_before.is_equal_approx(table.render3d.layout.field_rect(table.own_active)), "Closing details moved cards")
		check(counters_before.is_equal_approx(table.own_info.get_global_rect()), "Closing details moved counters")
	for target in [Vector2i(1024, 768), Vector2i(1280, 720)]:
		root.size = target
		await settle()
		for edge in ["left", "top", "right", "bottom"]:
			main.shell_view.safe_area.add_theme_constant_override("margin_" + edge, 48)
		await settle()
		main.battle_screen.show_card_detail(state.players[0].active.card_id, state.players[0].active)
		await settle()
		_check_battle()
		await capture("battle-safe")
	main.shell_view.apply_safe_area()
	for target in [Vector2i(900, 540), Vector2i(640, 960)]:
		root.size = target
		await settle()
		check(root.content_scale_size == UILayoutPolicy.MINIMUM_SIZE, "Small window lost its desktop canvas")
		await capture("fallback")
	if capture_enabled:
		var report := FileAccess.open(OUTPUT + "/geometry.json", FileAccess.WRITE)
		report.store_string(JSON.stringify(geometries, "\t"))
	main.queue_free()
	await settle()
	if failures.is_empty():
		print("DESKTOP_LAYOUT_CONTRACT_OK sizes=%d" % SIZES.size())
	else:
		for failure in failures:
			push_error(failure)
	harness._finish(0 if failures.is_empty() else 1)


func _check_battle() -> void:
	var table: BattleTable = main.battle_screen
	var detail := table.detail_panel as BattleDetailPanel
	inside(detail, "Battle details")
	check(detail.size.x >= 220 and detail.detail_text.size.y >= 48,
		"Details lost their reading area: %s text=%s" % [detail.size, detail.detail_text.size])
	var detail_rect := detail.get_global_rect()
	geometries.append({"window": str(root.size), "main": str(main.size), "table": str(table.size), "detail": str(detail_rect), "planned": str(table.board_view._detail_layout_rect()), "own_prizes": str(table.render3d.layout.prize_capacity_rect(table.zones["own_prizes"])), "opponent_prizes": str(table.render3d.layout.prize_capacity_rect(table.zones["opponent_prizes"]))})
	check(detail_rect.end.x < table.own_active.visual_global_bounds().position.x, "Details moved out of the left corridor")
	check(not detail_rect.intersects(table.own_info.get_global_rect()), "Details cover player counters")
	check(not detail_rect.intersects(table.own_allowance_row.get_global_rect()), "Details cover turn allowances")
	for key in ["own_prizes", "opponent_prizes", "stadium"]:
		var bounds := table.render3d.global_bounds(table.zones[key])
		check(not detail_rect.grow(4).intersects(bounds), "Details cover " + key)
	for view in table.slot_views.values():
		check(not detail_rect.grow(4).intersects(view.visual_global_bounds()), "Details cover field " + view.slot)
	var rail := table.hud.get_node("PhasePanel") as Control
	inside(rail, "Phase controls")
	if table.action_popover.visible:
		var actions := table.action_popover.panel_global_rect()
		check(not actions.intersects(detail_rect) and not actions.intersects(rail.get_global_rect())
			and not actions.intersects(table.own_active.visual_global_bounds()), "Actions obscure a reserved region")
	var to_window := root.get_final_transform() * rail.get_global_transform_with_canvas()
	check(to_window.x.length() * 48.0 >= 47.9, "Primary layout shrank its touch targets")
