extends SceneTree

const FRONT_THEME_PATH := "res://ui/frontend/front_end_theme.tres"
const GAME_THEME_PATH := "res://ui/game_theme.tres"
const FRONT_FONT_PATH := "res://assets/ui/fonts/NotoSansCJKsc-VF.ttf"
const FONT_WEIGHT_TAG := 0x77676874
const SAFE_INSET := 48
const MIN_TARGET_SIZE := 48.0
const EPSILON := 1.5
const TITLE_TIER_WIDE := 0
const TITLE_TIER_COMPACT_LANDSCAPE := 1
const TITLE_TIER_DENSE := 2
const TITLE_ENERGY_TYPES: Array[String] = [
	"Grass", "Fire", "Water", "Lightning",
	"Psychic", "Fighting", "Darkness", "Metal",
]
const ENERGY_ICON_CATALOG := preload("res://ui/energy_icon_catalog.gd")
const DISABLED_UI_ACTIONS: Array[StringName] = [
	&"ui_accept", &"ui_select", &"ui_cancel",
	&"ui_focus_next", &"ui_focus_prev",
	&"ui_left", &"ui_right", &"ui_up", &"ui_down",
	&"ui_page_up", &"ui_page_down", &"ui_home", &"ui_end",
]
const VIEWPORT_CASES: Array[Vector2i] = [
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1024, 768),
	Vector2i(2000, 900),
]
const TITLE_PORTRAIT_CASES: Array[Vector2i] = [
	Vector2i(720, 1280),
	Vector2i(800, 1280),
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
	await _check_shared_backdrop_contract()
	await _check_network_intro_contract(catalog)
	await _check_deck_tile_visual_contract(catalog)
	await _check_same_instance_resize(catalog)
	await _check_battle_canvas_resize()
	await _check_workbench_compact()
	for viewport_size in VIEWPORT_CASES:
		await _check_viewport(viewport_size, catalog)
	for viewport_size in TITLE_PORTRAIT_CASES:
		root.size = viewport_size
		await process_frame
		await _check_title(viewport_size)
	_restore_settings()
	if failures.is_empty():
		print("FRONTEND_LAYOUT_CONTRACT_OK sizes=%d safe_inset=%d" % [
			VIEWPORT_CASES.size() + TITLE_PORTRAIT_CASES.size(),
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
	_check(not main.modal_scroll.follow_focus,
		"Main modal scroll must not follow disabled keyboard navigation")
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
	await _check_pointer_only_input_contract(main)
	main.show_deck_select("challenge")
	await _settle_layout(4)
	var routed_deck_page := (
		main.screen_host.get_child(0) as DeckSelectPage
		if main.screen_host.get_child_count() > 0
		else null
	)
	_check(
		routed_deck_page != null and root.gui_get_focus_owner() == null,
		"Entering DeckSelect must not establish automatic GUI focus",
	)
	_check_pointer_only_controls(routed_deck_page, "main-routed-decks")
	main.show_title()
	await _settle_layout(3)
	_check(
		root.gui_get_focus_owner() == null,
		"Returning to title must not restore automatic GUI focus",
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
		and first_category.focus_mode == Control.FOCUS_NONE
		and last_category.focus_mode == Control.FOCUS_NONE
		and root.gui_get_focus_owner() == null,
		"Help modal category controls must remain pointer/touch only",
	)
	_check_pointer_only_controls(main.modal_layer, "help-modal")
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
	var history_target := deck_buttons[0] as Button if not deck_buttons.is_empty() else null
	_check(history_target != null,
		"Deck-detail modal exposes no card action for history checks")
	if history_target:
		main.modal_scroll.scroll_vertical = int(
			main.modal_scroll.get_v_scroll_bar().max_value
		)
		await _settle_layout(2)
		var saved_scroll: int = int(main.modal_scroll.scroll_vertical)
		history_target.pressed.emit()
		await _settle_layout(3)
		_check(
			main.modal_host_controller.active_spec.stack_behavior
			== ModalSpec.StackBehavior.RESTORE_PARENT,
			"Deck card inspector did not declare modal history behavior",
		)
		main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
		await _settle_layout(5)
		_check(
			abs(main.modal_scroll.scroll_vertical - saved_scroll) <= 2
			and root.gui_get_focus_owner() == null,
			"Deck-detail modal history did not restore scroll without GUI focus",
		)
	main._close_modal()
	main._finish_modal_close(main._modal_generation)
	main.queue_free()
	await _settle_layout(2)


func _check_pointer_only_input_contract(main: Control) -> void:
	_check(
		root.get_node_or_null("FrontendFocus") == null,
		"Legacy keyboard/controller focus autoload must not be present",
	)
	for action in DISABLED_UI_ACTIONS:
		_check(
			InputMap.has_action(action)
			and InputMap.action_get_events(action).is_empty(),
			"Built-in navigation action must have no bindings: %s" % action,
		)
	_check_pointer_only_controls(main, "main-startup")
	var initial_screen: int = int(main.get("current_screen"))
	var keyboard_event := InputEventKey.new()
	keyboard_event.keycode = KEY_ENTER
	keyboard_event.pressed = true
	Input.parse_input_event(keyboard_event)
	var joypad_event := InputEventJoypadButton.new()
	joypad_event.button_index = JOY_BUTTON_A
	joypad_event.pressed = true
	Input.parse_input_event(joypad_event)
	await _settle_layout(2)
	_check(
		int(main.get("current_screen")) == initial_screen
		and root.gui_get_focus_owner() == null
		and not main.modal_layer.visible,
		"Keyboard/controller input must not focus, activate, or reroute the UI",
	)


func _check_shared_backdrop_contract() -> void:
	root.size = Vector2i(1600, 900)
	var backdrop_scene := load("res://ui/frontend/frontend_backdrop.tscn") as PackedScene
	_check(backdrop_scene != null, "Shared frontend backdrop scene is unavailable")
	if backdrop_scene == null:
		return
	var backdrop := backdrop_scene.instantiate() as Control
	root.add_child(backdrop)
	backdrop.call("configure", "neutral")
	await _settle_layout(3)
	var card_fan := backdrop.get_node("%CardFan") as Control
	_check(
		card_fan != null and not card_fan.visible,
		"Neutral secondary-page backdrop must not show decorative cards",
	)
	backdrop.call("configure", "victory")
	await _settle_layout(2)
	_check(
		card_fan != null and card_fan.visible,
		"Victory backdrop lost its intentional celebration card fan",
	)
	backdrop.queue_free()
	await _settle_layout(2)


func _check_network_intro_contract(catalog: CardCatalog) -> void:
	root.size = Vector2i(1600, 900)
	var packed := load(PAGE_SCENES.network) as PackedScene
	_check(packed != null, "Network lobby scene is unavailable for intro-card checks")
	if packed == null:
		return
	var page := packed.instantiate() as Control
	root.add_child(page)
	page.call("configure", catalog, "lan", "wss://relay.example.test")
	await _settle_layout(4)
	var intro_panel := page.get_node("%IntroPanel") as PanelContainer
	var form_panel := page.find_child("FormPanel", true, false) as PanelContainer
	var body := page.find_child("Body", true, false) as HBoxContainer
	var top_bar := page.find_child("TopBar", true, false) as HBoxContainer
	var page_frame := page.get_node("%Page") as VBoxContainer
	var lan_page_top := top_bar.global_position.y
	var description := page.get_node("%KindDescription") as Label
	var tip := page.get_node("%IntroTip") as Label
	var kind_label := page.get_node("%KindLabel") as Label
	var kind_code := page.get_node("%KindCode") as Label
	var intro_icon := page.get_node("%IntroIcon") as TextureRect
	var role_badge := page.get_node("%RoleBadgeLabel") as Label
	_check(
		intro_panel.visible and not bool(page.get("_compact")),
		"1600x900 network lobby must expose the wide connection overview",
	)
	_check(
		_rect_inside(intro_panel.get_global_rect(), body.get_global_rect())
		and _rect_inside(form_panel.get_global_rect(), body.get_global_rect()),
		"Network overview or form escaped the wide Body container",
	)
	_check_pair_not_overlapping(intro_panel, form_panel, "network-intro-wide")
	_check(
		form_panel.size.x >= 620.0,
		"Network overview consumed too much width from the connection form",
	)
	_check_named_inside(page, intro_panel.get_global_rect(), [
		"IntroAccent", "IntroHeader", "KindDescription", "OverviewHeader",
		"FeatureList", "IntroTipPanel",
	], "network-intro-wide")
	_check(
		description.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART
		and description.get_line_count() >= 2
		and description.get_visible_line_count() == description.get_line_count(),
		"LAN overview description does not wrap fully inside the left card",
	)
	_check(
		tip.get_visible_line_count() == tip.get_line_count(),
		"LAN overview role hint is clipped",
	)
	_check(
		kind_label.text == "局域网直连"
		and kind_code.text.begins_with("LAN")
		and intro_icon.texture.resource_path.ends_with("lan.svg")
		and role_badge.text == "房主 · 创建",
		"LAN overview presentation is stale or incomplete",
	)
	var decorative_targets: Array[Control] = []
	_collect_pointer_targets(intro_panel, decorative_targets)
	_check(
		decorative_targets.is_empty() and intro_panel.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"Decorative network overview must not enter the pointer path",
	)
	var role_option := page.get_node("%NetworkRoleOption") as OptionButton
	role_option.select(1)
	page.call("refresh_fields", 1)
	_check(
		role_badge.text == "挑战者 · 加入" and tip.text.contains("局域网地址"),
		"LAN overview did not follow the selected client role",
	)
	var kind_option := page.get_node("%NetworkKindOption") as OptionButton
	kind_option.select(1)
	kind_option.item_selected.emit(1)
	await _settle_layout(3)
	_check(
		kind_label.text == "远程中继"
		and kind_code.text.begins_with("RELAY")
		and intro_icon.texture.resource_path.ends_with("globe.svg")
		and (page.get_node("%FeatureOne") as Label).text.contains("跨网络")
		and tip.text.contains("房间码"),
		"Relay overview did not update its icon, facts, or role hint",
	)
	role_option.select(0)
	page.call("refresh_fields", 0)
	await _settle_layout(3)
	_check(
		absf(top_bar.global_position.y - lan_page_top) <= 2.0
		and _rect_inside(page_frame.get_global_rect(), Rect2(Vector2.ZERO, root.size)),
		"LAN/Relay role changes shifted or clipped the wide network page "
		+ "(lan_y=%.1f relay_host_y=%.1f page=%s root=%s)" % [
			lan_page_top,
			top_bar.global_position.y,
			page_frame.get_global_rect(),
			root.size,
		],
	)
	page.queue_free()
	await _settle_layout(2)


func _check_deck_tile_visual_contract(catalog: CardCatalog) -> void:
	root.size = Vector2i(1600, 900)
	var packed := load(PAGE_SCENES.decks) as PackedScene
	_check(packed != null, "Deck-select scene is unavailable for tile visual checks")
	if packed == null:
		return
	var page := packed.instantiate() as Control
	root.add_child(page)
	page.call("configure", catalog, "local")
	await _settle_layout(4)
	var gallery_grid := page.get_node("%GalleryGrid") as GridContainer
	var gallery_scroll := page.get_node("%GalleryScroll") as ScrollContainer
	_check(gallery_grid.get_child_count() >= 3, "Deck gallery exposes too few tiles for state checks")
	if gallery_grid.get_child_count() < 3:
		page.queue_free()
		await _settle_layout(2)
		return
	var first := gallery_grid.get_child(0) as DeckGalleryTile
	var second := gallery_grid.get_child(1) as DeckGalleryTile
	var third := gallery_grid.get_child(2) as DeckGalleryTile
	_check(
		first.theme_type_variation == &"DeckGalleryTileButton"
		and first.find_child("Accent", true, false) == null,
		"Deck tile still uses the shared mode style or legacy full-width Accent",
	)
	for node_name in [
		"Artwork", "ArtworkFrame", "DeckName", "EnergyBadge", "EnergyIcon", "EnergyLabel",
		"CardCountLabel", "TaglineLabel", "AssignmentBadge", "AssignmentLabel",
	]:
		_check(
			first.find_child(node_name, true, false) != null,
			"Deck tile is missing visual node %s" % node_name,
		)
	var count_label := first.get_node("%CardCountLabel") as Label
	var energy_badge := first.get_node("%EnergyBadge") as PanelContainer
	var energy_icon := first.get_node("%EnergyIcon") as TextureRect
	var energy_label := first.get_node("%EnergyLabel") as Label
	var assignment_badge := first.get_node("%AssignmentBadge") as PanelContainer
	var assignment_label := first.get_node("%AssignmentLabel") as Label
	_check(
		count_label.visible
		and count_label.text.contains("60 张")
		and count_label.size.x >= 48.0
		and energy_badge.size.x >= 64.0
		and first.accessibility_name.contains("60 张"),
		"Deck tile lost its visible or accessible card count/type badge",
	)
	_check(
		energy_icon.visible
		and energy_icon.texture != null
		and energy_icon.custom_minimum_size.x >= 20.0
		and energy_icon.custom_minimum_size.x <= 22.0
		and energy_label.visible
		and not energy_label.text.is_empty()
		and energy_badge.accessibility_name.contains("牌组属性"),
		"Supported deck energy badge lost its compact icon or accessible text",
	)
	first.call("_configure_energy_badge", "Dragon")
	_check(
		not energy_icon.visible
		and energy_icon.texture == null
		and (first.get_node("%EnergyLabel") as Label).text == "龙属性"
		and energy_badge.accessibility_name.contains("龙属性"),
		"Unsupported deck energy type must fall back to text without a Colorless icon",
	)
	first.call("_configure_energy_badge", "Grass")
	for node in first.find_children("*", "ColorRect", true, false):
		var strip := node as ColorRect
		_check(
			not (strip.size.y <= 8.0 and strip.size.x >= first.size.x * 0.8),
			"Deck tile reintroduced a full-width colored strip",
		)
	for node in first.find_children("*", "Control", true, false):
		var child := node as Control
		_check(
			child.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"Deck tile child intercepts pointer input: %s" % child.get_path(),
		)
	var scroll_rect := gallery_scroll.get_global_rect()
	for tile_value in gallery_grid.get_children():
		var tile := tile_value as Control
		var tile_rect := tile.get_global_rect()
		_check(
			tile_rect.position.x >= scroll_rect.position.x - EPSILON
			and tile_rect.end.x <= scroll_rect.end.x + EPSILON,
			"Deck tile exceeds the gallery's horizontal viewport: %s" % tile.get_path(),
		)
	_check(
		first.is_pressed()
		and assignment_badge.visible
		and assignment_label.text == "P1"
		and not second.is_pressed()
		and (second.get_node("%AssignmentLabel") as Label).text == "P2"
		and not (third.get_node("%AssignmentBadge") as PanelContainer).visible,
		"Deck tile pressed and assignment states are no longer independent",
	)
	_check(
		first.focus_mode == Control.FOCUS_NONE
		and second.focus_mode == Control.FOCUS_NONE
		and root.gui_get_focus_owner() == null
		and first.is_pressed(),
		"Deck tiles must keep selection without exposing GUI focus",
	)
	var shared_keys: Array[String] = [first.deck_key, first.deck_key]
	first.set_assignment_state(0, shared_keys, "玩家 2")
	_check(
		first.is_pressed()
		and assignment_label.text == "P1 · P2"
		and first.accessibility_description.contains("玩家 1")
		and first.accessibility_description.contains("玩家 2"),
		"Deck tile cannot represent one deck assigned to both players",
	)
	page.queue_free()
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
	var deck_selection := [
		deck.selected_deck_key(0),
		deck.selected_deck_key(1),
	]
	host.size = Vector2(1024, 768)
	await _settle_layout(4)
	_check(
		bool(deck.get("_compact"))
		and deck.selected_deck_key(0) == deck_selection[0]
		and deck.selected_deck_key(1) == deck_selection[1]
		and root.gui_get_focus_owner() == null,
		"Deck same-instance wide→compact resize changed selection or created focus",
	)
	_check_pointer_only_controls(deck, "deck-same-instance-compact")
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
	host.size = Vector2(1024, 768)
	await _settle_layout(4)
	_check(
		bool(network.get("_compact"))
		and network.kind_option.is_visible_in_tree()
		and root.gui_get_focus_owner() == null,
		"Network same-instance wide→compact resize changed step or created focus",
	)
	_check_pointer_only_controls(network, "network-same-instance-compact")
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
	_check(title != null, "Workbench narrow preview did not mount the title page")
	if title:
		_check_named_inside(title, preview_host.get_global_rect(), [
			"TitleStack", "CardStage", "LocalTwoPlayerButton", "AIButton",
			"NetworkButton", "FooterRow",
		], "workbench-title-preview")
		_check_no_horizontal_scroll(title, "workbench-title-preview")
	_check_pointer_only_controls(workbench, "workbench")
	workbench.queue_free()
	await _settle_layout(2)


func _check_battle_canvas_resize() -> void:
	root.size = Vector2i(1600, 900)
	var battle_scene := load("res://scenes/battle/battle_screen.tscn") as PackedScene
	_check(battle_scene != null, "Battle screen is unavailable for live resize checks")
	if battle_scene == null:
		return
	var battle := battle_scene.instantiate()
	root.add_child(battle)
	battle.initialize_ui()
	await _settle_layout(4)
	var canvas := battle.board_canvas as Control
	var own_active := battle.own_active as Control
	_check(
		canvas != null
		and canvas.resized.is_connected(Callable(battle.table, "_layout_board")),
		"BattleTable must listen to its resolved BoardCanvas size",
	)
	var first_center_x := own_active.position.x + own_active.size.x * 0.5
	root.size = Vector2i(2000, 900)
	await _settle_layout(5)
	var metrics: Dictionary = battle.table._board_layout_metrics(
		canvas.size.x,
		canvas.size.y,
	)
	var resized_center_x := own_active.position.x + own_active.size.x * 0.5
	_check(
		absf(resized_center_x - float(metrics["center_x"])) <= 2.0
		and resized_center_x > first_center_x + 100.0,
		"Battle slots did not recenter after same-instance 1600→2000 resize",
	)
	_check_no_navigation_controls(battle, "battle-live-resize")
	battle.queue_free()
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
		"PageFrame", "TitleStack", "TypeOrbs", "CardStage", "LocalTwoPlayerButton",
		"AIButton", "NetworkButton", "FooterRow", "SettingsButton", "HelpButton",
	], label)
	_check_named_non_overlapping(page, [
		"LocalTwoPlayerButton", "AIButton", "NetworkButton",
		"SettingsButton", "HelpButton",
	], label)
	for legacy_name in [
		"ChallengeAIButton", "DeepAIButton", "LANButton", "RelayButton", "OnlineCard",
	]:
		_check(
			page.find_child(legacy_name, true, false) == null,
			"%s: legacy title control remains: %s" % [label, legacy_name],
		)
	var expected_tier := TITLE_TIER_DENSE
	if (
		page.size.x >= 1180.0
		and page.size.y >= 650.0
		and page.size.x / maxf(page.size.y, 1.0) >= 1.5
	):
		expected_tier = TITLE_TIER_WIDE
	elif (
		page.size.x >= 900.0
		and page.size.y >= 600.0
		and page.size.x / maxf(page.size.y, 1.0) >= 1.15
	):
		expected_tier = TITLE_TIER_COMPACT_LANDSCAPE
	_check(
		int(page.get("_layout_tier")) == expected_tier,
		"%s: title responsive tier does not match the documented breakpoints" % label,
	)
	_check_title_energy_badges(page, label, expected_tier)
	var modes_wrapper := page.find_child("ModesGlass", true, false) as Control
	_check(
		modes_wrapper is MarginContainer and not (modes_wrapper is PanelContainer),
		"%s: title mode buttons must not be enclosed by a visible panel frame" % label,
	)
	if viewport_size == Vector2i(1600, 900):
		_check_title_showcase_rotation(page, label)
	var expected_button_height := (
		116.0
		if expected_tier == TITLE_TIER_WIDE
		else 96.0
		if expected_tier == TITLE_TIER_COMPACT_LANDSCAPE
		else 84.0
	)
	for node_name in ["LocalTwoPlayerButton", "AIButton", "NetworkButton"]:
		var mode_button := page.find_child(node_name, true, false) as Button
		_check(
			mode_button != null
			and mode_button.focus_mode == Control.FOCUS_NONE
			and is_equal_approx(
				mode_button.custom_minimum_size.y,
				expected_button_height,
			),
			"%s: %s has the wrong height or still accepts navigation focus"
			% [label, node_name],
		)
		if mode_button:
			var foreground: Color = mode_button.get("foreground_color")
			var subtitle: Color = mode_button.get("subtitle_color")
			var fill: Color = mode_button.get("fill_color")
			var accent: Color = mode_button.get("accent_color")
			var hover_fill := fill.lightened(0.065)
			_check(
				_contrast_ratio(foreground, fill) >= 4.5
				and _contrast_ratio(foreground, hover_fill) >= 4.5
				and _contrast_ratio(subtitle, fill) >= 4.5
				and _contrast_ratio(subtitle, hover_fill) >= 4.5,
				"%s: %s title/subtitle contrast must be at least 4.5:1"
				% [label, node_name],
			)
			_check(
				_relative_luminance(fill) <= 0.04,
				"%s: %s must keep the midnight dark-surface treatment"
				% [label, node_name],
			)
			_check(
				_contrast_ratio(accent, fill) >= 3.0
				and _contrast_ratio(Color.WHITE, hover_fill) >= 3.0,
				"%s: %s accent and hover treatment must remain distinguishable"
				% [label, node_name],
			)
	_check_pointer_only_controls(page, label, _simulated_safe_rect(mounted.safe_host))
	_check_no_horizontal_scroll(page, label)
	_unmount(mounted)
	await _settle_layout(2)


func _check_title_energy_badges(
	page: Control,
	label: String,
	expected_tier: int,
) -> void:
	var grid := page.find_child("TypeOrbs", true, false) as GridContainer
	var expected_columns := 4 if expected_tier == TITLE_TIER_DENSE else 8
	var expected_size := (
		28.0
		if expected_tier == TITLE_TIER_WIDE
		else 24.0
		if expected_tier == TITLE_TIER_COMPACT_LANDSCAPE
		else 20.0
	)
	_check(grid != null, "%s: energy badge grid is missing" % label)
	if grid == null:
		return
	_check(
		grid.columns == expected_columns and grid.get_child_count() == 8,
		"%s: energy badges must use 8 columns or a dense 4x2 grid" % label,
	)
	for index in range(TITLE_ENERGY_TYPES.size()):
		var energy_type := TITLE_ENERGY_TYPES[index]
		var badge := page.find_child("%sEnergyBadge" % energy_type, true, false) as PanelContainer
		var icon := page.find_child("%sEnergyIcon" % energy_type, true, false) as TextureRect
		_check(
			badge != null and icon != null,
			"%s: missing %s basic-energy badge" % [label, energy_type],
		)
		if badge == null or icon == null:
			continue
		_check(
			str(badge.get_meta("energy_type", "")) == energy_type
			and grid.get_child(index) == badge,
			"%s: %s energy badge order/type metadata changed" % [label, energy_type],
		)
		_check(
			badge.custom_minimum_size.is_equal_approx(Vector2.ONE * expected_size),
			"%s: %s energy badge has the wrong responsive size" % [label, energy_type],
		)
		_check(
			icon.custom_minimum_size.is_equal_approx(Vector2.ONE * expected_size)
			and badge.get_theme_stylebox(&"panel") is StyleBoxEmpty,
			"%s: %s energy icon must not have a dark backing ring"
			% [label, energy_type],
		)
		_check(
			badge.focus_mode == Control.FOCUS_NONE
			and badge.mouse_filter == Control.MOUSE_FILTER_IGNORE
			and icon.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"%s: decorative energy badge must not enter pointer/focus navigation"
			% label,
		)
		var expected_path := ENERGY_ICON_CATALOG.path_for(energy_type)
		_check(
			icon.texture != null and icon.texture.resource_path == expected_path,
			"%s: %s energy badge must load through EnergyIconCatalog"
			% [label, energy_type],
		)


func _check_title_showcase_rotation(page: Control, label: String) -> void:
	var catalog := CardCatalog.shared()
	var pool: Array = page.get("_showcase_card_pool")
	var before: Array = page.get("_showcase_card_ids").duplicate()
	_check(pool.size() >= 3, "%s: Pokémon showcase rotation pool is empty" % label)
	for card_id_value in pool:
		var card_id := str(card_id_value)
		var image_path := str(catalog.get_card(card_id).get("image_path", ""))
		_check(
			catalog.is_pokemon(card_id)
			and not image_path.is_empty()
			and ResourceLoader.exists(image_path, "Texture2D"),
			"%s: showcase pool contains a non-Pokémon or missing texture: %s"
			% [label, card_id],
		)
	var rotated := bool(page.call("_rotate_showcase_card", 0))
	var after: Array = page.get("_showcase_card_ids").duplicate()
	var unique_after := {}
	for card_id_value in after:
		unique_after[str(card_id_value)] = true
	var cards: Array = page.get("cards")
	var shadows: Array = page.get("card_shadows")
	var rotated_path := (
		str(catalog.get_card(str(after[0])).get("image_path", ""))
		if not after.is_empty()
		else ""
	)
	var rotated_texture := (
		(cards[0] as TextureRect).texture
		if not cards.is_empty()
		else null
	)
	_check(
		rotated
		and after.size() == 3
		and str(after[0]) != str(before[0])
		and unique_after.size() == 3,
		"%s: showcase rotation must replace one slot without duplicates" % label,
	)
	_check(
		cards.size() == 3
		and shadows.size() == 3
		and rotated_texture != null
		and rotated_texture == (shadows[0] as TextureRect).texture
		and rotated_texture.resource_path == rotated_path,
		"%s: showcase card and shadow must share the catalog texture" % label,
	)
	var mode_button_source := FileAccess.get_file_as_string(
		"res://ui/frontend/title_mode_button.gd"
	)
	_check(
		not "Vector2(size.y * 0.29, 8)" in mode_button_source,
		"Title mode buttons must not restore the long top decoration line",
	)


func _check_decks(viewport_size: Vector2i, catalog: CardCatalog) -> void:
	var mounted := await _mount(PAGE_SCENES.decks, viewport_size)
	var page := mounted.page as Control
	if page == null:
		_unmount(mounted)
		return
	page.call("configure", catalog, "challenge")
	await _settle_layout(4)
	_check(
		not (page.get_node("%GalleryScroll") as ScrollContainer).follow_focus,
		"Deck gallery must not follow disabled keyboard navigation",
	)
	if viewport_size == Vector2i(1600, 900):
		_check_deck_public_api(page, catalog)
	elif viewport_size == Vector2i(1024, 768):
		await _check_deck_compact_pointer_flow(page)
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
	_check_pointer_only_controls(page, label, _simulated_safe_rect(mounted.safe_host))
	_check_no_horizontal_scroll(page, label)
	_unmount(mounted)
	await _settle_layout(2)


func _check_deck_compact_pointer_flow(page: Control) -> void:
	var gallery_grid := page.get_node("%GalleryGrid") as GridContainer
	_check(gallery_grid.get_child_count() > 0, "Deck compact pointer test requires a tile")
	if gallery_grid.get_child_count() == 0:
		return
	var tile := gallery_grid.get_child(0) as Button
	tile.pressed.emit()
	await _settle_layout()
	var back_button := page.get_node("%BackToGalleryButton") as Button
	_check(
		back_button.visible and back_button.size.y + EPSILON >= MIN_TARGET_SIZE,
		"Deck compact detail must expose a 48px return target",
	)
	_check(
		page.get_viewport().gui_get_focus_owner() == null,
		"Deck compact detail must not create GUI focus",
	)
	back_button.pressed.emit()
	await _settle_layout()
	_check(
		tile.is_visible_in_tree()
		and tile.is_pressed()
		and page.get_viewport().gui_get_focus_owner() == null,
		"Deck compact gallery return must restore selection without focus",
	)
	tile.pressed.emit()
	await _settle_layout()
	_check(
		bool(page.call("handle_back")),
		"Deck compact system back must consume the detail-to-gallery transition",
	)
	await _settle_layout()
	_check(
		tile.is_visible_in_tree()
		and page.get_viewport().gui_get_focus_owner() == null,
		"Deck compact system back must restore the gallery without focus",
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
	var ai_mode_option := page.get_node("%AIModeOption") as OptionButton
	_check(
		ai_mode_option.item_count == 2
		and str(ai_mode_option.get_item_metadata(0)) == "challenge"
		and str(ai_mode_option.get_item_metadata(1)) == "deep",
		"DeckSelect AIModeOption metadata changed",
	)
	var gallery_scroll := page.get_node("%GalleryScroll") as ScrollContainer
	var detail_title := page.get_node("%DetailTitle") as Label
	gallery_scroll.scroll_vertical = 37
	var preserved_state := {
		"first": page.call("selected_deck_key", 0),
		"second": page.call("selected_deck_key", 1),
		"active": page.get("_active_player_idx"),
		"first_player": first_player_option.selected,
		"scroll": gallery_scroll.scroll_vertical,
		"detail": detail_title.text,
	}
	ai_mode_option.select(1)
	ai_mode_option.item_selected.emit(1)
	_check(
		str(page.get("mode")) == "deep"
		and page.call("selected_deck_key", 0) == preserved_state["first"]
		and page.call("selected_deck_key", 1) == preserved_state["second"]
		and page.get("_active_player_idx") == preserved_state["active"]
		and first_player_option.selected == preserved_state["first_player"]
		and gallery_scroll.scroll_vertical == preserved_state["scroll"]
		and detail_title.text == preserved_state["detail"]
		and page.get_viewport().gui_get_focus_owner() == null,
		"DeckSelect AI switch reset deck, slot, turn, scroll, detail, or created focus",
	)
	_deck_start_payload.clear()
	var callback := Callable(self, "_on_deck_start_requested")
	if not page.is_connected("start_requested", callback):
		page.connect("start_requested", callback)
	var start_button := page.get_node("%StartButton") as Button
	start_button.pressed.emit()
	_check(
		_deck_start_payload == ["deep", deck_key, deck_key, 1],
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
		"NetworkKindOption", "NetworkRoleOption", "NetworkAddressInput", "NetworkPortInput",
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
		await _check_network_compact_pointer_flow(page)
	await _settle_layout()
	var label := _case_label("network-%s" % kind, viewport_size)
	_check_full_page(page, mounted.safe_host, label)
	_check_named_inside(page, _simulated_safe_rect(mounted.safe_host), [
		"Page", "TopBar", "Body", "FormPanel", "StatusPanel", "NetworkConnectButton",
	], label)
	_check_named_non_overlapping(page, [
		"TopBar", "Steps", "Body", "StatusPanel", "NetworkConnectButton",
	], label)
	_check_pointer_only_controls(page, label, _simulated_safe_rect(mounted.safe_host))
	_check_no_horizontal_scroll(page, label)
	_unmount(mounted)
	await _settle_layout(2)


func _check_network_compact_pointer_flow(page: Control) -> void:
	var step_bar := page.get_node("%CompactStepBar") as HBoxContainer
	var next_button := page.get_node("%CompactNextButton") as Button
	var kind_option := page.get_node("%NetworkKindOption") as OptionButton
	var role_option := page.get_node("%NetworkRoleOption") as OptionButton
	var address_input := page.get_node("%NetworkAddressInput") as LineEdit
	var deck_option := page.get_node("%NetworkDeckOption") as OptionButton
	var copy_button := page.get_node("%CopyRoomButton") as Button
	_check(
		step_bar.visible and kind_option.visible and role_option.visible,
		"Network compact flow must start at network kind and identity",
	)
	next_button.pressed.emit()
	await _settle_layout()
	_check(
		address_input.is_visible_in_tree()
		and address_input.focus_mode == Control.FOCUS_CLICK
		and page.get_viewport().gui_get_focus_owner() == null,
		"Network compact flow must expose click-only connection information",
	)
	next_button.pressed.emit()
	await _settle_layout()
	_check(
		deck_option.is_visible_in_tree()
		and deck_option.focus_mode == Control.FOCUS_NONE
		and page.get_viewport().gui_get_focus_owner() == null,
		"Network compact flow must expose pointer-only deck selection",
	)
	page.call("set_connection_state", 3, "等待测试玩家", "ROOM42")
	await _settle_layout()
	_check(
		copy_button.is_visible_in_tree()
		and copy_button.focus_mode == Control.FOCUS_NONE
		and page.get_viewport().gui_get_focus_owner() == null,
		"Network waiting state must expose a pointer-only room-code copy action",
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
		and page.get_viewport().gui_get_focus_owner() == null,
		"Network compact back did not restore the unfocused connection-information step",
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
	_check_pointer_only_controls(page, label)
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
	_check_pointer_only_controls(page, label)
	_check_no_horizontal_scroll(page, label)
	var core_grid := page.get_node("%CoreGrid") as GridContainer
	_check(core_grid.get_child_count() > 0, "%s: core card grid is empty" % label)
	for wrapper in core_grid.get_children():
		_check(
			wrapper is Button and wrapper.get_child_count() == 1,
			"%s: core card must be a dedicated clickable preview" % label,
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
	_check_pointer_only_controls(page, label, _simulated_safe_rect(mounted.safe_host))
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
		scroll.focus_mode = Control.FOCUS_NONE
		scroll.follow_focus = false
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


func _check_pointer_only_controls(
	owner: Node,
	label: String,
	bounds: Rect2 = Rect2(),
) -> void:
	_check(owner != null, "%s: pointer-only surface is unavailable" % label)
	if owner == null:
		return
	var targets: Array[Control] = []
	var invalid_navigation: Array[Control] = []
	_collect_pointer_targets(owner, targets)
	_collect_invalid_navigation_controls(owner, invalid_navigation)
	_check(not targets.is_empty(), "%s: page exposes no pointer/touch target" % label)
	for control in invalid_navigation:
		_check(
			false,
			"%s: control still accepts keyboard/controller focus: %s" % [
				label, control.get_path(),
			],
		)
	_check(
		owner.get_viewport().gui_get_focus_owner() == null,
		"%s: page unexpectedly owns GUI focus" % label,
	)
	for target in targets:
		var valid_mode := (
			target.focus_mode in [Control.FOCUS_NONE, Control.FOCUS_CLICK]
			if target is LineEdit
			else target.focus_mode == Control.FOCUS_NONE
		)
		_check(
			valid_mode,
			"%s: pointer target %s still accepts keyboard/controller focus" % [
				label, target.get_path(),
			],
		)
		if target is OptionButton:
			_check(
				not (target as OptionButton).get_popup().allow_search,
				"%s: option menu still accepts keyboard type-to-search: %s" % [
					label, target.get_path(),
				],
			)
		var rect := target.get_global_rect()
		_check(
			rect.size.x + EPSILON >= MIN_TARGET_SIZE
			and rect.size.y + EPSILON >= MIN_TARGET_SIZE,
			"%s: pointer target %s is smaller than 48x48 (%s)" % [
				label, target.get_path(), rect.size,
			],
		)
		if bounds.has_area():
			if not _has_scroll_ancestor(target, owner):
				_check(
					_rect_inside(rect, bounds),
					"%s: pointer target %s escaped safe bounds (%s)" % [
						label, target.get_path(), rect,
					],
				)
	for first_index in range(targets.size()):
		for second_index in range(first_index + 1, targets.size()):
			_check_pair_not_overlapping(targets[first_index], targets[second_index], label)


func _check_no_navigation_controls(owner: Node, label: String) -> void:
	var invalid_navigation: Array[Control] = []
	_collect_invalid_navigation_controls(owner, invalid_navigation)
	for control in invalid_navigation:
		_check(
			false,
			"%s: control still accepts keyboard/controller focus: %s" % [
				label, control.get_path(),
			],
		)


func _collect_pointer_targets(node: Node, output: Array[Control]) -> void:
	if node is Control:
		var control := node as Control
		if control != node.get_tree().root and (
			(control is BaseButton or control is Slider or control is LineEdit or control is CardView)
			and control.is_visible_in_tree()
			and control.mouse_filter != Control.MOUSE_FILTER_IGNORE
		):
			output.append(control)
	for child in node.get_children():
		_collect_pointer_targets(child, output)


func _collect_invalid_navigation_controls(node: Node, output: Array[Control]) -> void:
	if node is Control:
		var control := node as Control
		var valid_mode := (
			control.focus_mode in [Control.FOCUS_NONE, Control.FOCUS_CLICK]
			if control is LineEdit
			else control.focus_mode == Control.FOCUS_NONE
		)
		if not valid_mode:
			output.append(control)
	for child in node.get_children():
		_collect_invalid_navigation_controls(child, output)


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
	# Scroll children keep their full global rect even when most of the control is
	# clipped by the viewport. Compare the actually visible portions so a tile
	# below the fold is not reported as overlapping a fixed action bar.
	var overlap := _visible_control_rect(first).intersection(_visible_control_rect(second))
	_check(
		overlap.size.x <= EPSILON or overlap.size.y <= EPSILON,
		"%s: controls overlap: %s and %s (%s)" % [
			label, first.get_path(), second.get_path(), overlap,
		],
	)


func _visible_control_rect(control: Control) -> Rect2:
	var rect := control.get_global_rect()
	var ancestor := control.get_parent()
	while ancestor:
		if ancestor is ScrollContainer:
			rect = rect.intersection((ancestor as Control).get_global_rect())
		elif ancestor is Control and (ancestor as Control).clip_contents:
			rect = rect.intersection((ancestor as Control).get_global_rect())
		if not rect.has_area():
			return Rect2()
		ancestor = ancestor.get_parent()
	return rect


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
		"DeckGalleryTileButton": "Button",
		"TitleLogoLabel": "Label",
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
		and theme.has_stylebox(&"disabled", &"FrontPrimaryButton"),
		"Primary button variation must define pointer and disabled states",
	)
	_check(
		theme.has_stylebox(&"normal", &"DeckGalleryTileButton")
		and theme.has_stylebox(&"hover", &"DeckGalleryTileButton")
		and theme.has_stylebox(&"pressed", &"DeckGalleryTileButton")
		and theme.has_stylebox(&"hover_pressed", &"DeckGalleryTileButton")
		and theme.has_stylebox(&"disabled", &"DeckGalleryTileButton"),
		"Deck-gallery tile variation must define every pointer interaction state",
	)
	_check(
		theme.get_constant(&"v_separation", &"PopupMenu") >= 24,
		"Frontend PopupMenu rows must reserve touch-friendly vertical spacing",
	)
	_check(
		theme.get_icon(&"grabber", &"HSlider")
		!= theme.get_icon(&"grabber_highlight", &"HSlider"),
		"Frontend sliders need a visible hover grabber state",
	)
	_check(
		_font_weight(theme.default_font) >= 600.0,
		"Frontend compact body text must use Noto Semibold 600 or heavier",
	)
	_check(
		theme.has_font(&"font", &"Button")
		and _font_weight(theme.get_font(&"font", &"Button")) >= 700.0,
		"Frontend controls must use Noto Bold 700",
	)
	for heading_type in [&"FrontHeadingLabel", &"FrontSectionLabel", &"TitleLogoLabel"]:
		_check(
			theme.has_font(&"font", heading_type)
			and _font_weight(theme.get_font(&"font", heading_type)) >= 700.0,
			"Frontend heading weight must remain Bold 700: %s" % heading_type,
		)
	_check_frontend_contrast(theme)


func _check_frontend_contrast(theme: Theme) -> void:
	var raised := theme.get_stylebox(&"panel", &"FrontRaisedPanel") as StyleBoxFlat
	var primary := theme.get_stylebox(&"normal", &"FrontPrimaryButton") as StyleBoxFlat
	var primary_hover := theme.get_stylebox(&"hover", &"FrontPrimaryButton") as StyleBoxFlat
	var primary_pressed := theme.get_stylebox(&"pressed", &"FrontPrimaryButton") as StyleBoxFlat
	var status := theme.get_stylebox(&"panel", &"FrontStatusPanel") as StyleBoxFlat
	var input := theme.get_stylebox(&"normal", &"LineEdit") as StyleBoxFlat
	var scroll_track := theme.get_stylebox(&"scroll", &"VScrollBar") as StyleBoxFlat
	var scroll_grabber := theme.get_stylebox(&"grabber", &"VScrollBar") as StyleBoxFlat
	_check(raised != null, "Raised frontend panel style is unavailable for contrast checks")
	_check(primary != null, "Primary frontend button style is unavailable for contrast checks")
	_check(
		primary_hover != null and primary_pressed != null,
		"Primary frontend pointer styles are unavailable for contrast checks",
	)
	_check(status != null, "Status frontend panel style is unavailable for contrast checks")
	_check(input != null, "Frontend input style is unavailable for contrast checks")
	_check(scroll_track != null and scroll_grabber != null,
		"Frontend scrollbar styles are unavailable for contrast checks")
	if (
		raised == null
		or primary == null
		or primary_hover == null
		or primary_pressed == null
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
		["res://assets/ui/fonts/noto_sans_cjk_sc_semibold.tres", 600.0],
		["res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres", 700.0],
	]
	for row in font_rows:
		var variation := load(str(row[0])) as FontVariation
		_check(
			variation != null
			and is_equal_approx(
				float(variation.variation_opentype.get(FONT_WEIGHT_TAG, -1.0)),
				float(row[1]),
			),
			"Frontend FontVariation has the wrong weight: %s" % row[0],
		)
	var game_theme := load(GAME_THEME_PATH) as Theme
	_check(game_theme != null, "Game theme must load for font-weight checks")
	if game_theme:
		_check(
			_font_weight(game_theme.default_font) >= 600.0,
			"Game body/HUD text must use Noto Semibold 600 or heavier",
		)
		for control_type in [&"Button", &"CheckButton", &"OptionButton", &"PopupMenu"]:
			_check(
				game_theme.has_font(&"font", control_type)
				and _font_weight(game_theme.get_font(&"font", control_type)) >= 700.0,
				"Game control text must use Noto Bold 700: %s" % control_type,
			)
	var generated_theme := GameUITheme.create()
	_check(
		_font_weight(generated_theme.default_font) >= 600.0
		and _font_weight(generated_theme.get_font(&"font", &"Button")) >= 700.0,
		"GameUITheme factory must preserve the static body/control weight hierarchy",
	)
	var title_source := FileAccess.get_file_as_string(
		"res://scenes/title/title_page.tscn"
	)
	_check(
		title_source.count("theme_type_variation = &\"TitleLogoLabel\"") == 2,
		"Both title-logo layers must opt into the Bold title font variation",
	)
	var effect_source := FileAccess.get_file_as_string(
		"res://scenes/battle/effect_layer.gd"
	)
	_check(
		not "ThemeDB.fallback_font" in effect_source
		and "noto_sans_cjk_sc_bold.tres" in effect_source,
		"Battle floating text must use the project Bold font instead of ThemeDB fallback",
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


func _font_weight(font: Font) -> float:
	if font is FontVariation:
		return float((font as FontVariation).variation_opentype.get(FONT_WEIGHT_TAG, -1.0))
	return -1.0


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
