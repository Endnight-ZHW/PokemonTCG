extends SceneTree

const FRONT_THEME_PATH := "res://ui/frontend/front_end_theme.tres"
const FRONT_FONT_PATH := "res://assets/ui/fonts/NotoSansCJKsc-VF.ttf"
const SAFE_INSET := 48
const MIN_TARGET_SIZE := 48.0
const EPSILON := 1.5
const VIEWPORT_CASES: Array[Vector2i] = [
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1024, 768),
	Vector2i(2000, 900),
]

const PAGE_SCENES := {
	"title": "res://scenes/title/title_page.tscn",
	"decks": "res://scenes/decks/deck_select_page.tscn",
	"network": "res://scenes/network/network_lobby_page.tscn",
	"settings": "res://ui/dialogs/settings_panel.tscn",
	"help": "res://ui/panels/help_panel.tscn",
	"deck_detail": "res://ui/panels/deck_detail_panel.tscn",
	"victory": "res://scenes/end/victory_screen.tscn",
}

var failures: Array[String] = []
var _settings_snapshot: Dictionary = {}
var _settings_node: Node
var _deck_start_payload: Array = []


func _initialize() -> void:
	call_deferred("_run_contract")


func _run_contract() -> void:
	_settings_node = root.get_node_or_null("AppSettings")
	if _settings_node == null:
		failures.append("AppSettings autoload is unavailable")
		quit(1)
		return
	_settings_snapshot = _capture_settings()
	_apply_reduced_motion()
	_check_theme_contract()
	_check_frontend_font_coverage()
	_check_battle_theme_isolation()
	var catalog := CardCatalog.shared()
	await _check_main_shell_contract()
	await _check_same_instance_resize(catalog)
	await _check_workbench_compact()
	for viewport_size in VIEWPORT_CASES:
		await _check_viewport(viewport_size, catalog)
	_restore_settings()
	if failures.is_empty():
		print("FRONTEND_LAYOUT_CONTRACT_OK sizes=%d safe_inset=%d" % [
			VIEWPORT_CASES.size(),
			SAFE_INSET,
		])
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _check_main_shell_contract() -> void:
	var main_scene := load("res://scenes/main/main.tscn") as PackedScene
	_check(main_scene != null, "Main shell is unavailable for frontend interaction checks")
	if main_scene == null:
		return
	var main := main_scene.instantiate()
	root.add_child(main)
	await _settle_layout(3)
	_check(main.modal_scroll.follow_focus,
		"Main modal scroll must follow keyboard focus")
	_check(
		main.modal_host_controller._resolved_size(
			Vector2(900, 760), Vector2(1000, 700), true
		) == Vector2(976, 676),
		"Compact frontend modal must fill the available safe area",
	)
	_check(
		main.modal_host_controller._resolved_size(
			Vector2(720, 620), Vector2(1000, 700), false
		) == Vector2(720, 620),
		"Compact battle modal size semantics changed with frontend fill behavior",
	)
	var scaled_insets: Vector4 = main._safe_insets_to_canvas(
		Vector2i(1920, 0),
		Vector2i(2400, 1080),
		Rect2i(1968, 24, 2304, 1032),
		Vector2(2000, 900),
	)
	_check(
		scaled_insets.is_equal_approx(Vector4(40, 20, 40, 20)),
		"Main safe-area conversion failed for a scaled secondary display",
	)
	main.show_network_setup("relay")
	await _settle_layout(3)
	var lobby := main.current_network_page as NetworkLobbyPage
	_check(lobby != null and lobby.is_inside_tree(),
		"Main did not retain a live network-lobby route")
	if lobby:
		lobby.set_connection_state(
			NetworkLobbyPage.ConnectionState.WAITING,
			"等待测试连接",
			"ROOM42",
		)
		main._handle_network_disconnected("timeout")
		await _settle_layout(2)
		_check(
			lobby.connection_state == NetworkLobbyPage.ConnectionState.ERROR
			and not lobby.connect_button.disabled,
			"Lobby disconnect must unlock a retryable ERROR state",
		)
	main.show_title()
	main._show_help()
	await _settle_layout(4)
	var first_category := main.modal_body.find_child(
		"QuickStartCategory", true, false
	) as Button
	var last_category := main.modal_body.find_child(
		"NetworkCategory", true, false
	) as Button
	_check(
		first_category != null
		and last_category != null
		and first_category.get_node_or_null(first_category.focus_neighbor_left)
		== last_category,
		"Modal focus trap must preserve Help category directional navigation",
	)
	_check(main.modal_panel.theme != null,
		"Frontend modal did not apply the isolated frontend theme")
	main._close_modal()
	main._finish_modal_close(main._modal_generation)
	_check(main.modal_panel.theme == null,
		"Closing a frontend modal did not restore inherited shell theme")
	main._show_deck_details("fire")
	await _settle_layout(4)
	var deck_buttons: Array[Node] = main.modal_body.find_children(
		"*", "Button", true, false
	)
	var history_target: Button
	for node in deck_buttons:
		var candidate := node as Button
		if candidate and not str(candidate.get_meta("deck_focus_key", "")).is_empty():
			history_target = candidate
	_check(history_target != null,
		"Deck-detail modal exposes no focusable card for history checks")
	if history_target:
		main.modal_scroll.scroll_vertical = int(
			main.modal_scroll.get_v_scroll_bar().max_value
		)
		await _settle_layout(2)
		var saved_scroll: int = int(main.modal_scroll.scroll_vertical)
		var focus_key := str(history_target.get_meta("deck_focus_key", ""))
		var key_parts := focus_key.split("|", false, 1)
		history_target.grab_focus()
		main._show_deck_card_inspector({
			"card_id": str(key_parts[1]),
			"location": str(key_parts[0]),
		}, "fire")
		await _settle_layout(3)
		_check(
			main.modal_host_controller.active_spec.stack_behavior
			== ModalSpec.StackBehavior.RESTORE_PARENT,
			"Deck card inspector did not declare modal history behavior",
		)
		main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
		await _settle_layout(5)
		var restored_focus := root.gui_get_focus_owner()
		_check(
			abs(main.modal_scroll.scroll_vertical - saved_scroll) <= 2
			and restored_focus != null
			and str(restored_focus.get_meta("deck_focus_key", "")) == focus_key,
			"Deck-detail modal history did not restore scroll position and card focus",
		)
	main._close_modal()
	main._finish_modal_close(main._modal_generation)
	main.queue_free()
	await _settle_layout(2)


func _check_same_instance_resize(catalog: CardCatalog) -> void:
	var host := Control.new()
	host.name = "ResponsiveResizeHost"
	host.size = Vector2(1600, 900)
	root.add_child(host)
	var deck_scene := load(PAGE_SCENES.decks) as PackedScene
	var deck := deck_scene.instantiate() as DeckSelectPage
	deck.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(deck)
	deck.configure(catalog, "challenge")
	await _settle_layout(4)
	deck.details_button.grab_focus()
	host.size = Vector2(1024, 768)
	await _settle_layout(4)
	var deck_focus := root.gui_get_focus_owner()
	_check(
		deck_focus != null
		and deck.is_ancestor_of(deck_focus)
		and deck_focus.is_visible_in_tree(),
		"Deck same-instance wide→compact resize lost keyboard focus",
	)
	host.size = Vector2(1600, 900)
	await _settle_layout(3)
	deck.queue_free()
	await _settle_layout(2)
	var network_scene := load(PAGE_SCENES.network) as PackedScene
	var network := network_scene.instantiate() as NetworkLobbyPage
	network.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(network)
	network.configure(catalog, "relay", "wss://relay.example.test")
	await _settle_layout(4)
	network.deck_option.grab_focus()
	host.size = Vector2(1024, 768)
	await _settle_layout(4)
	var network_focus := root.gui_get_focus_owner()
	_check(
		network_focus != null
		and network.is_ancestor_of(network_focus)
		and network_focus.is_visible_in_tree(),
		"Network same-instance wide→compact resize lost keyboard focus",
	)
	host.queue_free()
	await _settle_layout(2)


func _check_workbench_compact() -> void:
	root.size = Vector2i(1600, 900)
	var workbench_scene := load("res://tools/ui_workbench.tscn") as PackedScene
	_check(workbench_scene != null,
		"UI Workbench is unavailable for narrow-host frontend checks")
	if workbench_scene == null:
		return
	var workbench := workbench_scene.instantiate()
	root.add_child(workbench)
	await _settle_layout(3)
	workbench.show_preview("title")
	await _settle_layout(4)
	var preview_host := workbench.get_node("%PreviewHost") as Control
	var title := (
		preview_host.get_child(0) as Control
		if preview_host.get_child_count() > 0
		else null
	)
	_check(title != null and not bool(title.get("_is_wide")),
		"Workbench narrow preview did not activate the compact title layout")
	if title:
		_check_named_inside(title, preview_host.get_global_rect(), [
			"HeaderPanel", "HeroPanel", "ModesPanel", "LocalTwoPlayerButton",
		], "workbench-title-compact")
		_check_no_horizontal_scroll(title, "workbench-title-compact")
	workbench.queue_free()
	await _settle_layout(2)


func _check_viewport(viewport_size: Vector2i, catalog: CardCatalog) -> void:
	root.size = viewport_size
	await process_frame
	await _check_title(viewport_size)
	await _check_decks(viewport_size, catalog)
	await _check_network(viewport_size, catalog)
	await _check_scrolling_panel(viewport_size, "settings")
	await _check_scrolling_panel(viewport_size, "help")
	await _check_deck_detail(viewport_size, catalog)
	await _check_victory(viewport_size)


func _check_title(viewport_size: Vector2i) -> void:
	var mounted := await _mount(PAGE_SCENES.title, viewport_size)
	var page := mounted.page as Control
	if page == null:
		_unmount(mounted)
		return
	page.call("configure", "Layout contract")
	await _settle_layout()
	var label := _case_label("title", viewport_size)
	_check_full_page(page, mounted.safe_host, label)
	_check_named_inside(page, _simulated_safe_rect(mounted.safe_host), [
		"PageFrame", "HeaderPanel", "BodyGrid", "HeroPanel", "ModesPanel",
	], label)
	_check_named_non_overlapping(page, ["HeaderPanel", "BodyGrid"], label)
	_check_named_non_overlapping(page, [
		"LocalTwoPlayerButton", "ChallengeAIButton", "DeepAIButton", "OnlineCard",
	], label)
	_check_focus_targets(page, label, _simulated_safe_rect(mounted.safe_host))
	_check_no_horizontal_scroll(page, label)
	_unmount(mounted)
	await _settle_layout(2)


func _check_decks(viewport_size: Vector2i, catalog: CardCatalog) -> void:
	var mounted := await _mount(PAGE_SCENES.decks, viewport_size)
	var page := mounted.page as Control
	if page == null:
		_unmount(mounted)
		return
	page.call("configure", catalog, "challenge")
	await _settle_layout(4)
	_check(
		(page.get_node("%GalleryScroll") as ScrollContainer).follow_focus,
		"Deck gallery must scroll to keep keyboard focus visible",
	)
	if viewport_size == Vector2i(1600, 900):
		_check_deck_public_api(page, catalog)
	elif viewport_size == Vector2i(1024, 768):
		await _check_deck_compact_focus(page)
	var label := _case_label("decks", viewport_size)
	_check_full_page(page, mounted.safe_host, label)
	_check_named_inside(page, _simulated_safe_rect(mounted.safe_host), [
		"PageContent", "TopBar", "SlotPanel", "MasterDetail", "ActionBar",
		"GalleryPanel", "DetailPanel", "StartButton",
	], label)
	_check_named_non_overlapping(page, [
		"TopBar", "SlotPanel", "MasterDetail", "ActionBar",
	], label)
	_check_named_non_overlapping(page, ["GalleryPanel", "DetailPanel"], label)
	_check_focus_targets(page, label, _simulated_safe_rect(mounted.safe_host))
	_check_no_horizontal_scroll(page, label)
	_unmount(mounted)
	await _settle_layout(2)


func _check_deck_compact_focus(page: Control) -> void:
	var gallery_grid := page.get_node("%GalleryGrid") as GridContainer
	_check(gallery_grid.get_child_count() > 0, "Deck compact focus test requires a tile")
	if gallery_grid.get_child_count() == 0:
		return
	var tile := gallery_grid.get_child(0) as Button
	tile.grab_focus()
	tile.pressed.emit()
	await _settle_layout()
	var back_button := page.get_node("%BackToGalleryButton") as Button
	_check(
		back_button.visible and back_button.size.y + EPSILON >= MIN_TARGET_SIZE,
		"Deck compact detail must expose a 48px return target",
	)
	_check(
		page.get_viewport().gui_get_focus_owner() == back_button,
		"Deck compact detail must move focus away from the hidden gallery tile",
	)
	back_button.pressed.emit()
	await _settle_layout()
	_check(
		page.get_viewport().gui_get_focus_owner() == tile,
		"Deck compact gallery return must restore focus to the selected tile",
	)
	tile.pressed.emit()
	await _settle_layout()
	_check(
		bool(page.call("handle_back")),
		"Deck compact system back must consume the detail-to-gallery transition",
	)
	await _settle_layout()
	_check(
		page.get_viewport().gui_get_focus_owner() == tile,
		"Deck compact system back must restore the selected gallery tile",
	)


func _check_deck_public_api(page: Control, catalog: CardCatalog) -> void:
	var deck_keys: Array = catalog.decks.keys()
	deck_keys.sort()
	_check(not deck_keys.is_empty(), "DeckSelect public API contract requires a release deck")
	if deck_keys.is_empty():
		return
	var deck_key := str(deck_keys[0])
	_check(
		bool(page.call("select_deck", 0, deck_key)),
		"DeckSelect.select_deck must accept a valid player 1 deck",
	)
	_check(
		bool(page.call("select_deck", 1, deck_key)),
		"DeckSelect.select_deck must allow the same valid deck for player 2/AI",
	)
	_check(
		str(page.call("selected_deck_key", 0)) == deck_key
		and str(page.call("selected_deck_key", 1)) == deck_key,
		"DeckSelect must preserve the same deck key independently in both slots",
	)
	_check(
		int(page.call("deck_count")) == catalog.decks.size(),
		"DeckSelect.deck_count must expose every release deck",
	)
	var first_player_option := page.get_node("%FirstPlayerOption") as OptionButton
	first_player_option.select(2)
	_deck_start_payload.clear()
	var callback := Callable(self, "_on_deck_start_requested")
	if not page.is_connected("start_requested", callback):
		page.connect("start_requested", callback)
	var start_button := page.get_node("%StartButton") as Button
	start_button.pressed.emit()
	_check(
		_deck_start_payload == ["challenge", deck_key, deck_key, 1],
		"DeckSelect.start_requested argument order/forced_first changed: %s" % [
			_deck_start_payload,
		],
	)


func _on_deck_start_requested(
	mode: String,
	first_deck_key: String,
	second_deck_key: String,
	forced_first_player: int,
) -> void:
	_deck_start_payload = [
		mode,
		first_deck_key,
		second_deck_key,
		forced_first_player,
	]


func _check_network(viewport_size: Vector2i, catalog: CardCatalog) -> void:
	var mounted := await _mount(PAGE_SCENES.network, viewport_size)
	var page := mounted.page as Control
	if page == null:
		_unmount(mounted)
		return
	var kind := "lan" if viewport_size.x in [1280, 2000] else "relay"
	page.call("configure", catalog, kind, "wss://relay.example.test/a/very/long/path")
	for control_name in [
		"NetworkRoleOption", "NetworkAddressInput", "NetworkPortInput",
		"NetworkRoomInput", "NetworkDeckOption",
	]:
		var form_control := page.find_child(control_name, true, false) as Control
		_check(
			form_control != null and not form_control.accessibility_name.is_empty(),
			"Network form control lacks an accessible name: %s" % control_name,
		)
	if kind == "relay":
		var role_option := page.get_node("%NetworkRoleOption") as OptionButton
		role_option.select(1)
		page.call("refresh_fields", 1)
	page.call("set_connection_state", 5, "模拟连接错误")
	var connect_button := page.get_node("%NetworkConnectButton") as Button
	_check(
		not connect_button.disabled and connect_button.text == "重新尝试",
		"%s: ERROR state must leave a visible retry action" % _case_label("network", viewport_size),
	)
	page.call("set_connection_state", 0)
	_check(
		not connect_button.disabled,
		"%s: returning to IDLE must unlock the network form" % _case_label("network", viewport_size),
	)
	if viewport_size == Vector2i(1024, 768):
		await _check_network_compact_focus(page)
	await _settle_layout()
	var label := _case_label("network-%s" % kind, viewport_size)
	_check_full_page(page, mounted.safe_host, label)
	_check_named_inside(page, _simulated_safe_rect(mounted.safe_host), [
		"Page", "TopBar", "Body", "FormPanel", "StatusPanel", "NetworkConnectButton",
	], label)
	_check_named_non_overlapping(page, [
		"TopBar", "Steps", "Body", "StatusPanel", "NetworkConnectButton",
	], label)
	_check_focus_targets(page, label, _simulated_safe_rect(mounted.safe_host))
	_check_no_horizontal_scroll(page, label)
	_unmount(mounted)
	await _settle_layout(2)


func _check_network_compact_focus(page: Control) -> void:
	var step_bar := page.get_node("%CompactStepBar") as HBoxContainer
	var next_button := page.get_node("%CompactNextButton") as Button
	var role_option := page.get_node("%NetworkRoleOption") as OptionButton
	var address_input := page.get_node("%NetworkAddressInput") as LineEdit
	var deck_option := page.get_node("%NetworkDeckOption") as OptionButton
	var copy_button := page.get_node("%CopyRoomButton") as Button
	_check(step_bar.visible and role_option.visible, "Network compact flow must start at identity")
	next_button.pressed.emit()
	await _settle_layout()
	_check(
		address_input.is_visible_in_tree()
		and page.get_viewport().gui_get_focus_owner() == address_input,
		"Network compact flow must advance and focus connection information",
	)
	next_button.pressed.emit()
	await _settle_layout()
	_check(
		deck_option.is_visible_in_tree()
		and page.get_viewport().gui_get_focus_owner() == deck_option,
		"Network compact flow must advance and focus deck selection",
	)
	page.call("set_connection_state", 3, "等待测试玩家", "ROOM42")
	await _settle_layout()
	_check(
		copy_button.is_visible_in_tree()
		and page.get_viewport().gui_get_focus_owner() == copy_button,
		"Network waiting state must repair focus to the room-code copy action",
	)
	page.call("set_connection_state", 0)
	await _settle_layout()
	_check(
		bool(page.call("handle_back")),
		"Network compact system back must return to the previous setup step",
	)
	await _settle_layout()
	_check(
		address_input.is_visible_in_tree()
		and page.get_viewport().gui_get_focus_owner() == address_input,
		"Network compact back did not restore the connection-information step",
	)


func _check_scrolling_panel(viewport_size: Vector2i, page_key: String) -> void:
	var mounted := await _mount(PAGE_SCENES[page_key], viewport_size, true)
	var page := mounted.page as Control
	if page == null:
		_unmount(mounted)
		return
	if page_key == "settings":
		page.call("configure")
		for control_name in [
			"MasterVolumeSlider", "MusicVolumeSlider", "SFXVolumeSlider",
			"MutedToggle", "ReducedMotionToggle", "AnimationModeOption",
			"QualityProfileOption", "CardCacheOption",
		]:
			var form_control := page.find_child(control_name, true, false) as Control
			_check(
				form_control != null and not form_control.accessibility_name.is_empty(),
				"Settings form control lacks an accessible name: %s" % control_name,
			)
		if viewport_size == Vector2i(1600, 900):
			var before_reset := _capture_settings()
			page.call("reset_form_to_defaults")
			_check(
				_capture_settings() == before_reset,
				"settings@1600x900: reset defaults must not mutate AppSettings before save",
			)
	else:
		page.call("configure")
		page.call("show_category", 3)
	await _settle_layout()
	var label := _case_label(page_key, viewport_size)
	var safe_rect: Rect2 = _simulated_safe_rect(mounted.safe_host)
	_check_horizontal_inside(page, safe_rect, label)
	_check_focus_targets(page, label)
	_check_no_horizontal_scroll(page, label)
	var scroll := mounted.scroll as ScrollContainer
	_check(scroll != null, "%s: scrolling host is missing" % label)
	if scroll:
		_check(
			scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED,
			"%s: modal body must disable horizontal scrolling" % label,
		)
		_check(
			_not_horizontally_scrollable(scroll),
			"%s: modal body exposes a horizontal scrollbar" % label,
		)
	var section_names := (
		["AudioSection", "MotionSection", "PerformanceSection"]
		if page_key == "settings"
		else ["Intro", "CategoryBar", "ContentPanel"]
	)
	_check_named_non_overlapping(page, section_names, label)
	_unmount(mounted)
	await _settle_layout(2)


func _check_deck_detail(viewport_size: Vector2i, catalog: CardCatalog) -> void:
	var mounted := await _mount(PAGE_SCENES.deck_detail, viewport_size, true)
	var page := mounted.page as Control
	if page == null:
		_unmount(mounted)
		return
	page.call("configure", catalog, "fire")
	await _settle_layout(4)
	var label := _case_label("deck-detail", viewport_size)
	var safe_rect: Rect2 = _simulated_safe_rect(mounted.safe_host)
	_check_horizontal_inside(page, safe_rect, label)
	_check_focus_targets(page, label)
	_check_no_horizontal_scroll(page, label)
	var core_grid := page.get_node("%CoreGrid") as GridContainer
	_check(core_grid.get_child_count() > 0, "%s: core card grid is empty" % label)
	for wrapper in core_grid.get_children():
		_check(
			wrapper is Button and wrapper.get_child_count() == 1,
			"%s: core card must be a dedicated focusable preview" % label,
		)
		if wrapper.get_child_count() != 1 or not (wrapper.get_child(0) is CenterContainer):
			continue
		var center := wrapper.get_child(0) as CenterContainer
		if center.get_child_count() != 1 or not (center.get_child(0) is PanelContainer):
			continue
		var frame := center.get_child(0) as PanelContainer
		var aspect := frame.size.x / maxf(frame.size.y, 1.0)
		_check(
			absf(aspect - 94.0 / 132.0) <= 0.04,
			"%s: core card aspect ratio is distorted (%s)" % [label, frame.size],
		)
		var image := frame.get_child(0) as TextureRect if frame.get_child_count() == 1 else null
		_check(
			image != null
			and image.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED,
			"%s: core card artwork must preserve its full aspect" % label,
		)
	_unmount(mounted)
	await _settle_layout(2)


func _check_victory(viewport_size: Vector2i) -> void:
	var mounted := await _mount(PAGE_SCENES.victory, viewport_size)
	var page := mounted.page as Control
	if page == null:
		_unmount(mounted)
		return
	page.call("configure", 0, 12, "玩家 1", "svi-hrot", {
		"mode": "challenge",
		"winner_deck_name": "烈焰核心测试牌组",
	})
	await _settle_layout()
	var label := _case_label("victory", viewport_size)
	_check_full_page(page, mounted.safe_host, label)
	_check_named_inside(page, _simulated_safe_rect(mounted.safe_host), [
		"SafeContent", "VictoryPanel", "ResultGrid", "CardStage", "MatchPanel",
		"RematchButton", "TitleButton",
	], label)
	_check_named_non_overlapping(page, ["CardStage", "MatchPanel"], label)
	_check_named_non_overlapping(page, ["RematchButton", "TitleButton"], label)
	_check_focus_targets(page, label, _simulated_safe_rect(mounted.safe_host))
	_check_no_horizontal_scroll(page, label)
	_unmount(mounted)
	await _settle_layout(2)


func _mount(
	scene_path: String,
	viewport_size: Vector2i,
	with_scroll: bool = false,
) -> Dictionary:
	root.size = viewport_size
	var safe_host := MarginContainer.new()
	safe_host.name = "SafeInsetHost"
	safe_host.clip_contents = true
	safe_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	safe_host.add_theme_constant_override("margin_left", SAFE_INSET)
	safe_host.add_theme_constant_override("margin_top", SAFE_INSET)
	safe_host.add_theme_constant_override("margin_right", SAFE_INSET)
	safe_host.add_theme_constant_override("margin_bottom", SAFE_INSET)
	root.add_child(safe_host)
	var content_host: Node = safe_host
	var scroll: ScrollContainer
	if with_scroll:
		scroll = ScrollContainer.new()
		scroll.name = "VerticalModalBody"
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		scroll.follow_focus = true
		scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		safe_host.add_child(scroll)
		content_host = scroll
	var packed := load(scene_path) as PackedScene
	_check(packed != null, "Unable to load frontend scene: %s" % scene_path)
	if packed == null:
		return {"surface": safe_host, "safe_host": safe_host, "scroll": scroll, "page": null}
	var page := packed.instantiate() as Control
	_check(page != null, "Frontend scene root must be a Control: %s" % scene_path)
	if page:
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content_host.add_child(page)
	await _settle_layout()
	return {"surface": safe_host, "safe_host": safe_host, "scroll": scroll, "page": page}


func _unmount(mounted: Dictionary) -> void:
	var surface := mounted.get("surface") as Control
	if surface and is_instance_valid(surface):
		surface.queue_free()


func _settle_layout(frame_count: int = 3) -> void:
	for _frame in range(maxi(frame_count, 2)):
		await process_frame


func _check_full_page(page: Control, safe_host: Control, label: String) -> void:
	var page_rect := page.get_global_rect()
	var safe_rect := _simulated_safe_rect(safe_host)
	_check(
		_rect_inside(page_rect, safe_rect),
		"%s: page escaped simulated 48px safe area. page=%s safe=%s" % [
			label, page_rect, safe_rect,
		],
	)


func _simulated_safe_rect(safe_host: Control) -> Rect2:
	var rect := safe_host.get_global_rect()
	return Rect2(
		rect.position + Vector2(SAFE_INSET, SAFE_INSET),
		Vector2(
			maxf(0.0, rect.size.x - SAFE_INSET * 2.0),
			maxf(0.0, rect.size.y - SAFE_INSET * 2.0),
		),
	)


func _check_named_inside(
	owner: Node,
	bounds: Rect2,
	names: Array,
	label: String,
) -> void:
	for node_name in names:
		var control := _find_control(owner, str(node_name))
		_check(control != null, "%s: missing key control %s" % [label, node_name])
		if control == null or not control.is_visible_in_tree():
			continue
		var rect := control.get_global_rect()
		_check(
			_rect_inside(rect, bounds),
			"%s: %s escaped safe bounds. rect=%s bounds=%s" % [
				label, node_name, rect, bounds,
			],
		)


func _check_horizontal_inside(control: Control, bounds: Rect2, label: String) -> void:
	var rect := control.get_global_rect()
	_check(
		rect.position.x >= bounds.position.x - EPSILON
		and rect.end.x <= bounds.end.x + EPSILON,
		"%s: panel exceeds horizontal safe bounds. rect=%s bounds=%s" % [
			label, rect, bounds,
		],
	)


func _check_named_non_overlapping(owner: Node, names: Array, label: String) -> void:
	var controls: Array[Control] = []
	for node_name in names:
		var control := _find_control(owner, str(node_name))
		if control and control.is_visible_in_tree():
			controls.append(control)
	for first_index in range(controls.size()):
		for second_index in range(first_index + 1, controls.size()):
			_check_pair_not_overlapping(controls[first_index], controls[second_index], label)


func _check_focus_targets(
	owner: Node,
	label: String,
	bounds: Rect2 = Rect2(),
) -> void:
	var targets: Array[Control] = []
	_collect_focus_targets(owner, targets)
	_check(not targets.is_empty(), "%s: page exposes no keyboard focus target" % label)
	for target in targets:
		var rect := target.get_global_rect()
		_check(
			rect.size.x + EPSILON >= MIN_TARGET_SIZE
			and rect.size.y + EPSILON >= MIN_TARGET_SIZE,
			"%s: focus target %s is smaller than 48x48 (%s)" % [
				label, target.get_path(), rect.size,
			],
		)
		if bounds.has_area():
			if not _has_scroll_ancestor(target, owner):
				_check(
					_rect_inside(rect, bounds),
					"%s: focus target %s escaped safe bounds (%s)" % [
						label, target.get_path(), rect,
					],
				)
	for first_index in range(targets.size()):
		for second_index in range(first_index + 1, targets.size()):
			_check_pair_not_overlapping(targets[first_index], targets[second_index], label)


func _collect_focus_targets(node: Node, output: Array[Control]) -> void:
	if node is Control:
		var control := node as Control
		if control != node.get_tree().root and (
			control.focus_mode == Control.FOCUS_ALL
			and control.is_visible_in_tree()
			and control.mouse_filter != Control.MOUSE_FILTER_IGNORE
		):
			output.append(control)
	for child in node.get_children():
		_collect_focus_targets(child, output)


func _has_scroll_ancestor(control: Control, boundary: Node) -> bool:
	var ancestor := control.get_parent()
	while ancestor and ancestor != boundary:
		if ancestor is ScrollContainer:
			return true
		ancestor = ancestor.get_parent()
	return false


func _find_control(owner: Node, node_name: String) -> Control:
	return owner.find_child(node_name, true, false) as Control


func _check_pair_not_overlapping(first: Control, second: Control, label: String) -> void:
	var overlap := first.get_global_rect().intersection(second.get_global_rect())
	_check(
		overlap.size.x <= EPSILON or overlap.size.y <= EPSILON,
		"%s: controls overlap: %s and %s (%s)" % [
			label, first.get_path(), second.get_path(), overlap,
		],
	)


func _check_no_horizontal_scroll(owner: Node, label: String) -> void:
	var scrolls: Array[ScrollContainer] = []
	_collect_scroll_containers(owner, scrolls)
	for scroll in scrolls:
		_check(
			_not_horizontally_scrollable(scroll),
			"%s: horizontal scrollbar is visible at %s" % [label, scroll.get_path()],
		)


func _collect_scroll_containers(node: Node, output: Array[ScrollContainer]) -> void:
	if node is ScrollContainer and (node as ScrollContainer).is_visible_in_tree():
		output.append(node as ScrollContainer)
	for child in node.get_children():
		_collect_scroll_containers(child, output)


func _not_horizontally_scrollable(scroll: ScrollContainer) -> bool:
	return (
		scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED
		or not scroll.get_h_scroll_bar().visible
	)


func _rect_inside(inner: Rect2, outer: Rect2) -> bool:
	return (
		inner.position.x >= outer.position.x - EPSILON
		and inner.position.y >= outer.position.y - EPSILON
		and inner.end.x <= outer.end.x + EPSILON
		and inner.end.y <= outer.end.y + EPSILON
	)


func _check_theme_contract() -> void:
	_check(FileAccess.file_exists(FRONT_THEME_PATH), "Frontend theme resource is missing")
	var theme := load(FRONT_THEME_PATH) as Theme
	_check(theme != null, "Frontend theme must load as Theme")
	if theme == null:
		return
	var expected_variations := {
		"FrontPrimaryButton": "Button",
		"FrontSecondaryButton": "Button",
		"FrontGhostButton": "Button",
		"FrontDangerButton": "Button",
		"FrontModeTileButton": "Button",
		"FrontSectionPanel": "PanelContainer",
		"FrontRaisedPanel": "PanelContainer",
		"FrontCardFrame": "PanelContainer",
		"FrontStatusPanel": "PanelContainer",
		"FrontHeadingLabel": "Label",
		"FrontMutedLabel": "Label",
	}
	for variation in expected_variations:
		_check(
			theme.get_type_variation_base(StringName(variation))
			== StringName(expected_variations[variation]),
			"Frontend theme variation %s must derive from %s" % [
				variation, expected_variations[variation],
			],
		)
	_check(
		theme.has_stylebox(&"normal", &"FrontPrimaryButton")
		and theme.has_stylebox(&"hover", &"FrontPrimaryButton")
		and theme.has_stylebox(&"pressed", &"FrontPrimaryButton")
		and theme.has_stylebox(&"focus", &"FrontPrimaryButton"),
		"Primary button variation must define normal, hover, pressed and focus states",
	)
	_check(
		theme.get_constant(&"v_separation", &"PopupMenu") >= 24,
		"Frontend PopupMenu rows must reserve touch-friendly vertical spacing",
	)
	_check(
		theme.get_icon(&"grabber", &"HSlider")
		!= theme.get_icon(&"grabber_highlight", &"HSlider"),
		"Frontend sliders need a visible hover/focus grabber state",
	)
	_check_frontend_contrast(theme)


func _check_frontend_contrast(theme: Theme) -> void:
	var raised := theme.get_stylebox(&"panel", &"FrontRaisedPanel") as StyleBoxFlat
	var primary := theme.get_stylebox(&"normal", &"FrontPrimaryButton") as StyleBoxFlat
	var status := theme.get_stylebox(&"panel", &"FrontStatusPanel") as StyleBoxFlat
	var input := theme.get_stylebox(&"normal", &"LineEdit") as StyleBoxFlat
	var scroll_track := theme.get_stylebox(&"scroll", &"VScrollBar") as StyleBoxFlat
	var scroll_grabber := theme.get_stylebox(&"grabber", &"VScrollBar") as StyleBoxFlat
	_check(raised != null, "Raised frontend panel style is unavailable for contrast checks")
	_check(primary != null, "Primary frontend button style is unavailable for contrast checks")
	_check(status != null, "Status frontend panel style is unavailable for contrast checks")
	_check(input != null, "Frontend input style is unavailable for contrast checks")
	_check(scroll_track != null and scroll_grabber != null,
		"Frontend scrollbar styles are unavailable for contrast checks")
	if (
		raised == null
		or primary == null
		or status == null
		or input == null
		or scroll_track == null
		or scroll_grabber == null
	):
		return
	var body_text := theme.get_color(&"font_color", &"Label")
	var muted_text := theme.get_color(&"font_color", &"FrontMutedLabel")
	_check(
		_contrast_ratio(body_text, raised.bg_color) >= 4.5,
		"Frontend body text contrast must be at least 4.5:1 (actual %.2f:1)" % [
			_contrast_ratio(body_text, raised.bg_color),
		],
	)
	_check(
		_contrast_ratio(muted_text, raised.bg_color) >= 4.5,
		"Frontend secondary text contrast must be at least 4.5:1 (actual %.2f:1)" % [
			_contrast_ratio(muted_text, raised.bg_color),
		],
	)
	_check(
		_contrast_ratio(primary.bg_color, raised.bg_color) >= 3.0,
		"Gold primary state contrast must be at least 3:1 (actual %.2f:1)" % [
			_contrast_ratio(primary.bg_color, raised.bg_color),
		],
	)
	_check(
		_contrast_ratio(status.border_color, status.bg_color) >= 3.0,
		"Cyan status boundary contrast must be at least 3:1 (actual %.2f:1)" % [
			_contrast_ratio(status.border_color, status.bg_color),
		],
	)
	var status_background := _composite_color(status.bg_color, raised.bg_color)
	var error_text := Color("#ff9aa4")
	_check(
		_contrast_ratio(error_text, status_background) >= 4.5,
		"Frontend error text contrast must be at least 4.5:1 (actual %.2f:1)" % [
			_contrast_ratio(error_text, status_background),
		],
	)
	_check(
		_contrast_ratio(input.border_color, raised.bg_color) >= 3.0,
		"Frontend input boundary contrast must be at least 3:1 (actual %.2f:1)" % [
			_contrast_ratio(input.border_color, raised.bg_color),
		],
	)
	var track_background := _composite_color(scroll_track.bg_color, raised.bg_color)
	var grabber_background := _composite_color(
		scroll_grabber.bg_color,
		track_background,
	)
	_check(
		_contrast_ratio(grabber_background, track_background) >= 3.0,
		"Frontend scrollbar boundary contrast must be at least 3:1 (actual %.2f:1)" % [
			_contrast_ratio(grabber_background, track_background),
		],
	)


func _check_frontend_font_coverage() -> void:
	_check(FileAccess.file_exists(FRONT_FONT_PATH), "Frontend CJK font file is missing")
	_check(
		FileAccess.get_sha256(FRONT_FONT_PATH).to_upper()
		== "990C807E79C25662A5A9ECF7F971BAEB2BF2EAB9A559E5ECF15CDFDB8561D21F",
		"Frontend CJK font checksum does not match the documented Noto 2.004 source",
	)
	_check(
		FileAccess.file_exists("res://assets/ui/fonts/OFL.txt")
		and FileAccess.file_exists("res://assets/ui/fonts/SOURCE.md"),
		"Frontend CJK font license/source notice is missing",
	)
	var font := load(FRONT_FONT_PATH) as Font
	_check(font != null, "Frontend CJK font must load as a Font resource")
	if font == null:
		return
	var font_rows := [
		["res://assets/ui/fonts/noto_sans_cjk_sc_regular.tres", 400.0],
		["res://assets/ui/fonts/noto_sans_cjk_sc_medium.tres", 500.0],
		["res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres", 700.0],
	]
	for row in font_rows:
		var variation := load(str(row[0])) as FontVariation
		_check(
			variation != null
			and is_equal_approx(
				float(variation.variation_opentype.get("wght", -1.0)),
				float(row[1]),
			),
			"Frontend FontVariation has the wrong weight: %s" % row[0],
		)
	var sources: Array[String] = []
	for directory in ["res://scenes", "res://ui"]:
		for path in _files_recursive(directory):
			if path.get_extension() in ["gd", "tscn", "tres"]:
				sources.append(path)
	for path in [
		"res://data/cards.json",
		"res://data/decks.json",
		"res://data/effects.json",
	]:
		if FileAccess.file_exists(path):
			sources.append(path)
	var checked: Dictionary = {}
	var missing: Array[String] = []
	for path in sources:
		var source := FileAccess.get_file_as_string(path)
		for character in source:
			var codepoint := (character as String).unicode_at(0)
			if codepoint < 33 or checked.has(codepoint):
				continue
			checked[codepoint] = true
			if not font.has_char(codepoint):
				missing.append("U+%04X %s" % [codepoint, character])
	_check(
		missing.is_empty(),
		"Frontend CJK font is missing current UI/data characters: %s" % [
			", ".join(missing.slice(0, mini(12, missing.size()))),
		],
	)


func _contrast_ratio(first: Color, second: Color) -> float:
	var first_luminance := _relative_luminance(first)
	var second_luminance := _relative_luminance(second)
	var lighter := maxf(first_luminance, second_luminance)
	var darker := minf(first_luminance, second_luminance)
	return (lighter + 0.05) / (darker + 0.05)


func _composite_color(foreground: Color, background: Color) -> Color:
	return Color(
		foreground.r * foreground.a + background.r * (1.0 - foreground.a),
		foreground.g * foreground.a + background.g * (1.0 - foreground.a),
		foreground.b * foreground.a + background.b * (1.0 - foreground.a),
		1.0,
	)


func _relative_luminance(color: Color) -> float:
	return (
		0.2126 * _linear_color_channel(color.r)
		+ 0.7152 * _linear_color_channel(color.g)
		+ 0.0722 * _linear_color_channel(color.b)
	)


func _linear_color_channel(value: float) -> float:
	return (
		value / 12.92
		if value <= 0.04045
		else pow((value + 0.055) / 1.055, 2.4)
	)


func _check_battle_theme_isolation() -> void:
	var forbidden := ["front_end_theme.tres", "theme_type_variation = &\"Front"]
	for path in _files_recursive("res://scenes/battle"):
		if path.get_extension() not in ["gd", "tscn", "tres"]:
			continue
		var source := FileAccess.get_file_as_string(path)
		for needle in forbidden:
			_check(
				not needle in source,
				"Battle UI must not reference frontend theme semantics: %s contains %s" % [
					path, needle,
				],
			)
	var battle_scene := load("res://scenes/battle/battle_screen.tscn") as PackedScene
	_check(battle_scene != null, "Battle screen must remain loadable for theme isolation")
	if battle_scene:
		var battle := battle_scene.instantiate() as Control
		_check(battle.theme == null, "BattleScreen root must continue inheriting the game theme")
		battle.free()


func _files_recursive(path: String) -> Array[String]:
	var result: Array[String] = []
	var directory := DirAccess.open(path)
	if directory == null:
		_check(false, "Unable to inspect directory: %s" % path)
		return result
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var child_path := path.path_join(entry)
			if directory.current_is_dir():
				result.append_array(_files_recursive(child_path))
			else:
				result.append(child_path)
		entry = directory.get_next()
	directory.list_dir_end()
	return result


func _capture_settings() -> Dictionary:
	return {
		"master_volume": _settings_node.get("master_volume"),
		"music_volume": _settings_node.get("music_volume"),
		"sfx_volume": _settings_node.get("sfx_volume"),
		"muted": _settings_node.get("muted"),
		"reduced_motion": _settings_node.get("reduced_motion"),
		"card_cache_size": _settings_node.get("card_cache_size"),
		"animation_mode": _settings_node.get("animation_mode"),
		"quality_profile": _settings_node.get("quality_profile"),
	}


func _apply_reduced_motion() -> void:
	_settings_node.call(
		"update",
		float(_settings_snapshot.master_volume),
		bool(_settings_snapshot.muted),
		true,
		int(_settings_snapshot.card_cache_size),
		"reduced",
		str(_settings_snapshot.quality_profile),
		float(_settings_snapshot.music_volume),
		float(_settings_snapshot.sfx_volume),
	)


func _restore_settings() -> void:
	if _settings_snapshot.is_empty():
		return
	_settings_node.call(
		"update",
		float(_settings_snapshot.master_volume),
		bool(_settings_snapshot.muted),
		bool(_settings_snapshot.reduced_motion),
		int(_settings_snapshot.card_cache_size),
		str(_settings_snapshot.animation_mode),
		str(_settings_snapshot.quality_profile),
		float(_settings_snapshot.music_volume),
		float(_settings_snapshot.sfx_volume),
	)


func _case_label(page_name: String, viewport_size: Vector2i) -> String:
	return "%s@%dx%d+safe%d" % [
		page_name,
		viewport_size.x,
		viewport_size.y,
		SAFE_INSET,
	]


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
