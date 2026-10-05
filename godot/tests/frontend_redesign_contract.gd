extends SceneTree

## Front-end assignments, modal restoration, shared badges and one-shot results.
## --capture additionally records the key states using the real graphics driver.
const OUTPUT := "res://../build/frontend-redesign/states"
var main: Control
var failures: Array[String] = []
var capture_enabled := false

func _initialize() -> void:
	capture_enabled = "--capture" in OS.get_cmdline_user_args()
	if capture_enabled:
		preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("run")

func settle(frames: int = 6) -> void:
	for frame in range(frames):
		await process_frame

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func capture(label: String) -> void:
	if not capture_enabled:
		return
	await settle()
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(OUTPUT + "/" + label + ".png") == OK, "Capture failed: " + label)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	root.size = Vector2i(1600, 900)
	var settings := root.get_node("AppSettings")
	settings.animation_mode = "reduced"
	settings.muted = true
	main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	await settle()
	main.audio_director.play_music("")
	var catalog: CardCatalog = main.catalog
	var keys := DeckVisualCatalog.ordered_deck_keys(catalog)
	check(keys.size() == 14, "Release gallery must include all 14 decks")
	var attributes := {}
	for mode in ["local", "challenge"]:
		main.shell_view.show_deck_select(mode)
		var page := main.screen_host.get_child(0) as DeckSelectPage
		for key in keys:
			var previous := [page.selected_deck_key(0), page.selected_deck_key(1)]
			page._on_deck_tile_pressed(key)
			check([page.selected_deck_key(0), page.selected_deck_key(1)] == previous, "Browsing assigned a deck: " + key)
			page.assign_deck_button.pressed.emit()
			page.assign_player_two_button.pressed.emit()
			check(page.selected_deck_key(0) == key and page.selected_deck_key(1) == key, "Indexed assignment failed: " + key)
			check(page._preview_deck_key == key, "Assignment changed the preview")
			var energy := str(catalog.get_deck(key).get("energy_type", ""))
			attributes[energy] = true
			check(FrontendAttributes.texture_for(energy) != null, "Missing badge: " + energy)
			var panel := load("res://ui/panels/deck_detail_panel.tscn").instantiate() as DeckDetailPanel
			root.add_child(panel)
			panel.configure(catalog, key)
			var groups := panel._group_rows(catalog.get_deck(key))
			var counts := panel._category_counts(groups)
			check(int(counts["Pokémon"]) + int(counts["Trainer"]) + int(counts["Energy"]) == 60, "Deck count mismatch: " + key)
			for group: Array in groups.values():
				var seen := {}
				for row: Dictionary in group:
					check(not seen.has(row.card_id), "Duplicate card grid entry: " + str(row.card_id))
					seen[row.card_id] = true
					var card := catalog.get_card(str(row.card_id))
					var texts: Array[String] = []
					for block in CardPresentation.detail_groups(card, catalog):
						texts.append(str(block.bbcode))
					check("\n\n".join(texts) == CardPresentation.detail_bbcode(card, catalog), "Structured rules diverged: " + str(row.card_id))
			panel.free()
		await settle()
		await capture("decks-" + mode + "-same-deck")
	check(attributes.size() == 10, "Gallery must cover all ten attributes")
	await check_nested_details()
	await check_network()
	await check_reading_panes()
	await check_results()
	main.free()
	await create_timer(0.08).timeout
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("FRONTEND_REDESIGN_OK")
	quit(0 if failures.is_empty() else 1)

func check_nested_details() -> void:
	var page := main.screen_host.get_child(0) as DeckSelectPage
	page._on_deck_tile_pressed("fire")
	page.gallery_scroll.scroll_vertical = 190
	await settle()
	var gallery_scroll := page.gallery_scroll.scroll_vertical
	var keys := [page.selected_deck_key(0), page.selected_deck_key(1)]
	page.details_button.pressed.emit()
	await settle()
	main.modal_scroll.scroll_vertical = 210
	await settle()
	var saved_scroll: int = main.modal_scroll.scroll_vertical
	var detail := main.modal_body.get_child(0) as DeckDetailPanel
	(detail._category_grids[0].get_child(0) as Button).pressed.emit()
	await settle()
	await capture("card-detail")
	(main.modal_body.get_child(0) as CardInspectorPanel).art_requested.emit()
	await settle()
	await capture("card-art")
	main.modal_host_controller.handle_back()
	await settle()
	check(main.modal_body.get_child(0) is CardInspectorPanel, "Art back lost the card inspector")
	main.modal_host_controller.handle_back()
	await settle()
	check(main.modal_body.get_child(0) is DeckDetailPanel and main.modal_scroll.scroll_vertical == saved_scroll,
		"Card back lost the deck reading position")
	main.modal_host_controller.handle_back()
	await settle()
	check(page._preview_deck_key == "fire" and page.gallery_scroll.scroll_vertical == gallery_scroll and
		[page.selected_deck_key(0), page.selected_deck_key(1)] == keys, "Details changed the preparation state")

func check_network() -> void:
	for kind in ["lan", "relay"]:
		main.shell_view.show_network_setup(kind)
		var page := main.screen_host.get_child(0) as NetworkLobbyPage
		page.address_input.text = "wss://relay.example.test" if kind == "relay" else "192.168.1.20"
		page.port_input.text = "50751"
		await settle()
		for role_idx in range(2):
			page.role_option.select(role_idx)
			page.refresh_fields(role_idx)
			page.room_input.text = "ROOM42"
			await capture("network-" + kind + ("-host" if role_idx == 0 else "-join"))
			for state in [NetworkLobbyPage.ConnectionState.CONNECTING, NetworkLobbyPage.ConnectionState.WAITING,
				NetworkLobbyPage.ConnectionState.CONNECTED, NetworkLobbyPage.ConnectionState.ERROR]:
				page.set_connection_state(state, "", "ROOM42" if kind == "relay" else "")
				check((page.get_node("%ChangeDeckButton") as Button).disabled == (state != NetworkLobbyPage.ConnectionState.ERROR),
					"Deck picker lock diverged from connection state")
				if role_idx == 0 and state in [NetworkLobbyPage.ConnectionState.WAITING, NetworkLobbyPage.ConnectionState.ERROR]:
					await capture("network-" + kind + "-state-" + str(state))
			page.set_connection_state(NetworkLobbyPage.ConnectionState.IDLE)
		page.get_node("%ChangeDeckButton").pressed.emit()
		await settle()
		var picker := main.modal_body.get_child(0) as DeckPickerPanel
		await capture("deck-picker-" + kind)
		var tile := picker.grid.get_child(4) as DeckGalleryTile
		var chosen := tile.deck_key
		tile.pressed.emit()
		await settle()
		check(page.selected_deck_key() == chosen and not main.modal_layer.visible, "Single-player picker failed")
		check(page.port_input.text == "50751", "Deck picker reset the room draft")

func check_reading_panes() -> void:
	main.shell_view.show_title()
	main._show_settings()
	await settle()
	var settings: Variant = main.modal_body.get_child(0)
	var frame: Rect2 = main.modal_panel.get_global_rect()
	settings.master_volume_slider.value = 0.35
	for category in range(3):
		settings.show_category(category)
		await settle()
		check(frame.is_equal_approx(main.modal_panel.get_global_rect()), "Settings categories changed modal size")
		check(is_equal_approx(settings.values().master_volume, 0.35), "Category discarded a draft")
		await capture("settings-" + str(category))
	var draft: Dictionary = settings.values()
	var preferences := root.get_node("AppSettings")
	var original_volume: float = preferences.master_volume
	var changes := [0]
	var on_changed := func() -> void: changes[0] += 1
	preferences.changed.connect(on_changed)
	main.auxiliary_panels.settings_writer = func() -> bool: return false
	main.modal_confirm.pressed.emit()
	await settle()
	check(main.modal_layer.visible and settings.values() == draft, "Failed persistence lost the settings form")
	check(is_equal_approx(preferences.master_volume, original_volume) and changes[0] == 0,
		"Failed persistence applied the unsaved draft to runtime settings")
	await capture("settings-save-failed")
	main.auxiliary_panels.settings_writer = func() -> bool: return true
	main.modal_confirm.pressed.emit()
	await settle()
	check(not main.modal_layer.visible, "Saving could not be retried after failure")
	check(is_equal_approx(preferences.master_volume, 0.35) and changes[0] == 1,
		"Successful retry must apply settings exactly once")
	preferences.changed.disconnect(on_changed)
	main.auxiliary_panels.settings_writer = Callable()
	main.modal_host_controller.handle_back()
	main._show_help()
	await settle()
	var help := main.modal_body.get_child(0) as HelpPanel
	for category in range(4):
		help.show_category(category)
		await settle()
		var nav := help.get_node("%CategoryBar") as Control
		var original := nav.get_global_rect()
		var scroll := help.content_body.get_parent() as ScrollContainer
		scroll.scroll_vertical = 130
		await settle()
		check(nav.get_global_rect().is_equal_approx(original), "Help scrolling moved the category navigation")
		check(not main.modal_scroll.get_v_scroll_bar().visible, "Help has competing vertical scroll owners")
		scroll.scroll_vertical = 0
		await capture("help-" + str(category))
	main.modal_host_controller.close()

func check_results() -> void:
	for variant in ["winner", "draw", "missing", "network"]:
		var result: Variant = main.shell_view.mount(load("res://scenes/end/victory_screen.tscn"))
		result.configure(-1 if variant == "draw" else 0, 18, "玩家 1", "" if variant == "missing" else "svi-ente",
			{"mode": "network" if variant == "network" else "local", "winner_deck_name": "烈焰猴"})
		await settle()
		check(not result.celebration.is_processing(), "Reduced results kept decorative motion running")
		check(not result.rematch_button.disabled and not result.title_button.disabled, "Result navigation is blocked")
		if variant in ["draw", "missing"]:
			check(result.card_placeholder.visible, "Missing/neutral result must show a placeholder")
		if variant == "network":
			check(result.rematch_button.text == "返回联机大厅", "Network result lost its navigation label")
		await capture("result-" + variant)
	var settings := root.get_node("AppSettings")
	settings.animation_mode = "standard"
	settings.quality_profile = "high"
	var animated: Variant = main.shell_view.mount(load("res://scenes/end/victory_screen.tscn"))
	animated.configure(0, 18, "玩家 1", "svi-ente", {"mode": "local"})
	await settle(4)
	check(animated.celebration.is_processing(), "Standard victory did not start a celebration")
	await capture("result-celebration")
	await create_timer(1.1).timeout
	check(not animated.celebration.is_processing() and animated.celebration.elapsed == 1.0, "Celebration did not stop after one second")
