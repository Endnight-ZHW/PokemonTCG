extends RefCounted

var context: FrontendContractContext


func configure(contract_context: FrontendContractContext) -> void:
	context = contract_context


func _check_shared_backdrop_contract() -> void:
	context.tree.root.size = Vector2i(1600, 900)
	var backdrop_scene := load("res://ui/frontend/frontend_backdrop.tscn") as PackedScene
	context._check(backdrop_scene != null, "Shared frontend backdrop scene is unavailable")
	if backdrop_scene == null:
		return
	var backdrop := backdrop_scene.instantiate() as Control
	context.tree.root.add_child(backdrop)
	backdrop.call("configure", "neutral")
	await context._settle_layout(3)
	context._check(
		backdrop.get_node_or_null("%CardFan") == null,
		"Shared frontend backdrop must not contain decorative card artwork",
	)
	backdrop.call("configure", "victory")
	await context._settle_layout(2)
	context._check(
		backdrop.get_node_or_null("%CardFan") == null,
		"Victory backdrop must not restore decorative card artwork",
	)
	backdrop.queue_free()
	await context._settle_layout(2)

	var title_backdrop_scene := load(
		"res://ui/frontend/title_backdrop.tscn"
	) as PackedScene
	context._check(title_backdrop_scene != null, "Title backdrop scene is unavailable")
	if title_backdrop_scene == null:
		return
	var title_backdrop := title_backdrop_scene.instantiate() as Control
	context.tree.root.add_child(title_backdrop)
	await context._settle_layout(2)
	context._check(
		title_backdrop.get_node_or_null("%CardBackLayer") == null,
		"Title and modal backdrops must not contain decorative edge cards",
	)
	title_backdrop.queue_free()
	await context._settle_layout(2)


func _check_network_intro_contract(catalog: CardCatalog) -> void:
	context.tree.root.size = Vector2i(1600, 900)
	var packed := load(context.PAGE_SCENES.network) as PackedScene
	context._check(packed != null, "Network lobby scene is unavailable for intro-card checks")
	if packed == null:
		return
	var page := packed.instantiate() as Control
	context.tree.root.add_child(page)
	page.call("configure", catalog, "lan", "wss://relay.example.test")
	await context._settle_layout(4)
	var intro_panel := page.get_node("%IntroPanel") as PanelContainer
	var form_panel := page.find_child("FormPanel", true, false) as PanelContainer
	var body := page.find_child("Body", true, false) as HBoxContainer
	var top_bar := page.find_child("TopBar", true, false) as HBoxContainer
	var page_frame := page.get_node("%Page") as VBoxContainer
	var description := page.get_node("%KindDescription") as Label
	var tip := page.get_node("%IntroTip") as Label
	var kind_label := page.get_node("%KindLabel") as Label
	var kind_code := page.get_node("%KindCode") as Label
	var intro_icon := page.get_node("%IntroIcon") as TextureRect
	var role_badge := page.get_node("%RoleBadgeLabel") as Label
	_check_network_wide_first_screen(page, "LAN idle")
	context._check(
		intro_panel.visible and not bool(page.get("_compact")),
		"1600x900 network lobby must expose the wide connection overview",
	)
	context._check(
		context._rect_inside(intro_panel.get_global_rect(), body.get_global_rect())
		and context._rect_inside(form_panel.get_global_rect(), body.get_global_rect()),
		"Network overview or form escaped the wide Body container",
	)
	context._check_pair_not_overlapping(intro_panel, form_panel, "network-intro-wide")
	context._check(
		form_panel.size.x >= 620.0,
		"Network overview consumed too much width from the connection form",
	)
	context._check_named_inside(page, intro_panel.get_global_rect(), [
		"IntroAccent", "IntroHeader", "KindDescription", "OverviewHeader",
		"FeatureList", "IntroTipPanel",
	], "network-intro-wide")
	context._check(
		description.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART
		and description.get_line_count() >= 2
		and description.get_visible_line_count() == description.get_line_count(),
		"LAN overview description does not wrap fully inside the left card",
	)
	context._check(
		tip.get_visible_line_count() == tip.get_line_count(),
		"LAN overview role hint is clipped",
	)
	context._check(
		kind_label.text == "局域网直连"
		and kind_code.text.begins_with("LAN")
		and intro_icon.texture.resource_path.ends_with("lan.svg")
		and role_badge.text == "房主 · 创建",
		"LAN overview presentation is stale or incomplete",
	)
	var decorative_targets: Array[Control] = []
	context._collect_pointer_targets(intro_panel, decorative_targets)
	context._check(
		decorative_targets.is_empty() and intro_panel.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"Decorative network overview must not enter the pointer path",
	)
	var role_option := page.get_node("%NetworkRoleOption") as OptionButton
	role_option.select(1)
	page.call("refresh_fields", 1)
	context._check(
		role_badge.text == "挑战者 · 加入" and tip.text.contains("局域网地址"),
		"LAN overview did not follow the selected client role",
	)
	var kind_option := page.get_node("%NetworkKindOption") as OptionButton
	kind_option.select(1)
	kind_option.item_selected.emit(1)
	await context._settle_layout(3)
	context._check(
		kind_label.text == "远程中继"
		and kind_code.text.begins_with("RELAY")
		and intro_icon.texture.resource_path.ends_with("globe.svg")
		and (page.get_node("%FeatureOne") as Label).text.contains("跨网络")
		and tip.text.contains("房间码"),
		"Relay overview did not update its icon, facts, or role hint",
	)
	role_option.select(0)
	page.call("refresh_fields", 0)
	await context._settle_layout(3)
	_check_network_wide_first_screen(page, "Relay idle")
	context._check(
		context._rect_inside(page_frame.get_global_rect(), Rect2(Vector2.ZERO, context.tree.root.size)),
		"LAN/Relay role changes clipped the wide network page "
		+ "(relay_host_y=%.1f page=%s context.tree.root=%s)" % [
			top_bar.global_position.y, page_frame.get_global_rect(), context.tree.root.size,
		],
	)
	page.call(
		"set_connection_state",
		NetworkLobbyPage.ConnectionState.WAITING,
		"房间已创建，等待挑战者加入。",
		"ROOM42",
	)
	await context._settle_layout(3)
	_check_network_wide_first_screen(page, "Relay waiting")
	page.call("set_connection_state", NetworkLobbyPage.ConnectionState.ERROR,
		"连接失败：无法到达指定设备。请确认双方处于同一局域网、系统防火墙允许当前端口，并核对房主地址后重新尝试。")
	await context._settle_layout(3)
	_check_network_wide_first_screen(page, "Relay long error")
	page.queue_free()
	await context._settle_layout(2)


func _check_network_wide_first_screen(page: NetworkLobbyPage, label: String) -> void:
	var scroll := page.page_scroll
	context._check(scroll != null, "%s: network scroll host is missing" % label)
	if scroll == null:
		return
	var viewport_rect := scroll.get_global_rect()
	var page_rect := page.page.get_global_rect()
	var scrollbar := scroll.get_v_scroll_bar()
	context._check(
		scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED
		and not scroll.follow_focus
		and not scrollbar.visible
		and scroll.scroll_vertical == 0,
		"1600x900 %s must be top-aligned without scrollbars (scroll=%d max=%.1f visible=%s)" % [
			label, scroll.scroll_vertical, scrollbar.max_value, scrollbar.visible,
		],
	)
	var left_gutter := page_rect.position.x - viewport_rect.position.x
	var right_gutter := viewport_rect.end.x - page_rect.end.x
	var top_gutter := page_rect.position.y - viewport_rect.position.y
	context._check(
		left_gutter >= -context.EPSILON
		and right_gutter >= -context.EPSILON
		and absf(left_gutter - right_gutter) <= 2.0
		and absf(page_rect.get_center().x - viewport_rect.get_center().x) <= 1.0
		and absf(top_gutter) <= 1.0
		and page.page.get_parent() == page.page_center,
		"1600x900 %s must top-align and horizontally center the network page (left=%.1f right=%.1f top=%.1f page=%s viewport=%s)" % [
			label, left_gutter, right_gutter, top_gutter, page_rect, viewport_rect,
		],
	)
	for node_name in [
		"Page", "TopBar", "Steps", "Body", "FormPanel", "StatusPanel",
		"NetworkConnectButton",
	]:
		var control := page.find_child(node_name, true, false) as Control
		context._check(control != null, "%s: missing %s" % [label, node_name])
		if control == null or not control.is_visible_in_tree():
			continue
		context._check(
			context._rect_inside(control.get_global_rect(), viewport_rect),
			"1600x900 %s clipped %s: rect=%s viewport=%s" % [
				label, node_name, control.get_global_rect(), viewport_rect,
			],
		)
	context._check(
		page.connect_button.get_global_rect().size.y >= context.MIN_TARGET_SIZE,
		"1600x900 %s reduced the primary action below 48px" % label,
	)


func _check_network_scrollbar_width_contract(catalog: CardCatalog) -> void:
	var mounted := await context._mount(context.PAGE_SCENES.network, Vector2i(1024, 600))
	var page := mounted.page as NetworkLobbyPage
	if page == null:
		context._unmount(mounted)
		return
	page.configure(catalog, "lan", "wss://relay.example.test")
	page._set_compact_step(2)
	page.set_connection_state(
		NetworkLobbyPage.ConnectionState.ERROR,
		"连接失败：请确认房主地址、端口、防火墙和局域网连接状态后重新尝试。",
	)
	await context._settle_layout(5)
	var scroll := page.page_scroll
	var scrollbar := scroll.get_v_scroll_bar()
	# Keep this fixture deterministic across display-driver stretch behavior and
	# font metric changes: its purpose is the fallback's scrollbar geometry, so
	# explicitly make the content taller than the available viewport.
	if not scrollbar.visible:
		page.page.custom_minimum_size.y = scroll.size.y + 96.0
		await context._settle_layout(3)
	context._check(
		scrollbar.visible
		and scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED,
		"1024x600 compact network fixture must exercise the vertical-scroll fallback (scroll=%s page=%s minimum=%s max=%.1f)" % [
			scroll.get_global_rect(), page.page.get_global_rect(),
			page.page.get_combined_minimum_size(), scrollbar.max_value,
		],
	)
	var visible_rect := scroll.get_global_rect()
	var visible_right := (
		minf(visible_rect.end.x, scrollbar.get_global_rect().position.x)
		if scrollbar.visible
		else visible_rect.end.x
	)
	for node_name in [
		"Page", "FormPanel", "RuleRow", "NetworkDeckOption", "NetworkConnectButton",
	]:
		var control := page.find_child(node_name, true, false) as Control
		context._check(control != null, "Compact network scrollbar fixture lacks %s" % node_name)
		if control == null or not control.is_visible_in_tree():
			continue
		var rect := control.get_global_rect()
		context._check(
			rect.position.x >= visible_rect.position.x - context.EPSILON
			and rect.end.x <= visible_right + context.EPSILON,
			"Vertical scrollbar clips compact network content horizontally: %s rect=%s viewport=%s" % [
				node_name, rect, visible_rect,
			],
		)
	context._check_no_horizontal_scroll(page, "network-scrollbar-1024x600")
	context._unmount(mounted)
	await context._settle_layout(2)


func _check_deck_tile_visual_contract(catalog: CardCatalog) -> void:
	context.tree.root.size = Vector2i(1600, 900)
	var packed := load(context.PAGE_SCENES.decks) as PackedScene
	context._check(packed != null, "Deck-select scene is unavailable for tile visual checks")
	if packed == null:
		return
	var page := packed.instantiate() as Control
	context.tree.root.add_child(page)
	page.call("configure", catalog, "local")
	await context._settle_layout(4)
	var gallery_grid := page.get_node("%GalleryGrid") as GridContainer
	var gallery_scroll := page.get_node("%GalleryScroll") as ScrollContainer
	context._check(gallery_grid.get_child_count() >= 3, "Deck gallery exposes too few tiles for state checks")
	if gallery_grid.get_child_count() < 3:
		page.queue_free()
		await context._settle_layout(2)
		return
	var first := gallery_grid.get_child(0) as DeckGalleryTile
	var second := gallery_grid.get_child(1) as DeckGalleryTile
	var third := gallery_grid.get_child(2) as DeckGalleryTile
	context._check(
		first.theme_type_variation == &"DeckGalleryTileButton"
		and first.find_child("Accent", true, false) == null,
		"Deck tile still uses the shared mode style or legacy full-width Accent",
	)
	for node_name in [
		"Artwork", "ArtworkFrame", "DeckName", "EnergyBadge", "EnergyIcon", "EnergyLabel",
		"CardCountLabel", "TaglineLabel", "AssignmentBadge", "AssignmentLabel",
	]:
		context._check(
			first.find_child(node_name, true, false) != null,
			"Deck tile is missing visual node %s" % node_name,
		)
	var count_label := first.get_node("%CardCountLabel") as Label
	var energy_badge := first.get_node("%EnergyBadge") as PanelContainer
	var energy_icon := first.get_node("%EnergyIcon") as TextureRect
	var energy_label := first.get_node("%EnergyLabel") as Label
	var assignment_badge := first.get_node("%AssignmentBadge") as PanelContainer
	var assignment_label := first.get_node("%AssignmentLabel") as Label
	context._check(
		count_label.visible
		and count_label.text.contains("60 张")
		and count_label.size.x >= 48.0
		and energy_badge.size.x >= 64.0
		and first.accessibility_name.contains("60 张"),
		"Deck tile lost its visible or accessible card count/type badge",
	)
	context._check(
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
	context._check(
		not energy_icon.visible
		and energy_icon.texture == null
		and (first.get_node("%EnergyLabel") as Label).text == "龙属性"
		and energy_badge.accessibility_name.contains("龙属性"),
		"Unsupported deck energy type must fall back to text without a Colorless icon",
	)
	first.call("_configure_energy_badge", "Grass")
	for node in first.find_children("*", "ColorRect", true, false):
		var strip := node as ColorRect
		context._check(
			not (strip.size.y <= 8.0 and strip.size.x >= first.size.x * 0.8),
			"Deck tile reintroduced a full-width colored strip",
		)
	for node in first.find_children("*", "Control", true, false):
		var child := node as Control
		context._check(
			child.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"Deck tile child intercepts pointer input: %s" % child.get_path(),
		)
	var scroll_rect := gallery_scroll.get_global_rect()
	for tile_value in gallery_grid.get_children():
		var tile := tile_value as Control
		var tile_rect := tile.get_global_rect()
		context._check(
			tile_rect.position.x >= scroll_rect.position.x - context.EPSILON
			and tile_rect.end.x <= scroll_rect.end.x + context.EPSILON,
			"Deck tile exceeds the gallery's horizontal viewport: %s" % tile.get_path(),
		)
	context._check(
		first.is_pressed()
		and assignment_badge.visible
		and assignment_label.text == "P1"
		and not second.is_pressed()
		and (second.get_node("%AssignmentLabel") as Label).text == "P2"
		and not (third.get_node("%AssignmentBadge") as PanelContainer).visible,
		"Deck tile pressed and assignment states are no longer independent",
	)
	context._check(
		first.focus_mode == Control.FOCUS_NONE
		and second.focus_mode == Control.FOCUS_NONE
		and context.tree.root.gui_get_focus_owner() == null
		and first.is_pressed(),
		"Deck tiles must keep selection without exposing GUI focus",
	)
	var shared_keys: Array[String] = [first.deck_key, first.deck_key]
	first.set_assignment_state(0, shared_keys, "玩家 2")
	context._check(
		first.is_pressed()
		and assignment_label.text == "P1 · P2"
		and first.accessibility_description.contains("玩家 1")
		and first.accessibility_description.contains("玩家 2"),
		"Deck tile cannot represent one deck assigned to both players",
	)
	page.queue_free()
	await context._settle_layout(2)


func _check_same_instance_resize(catalog: CardCatalog) -> void:
	var host := Control.new()
	host.name = "ResponsiveResizeHost"
	host.size = Vector2(1600, 900)
	context.tree.root.add_child(host)
	var deck_scene := load(context.PAGE_SCENES.decks) as PackedScene
	var deck := deck_scene.instantiate() as DeckSelectPage
	deck.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(deck)
	deck.configure(catalog, "challenge")
	await context._settle_layout(4)
	var deck_selection := [
		deck.selected_deck_key(0),
		deck.selected_deck_key(1),
	]
	host.size = Vector2(1024, 768)
	await context._settle_layout(4)
	context._check(
		bool(deck.get("_compact"))
		and deck.selected_deck_key(0) == deck_selection[0]
		and deck.selected_deck_key(1) == deck_selection[1]
		and context.tree.root.gui_get_focus_owner() == null,
		"Deck same-instance wide→compact resize changed selection or created focus",
	)
	context._check_pointer_only_controls(deck, "deck-same-instance-compact")
	host.size = Vector2(1600, 900)
	await context._settle_layout(3)
	deck.queue_free()
	await context._settle_layout(2)
	var network_scene := load(context.PAGE_SCENES.network) as PackedScene
	var network := network_scene.instantiate() as NetworkLobbyPage
	network.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(network)
	network.configure(catalog, "relay", "wss://relay.example.test")
	await context._settle_layout(4)
	host.size = Vector2(1024, 768)
	await context._settle_layout(4)
	context._check(
		bool(network.get("_compact"))
		and network.kind_option.is_visible_in_tree()
		and context.tree.root.gui_get_focus_owner() == null,
		"Network same-instance wide→compact resize changed step or created focus",
	)
	context._check_pointer_only_controls(network, "network-same-instance-compact")
	host.queue_free()
	await context._settle_layout(2)


func _check_workbench_compact() -> void:
	context.tree.root.size = Vector2i(1600, 900)
	var workbench_scene := load("res://tools/ui_workbench.tscn") as PackedScene
	context._check(workbench_scene != null,
		"UI Workbench is unavailable for narrow-host frontend checks")
	if workbench_scene == null:
		return
	var workbench := workbench_scene.instantiate()
	context.tree.root.add_child(workbench)
	await context._settle_layout(3)
	workbench.show_preview("title")
	await context._settle_layout(4)
	var preview_host := workbench.get_node("%PreviewHost") as Control
	var title := (
		preview_host.get_child(0) as Control
		if preview_host.get_child_count() > 0
		else null
	)
	context._check(title != null, "Workbench narrow preview did not mount the title page")
	if title:
		context._check_named_inside(title, preview_host.get_global_rect(), [
			"TitleStack", "CardStage", "LocalTwoPlayerButton", "AIButton",
			"NetworkButton", "FooterRow",
		], "workbench-title-preview")
		context._check_no_horizontal_scroll(title, "workbench-title-preview")
	context._check_pointer_only_controls(workbench, "workbench")
	workbench.queue_free()
	await context._settle_layout(2)


func _check_battle_canvas_resize() -> void:
	context.tree.root.size = Vector2i(1600, 900)
	var battle_scene := load("res://scenes/battle/components/battle_table.tscn") as PackedScene
	context._check(battle_scene != null, "Battle screen is unavailable for live resize checks")
	if battle_scene == null:
		return
	var battle := battle_scene.instantiate()
	context.tree.root.add_child(battle)
	battle.initialize_ui()
	await context._settle_layout(4)
	var canvas := battle.board_canvas as Control
	var own_active := battle.own_active as Control
	context._check(
		canvas != null
		and canvas.resized.is_connected(
			Callable(battle.board_view, "_layout_board")
		),
		"BattleTable must listen to its resolved BoardCanvas size",
	)
	battle.show_card_detail("sv1-104")
	await context._settle_layout(2)
	var detail := battle.detail_panel as BattleDetailPanel
	var opponent_bench_bottom := -INF
	for bench_view in battle.opponent_bench:
		if bench_view != null and bench_view.visible:
			opponent_bench_bottom = maxf(
				opponent_bench_bottom,
				bench_view.get_global_rect().end.y,
			)
	context._check(
		detail != null
		and detail.visible
		and opponent_bench_bottom > -INF
		and detail.get_global_rect().position.y + context.EPSILON >= opponent_bench_bottom,
		"Battle card preview must stay below the opponent bench row",
	)
	var first_center_x := own_active.position.x + own_active.size.x * 0.5
	context.tree.root.size = Vector2i(2000, 900)
	await context._settle_layout(5)
	var metrics: Dictionary = battle.board_view._board_layout_metrics(
		canvas.size.x,
		canvas.size.y,
	)
	var resized_center_x := own_active.position.x + own_active.size.x * 0.5
	context._check(
		absf(resized_center_x - float(metrics["center_x"])) <= 2.0
		and resized_center_x > first_center_x + 100.0,
		"Battle slots did not recenter after same-instance 1600→2000 resize",
	)
	context._check_no_navigation_controls(battle, "battle-live-resize")
	battle.queue_free()
	await context._settle_layout(2)


func _check_compact_battle_detail_layout() -> void:
	var battle_scene := load("res://scenes/battle/components/battle_table.tscn") as PackedScene
	context._check(battle_scene != null,
		"Battle screen is unavailable for compact detail checks")
	if battle_scene == null:
		return
	var host := Control.new()
	host.name = "CompactBattleHost"
	host.size = Vector2(900, 540)
	context.tree.root.add_child(host)
	var battle := battle_scene.instantiate() as BattleTable
	host.add_child(battle)
	battle.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	battle.initialize_ui()
	await context._settle_layout(5)
	var state := UIPreviewStateFactory.battle_state()
	var pokemon := state.players[0].active
	pokemon.damage_counters = 2
	pokemon.status_conditions.assign(["POISONED"])
	battle.update_view(
		state,
		0,
		UIPreviewStateFactory.action_rows(state),
		"pokemon:0:active",
		false,
		"local",
	)
	battle.show_card_detail(pokemon.card_id, pokemon)
	await context._settle_layout(4)
	var detail := battle.detail_panel as BattleDetailPanel
	var board_rect := battle.board_panel.get_global_rect()
	var detail_rect := detail.get_global_rect() if detail else Rect2()
	var close_rect := (
		detail.close_button.get_global_rect()
		if detail and detail.close_button
		else Rect2()
	)
	context._check(
		detail != null
		and detail.visible
		and detail.is_compact_layout()
		and detail.scale.is_equal_approx(Vector2.ONE)
		and detail.size.is_equal_approx(BattleDetailPanel.COMPACT_PANEL_SIZE)
		and detail_rect.position.y >= board_rect.position.y + board_rect.size.y * 0.4
		and detail_rect.end.y <= board_rect.end.y + context.EPSILON,
		"900x540 battle detail must use the unscaled 440x220 bottom layout: detail=%s board=%s" % [
			detail_rect, board_rect,
		],
	)
	context._check(
		close_rect.size.x + context.EPSILON >= context.MIN_TARGET_SIZE
		and close_rect.size.y + context.EPSILON >= context.MIN_TARGET_SIZE,
		"Compact battle detail close target is below 48x48: %s" % close_rect,
	)
	context._check(
		detail != null and detail.detail_text.scroll_active,
		"Compact battle detail must keep its body internally scrollable",
	)
	context._check(
		detail != null
		and detail.state_panel.visible
		and "当前状态" in detail.state_text.text
		and "当前状态" not in detail.detail_text.text
		and detail.detail_text.tooltip_text.is_empty()
		and detail.state_text.get_content_height() <= detail.state_text.size.y + context.EPSILON,
		"Compact battle detail must separate unclipped live state from printed rules: "
		+ "visible=%s state=%s rules=%s tooltip=%s content=%s size=%s" % [
			detail.state_panel.visible if detail else false,
			detail.state_text.text if detail else "<missing>",
			detail.detail_text.text if detail else "<missing>",
			detail.detail_text.tooltip_text if detail else "<missing>",
			detail.state_text.get_content_height() if detail else -1,
			detail.state_text.size if detail else Vector2.ZERO,
		],
	)
	context._check(
		battle.action_popover != null
		and battle.action_popover.visible
		and battle.action_popover.is_compact_layout()
		and not detail_rect.intersects(
			battle.action_popover.panel_global_rect().grow(4.0)
		),
		"Compact card actions must use the short action strip without covering details: "
		+ "detail=%s actions=%s placement=%s" % [
			detail_rect,
			battle.action_popover.panel_global_rect() if battle.action_popover else Rect2(),
			battle.action_popover.current_placement if battle.action_popover else "<missing>",
		],
	)
	host.queue_free()
	await context._settle_layout(2)


func _check_viewport(viewport_size: Vector2i, catalog: CardCatalog) -> void:
	context.tree.root.size = viewport_size
	await context.tree.process_frame
	await _check_title(viewport_size)
	await _check_decks(viewport_size, catalog)
	await _check_network(viewport_size, catalog)
	await _check_scrolling_panel(viewport_size, "settings")
	await _check_scrolling_panel(viewport_size, "help")
	await _check_deck_detail(viewport_size, catalog)
	await _check_victory(viewport_size)


func _check_title(viewport_size: Vector2i) -> void:
	var mounted := await context._mount(context.PAGE_SCENES.title, viewport_size)
	var page := mounted.page as Control
	if page == null:
		context._unmount(mounted)
		return
	page.call("configure", "Layout contract")
	await context._settle_layout()
	var label := context._case_label("title", viewport_size)
	context._check_full_page(page, mounted.safe_host, label)
	context._check_named_inside(page, context._simulated_safe_rect(mounted.safe_host), [
		"PageFrame", "TitleStack", "TypeOrbs", "CardStage", "LocalTwoPlayerButton",
		"AIButton", "NetworkButton", "FooterRow", "SettingsButton", "HelpButton",
	], label)
	context._check_named_non_overlapping(page, [
		"LocalTwoPlayerButton", "AIButton", "NetworkButton",
		"SettingsButton", "HelpButton",
	], label)
	for legacy_name in [
		"ChallengeAIButton", "DeepAIButton", "LANButton", "RelayButton", "OnlineCard",
	]:
		context._check(
			page.find_child(legacy_name, true, false) == null,
			"%s: legacy title control remains: %s" % [label, legacy_name],
		)
	var expected_tier := context.TITLE_TIER_DENSE
	if (
		page.size.x >= 1180.0
		and page.size.y >= 650.0
		and page.size.x / maxf(page.size.y, 1.0) >= 1.5
	):
		expected_tier = context.TITLE_TIER_WIDE
	elif (
		page.size.x >= 900.0
		and page.size.y >= 600.0
		and page.size.x / maxf(page.size.y, 1.0) >= 1.15
	):
		expected_tier = context.TITLE_TIER_COMPACT_LANDSCAPE
	context._check(
		int(page.get("_layout_tier")) == expected_tier,
		"%s: title responsive tier does not match the documented breakpoints" % label,
	)
	_check_title_energy_badges(page, label, expected_tier)
	var modes_wrapper := page.find_child("ModesGlass", true, false) as Control
	context._check(
		modes_wrapper is MarginContainer and not (modes_wrapper is PanelContainer),
		"%s: title mode buttons must not be enclosed by a visible panel frame" % label,
	)
	if viewport_size == Vector2i(1600, 900):
		_check_title_showcase_rotation(page, label)
	var expected_button_height := (
		116.0
		if expected_tier == context.TITLE_TIER_WIDE
		else 96.0
		if expected_tier == context.TITLE_TIER_COMPACT_LANDSCAPE
		else 84.0
	)
	for node_name in ["LocalTwoPlayerButton", "AIButton", "NetworkButton"]:
		var mode_button := page.find_child(node_name, true, false) as Button
		context._check(
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
			context._check(
				context._contrast_ratio(foreground, fill) >= 4.5
				and context._contrast_ratio(foreground, hover_fill) >= 4.5
				and context._contrast_ratio(subtitle, fill) >= 4.5
				and context._contrast_ratio(subtitle, hover_fill) >= 4.5,
				"%s: %s title/subtitle contrast must be at least 4.5:1"
				% [label, node_name],
			)
			context._check(
				context._relative_luminance(fill) <= 0.04,
				"%s: %s must keep the midnight dark-surface treatment"
				% [label, node_name],
			)
			context._check(
				context._contrast_ratio(accent, fill) >= 3.0
				and context._contrast_ratio(Color.WHITE, hover_fill) >= 3.0,
				"%s: %s accent and hover treatment must remain distinguishable"
				% [label, node_name],
			)
	context._check_pointer_only_controls(page, label, context._simulated_safe_rect(mounted.safe_host))
	context._check_no_horizontal_scroll(page, label)
	context._unmount(mounted)
	await context._settle_layout(2)


func _check_title_energy_badges(
	page: Control,
	label: String,
	expected_tier: int,
) -> void:
	var grid := page.find_child("TypeOrbs", true, false) as GridContainer
	var expected_columns := 4 if expected_tier == context.TITLE_TIER_DENSE else 8
	var expected_size := (
		28.0
		if expected_tier == context.TITLE_TIER_WIDE
		else 24.0
		if expected_tier == context.TITLE_TIER_COMPACT_LANDSCAPE
		else 20.0
	)
	context._check(grid != null, "%s: energy badge grid is missing" % label)
	if grid == null:
		return
	context._check(
		grid.columns == expected_columns and grid.get_child_count() == 8,
		"%s: energy badges must use 8 columns or a dense 4x2 grid" % label,
	)
	for index in range(context.TITLE_ENERGY_TYPES.size()):
		var energy_type := context.TITLE_ENERGY_TYPES[index]
		var badge := page.find_child("%sEnergyBadge" % energy_type, true, false) as PanelContainer
		var icon := page.find_child("%sEnergyIcon" % energy_type, true, false) as TextureRect
		context._check(
			badge != null and icon != null,
			"%s: missing %s basic-energy badge" % [label, energy_type],
		)
		if badge == null or icon == null:
			continue
		context._check(
			str(badge.get_meta("energy_type", "")) == energy_type
			and grid.get_child(index) == badge,
			"%s: %s energy badge order/type metadata changed" % [label, energy_type],
		)
		context._check(
			badge.custom_minimum_size.is_equal_approx(Vector2.ONE * expected_size),
			"%s: %s energy badge has the wrong responsive size" % [label, energy_type],
		)
		context._check(
			icon.custom_minimum_size.is_equal_approx(Vector2.ONE * expected_size)
			and badge.get_theme_stylebox(&"panel") is StyleBoxEmpty,
			"%s: %s energy icon must not have a dark backing ring"
			% [label, energy_type],
		)
		context._check(
			badge.focus_mode == Control.FOCUS_NONE
			and badge.mouse_filter == Control.MOUSE_FILTER_IGNORE
			and icon.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"%s: decorative energy badge must not enter pointer/focus navigation"
			% label,
		)
		var expected_path := context.ENERGY_ICON_CATALOG.path_for(energy_type)
		context._check(
			icon.texture != null and icon.texture.resource_path == expected_path,
			"%s: %s energy badge must load through EnergyIconCatalog"
			% [label, energy_type],
		)


func _check_title_showcase_rotation(page: Control, label: String) -> void:
	var catalog := CardCatalog.shared()
	var pool: Array = page.get("_showcase_card_pool")
	var before: Array = page.get("_showcase_card_ids").duplicate()
	context._check(pool.size() >= 3, "%s: Pokémon showcase rotation pool is empty" % label)
	for card_id_value in pool:
		var card_id := str(card_id_value)
		var image_path := str(catalog.get_card(card_id).get("image_path", ""))
		context._check(
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
	context._check(
		rotated
		and after.size() == 3
		and str(after[0]) != str(before[0])
		and unique_after.size() == 3,
		"%s: showcase rotation must replace one slot without duplicates" % label,
	)
	context._check(
		cards.size() == 3
		and shadows.size() == 3
		and rotated_texture != null
		and rotated_texture == (shadows[0] as TextureRect).texture
		and rotated_texture.resource_path == rotated_path,
		"%s: showcase card and shadow must share the catalog texture" % label,
	)


func _check_decks(viewport_size: Vector2i, catalog: CardCatalog) -> void:
	var mounted := await context._mount(context.PAGE_SCENES.decks, viewport_size)
	var page := mounted.page as Control
	if page == null:
		context._unmount(mounted)
		return
	page.call("configure", catalog, "challenge")
	await context._settle_layout(4)
	context._check(
		not (page.get_node("%GalleryScroll") as ScrollContainer).follow_focus,
		"Deck gallery must not follow disabled keyboard navigation",
	)
	if viewport_size == Vector2i(1600, 900):
		_check_deck_public_api(page, catalog)
	elif viewport_size == Vector2i(1024, 768):
		await _check_deck_compact_pointer_flow(page)
	var label := context._case_label("decks", viewport_size)
	context._check_full_page(page, mounted.safe_host, label)
	context._check_named_inside(page, context._simulated_safe_rect(mounted.safe_host), [
		"PageContent", "TopBar", "SlotPanel", "MasterDetail", "ActionBar",
		"GalleryPanel", "DetailPanel", "StartButton",
	], label)
	context._check_named_non_overlapping(page, [
		"TopBar", "SlotPanel", "MasterDetail", "ActionBar",
	], label)
	context._check_named_non_overlapping(page, ["GalleryPanel", "DetailPanel"], label)
	context._check_pointer_only_controls(page, label, context._simulated_safe_rect(mounted.safe_host))
	context._check_no_horizontal_scroll(page, label)
	context._unmount(mounted)
	await context._settle_layout(2)


func _check_deck_compact_pointer_flow(page: Control) -> void:
	var gallery_grid := page.get_node("%GalleryGrid") as GridContainer
	context._check(gallery_grid.get_child_count() > 0, "Deck compact pointer test requires a tile")
	if gallery_grid.get_child_count() == 0:
		return
	var tile := gallery_grid.get_child(0) as Button
	tile.pressed.emit()
	await context._settle_layout()
	var back_button := page.get_node("%BackToGalleryButton") as Button
	context._check(
		back_button.visible and back_button.size.y + context.EPSILON >= context.MIN_TARGET_SIZE,
		"Deck compact detail must expose a 48px return target",
	)
	context._check(
		page.get_viewport().gui_get_focus_owner() == null,
		"Deck compact detail must not create GUI focus",
	)
	back_button.pressed.emit()
	await context._settle_layout()
	context._check(
		tile.is_visible_in_tree()
		and tile.is_pressed()
		and page.get_viewport().gui_get_focus_owner() == null,
		"Deck compact gallery return must restore selection without focus",
	)
	tile.pressed.emit()
	await context._settle_layout()
	context._check(
		bool(page.call("handle_back")),
		"Deck compact system back must consume the detail-to-gallery transition",
	)
	await context._settle_layout()
	context._check(
		tile.is_visible_in_tree()
		and page.get_viewport().gui_get_focus_owner() == null,
		"Deck compact system back must restore the gallery without focus",
	)


func _check_deck_public_api(page: Control, catalog: CardCatalog) -> void:
	var deck_keys: Array = catalog.decks.keys()
	deck_keys.sort()
	context._check(not deck_keys.is_empty(), "DeckSelect public API contract requires a release deck")
	if deck_keys.is_empty():
		return
	var deck_key := str(deck_keys[0])
	context._check(
		bool(page.call("select_deck", 0, deck_key)),
		"DeckSelect.select_deck must accept a valid player 1 deck",
	)
	context._check(
		bool(page.call("select_deck", 1, deck_key)),
		"DeckSelect.select_deck must allow the same valid deck for player 2/AI",
	)
	context._check(
		str(page.call("selected_deck_key", 0)) == deck_key
		and str(page.call("selected_deck_key", 1)) == deck_key,
		"DeckSelect must preserve the same deck key independently in both slots",
	)
	context._check(
		int(page.call("deck_count")) == catalog.decks.size(),
		"DeckSelect.deck_count must expose every release deck",
	)
	var first_player_option := page.get_node("%FirstPlayerOption") as OptionButton
	var ai_mode_option := page.get_node("%AIModeOption") as OptionButton
	var matchup_toggle := page.get_node("%TypeMatchupToggle") as CheckButton
	context._check(
		ai_mode_option.item_count == 1
		and str(ai_mode_option.get_item_metadata(0)) == "challenge"
		and ai_mode_option.disabled,
		"DeckSelect must expose only the Challenge AI release mode",
	)
	context._check(
		first_player_option.item_count == 1
		and int(first_player_option.get_item_metadata(0)) == -1
		and first_player_option.disabled,
		"DeckSelect must defer turn order to the setup coin winner",
	)
	context._check(
		not matchup_toggle.button_pressed
		and matchup_toggle.theme_type_variation == &"FrontRuleToggle"
		and matchup_toggle.text.contains("已关闭")
		and matchup_toggle.tooltip_text.contains("项目默认")
		and matchup_toggle.get_theme_color(&"font_color").is_equal_approx(
			DesignTokens.TEXT_MUTED
		),
		"DeckSelect must use the dedicated rule-toggle style and present an explicit disabled state",
	)
	matchup_toggle.set_pressed_no_signal(true)
	matchup_toggle.toggled.emit(true)
	var enabled_hover_style := (
		matchup_toggle.get_theme_stylebox(&"hover_pressed") as StyleBoxFlat
	)
	context._check(
		matchup_toggle.text.contains("已开启")
		and matchup_toggle.tooltip_text.contains("当前已开启")
		and matchup_toggle.accessibility_name.contains("已开启")
		and enabled_hover_style != null
		and enabled_hover_style.get_border_width(SIDE_LEFT) >= 2
		and enabled_hover_style.get_border_width(SIDE_TOP) >= 2
		and enabled_hover_style.get_border_width(SIDE_RIGHT) >= 2
		and enabled_hover_style.get_border_width(SIDE_BOTTOM) >= 2
		and enabled_hover_style.border_color.a >= 0.9
		and matchup_toggle.get_theme_color(&"font_color").is_equal_approx(
			DesignTokens.GREEN
		),
		"DeckSelect matchup toggle did not expose a bordered enabled-hover state",
	)
	matchup_toggle.set_pressed_no_signal(false)
	matchup_toggle.toggled.emit(false)
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
	context._check(
		str(page.get("mode")) == "challenge"
		and page.call("selected_deck_key", 0) == preserved_state["first"]
		and page.call("selected_deck_key", 1) == preserved_state["second"]
		and page.get("_active_player_idx") == preserved_state["active"]
		and first_player_option.selected == preserved_state["first_player"]
		and gallery_scroll.scroll_vertical == preserved_state["scroll"]
		and detail_title.text == preserved_state["detail"]
		and page.get_viewport().gui_get_focus_owner() == null,
		"DeckSelect release AI configuration reset deck, slot, turn, scroll, detail, or created focus",
	)
	context._deck_start_payload.clear()
	var callback := Callable(self, "_on_deck_start_requested")
	if not page.is_connected("start_requested", callback):
		page.connect("start_requested", callback)
	var start_button := page.get_node("%StartButton") as Button
	start_button.pressed.emit()
	context._check(
		context._deck_start_payload == ["challenge", deck_key, deck_key, -1, false],
		"DeckSelect.start_requested argument order/forced_first changed: %s" % [
			context._deck_start_payload,
		],
	)


func _on_deck_start_requested(
	mode: String,
	first_deck_key: String,
	second_deck_key: String,
	forced_first_player: int,
	apply_type_matchups: bool,
) -> void:
	context._deck_start_payload = [
		mode,
		first_deck_key,
		second_deck_key,
		forced_first_player,
		apply_type_matchups,
	]


func _check_network(viewport_size: Vector2i, catalog: CardCatalog) -> void:
	var mounted := await context._mount(context.PAGE_SCENES.network, viewport_size)
	var page := mounted.page as Control
	if page == null:
		context._unmount(mounted)
		return
	var kind := "lan" if viewport_size.x in [1280, 2000] else "relay"
	page.call("configure", catalog, kind, "wss://relay.example.test/a/very/long/path")
	var matchup_toggle := page.get_node("%TypeMatchupToggle") as CheckButton
	var rule_status_badge := page.get_node("%RuleStatusBadge") as Label
	context._check(
		not matchup_toggle.button_pressed
		and matchup_toggle.text == "启用弱点与抗性"
		and matchup_toggle.theme_type_variation == &"FrontRuleToggle"
		and rule_status_badge.text.contains("已关闭")
		and rule_status_badge.text.contains("可修改")
		and rule_status_badge.get_theme_color(&"font_color").is_equal_approx(
			DesignTokens.TEXT_MUTED
		),
		"Network host must see the default disabled matchup state explicitly",
	)
	matchup_toggle.set_pressed_no_signal(true)
	matchup_toggle.toggled.emit(true)
	context._check(
		rule_status_badge.text.contains("已开启")
		and matchup_toggle.get_draw_mode() in [
			BaseButton.DRAW_PRESSED, BaseButton.DRAW_HOVER_PRESSED,
		]
		and matchup_toggle.accessibility_name.contains("已开启")
		and rule_status_badge.get_theme_color(&"font_color").is_equal_approx(
			DesignTokens.GREEN
		),
		"Network host matchup toggle did not expose its enabled visual state",
	)
	page.call("set_connection_state", 3, "规则已经随房间锁定。", "RULE42")
	context._check(
		matchup_toggle.disabled
		and matchup_toggle.button_pressed
		and matchup_toggle.get_draw_mode() == BaseButton.DRAW_DISABLED
		and rule_status_badge.text.contains("已开启")
		and rule_status_badge.text.contains("已锁定")
		and matchup_toggle.get_theme_color(&"icon_disabled_color").a
		< matchup_toggle.get_theme_color(&"icon_normal_color").a,
		"Network host locked matchup state must preserve its value without looking interactive",
	)
	page.call("set_connection_state", 0)
	if kind != "relay":
		matchup_toggle.set_pressed_no_signal(false)
		matchup_toggle.toggled.emit(false)
	for control_name in [
		"NetworkKindOption", "NetworkRoleOption", "NetworkAddressInput", "NetworkPortInput",
		"NetworkRoomInput", "NetworkDeckOption",
	]:
		var form_control := page.find_child(control_name, true, false) as Control
		context._check(
			form_control != null and not form_control.accessibility_name.is_empty(),
			"Network form control lacks an accessible name: %s" % control_name,
		)
	if kind == "relay":
		var role_option := page.get_node("%NetworkRoleOption") as OptionButton
		role_option.select(1)
		page.call("refresh_fields", 1)
		context._check(
			matchup_toggle.disabled
			and not matchup_toggle.button_pressed
			and rule_status_badge.text.contains("等待同步")
			and rule_status_badge.text.contains("只读"),
			"Network challenger must see a distinct read-only pending state without a stale host value",
		)
		page.call("show_locked_rules_options", {"apply_type_matchups": true})
		context._check(
			matchup_toggle.disabled
			and matchup_toggle.button_pressed
			and rule_status_badge.text.contains("已开启")
			and rule_status_badge.text.contains("房主锁定")
			and rule_status_badge.get_theme_color(&"font_color").is_equal_approx(
				DesignTokens.GREEN
			)
			and not matchup_toggle.get_theme_color(&"font_disabled_color").is_equal_approx(
				DesignTokens.GREEN
			),
			"Network challenger must see the host-locked enabled matchup state explicitly",
		)
		page.call("set_connection_state", 1)
		context._check(
			not matchup_toggle.button_pressed
			and rule_status_badge.text.contains("等待同步"),
			"Network challenger retry retained the previous room's locked matchup value",
		)
	page.call("set_connection_state", 5, "模拟连接错误")
	var connect_button := page.get_node("%NetworkConnectButton") as Button
	context._check(
		not connect_button.disabled and connect_button.text == "重新尝试",
		"%s: ERROR state must leave a visible retry action" % context._case_label("network", viewport_size),
	)
	page.call("set_connection_state", 0)
	context._check(
		not connect_button.disabled,
		"%s: returning to IDLE must unlock the network form" % context._case_label("network", viewport_size),
	)
	if viewport_size == Vector2i(1024, 768):
		await _check_network_compact_pointer_flow(page)
	await context._settle_layout()
	var label := context._case_label("network-%s" % kind, viewport_size)
	context._check_full_page(page, mounted.safe_host, label)
	context._check_named_inside(page, context._simulated_safe_rect(mounted.safe_host), [
		"Page", "TopBar", "Body", "FormPanel", "StatusPanel", "NetworkConnectButton",
	], label)
	context._check_named_non_overlapping(page, [
		"TopBar", "Steps", "Body", "StatusPanel", "NetworkConnectButton",
	], label)
	context._check_pointer_only_controls(page, label, context._simulated_safe_rect(mounted.safe_host))
	context._check_no_horizontal_scroll(page, label)
	context._unmount(mounted)
	await context._settle_layout(2)


func _check_network_compact_pointer_flow(page: Control) -> void:
	var step_bar := page.get_node("%CompactStepBar") as HBoxContainer
	var next_button := page.get_node("%CompactNextButton") as Button
	var kind_option := page.get_node("%NetworkKindOption") as OptionButton
	var role_option := page.get_node("%NetworkRoleOption") as OptionButton
	var address_input := page.get_node("%NetworkAddressInput") as LineEdit
	var deck_option := page.get_node("%NetworkDeckOption") as OptionButton
	var rule_row := page.get_node("%RuleRow") as HBoxContainer
	var matchup_toggle := page.get_node("%TypeMatchupToggle") as CheckButton
	var rule_status_badge := page.get_node("%RuleStatusBadge") as Label
	var copy_button := page.get_node("%CopyRoomButton") as Button
	context._check(
		step_bar.visible
		and kind_option.visible
		and role_option.visible
		and not rule_row.visible,
		"Network compact flow must start at network kind and identity",
	)
	next_button.pressed.emit()
	await context._settle_layout()
	context._check(
		address_input.is_visible_in_tree()
		and not rule_row.is_visible_in_tree()
		and address_input.focus_mode == Control.FOCUS_CLICK
		and page.get_viewport().gui_get_focus_owner() == null,
		"Network compact flow must expose click-only connection information",
	)
	next_button.pressed.emit()
	await context._settle_layout()
	context._check(
		deck_option.is_visible_in_tree()
		and rule_row.is_visible_in_tree()
		and deck_option.focus_mode == Control.FOCUS_NONE
		and page.get_viewport().gui_get_focus_owner() == null,
		"Network compact flow must expose pointer-only deck selection",
	)
	page.call("show_locked_rules_options", {"apply_type_matchups": true})
	page.call("set_connection_state", 3, "等待测试玩家", "ROOM42")
	await context._settle_layout()
	context._check(
		copy_button.is_visible_in_tree()
		and matchup_toggle.is_visible_in_tree()
		and matchup_toggle.disabled
		and matchup_toggle.button_pressed
		and matchup_toggle.get_global_rect().size.y >= context.MIN_TARGET_SIZE
		and rule_status_badge.text.contains("房主锁定")
		and copy_button.focus_mode == Control.FOCUS_NONE
		and page.get_viewport().gui_get_focus_owner() == null,
		"Network compact waiting state must expose its locked rule and pointer-only copy action",
	)
	page.call("set_connection_state", 0)
	await context._settle_layout()
	context._check(
		bool(page.call("handle_back")),
		"Network compact system back must return to the previous setup step",
	)
	await context._settle_layout()
	context._check(
		address_input.is_visible_in_tree()
		and page.get_viewport().gui_get_focus_owner() == null,
		"Network compact back did not restore the unfocused connection-information step",
	)


func _check_scrolling_panel(viewport_size: Vector2i, page_key: String) -> void:
	var mounted := await context._mount(context.PAGE_SCENES[page_key], viewport_size, true)
	var page := mounted.page as Control
	if page == null:
		context._unmount(mounted)
		return
	if page_key == "settings":
		page.call("configure")
		for control_name in [
			"MasterVolumeSlider", "MusicVolumeSlider", "SFXVolumeSlider",
			"MutedToggle", "ReducedMotionToggle", "AnimationModeOption",
			"QualityProfileOption", "CardCacheOption",
		]:
			var form_control := page.find_child(control_name, true, false) as Control
			context._check(
				form_control != null and not form_control.accessibility_name.is_empty(),
				"Settings form control lacks an accessible name: %s" % control_name,
			)
		if viewport_size == Vector2i(1600, 900):
			var before_reset := context._capture_settings()
			page.call("reset_form_to_defaults")
			context._check(
				context._capture_settings() == before_reset,
				"settings@1600x900: reset defaults must not mutate AppSettings before save",
			)
	else:
		page.call("configure")
		page.call("show_category", 3)
	await context._settle_layout()
	var label := context._case_label(page_key, viewport_size)
	var safe_rect: Rect2 = context._simulated_safe_rect(mounted.safe_host)
	context._check_horizontal_inside(page, safe_rect, label)
	context._check_pointer_only_controls(page, label)
	context._check_no_horizontal_scroll(page, label)
	var scroll := mounted.scroll as ScrollContainer
	context._check(scroll != null, "%s: scrolling host is missing" % label)
	if scroll:
		context._check(
			scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED,
			"%s: modal body must disable horizontal scrolling" % label,
		)
		context._check(
			context._not_horizontally_scrollable(scroll),
			"%s: modal body exposes a horizontal scrollbar" % label,
		)
	var section_names := (
		["AudioSection", "MotionSection", "PerformanceSection"]
		if page_key == "settings"
		else ["Intro", "CategoryBar", "ContentPanel"]
	)
	context._check_named_non_overlapping(page, section_names, label)
	context._unmount(mounted)
	await context._settle_layout(2)


func _check_deck_detail(viewport_size: Vector2i, catalog: CardCatalog) -> void:
	var mounted := await context._mount(context.PAGE_SCENES.deck_detail, viewport_size, true)
	var page := mounted.page as Control
	if page == null:
		context._unmount(mounted)
		return
	page.call("configure", catalog, "fire")
	await context._settle_layout(4)
	var label := context._case_label("deck-detail", viewport_size)
	var safe_rect: Rect2 = context._simulated_safe_rect(mounted.safe_host)
	context._check_horizontal_inside(page, safe_rect, label)
	context._check_pointer_only_controls(page, label)
	context._check_no_horizontal_scroll(page, label)
	var core_grid := page.get_node("%CoreGrid") as GridContainer
	context._check(core_grid.get_child_count() > 0, "%s: core card grid is empty" % label)
	for wrapper in core_grid.get_children():
		context._check(
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
		context._check(
			absf(aspect - 94.0 / 132.0) <= 0.04,
			"%s: core card aspect ratio is distorted (%s)" % [label, frame.size],
		)
		var image := frame.get_child(0) as TextureRect if frame.get_child_count() == 1 else null
		context._check(
			image != null
			and image.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED,
			"%s: core card artwork must preserve its full aspect" % label,
		)
	context._unmount(mounted)
	await context._settle_layout(2)


func _check_victory(viewport_size: Vector2i) -> void:
	var mounted := await context._mount(context.PAGE_SCENES.victory, viewport_size)
	var page := mounted.page as Control
	if page == null:
		context._unmount(mounted)
		return
	page.call("configure", 0, 12, "玩家 1", "svi-hrot", {
		"mode": "challenge",
		"winner_deck_name": "烈焰核心测试牌组",
	})
	await context._settle_layout()
	var label := context._case_label("victory", viewport_size)
	context._check_full_page(page, mounted.safe_host, label)
	context._check_named_inside(page, context._simulated_safe_rect(mounted.safe_host), [
		"SafeContent", "VictoryPanel", "ResultGrid", "CardStage", "MatchPanel",
		"RematchButton", "TitleButton",
	], label)
	context._check_named_non_overlapping(page, ["CardStage", "MatchPanel"], label)
	context._check_named_non_overlapping(page, ["RematchButton", "TitleButton"], label)
	context._check_pointer_only_controls(page, label, context._simulated_safe_rect(mounted.safe_host))
	context._check_no_horizontal_scroll(page, label)
	page.call("configure", -1, 12, "", "", {
		"mode": "challenge",
		"result_status": GameState.RESULT_DRAW,
	})
	await context._settle_layout()
	context._check(
		(page.get_node("%WinnerLabel") as Label).text == "本局平局"
		and (page.get_node("%ResultSubtitle") as Label).text.begins_with("DRAW")
		and (page.get_node("%CardNameLabel") as Label).text.contains("无胜者"),
		"Victory screen did not render DRAW as a distinct result without a winner",
	)
	context._unmount(mounted)
	await context._settle_layout(2)
