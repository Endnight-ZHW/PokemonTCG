extends RefCounted

var harness: Variant


func configure(preview_harness: Variant) -> void:
	harness = preview_harness


func run(ui: Control) -> void:
	if not harness._capture("title.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1280, 720)
	await harness._settle_frontend(3)
	if not harness._capture("title-1280x720.png"):
		harness._finish(1)
		return
	var title_ai_button := ui.find_child("AIButton", true, false) as Button
	if title_ai_button != null:
		var hover_position := title_ai_button.get_global_rect().get_center()
		Input.warp_mouse(hover_position)
		var hover_event := InputEventMouseMotion.new()
		hover_event.position = hover_position
		hover_event.global_position = hover_position
		Input.parse_input_event(hover_event)
	await harness._settle_frontend(2)
	if not harness._capture("title-hover.png"):
		harness._finish(1)
		return
	Input.warp_mouse(Vector2(4, 4))
	var reset_hover_event := InputEventMouseMotion.new()
	reset_hover_event.position = Vector2(4, 4)
	reset_hover_event.global_position = Vector2(4, 4)
	Input.parse_input_event(reset_hover_event)
	var title_page := ui.find_child("TitlePage", true, false)
	var showcase_rng: Variant = (
		title_page.get("_showcase_rng")
		if title_page != null
		else null
	)
	if showcase_rng != null and showcase_rng.has_method("set_state"):
		showcase_rng.call("set_state", 5)
	if title_page != null:
		for slot in range(3):
			title_page.call("_rotate_showcase_card", slot)
	await harness._settle_frontend(2)
	if not harness._capture("title-rotated.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1600, 900)
	ui.shell_view.show_title()
	await harness._settle_frontend(2)
	harness._set_preview_quality("low")
	await harness._settle_frontend(3)
	if not harness._capture("title-low-reduced.png"):
		harness._finish(1)
		return
	harness._set_preview_quality("high")
	await harness._settle_frontend(3)
	ui._show_help()
	await harness._settle_frontend()
	if not harness._capture("help.png"):
		harness._finish(1)
		return
	var help_turn_category := ui.modal_body.find_child(
		"TurnCategory", true, false
	) as Button
	var help_mouse_pressed: bool = await harness._begin_mouse_press(help_turn_category)
	if not help_mouse_pressed:
		push_error("Help Category did not enter a real mouse-pressed draw state")
		harness._finish(1)
		return
	if not harness._capture("help-category-mouse-pressed.png"):
		harness._finish(1)
		return
	await harness._cancel_mouse_press(help_turn_category)
	var help_board_category := ui.modal_body.find_child(
		"BoardCategory", true, false
	) as Button
	var help_touch_pressed: bool = await harness._begin_touch_press(help_board_category)
	if not help_touch_pressed:
		push_error("Help Category did not enter a real touch-pressed draw state")
		harness._finish(1)
		return
	if not harness._capture("help-category-touch-pressed.png"):
		harness._finish(1)
		return
	await harness._cancel_touch_press()
	if (
		not harness._captures_differ("help.png", "help-category-mouse-pressed.png")
		or not harness._captures_differ("help.png", "help-category-touch-pressed.png")
	):
		push_error("Help Category pressed fixtures are visually identical to normal")
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._settle_frontend(2)

	ui.shell_view.show_network_setup("lan")
	await harness._settle_frontend()
	Input.warp_mouse(Vector2(4, 4))
	var network_reset_hover := InputEventMouseMotion.new()
	network_reset_hover.position = Vector2(4, 4)
	network_reset_hover.global_position = Vector2(4, 4)
	Input.parse_input_event(network_reset_hover)
	await harness._settle_frontend(2)
	if not harness._assert_network_first_screen(ui.current_network_page, "LAN idle"):
		harness._finish(1)
		return
	if not harness._capture("network-lan.png"):
		harness._finish(1)
		return
	var network_rule_toggle := (
		ui.current_network_page.matchup_toggle as CheckButton
	)
	await harness._move_pointer_to_control(network_rule_toggle)
	await RenderingServer.frame_post_draw
	if network_rule_toggle.get_draw_mode() != BaseButton.DRAW_HOVER:
		push_error("Network rule toggle did not enter a real hover draw state")
		harness._finish(1)
		return
	if not harness._capture("network-rule-hover.png"):
		harness._finish(1)
		return
	var network_rule_pressed: bool = await harness._begin_mouse_press(network_rule_toggle)
	if not network_rule_pressed:
		push_error("Network rule toggle did not enter a real pressed draw state")
		harness._finish(1)
		return
	if not harness._capture("network-rule-pressed.png"):
		harness._finish(1)
		return
	await harness._cancel_mouse_press(network_rule_toggle)
	await harness._click_control(network_rule_toggle)
	await harness._settle_frontend(2)
	await RenderingServer.frame_post_draw
	var enabled_hover_style := (
		network_rule_toggle.get_theme_stylebox(&"hover_pressed") as StyleBoxFlat
	)
	if (
		not network_rule_toggle.button_pressed
		or network_rule_toggle.get_draw_mode() != BaseButton.DRAW_HOVER_PRESSED
		or enabled_hover_style == null
		or enabled_hover_style.get_border_width(SIDE_LEFT) < 2
		or enabled_hover_style.border_color.a < 0.9
	):
		push_error(
			"Network rule toggle did not resolve its visible hover_pressed state after pointer input"
		)
		harness._finish(1)
		return
	if not harness._capture("network-rule-enabled-hover.png"):
		harness._finish(1)
		return
	Input.warp_mouse(Vector2(4, 4))
	var network_enabled_leave := InputEventMouseMotion.new()
	network_enabled_leave.position = Vector2(4, 4)
	network_enabled_leave.global_position = Vector2(4, 4)
	Input.parse_input_event(network_enabled_leave)
	await harness._settle_frontend(2)
	await RenderingServer.frame_post_draw
	if network_rule_toggle.get_draw_mode() != BaseButton.DRAW_PRESSED:
		push_error("Network rule toggle did not return to its non-hover enabled draw state")
		harness._finish(1)
		return
	if not harness._capture("network-rule-enabled.png"):
		harness._finish(1)
		return
	ui.current_network_page.set_connection_state(
		NetworkLobbyPage.ConnectionState.WAITING,
		"规则已经随房间锁定。",
		"RULE42",
	)
	await harness._settle_frontend(5)
	if (
		not harness._assert_network_first_screen(ui.current_network_page, "LAN locked")
		or not network_rule_toggle.disabled
		or not network_rule_toggle.button_pressed
	):
		push_error("Network rule locked fixture lost its enabled value or remained interactive")
		harness._finish(1)
		return
	if not harness._capture("network-rule-locked.png"):
		harness._finish(1)
		return
	if (
		not harness._captures_differ("network-lan.png", "network-rule-hover.png")
		or not harness._captures_differ("network-rule-hover.png", "network-rule-pressed.png")
		or not harness._captures_differ("network-rule-pressed.png", "network-rule-enabled-hover.png")
		or not harness._captures_differ("network-rule-enabled-hover.png", "network-rule-enabled.png")
		or not harness._captures_differ("network-rule-enabled.png", "network-rule-locked.png")
	):
		push_error("Network rule toggle fixtures do not distinguish all pointer and lock states")
		harness._finish(1)
		return
	Input.warp_mouse(Vector2(4, 4))
	await harness._settle_frontend(2)

	ui.shell_view.show_network_setup("relay")
	await harness._settle_frontend()
	if not harness._assert_network_first_screen(ui.current_network_page, "Relay idle"):
		harness._finish(1)
		return
	if not harness._capture("network.png"):
		harness._finish(1)
		return
	ui.current_network_page.set_connection_state(
		NetworkLobbyPage.ConnectionState.WAITING,
		"房间已创建，等待挑战者加入。",
		"ROOM42",
	)
	await harness._settle_frontend()
	if not harness._assert_network_first_screen(ui.current_network_page, "Relay waiting"):
		harness._finish(1)
		return
	if not harness._capture("network-waiting.png"):
		harness._finish(1)
		return
	ui.current_network_page.set_connection_state(
		NetworkLobbyPage.ConnectionState.ERROR,
		"连接中断：无法联系 Relay 服务，请检查网络地址后重新尝试。",
	)
	await harness._settle_frontend()
	if not harness._assert_network_first_screen(ui.current_network_page, "Relay error"):
		harness._finish(1)
		return
	if not harness._capture("network-error.png"):
		harness._finish(1)
		return

	ui.shell_view.show_title()
	ui._show_settings()
	await harness._settle_frontend()
	if not harness._capture("settings.png"):
		harness._finish(1)
		return
	var settings_reset := ui.modal_body.find_child(
		"ResetDefaultsButton", true, false
	) as Button
	var settings_touch_pressed: bool = await harness._begin_touch_press(settings_reset)
	if not settings_touch_pressed:
		push_error("Settings Ghost action did not enter a real touch-pressed state")
		harness._finish(1)
		return
	if not harness._capture("settings-ghost-touch-pressed.png"):
		harness._finish(1)
		return
	await harness._cancel_touch_press()
	if not harness._captures_differ("settings.png", "settings-ghost-touch-pressed.png"):
		push_error("Settings Ghost touch fixture is visually identical to normal")
		harness._finish(1)
		return
	ui.modal_scroll.scroll_vertical = int(ui.modal_scroll.get_v_scroll_bar().max_value)
	await harness._settle_frontend()
	if not harness._capture("settings-bottom.png"):
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._settle_frontend(2)

	ui.shell_view.show_deck_select()
	await harness._settle_frontend()
	if not harness._capture("decks.png"):
		harness._finish(1)
		return
	var deck_page := (
		ui.screen_host.get_child(0) as DeckSelectPage
		if ui.screen_host != null and ui.screen_host.get_child_count() > 0
		else null
	)
	var deck_matchup_toggle := (
		deck_page.get_node("%TypeMatchupToggle") as CheckButton
		if deck_page != null
		else null
	)
	if deck_matchup_toggle == null:
		push_error("Deck matchup toggle preview fixture is unavailable")
		harness._finish(1)
		return
	await harness._click_control(deck_matchup_toggle)
	await harness._settle_frontend(2)
	await RenderingServer.frame_post_draw
	var deck_enabled_hover_style := (
		deck_matchup_toggle.get_theme_stylebox(&"hover_pressed") as StyleBoxFlat
	)
	if (
		not deck_matchup_toggle.button_pressed
		or deck_matchup_toggle.theme_type_variation != &"FrontRuleToggle"
		or deck_matchup_toggle.get_draw_mode() != BaseButton.DRAW_HOVER_PRESSED
		or deck_enabled_hover_style == null
		or deck_enabled_hover_style.get_border_width(SIDE_LEFT) < 2
		or deck_enabled_hover_style.border_color.a < 0.9
	):
		push_error("Deck matchup toggle did not render its bordered enabled-hover state")
		harness._finish(1)
		return
	if not harness._capture("decks-matchup-enabled-hover.png"):
		harness._finish(1)
		return
	Input.warp_mouse(Vector2(4, 4))
	var deck_toggle_leave := InputEventMouseMotion.new()
	deck_toggle_leave.position = Vector2(4, 4)
	deck_toggle_leave.global_position = Vector2(4, 4)
	Input.parse_input_event(deck_toggle_leave)
	await harness._settle_frontend(2)
	await RenderingServer.frame_post_draw
	if deck_matchup_toggle.get_draw_mode() != BaseButton.DRAW_PRESSED:
		push_error("Deck matchup toggle did not retain its bordered enabled state after hover")
		harness._finish(1)
		return
	if not harness._capture("decks-matchup-enabled.png"):
		harness._finish(1)
		return
	if not harness._captures_differ(
		"decks-matchup-enabled-hover.png",
		"decks-matchup-enabled.png",
	):
		push_error("Deck matchup enabled-hover fixture is visually identical to enabled")
		harness._finish(1)
		return
	deck_matchup_toggle.set_pressed_no_signal(false)
	deck_matchup_toggle.toggled.emit(false)
	ui._show_deck_details("fire")
	await harness._settle_frontend()
	if not harness._capture("deck-detail.png"):
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._settle_frontend(2)

	harness.tree.root.size = Vector2i(1024, 768)
	await harness._settle_frontend(3)
	ui.shell_view.show_title()
	await harness._settle_frontend()
	if not harness._capture("title-compact.png"):
		harness._finish(1)
		return
	var previous_content_scale_size: Vector2i = harness.tree.root.content_scale_size
	var previous_window_min_size: Vector2i = harness.tree.root.min_size
	harness.tree.root.min_size = Vector2i.ZERO
	harness.tree.root.size = Vector2i(640, 360)
	await harness._settle_frontend(3)
	ui.shell_view.show_title()
	await harness._settle_frontend()
	if not harness._capture("title-minimum.png"):
		harness._finish(1)
		return
	harness.tree.root.content_scale_size = Vector2i(720, 1280)
	harness.tree.root.size = Vector2i(720, 1280)
	await harness._settle_frontend(3)
	ui.shell_view.show_title()
	await harness._settle_frontend()
	if not harness._capture("title-portrait.png"):
		harness._finish(1)
		return
	harness.tree.root.content_scale_size = previous_content_scale_size
	harness.tree.root.min_size = previous_window_min_size
	harness.tree.root.size = Vector2i(1024, 768)
	await harness._settle_frontend(3)
	ui.shell_view.show_deck_select("challenge")
	await harness._settle_frontend()
	if not harness._capture("decks-compact.png"):
		harness._finish(1)
		return
	ui.shell_view.show_network_setup("relay")
	ui.current_network_page.role_option.select(1)
	ui.current_network_page.refresh_fields(1)
	await harness._settle_frontend()
	if not harness._assert_physical_touch_targets([
		ui.current_network_page.back_button,
		ui.current_network_page.compact_next_button,
		ui.current_network_page.kind_option,
		ui.current_network_page.role_option,
	], "network compact"):
		harness._finish(1)
		return
	if not harness._capture("network-compact.png"):
		harness._finish(1)
		return
	ui.current_network_page.call("_set_compact_step", 2)
	ui.current_network_page.show_locked_rules_options({"apply_type_matchups": true})
	await harness._settle_frontend(3)
	var compact_rule_toggle := ui.current_network_page.matchup_toggle as CheckButton
	if (
		not compact_rule_toggle.is_visible_in_tree()
		or not compact_rule_toggle.disabled
		or not compact_rule_toggle.button_pressed
		or not harness._assert_physical_touch_targets(
			[compact_rule_toggle], "network compact locked rule"
		)
	):
		push_error("Network compact rule step does not expose a legible locked toggle")
		harness._finish(1)
		return
	if not harness._capture("network-compact-rule-locked.png"):
		harness._finish(1)
		return
	ui.shell_view.show_title()
	ui._show_settings()
	await harness._settle_frontend()
	if not harness._assert_physical_touch_targets([
		ui.modal_confirm,
		ui.modal_cancel,
		ui.modal_body.find_child("ResetDefaultsButton", true, false),
	], "settings compact"):
		harness._finish(1)
		return
	if not harness._capture("settings-compact.png"):
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._settle_frontend(2)
	ui._show_help()
	await harness._settle_frontend()
	if not harness._assert_physical_touch_targets([
		ui.modal_confirm,
		ui.modal_body.find_child("QuickStartCategory", true, false),
		ui.modal_body.find_child("TurnCategory", true, false),
		ui.modal_body.find_child("BoardCategory", true, false),
		ui.modal_body.find_child("NetworkCategory", true, false),
	], "help compact"):
		harness._finish(1)
		return
	if not harness._capture("help-compact.png"):
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._settle_frontend(2)
	ui.shell_view.show_deck_select("challenge")
	ui._show_deck_details("fire")
	await harness._settle_frontend()
	if not harness._capture("deck-detail-compact.png"):
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._settle_frontend(2)
	harness.tree.root.size = Vector2i(1600, 900)
	await harness._settle_frontend(3)
	ui.shell_view.show_title()
	ui.shell_view.show_loading("正在准备牌桌与卡图…")
	await harness._settle_frontend()
	if not harness._capture("loading.png"):
		harness._finish(1)
		return
	ui.shell_view.hide_loading()
	ui.shell_view.show_toast("牌组已就绪，可以开始对战。")
	await harness._settle_frontend()
	if not harness._capture("toast.png"):
		harness._finish(1)
		return
	# The toast baseline is intentionally captured above. Hide it before battle
	# baselines so it cannot cover the turn/phase/task header in reduced motion.
	ui.toast_label.visible = false
