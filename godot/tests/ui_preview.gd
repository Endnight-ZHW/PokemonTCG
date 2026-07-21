extends SceneTree

const OUTPUT_ROOT := "res://../build/ui-preview"

var _settings_node: Node
var _settings_snapshot: Dictionary = {}
var _finished := false


func _initialize() -> void:
	root.size = Vector2i(1600, 900)
	call_deferred("_render_previews")


func _render_previews() -> void:
	# The project uses a 1280×720 desktop override. Re-apply the requested
	# capture size after the initial window setup so every baseline is emitted
	# at the same physical resolution.
	root.size = Vector2i(1600, 900)
	await _settle_frontend(2)
	if not _enable_deterministic_preview_mode():
		push_error("AppSettings autoload is unavailable")
		_finish(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_ROOT))
	var packed := load("res://scenes/main/main.tscn") as PackedScene
	if packed == null:
		push_error("Unable to load main UI scene")
		_finish(1)
		return
	var ui := packed.instantiate()
	root.add_child(ui)
	ui.initialize_ui()
	Input.warp_mouse(Vector2(4, 4))
	# Give fonts, card textures and the procedural gradient one extra upload pass
	# before the first GPU readback. Later captures reuse these resources.
	await _settle_frontend(8)
	if not _capture("title.png"):
		_finish(1)
		return
	root.size = Vector2i(1280, 720)
	await _settle_frontend(3)
	if not _capture("title-1280x720.png"):
		_finish(1)
		return
	var title_ai_button := ui.find_child("AIButton", true, false) as Button
	if title_ai_button != null:
		var hover_position := title_ai_button.get_global_rect().get_center()
		Input.warp_mouse(hover_position)
		var hover_event := InputEventMouseMotion.new()
		hover_event.position = hover_position
		hover_event.global_position = hover_position
		Input.parse_input_event(hover_event)
	await _settle_frontend(2)
	if not _capture("title-hover.png"):
		_finish(1)
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
	await _settle_frontend(2)
	if not _capture("title-rotated.png"):
		_finish(1)
		return
	root.size = Vector2i(1600, 900)
	ui.show_title()
	await _settle_frontend(2)
	_set_preview_quality("low")
	await _settle_frontend(3)
	if not _capture("title-low-reduced.png"):
		_finish(1)
		return
	_set_preview_quality("high")
	await _settle_frontend(3)
	ui._show_help()
	await _settle_frontend()
	if not _capture("help.png"):
		_finish(1)
		return
	var help_turn_category := ui.modal_body.find_child(
		"TurnCategory", true, false
	) as Button
	var help_mouse_pressed := await _begin_mouse_press(help_turn_category)
	if not help_mouse_pressed:
		push_error("Help Category did not enter a real mouse-pressed draw state")
		_finish(1)
		return
	if not _capture("help-category-mouse-pressed.png"):
		_finish(1)
		return
	await _cancel_mouse_press(help_turn_category)
	var help_board_category := ui.modal_body.find_child(
		"BoardCategory", true, false
	) as Button
	var help_touch_pressed := await _begin_touch_press(help_board_category)
	if not help_touch_pressed:
		push_error("Help Category did not enter a real touch-pressed draw state")
		_finish(1)
		return
	if not _capture("help-category-touch-pressed.png"):
		_finish(1)
		return
	await _cancel_touch_press()
	if (
		not _captures_differ("help.png", "help-category-mouse-pressed.png")
		or not _captures_differ("help.png", "help-category-touch-pressed.png")
	):
		push_error("Help Category pressed fixtures are visually identical to normal")
		_finish(1)
		return
	ui._close_modal()
	await _settle_frontend(2)

	ui.show_network_setup("lan")
	await _settle_frontend()
	Input.warp_mouse(Vector2(4, 4))
	var network_reset_hover := InputEventMouseMotion.new()
	network_reset_hover.position = Vector2(4, 4)
	network_reset_hover.global_position = Vector2(4, 4)
	Input.parse_input_event(network_reset_hover)
	await _settle_frontend(2)
	if not _assert_network_first_screen(ui.current_network_page, "LAN idle"):
		_finish(1)
		return
	if not _capture("network-lan.png"):
		_finish(1)
		return
	var network_rule_toggle := (
		ui.current_network_page.matchup_toggle as CheckButton
	)
	await _move_pointer_to_control(network_rule_toggle)
	await RenderingServer.frame_post_draw
	if network_rule_toggle.get_draw_mode() != BaseButton.DRAW_HOVER:
		push_error("Network rule toggle did not enter a real hover draw state")
		_finish(1)
		return
	if not _capture("network-rule-hover.png"):
		_finish(1)
		return
	var network_rule_pressed := await _begin_mouse_press(network_rule_toggle)
	if not network_rule_pressed:
		push_error("Network rule toggle did not enter a real pressed draw state")
		_finish(1)
		return
	if not _capture("network-rule-pressed.png"):
		_finish(1)
		return
	await _cancel_mouse_press(network_rule_toggle)
	await _click_control(network_rule_toggle)
	await _settle_frontend(2)
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
		_finish(1)
		return
	if not _capture("network-rule-enabled-hover.png"):
		_finish(1)
		return
	Input.warp_mouse(Vector2(4, 4))
	var network_enabled_leave := InputEventMouseMotion.new()
	network_enabled_leave.position = Vector2(4, 4)
	network_enabled_leave.global_position = Vector2(4, 4)
	Input.parse_input_event(network_enabled_leave)
	await _settle_frontend(2)
	await RenderingServer.frame_post_draw
	if network_rule_toggle.get_draw_mode() != BaseButton.DRAW_PRESSED:
		push_error("Network rule toggle did not return to its non-hover enabled draw state")
		_finish(1)
		return
	if not _capture("network-rule-enabled.png"):
		_finish(1)
		return
	ui.current_network_page.set_connection_state(
		NetworkLobbyPage.ConnectionState.WAITING,
		"规则已经随房间锁定。",
		"RULE42",
	)
	await _settle_frontend(5)
	if (
		not _assert_network_first_screen(ui.current_network_page, "LAN locked")
		or not network_rule_toggle.disabled
		or not network_rule_toggle.button_pressed
	):
		push_error("Network rule locked fixture lost its enabled value or remained interactive")
		_finish(1)
		return
	if not _capture("network-rule-locked.png"):
		_finish(1)
		return
	if (
		not _captures_differ("network-lan.png", "network-rule-hover.png")
		or not _captures_differ("network-rule-hover.png", "network-rule-pressed.png")
		or not _captures_differ("network-rule-pressed.png", "network-rule-enabled-hover.png")
		or not _captures_differ("network-rule-enabled-hover.png", "network-rule-enabled.png")
		or not _captures_differ("network-rule-enabled.png", "network-rule-locked.png")
	):
		push_error("Network rule toggle fixtures do not distinguish all pointer and lock states")
		_finish(1)
		return
	Input.warp_mouse(Vector2(4, 4))
	await _settle_frontend(2)

	ui.show_network_setup("relay")
	await _settle_frontend()
	if not _assert_network_first_screen(ui.current_network_page, "Relay idle"):
		_finish(1)
		return
	if not _capture("network.png"):
		_finish(1)
		return
	ui.current_network_page.set_connection_state(
		NetworkLobbyPage.ConnectionState.WAITING,
		"房间已创建，等待挑战者加入。",
		"ROOM42",
	)
	await _settle_frontend()
	if not _assert_network_first_screen(ui.current_network_page, "Relay waiting"):
		_finish(1)
		return
	if not _capture("network-waiting.png"):
		_finish(1)
		return
	ui.current_network_page.set_connection_state(
		NetworkLobbyPage.ConnectionState.ERROR,
		"连接中断：无法联系 Relay 服务，请检查网络地址后重新尝试。",
	)
	await _settle_frontend()
	if not _assert_network_first_screen(ui.current_network_page, "Relay error"):
		_finish(1)
		return
	if not _capture("network-error.png"):
		_finish(1)
		return

	ui.show_title()
	ui.show_settings()
	await _settle_frontend()
	if not _capture("settings.png"):
		_finish(1)
		return
	var settings_reset := ui.modal_body.find_child(
		"ResetDefaultsButton", true, false
	) as Button
	var settings_touch_pressed := await _begin_touch_press(settings_reset)
	if not settings_touch_pressed:
		push_error("Settings Ghost action did not enter a real touch-pressed state")
		_finish(1)
		return
	if not _capture("settings-ghost-touch-pressed.png"):
		_finish(1)
		return
	await _cancel_touch_press()
	if not _captures_differ("settings.png", "settings-ghost-touch-pressed.png"):
		push_error("Settings Ghost touch fixture is visually identical to normal")
		_finish(1)
		return
	ui.modal_scroll.scroll_vertical = int(ui.modal_scroll.get_v_scroll_bar().max_value)
	await _settle_frontend()
	if not _capture("settings-bottom.png"):
		_finish(1)
		return
	ui._close_modal()
	await _settle_frontend(2)

	ui.show_deck_select()
	await _settle_frontend()
	if not _capture("decks.png"):
		_finish(1)
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
		_finish(1)
		return
	await _click_control(deck_matchup_toggle)
	await _settle_frontend(2)
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
		_finish(1)
		return
	if not _capture("decks-matchup-enabled-hover.png"):
		_finish(1)
		return
	Input.warp_mouse(Vector2(4, 4))
	var deck_toggle_leave := InputEventMouseMotion.new()
	deck_toggle_leave.position = Vector2(4, 4)
	deck_toggle_leave.global_position = Vector2(4, 4)
	Input.parse_input_event(deck_toggle_leave)
	await _settle_frontend(2)
	await RenderingServer.frame_post_draw
	if deck_matchup_toggle.get_draw_mode() != BaseButton.DRAW_PRESSED:
		push_error("Deck matchup toggle did not retain its bordered enabled state after hover")
		_finish(1)
		return
	if not _capture("decks-matchup-enabled.png"):
		_finish(1)
		return
	if not _captures_differ(
		"decks-matchup-enabled-hover.png",
		"decks-matchup-enabled.png",
	):
		push_error("Deck matchup enabled-hover fixture is visually identical to enabled")
		_finish(1)
		return
	deck_matchup_toggle.set_pressed_no_signal(false)
	deck_matchup_toggle.toggled.emit(false)
	ui._show_deck_details("fire")
	await _settle_frontend()
	if not _capture("deck-detail.png"):
		_finish(1)
		return
	ui._close_modal()
	await _settle_frontend(2)

	root.size = Vector2i(1024, 768)
	await _settle_frontend(3)
	ui.show_title()
	await _settle_frontend()
	if not _capture("title-compact.png"):
		_finish(1)
		return
	var previous_content_scale_size := root.content_scale_size
	root.content_scale_size = Vector2i(720, 1280)
	root.size = Vector2i(720, 1280)
	await _settle_frontend(3)
	ui.show_title()
	await _settle_frontend()
	if not _capture("title-portrait.png"):
		_finish(1)
		return
	root.content_scale_size = previous_content_scale_size
	root.size = Vector2i(1024, 768)
	await _settle_frontend(3)
	ui.show_deck_select("challenge")
	await _settle_frontend()
	if not _capture("decks-compact.png"):
		_finish(1)
		return
	ui.show_network_setup("relay")
	ui.current_network_page.role_option.select(1)
	ui.current_network_page.refresh_fields(1)
	await _settle_frontend()
	if not _assert_physical_touch_targets([
		ui.current_network_page.back_button,
		ui.current_network_page.compact_next_button,
		ui.current_network_page.kind_option,
		ui.current_network_page.role_option,
	], "network compact"):
		_finish(1)
		return
	if not _capture("network-compact.png"):
		_finish(1)
		return
	ui.current_network_page.call("_set_compact_step", 2)
	ui.current_network_page.show_locked_rules_options({"apply_type_matchups": true})
	await _settle_frontend(3)
	var compact_rule_toggle := ui.current_network_page.matchup_toggle as CheckButton
	if (
		not compact_rule_toggle.is_visible_in_tree()
		or not compact_rule_toggle.disabled
		or not compact_rule_toggle.button_pressed
		or not _assert_physical_touch_targets(
			[compact_rule_toggle], "network compact locked rule"
		)
	):
		push_error("Network compact rule step does not expose a legible locked toggle")
		_finish(1)
		return
	if not _capture("network-compact-rule-locked.png"):
		_finish(1)
		return
	ui.show_title()
	ui.show_settings()
	await _settle_frontend()
	if not _assert_physical_touch_targets([
		ui.modal_confirm,
		ui.modal_cancel,
		ui.modal_body.find_child("ResetDefaultsButton", true, false),
	], "settings compact"):
		_finish(1)
		return
	if not _capture("settings-compact.png"):
		_finish(1)
		return
	ui._close_modal()
	await _settle_frontend(2)
	ui._show_help()
	await _settle_frontend()
	if not _assert_physical_touch_targets([
		ui.modal_confirm,
		ui.modal_body.find_child("QuickStartCategory", true, false),
		ui.modal_body.find_child("TurnCategory", true, false),
		ui.modal_body.find_child("BoardCategory", true, false),
		ui.modal_body.find_child("NetworkCategory", true, false),
	], "help compact"):
		_finish(1)
		return
	if not _capture("help-compact.png"):
		_finish(1)
		return
	ui._close_modal()
	await _settle_frontend(2)
	ui.show_deck_select("challenge")
	ui._show_deck_details("fire")
	await _settle_frontend()
	if not _capture("deck-detail-compact.png"):
		_finish(1)
		return
	ui._close_modal()
	await _settle_frontend(2)
	root.size = Vector2i(1600, 900)
	await _settle_frontend(3)
	ui.show_title()
	ui._show_loading("正在准备牌桌与卡图…")
	await _settle_frontend()
	if not _capture("loading.png"):
		_finish(1)
		return
	ui._hide_loading()
	ui._show_toast("牌组已就绪，可以开始对战。")
	await _settle_frontend()
	if not _capture("toast.png"):
		_finish(1)
		return
	# The toast baseline is intentionally captured above. Hide it before battle
	# baselines so it cannot cover the turn/phase/task header in reduced motion.
	ui.toast_label.visible = false

	if not ui.start_local_match_for_test("fire", "water"):
		push_error("Unable to start preview match")
		_finish(1)
		return
	await process_frame
	await create_timer(0.25).timeout
	if not _capture("privacy.png"):
		_finish(1)
		return

	ui._close_modal()
	await _wait_until_hidden(ui.modal_layer)
	var empty_demo := UIPreviewStateFactory.setup_state()
	for empty_player in empty_demo.players:
		empty_player.active = null
		for bench_index in range(empty_player.bench.size()):
			empty_player.bench[bench_index] = null
	_update_battle_preview(ui, empty_demo, [])
	await _settle_rendered(4)
	if not _capture("battle-empty.png"):
		_finish(1)
		return

	var setup_demo := UIPreviewStateFactory.setup_state()
	_update_battle_preview(
		ui,
		setup_demo,
		UIPreviewStateFactory.setup_action_rows(setup_demo),
		"hand:0",
	)
	await _settle_rendered(4)
	if not _capture("game.png"):
		_finish(1)
		return
	if not _capture("battle-setup.png"):
		_finish(1)
		return
	root.size = Vector2i(1280, 720)
	await _settle_rendered(3)
	if not _capture("battle-setup-1280x720.png"):
		_finish(1)
		return
	root.size = Vector2i(2000, 900)
	await _settle_rendered(3)
	if not _capture("game-20x9.png"):
		_finish(1)
		return
	root.size = Vector2i(1600, 900)
	await process_frame

	var demo := GameState.new()
	demo.phase = "MAIN"
	demo.turn_number = 4
	demo.first_player_idx = 1
	demo.active_player_idx = 0
	demo.stadium_card_id = "sv1-171"
	demo.players[0].name = "玩家 1"
	demo.players[1].name = "玩家 2"
	demo.public_deck_keys = ["fire", "water"]
	demo.players[0].active = PokemonState.new("svi-hrot")
	demo.players[0].active.placed_this_turn = false
	demo.players[0].active.energy_card_ids.assign([
		"sv1-ener-2", "sv1-ener-2", "svi-mirc", "svg2-lume",
	])
	demo.players[0].active.damage_counters = 2
	demo.players[0].active.attached_tool_id = "sv1-202"
	demo.players[0].active.status_conditions.assign(["BURNED"])
	demo.players[0].bench[0] = PokemonState.new("svi-chim")
	demo.players[0].bench[0].energy_card_ids.assign(["sv1-ener-2"])
	demo.players[0].bench[1] = PokemonState.new("svi-ente")
	demo.players[1].active = PokemonState.new("sv2-keldeo")
	demo.players[1].active.placed_this_turn = false
	demo.players[1].active.damage_counters = 4
	demo.players[1].active.energy_card_ids.assign(["sv1-ener-3"])
	demo.players[1].active.status_conditions.assign(["POISONED"])
	demo.players[1].bench[0] = PokemonState.new("sv2-starm")
	demo.players[0].hand = [
		"sv1-ener-2", "sv1-189", "svf-potion", "sv1-151", "svi-jete",
	]
	for index in range(43):
		demo.players[0].deck.append([
			"sv1-ener-2", "svi-chim", "sv1-189", "svf-potion",
		][index % 4])
	for _index in range(43):
		demo.players[1].deck.append("")
	demo.players[0].discard = ["sv1-180"]
	demo.players[1].discard = ["sv1-176"]
	demo.players[0].prizes = ["sv1-ener-2", "sv1-151", "sv1-189", "svf-potion"]
	demo.players[1].prizes = ["", "", "", "", "", ""]
	demo.players[1].hand = ["", "", "", "", "", ""]
	demo.log_action("玩家1附着了火能量。")
	demo.log_action("玩家2的宝可梦受到40点伤害。")
	demo.log_action("玩家1将喷火龙ex放置到active。")
	demo.log_action("玩家2将小火焰猴放置到bench_0。")
	ui.state = demo
	ui.current_view_player = 0
	ui._build_game_screen()
	_update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await _settle_rendered(4)
	if not _capture("battle-populated.png"):
		_finish(1)
		return
	if not _capture("battle-main.png"):
		_finish(1)
		return
	root.size = Vector2i(1280, 720)
	await _settle_rendered(4)
	if not _capture("battle-main-1280x720.png"):
		_finish(1)
		return
	root.size = Vector2i(2000, 900)
	await _settle_rendered(4)
	if not _capture("battle-main-20x9.png"):
		_finish(1)
		return
	root.size = Vector2i(900, 540)
	await _settle_rendered(4)
	if not _capture("battle-main-compact.png"):
		_finish(1)
		return
	root.size = Vector2i(1600, 900)
	await _settle_rendered(4)
	var energy_count_demo := demo.clone_state()
	energy_count_demo.players[0].active.energy_card_ids.clear()
	energy_count_demo.players[0].bench[0].energy_card_ids.clear()
	for _energy_index in range(12):
		energy_count_demo.players[0].active.energy_card_ids.append("sv1-ener-2")
	for _energy_index in range(10):
		energy_count_demo.players[0].bench[0].energy_card_ids.append("sv1-ener-2")
	_update_battle_preview(
		ui,
		energy_count_demo,
		UIPreviewStateFactory.action_rows(energy_count_demo),
	)
	await _settle_rendered(4)
	if (
		not _energy_count_badge_is_readable(
			ui.battle_screen.table.get_slot_view(0, "active"), "12"
		)
		or not _energy_count_badge_is_readable(
			ui.battle_screen.table.get_slot_view(0, "bench_0"), "10"
		)
	):
		push_error("Standard battle energy count badges are unreadable or clipped")
		_finish(1)
		return
	if not _capture("battle-energy-counts.png"):
		_finish(1)
		return
	root.size = Vector2i(900, 540)
	await _settle_rendered(4)
	if (
		not _energy_count_badge_is_readable(
			ui.battle_screen.table.get_slot_view(0, "active"), "12"
		)
		or not _energy_count_badge_is_readable(
			ui.battle_screen.table.get_slot_view(0, "bench_0"), "10"
		)
	):
		push_error("Compact battle energy count badges are unreadable or clipped")
		_finish(1)
		return
	if not _capture("battle-energy-counts-compact.png"):
		_finish(1)
		return
	root.size = Vector2i(1600, 900)
	_update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await _settle_rendered(4)
	var full_bench_demo := demo.clone_state()
	var bench_cards := [
		"svi-chim", "svi-ente", "sv2-starm", "sv2-keldeo", "svi-hrot",
	]
	for player_index in range(2):
		for bench_index in range(5):
			full_bench_demo.players[player_index].bench[bench_index] = PokemonState.new(
				str(bench_cards[(bench_index + player_index) % bench_cards.size()])
			)
	_update_battle_preview(
		ui,
		full_bench_demo,
		UIPreviewStateFactory.action_rows(full_bench_demo),
	)
	await _settle_rendered(4)
	if not _capture("battle-full-bench.png"):
		_finish(1)
		return

	var discard_stack_demo := demo.clone_state()
	discard_stack_demo.players[0].discard.clear()
	discard_stack_demo.players[1].discard.clear()
	for discard_index in range(30):
		discard_stack_demo.players[0].discard.append(
			"sv1-180" if discard_index % 2 == 0 else "sv1-176"
		)
		discard_stack_demo.players[1].discard.append(
			"sv1-176" if discard_index % 2 == 0 else "sv1-180"
		)
	_update_battle_preview(ui, discard_stack_demo, [])
	await _settle_rendered(4)
	if not _capture("battle-discard-stack-30.png"):
		_finish(1)
		return

	var three_prize_demo := demo.clone_state()
	three_prize_demo.players[0].prizes = [
		"sv1-ener-2", "sv1-151", "sv1-189",
	]
	three_prize_demo.players[1].prizes = ["", "", ""]
	_update_battle_preview(
		ui,
		three_prize_demo,
		UIPreviewStateFactory.action_rows(three_prize_demo),
		"pokemon:0:active",
	)
	ui.battle_screen.show_card_detail(
		three_prize_demo.players[0].active.card_id,
		three_prize_demo.players[0].active,
	)
	await _settle_rendered(4)
	if not _capture("battle-prizes-3.png"):
		_finish(1)
		return
	ui.battle_screen.hide_card_detail()
	_update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await _settle_rendered(3)
	# Two adjacent Energy cards are both actionable here. This baseline guards
	# the parent-card Z ordering: a lower card's cyan outline must disappear
	# behind the next card instead of drawing across its face.
	var overlapping_highlight_demo := demo.clone_state()
	overlapping_highlight_demo.players[0].hand = [
		"sv1-ener-2", "sv1-ener-2", "sv1-189", "svf-potion", "sv1-151",
		"svi-jete", "sv1-189", "svf-potion", "sv1-151",
	]
	_update_battle_preview(
		ui,
		overlapping_highlight_demo,
		UIPreviewStateFactory.action_rows(overlapping_highlight_demo),
	)
	await _settle_rendered(4)
	if not _capture("battle-overlapping-highlights.png"):
		_finish(1)
		return
	# Dense-hand hover must keep the canonical left-to-right card stack. Drive a
	# real pointer into the exposed edge of a middle card so these baselines cover
	# GUI picking, CardView hover feedback, and the neighboring card's occlusion.
	var dense_hover_demo := demo.clone_state()
	dense_hover_demo.players[0].hand = [
		"sv1-104",
		"sv1-106",
		"sv1-108",
		"sv2-delib",
		"sv1-151",
		"svf-potion",
		"sv1-189",
		"svi-jete",
		"svi-dtur",
		"svi-hrot",
		"sv1-ener-1",
		"sv1-ener-2",
		"sv1-ener-3",
		"sv1-ener-4",
		"sv1-ener-5",
	]
	# start_local_match_for_test intentionally enters pass-and-play privacy mode.
	# Reveal only this fixture's local hand, just as completing the handoff does.
	ui.battle_screen.set_local_hand_privacy_hidden(false)
	_update_battle_preview(
		ui,
		dense_hover_demo,
		UIPreviewStateFactory.action_rows(dense_hover_demo),
	)
	await _settle_rendered(4)
	var dense_hover_index := 7
	var dense_hover_view := (
		ui.battle_screen.hand_views[dense_hover_index] as CardView
	)
	var dense_hover_routed := await _move_pointer_to_hand_card_exposed_edge(
		dense_hover_view,
	)
	if not dense_hover_routed or not dense_hover_view._hovered:
		push_error(_dense_hand_hover_failure_message(
			"Dense-hand preview did not produce a real middle-card hover",
			dense_hover_view,
		))
		_finish(1)
		return
	var dense_hover_right := (
		ui.battle_screen.hand_views[dense_hover_index + 1] as CardView
	)
	if not _preview_card_draws_above(dense_hover_right, dense_hover_view):
		push_error("Dense-hand hover raised the middle card above its right neighbor")
		_finish(1)
		return
	await _settle_rendered(3)
	if not _capture("battle-dense-hand-hover-1600x900.png"):
		_finish(1)
		return

	await _move_pointer_to_position(Vector2(4.0, 4.0))
	root.size = Vector2i(900, 540)
	await _settle_rendered(4)
	dense_hover_view = ui.battle_screen.hand_views[dense_hover_index] as CardView
	dense_hover_routed = await _move_pointer_to_hand_card_exposed_edge(
		dense_hover_view,
	)
	if not dense_hover_routed or not dense_hover_view._hovered:
		push_error(_dense_hand_hover_failure_message(
			"Compact dense-hand preview did not produce a real middle-card hover",
			dense_hover_view,
		))
		_finish(1)
		return
	dense_hover_right = (
		ui.battle_screen.hand_views[dense_hover_index + 1] as CardView
	)
	if not _preview_card_draws_above(dense_hover_right, dense_hover_view):
		push_error(
			"Compact dense-hand hover raised the middle card above its right neighbor"
		)
		_finish(1)
		return
	await _settle_rendered(3)
	if not _capture("battle-dense-hand-hover-900x540.png"):
		_finish(1)
		return
	await _move_pointer_to_position(Vector2(4.0, 4.0))
	ui.battle_screen.set_local_hand_privacy_hidden(true)
	root.size = Vector2i(1600, 900)
	await _settle_rendered(4)
	_update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await _settle_rendered(3)
	ui._show_toast("能量已附着。")
	await _settle_rendered(4)
	if not _capture("battle-toast.png"):
		_finish(1)
		return
	ui.toast_label.visible = false
	var ai_demo := demo.clone_state()
	ai_demo.active_player_idx = 1
	ai_demo.players[1].name = "Challenge AI"
	_update_battle_preview(ui, ai_demo, [], "", true, "challenge")
	await _settle_rendered(4)
	if not _capture("ai-thinking.png"):
		_finish(1)
		return
	if not _capture("battle-ai.png"):
		_finish(1)
		return
	_update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await _settle_frontend(3)
	_update_battle_preview(
		ui,
		demo,
		UIPreviewStateFactory.action_rows(demo),
		"hand:1",
	)
	ui.battle_screen.show_card_detail(str(demo.players[0].hand[1]))
	await _settle_rendered(4)
	if not _capture("card-actions.png"):
		_finish(1)
		return
	if not _capture("battle-card-preview.png"):
		_finish(1)
		return
	root.size = Vector2i(1280, 720)
	await _settle_rendered(4)
	if not _capture("battle-card-preview-1280x720.png"):
		_finish(1)
		return
	root.size = Vector2i(900, 540)
	await _settle_rendered(4)
	var compact_detail := ui.battle_screen.detail_panel as BattleDetailPanel
	if (
		compact_detail == null
		or not compact_detail.is_compact_layout()
		or not compact_detail.scale.is_equal_approx(Vector2.ONE)
		or not compact_detail.size.is_equal_approx(
			BattleDetailPanel.COMPACT_PANEL_SIZE
		)
		or not _physical_control_rect(compact_detail).size.is_equal_approx(
			BattleDetailPanel.COMPACT_PANEL_SIZE
		)
		or not _assert_physical_touch_targets(
			[compact_detail.close_button],
			"battle detail compact",
		)
	):
		push_error(
			"Compact battle detail did not use an unscaled 560x240 bottom surface"
		)
		_finish(1)
		return
	if not _capture("battle-card-preview-compact.png"):
		_finish(1)
		return
	root.size = Vector2i(1600, 900)
	await _settle_rendered(4)
	_update_battle_preview(
		ui,
		demo,
		UIPreviewStateFactory.action_rows(demo),
		"pokemon:1:active",
	)
	ui.battle_screen.show_card_detail(
		demo.players[1].active.card_id,
		demo.players[1].active,
	)
	await _settle_rendered(4)
	if not _capture("battle-card-preview-opponent.png"):
		_finish(1)
		return
	ui.battle_screen.hide_card_detail()
	_update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	var preview_hud := ui.battle_screen.hud as BattlePhaseHud
	if preview_hud == null:
		push_error("Battle preview HUD is unavailable")
		_finish(1)
		return
	preview_hud.set_log_drawer_open(true)
	await _settle_rendered(4)
	if not _capture("battle-log-open.png"):
		_finish(1)
		return
	preview_hud.close_log_drawer()
	await _settle_rendered(3)
	if not _capture("battle-log-closed.png"):
		_finish(1)
		return
	_update_battle_preview(
		ui,
		demo,
		UIPreviewStateFactory.action_rows(demo),
		"pokemon:0:active",
	)
	ui.battle_screen.show_card_detail(
		demo.players[0].active.card_id,
		demo.players[0].active,
	)
	await _settle_rendered(4)
	if not _capture("battle-attack-actions.png"):
		_finish(1)
		return
	var preview_source_card := ui.battle_screen.own_active as CardView
	await _move_pointer_to_control(preview_source_card)
	var hovered_card_control := root.gui_get_hovered_control()
	if (
		hovered_card_control == null
		or (
			hovered_card_control != preview_source_card
			and not preview_source_card.is_ancestor_of(hovered_card_control)
		)
	):
		push_error("Battle card became unreachable through transparent layout surfaces")
		_finish(1)
		return
	var preview_action_button := ui.battle_screen.table.action_popover.action_buttons.get_child(
		0
	) as Button
	await _move_pointer_to_control(preview_action_button)
	var hovered_action_control := root.gui_get_hovered_control()
	if (
		hovered_action_control == null
		or (
			hovered_action_control != preview_action_button
			and not preview_action_button.is_ancestor_of(hovered_action_control)
		)
	):
		push_error("Card action button became unreachable through its transparent root")
		_finish(1)
		return
	# Reproduce the reported state exactly: a card action popover and detail panel
	# are visible, then the player clicks the system menu. Use routed pointer input
	# instead of emitting Button.pressed so z-order and full-screen blockers are
	# covered by this visual smoke test.
	ui.battle_screen.input_blocker.visible = true
	await _click_control(ui.battle_screen.header.menu_button)
	await _settle_rendered(3)
	if not ui.modal_layer.visible or ui.modal_title.text != "对局菜单":
		push_error("Battle menu click was intercepted by a table overlay")
		_finish(1)
		return
	if not _capture("battle-menu-open.png"):
		_finish(1)
		return
	var danger_mouse_pressed := await _begin_mouse_press(ui.modal_cancel)
	if not danger_mouse_pressed:
		push_error("Battle Danger action did not enter a real pressed draw state")
		_finish(1)
		return
	if not _capture("battle-menu-danger-pressed.png"):
		_finish(1)
		return
	await _cancel_mouse_press(ui.modal_cancel)
	if (
		not ui.modal_layer.visible
		or not _captures_differ(
			"battle-menu-open.png", "battle-menu-danger-pressed.png"
		)
	):
		push_error("Battle Danger pressed fixture did not remain visible and distinct")
		_finish(1)
		return
	ui._close_modal()
	await _wait_until_hidden(ui.modal_layer)
	ui.battle_screen.input_blocker.visible = false

	var promotion_demo := UIPreviewStateFactory.promotion_state()
	_update_battle_preview(
		ui,
		promotion_demo,
		UIPreviewStateFactory.promotion_action_rows(promotion_demo),
		"pokemon:0:bench_0",
	)
	await _settle_rendered(4)
	if not _capture("battle-promotion.png"):
		_finish(1)
		return
	_update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await _settle_frontend(3)
	ui._show_card_inspector({
		"card_id": "svi-hrot",
		"pokemon": demo.players[0].active,
		"location": "玩家 1 战斗区",
	})
	await process_frame
	await create_timer(0.2).timeout
	if not _capture("card-inspector.png"):
		_finish(1)
		return
	ui._close_modal()
	await _wait_until_hidden(ui.modal_layer)
	ui._show_zone_inspector({
		"title": "弃牌",
		"player": 0,
		"zone": "discard",
		"card_ids": ["sv1-180", "sv1-189", "svf-potion"],
		"count": 3,
		"hidden": false,
	})
	await process_frame
	await create_timer(0.2).timeout
	if not _capture("zone-inspector.png"):
		_finish(1)
		return
	ui._close_modal()
	await _wait_until_hidden(ui.modal_layer)
	await _settle_frontend(2)
	_update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await _settle_frontend(3)

	ui.battle_screen.play_presentation([{
		"event_type": "cards_drawn",
		"actor": 0,
		"visibility": "owner",
		"source": {"player": 0, "zone": "deck"},
		"target": {"player": 0, "zone": "hand"},
		"amount": 3,
		"data": {
			"player": 0,
			"count": 3,
			"card_ids": ["sv1-ener-2", "sv1-151", "svf-potion"],
		},
	}], demo.revision + 10, 0)
	await create_timer(0.24).timeout
	if not _capture("draw.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	ui.battle_screen.play_presentation([{
		"event_type": "cards_discarded",
		"actor": 0,
		"source": {"player": 0, "zone": "hand"},
		"target": {"player": 0, "zone": "discard"},
		"amount": 3,
		"data": {
			"player": 0,
			"count": 3,
			"card_ids": ["sv1-ener-2", "sv1-189", "svf-potion"],
		},
	}], demo.revision + 11, 0)
	await create_timer(0.26).timeout
	if not _capture("discard.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	_set_preview_motion("standard", "high")
	await _settle_rendered(2)
	ui.battle_screen.play_presentation([{
		"event_type": "deck_shuffled",
		"actor": 0,
		"source": {"player": 0, "zone": "deck"},
		"target": {"player": 0, "zone": "deck"},
		"data": {"player": 0},
	}], demo.revision + 111, 0)
	await create_timer(0.24).timeout
	if not _capture("shuffle-high.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	_set_preview_motion("standard", "low")
	await _settle_rendered(2)
	ui.battle_screen.play_presentation([{
		"event_type": "deck_shuffled",
		"actor": 0,
		"source": {"player": 0, "zone": "deck"},
		"target": {"player": 0, "zone": "deck"},
		"data": {"player": 0},
	}], demo.revision + 112, 0)
	await create_timer(0.24).timeout
	if not _capture("shuffle-low.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	_set_preview_motion("reduced", "high")
	await _settle_rendered(2)
	ui.battle_screen.play_presentation([{
		"event_type": "deck_shuffled",
		"actor": 0,
		"source": {"player": 0, "zone": "deck"},
		"target": {"player": 0, "zone": "deck"},
		"data": {"player": 0},
	}], demo.revision + 113, 0)
	await create_timer(0.08).timeout
	if not _capture("shuffle-reduced.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	_set_preview_motion("standard", "high")
	await _settle_rendered(2)
	var reveal_preview_event := {
		"event_type": "cards_revealed",
		"actor": 0,
		"visibility": "public",
		"source": {"player": 0, "zone": "deck"},
		"target": {"player": 0, "zone": "deck"},
		"data": {
			"player": 0,
			"purpose": "mill_then_damage",
			"cards": [
				{
					"card_id": "sv1-ener-2",
					"matched": true,
					"destination": {"player": 0, "zone": "discard"},
				},
				{
					"card_id": "sv1-151",
					"matched": false,
					"destination": {"player": 0, "zone": "deck"},
				},
				{
					"card_id": "sv1-ener-5",
					"matched": true,
					"destination": {"player": 0, "zone": "discard"},
				},
				{
					"card_id": "svf-potion",
					"matched": false,
					"destination": {"player": 0, "zone": "deck"},
				},
				{
					"card_id": "svi-chim",
					"matched": false,
					"destination": {"player": 0, "zone": "deck"},
				},
			],
			"summary": {
				"kind": "energy_damage",
				"matched_count": 2,
				"amount": 160,
			},
		},
	}
	ui.battle_screen.play_presentation(
		[reveal_preview_event], demo.revision + 114, 0)
	await create_timer(0.82).timeout
	if not _capture("reveal-public.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	_set_preview_motion("reduced", "high")
	await _settle_rendered(2)
	ui.battle_screen.play_presentation(
		[reveal_preview_event], demo.revision + 115, 0)
	await create_timer(0.12).timeout
	if not _capture("reveal-public-reduced.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	_set_preview_motion("standard", "high")
	await _settle_rendered(2)
	var reveal_no_energy_event: Dictionary = reveal_preview_event.duplicate(true)
	reveal_no_energy_event["data"]["cards"] = [
		{
			"card_id": "sv1-151",
			"matched": false,
			"destination": {"player": 0, "zone": "deck"},
		},
		{
			"card_id": "svf-potion",
			"matched": false,
			"destination": {"player": 0, "zone": "deck"},
		},
		{
			"card_id": "svi-chim",
			"matched": false,
			"destination": {"player": 0, "zone": "deck"},
		},
	]
	reveal_no_energy_event["data"]["summary"] = {
		"kind": "energy_damage",
		"matched_count": 0,
		"amount": 0,
	}
	ui.battle_screen.play_presentation(
		[reveal_no_energy_event], demo.revision + 116, 0)
	await create_timer(0.82).timeout
	if not _capture("reveal-public-no-energy.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	await _settle_rendered(2)
	var reveal_all_energy_event: Dictionary = reveal_preview_event.duplicate(true)
	reveal_all_energy_event["data"]["cards"] = [
		{
			"card_id": "sv1-ener-1",
			"matched": true,
			"destination": {"player": 0, "zone": "discard"},
		},
		{
			"card_id": "sv1-ener-2",
			"matched": true,
			"destination": {"player": 0, "zone": "discard"},
		},
		{
			"card_id": "sv1-ener-3",
			"matched": true,
			"destination": {"player": 0, "zone": "discard"},
		},
		{
			"card_id": "sv1-ener-4",
			"matched": true,
			"destination": {"player": 0, "zone": "discard"},
		},
		{
			"card_id": "sv1-ener-5",
			"matched": true,
			"destination": {"player": 0, "zone": "discard"},
		},
	]
	reveal_all_energy_event["data"]["summary"] = {
		"kind": "energy_damage",
		"matched_count": 5,
		"amount": 400,
	}
	ui.battle_screen.play_presentation(
		[reveal_all_energy_event], demo.revision + 117, 0)
	await create_timer(0.82).timeout
	if not _capture("reveal-public-all-energy.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	await _settle_rendered(2)
	var single_coin_preview_event := {
		"event_type": "coin_flip",
		"actor": 0,
		"visibility": "public",
		"data": {
			"results": [true],
			"purpose": "setup_first_player",
			"first_player": 0,
		},
	}
	ui.battle_screen.play_presentation(
		[single_coin_preview_event], demo.revision + 118, 0)
	await create_timer(0.72).timeout
	if not _capture("coin-public-single.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	await _settle_rendered(2)
	var coin_preview_event := {
		"event_type": "coin_flip",
		"actor": 1,
		"visibility": "public",
		"data": {
			"results": [true, false, true, true, false, false, true, false],
		},
	}
	ui.battle_screen.play_presentation(
		[coin_preview_event], demo.revision + 119, 1)
	await create_timer(1.95).timeout
	if not _capture("coin-public-multi.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	_set_preview_motion("reduced", "high")
	await _settle_rendered(2)
	ui.battle_screen.play_presentation(
		[coin_preview_event], demo.revision + 120, 1)
	await create_timer(0.08).timeout
	if not _capture("coin-public-reduced.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	_set_preview_motion("standard", "high")
	await _settle_rendered(2)

	var energy_snapshot: Dictionary = ui.battle_screen.capture_presentation_snapshot()
	if not demo.players[0].hand.is_empty():
		demo.players[0].hand.remove_at(0)
	demo.players[0].active.energy_card_ids.append("sv1-ener-2")
	ui._refresh_game()
	await process_frame
	ui.battle_screen.play_presentation([{
		"event_type": "energy_attached",
		"actor": 0,
		"card_id": "sv1-ener-2",
		"source": {"player": 0, "zone": "hand", "index": 0},
		"target": {"player": 0, "slot": "active"},
		"data": {
			"player": 0,
			"slot": "active",
			"card_id": "sv1-ener-2",
			"source_zone": "hand",
			"source_index": 0,
		},
	}], demo.revision + 12, 0, energy_snapshot)
	await create_timer(0.24).timeout
	if not _capture("energy-attach.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	await _settle_rendered(2)

	# Capture the complete stack during a real switch. The outgoing active has
	# both an attached Tool and the energy added above, so any regression to
	# independent paper-card attachment flyers is visible and asserted here.
	var switch_snapshot: Dictionary = ui.battle_screen.capture_presentation_snapshot()
	var outgoing_active: PokemonState = demo.players[0].active
	var incoming_bench: PokemonState = demo.players[0].bench[0]
	if outgoing_active == null or incoming_bench == null:
		push_error("Switch preview fixture requires an active and bench Pokemon")
		_finish(1)
		return
	demo.players[0].active = incoming_bench
	demo.players[0].bench[0] = outgoing_active
	ui._refresh_game()
	await process_frame
	ui.battle_screen.play_presentation([{
		"event_type": "switched",
		"actor": 0,
		"source": {"player": 0, "slot": "active"},
		"target": {"player": 0, "slot": "bench_0"},
		"data": {"player": 0, "slot": "bench_0"},
	}], demo.revision + 121, 0, switch_snapshot)
	await create_timer(0.08).timeout
	var switch_movers: Array[Control] = []
	for flyer_value in ui.battle_screen.table._active_flyers:
		var flyer := flyer_value as Control
		if flyer != null and bool(flyer.get_meta("slot_composite_motion", false)):
			switch_movers.append(flyer)
	if switch_movers.size() != 2:
		push_error(
			"Switch preview expected two Pokemon composites, got %d"
			% switch_movers.size()
		)
		_finish(1)
		return
	for mover in switch_movers:
		if mover.get_node_or_null("PaperImage") != null:
			push_error("Switch preview regressed to a paper-card attachment flyer")
			_finish(1)
			return
	if not _capture("battle-switch-25.png"):
		_finish(1)
		return
	await create_timer(0.11).timeout
	if not _capture("battle-switch-50.png"):
		_finish(1)
		return
	await create_timer(0.11).timeout
	if not _capture("battle-switch-75.png"):
		_finish(1)
		return
	await create_timer(0.34).timeout
	ui.battle_screen.clear_presentation_for_resync()
	demo.players[0].active = outgoing_active
	demo.players[0].bench[0] = incoming_bench
	ui._refresh_game()
	await _settle_rendered(2)

	var evolution_card_id := "svi-infr"
	demo.players[0].hand.append(evolution_card_id)
	ui._refresh_game()
	await process_frame
	var evolve_snapshot: Dictionary = ui.battle_screen.capture_presentation_snapshot()
	var evolve_hand_index := demo.players[0].hand.size() - 1
	var old_active_card_id: String = demo.players[0].active.card_id
	demo.players[0].hand.remove_at(evolve_hand_index)
	demo.players[0].active.evolution_stack_ids.append(old_active_card_id)
	demo.players[0].active.card_id = evolution_card_id
	ui._refresh_game()
	await process_frame
	ui.battle_screen.play_presentation([{
		"event_type": "pokemon_evolved",
		"actor": 0,
		"card_id": evolution_card_id,
		"source": {"player": 0, "zone": "hand", "index": evolve_hand_index},
		"target": {"player": 0, "slot": "active"},
		"data": {
			"player": 0,
			"slot": "active",
			"card_id": evolution_card_id,
			"source_zone": "hand",
			"source_index": evolve_hand_index,
		},
	}], demo.revision + 13, 0, evolve_snapshot)
	await create_timer(0.34).timeout
	if not _capture("evolve.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	demo.players[0].active.card_id = old_active_card_id
	demo.players[0].active.evolution_stack_ids.erase(old_active_card_id)
	ui._refresh_game()
	await process_frame

	var choice := ChoiceRequest.new(
		"preview-choice",
		"search",
		0,
		"选择一张要加入手牌的卡牌",
		[
			{
				"option_id": "card:deck:0:sv1-104",
				"label": "墓仔狗",
				"ref": {
					"kind": "card",
					"player": 0,
					"zone": "deck",
					"index": 0,
					"card_id": "sv1-104",
				},
				"value": {"index": 0, "card_id": "sv1-104"},
			},
			{
				"option_id": "card:deck:1:sv1-151",
				"label": "高级球",
				"ref": {
					"kind": "card",
					"player": 0,
					"zone": "deck",
					"index": 1,
					"card_id": "sv1-151",
				},
				"value": {"index": 1, "card_id": "sv1-151"},
			},
			{
				"option_id": "card:deck:2:svf-potion",
				"label": "伤药",
				"ref": {
					"kind": "card",
					"player": 0,
					"zone": "deck",
					"index": 2,
					"card_id": "svf-potion",
				},
				"value": {"index": 2, "card_id": "svf-potion"},
			},
		],
		1,
		1,
	)
	ui.show_choice(choice)
	await process_frame
	await create_timer(0.25).timeout
	if ui.active_choice_panel == null or ui.active_choice_panel.card_option_count() != 3:
		push_error("Choice preview fixture did not render its card options")
		_finish(1)
		return
	if not _capture("choice.png"):
		_finish(1)
		return
	var first_choice_card := (
		ui.active_choice_panel._option_cards.get("card:deck:0:sv1-104") as CardView
		if ui.active_choice_panel
		else null
	)
	if first_choice_card:
		first_choice_card.activated.emit("sv1-104", -1, 0, "")
	await process_frame
	await create_timer(0.18).timeout
	if not _capture("choice-selected.png"):
		_finish(1)
		return
	var second_choice_card := (
		ui.active_choice_panel._option_cards.get("card:deck:1:sv1-151") as CardView
		if ui.active_choice_panel
		else null
	)
	if second_choice_card:
		second_choice_card.activated.emit("sv1-151", -1, 0, "")
	await process_frame
	await create_timer(0.18).timeout
	if not _capture("choice-switched.png"):
		_finish(1)
		return
	if (
		not _captures_differ("choice.png", "choice-selected.png")
		or not _captures_differ("choice-selected.png", "choice-switched.png")
	):
		push_error("Choice preview state captures are unexpectedly identical")
		_finish(1)
		return
	root.size = Vector2i(560, 720)
	await _settle_rendered(4)
	if not _capture("choice-compact-preview.png"):
		_finish(1)
		return
	root.size = Vector2i(1600, 900)
	await _settle_rendered(4)
	ui._close_modal()
	await _wait_until_hidden(ui.modal_layer)

	var multi_card_ids: Array[String] = [
		"sv1-104",
		"sv1-106",
		"sv1-108",
		"sv2-delib",
		"sv1-151",
		"svf-potion",
		"sv1-189",
		"svi-jete",
		"svi-dtur",
		"svi-hrot",
	]
	var multi_options: Array[Dictionary] = []
	for index in range(multi_card_ids.size()):
		var card_id := multi_card_ids[index]
		multi_options.append({
			"option_id": "card:deck:%d:%s" % [index, card_id],
			"label": ui.catalog.card_name(card_id),
			"ref": {
				"kind": "card",
				"player": 0,
				"zone": "deck",
				"index": index,
				"card_id": card_id,
			},
			"value": {"index": index, "card_id": card_id},
		})
	var multi_choice := ChoiceRequest.new(
		"preview-multi-choice",
		"search",
		0,
		"从这些卡牌中选择两至三张加入手牌。",
		multi_options,
		2,
		3,
	)
	ui.show_choice(multi_choice)
	ui._toggle_choice(str(multi_options[0]["option_id"]))
	ui._toggle_choice(str(multi_options[4]["option_id"]))
	ui._toggle_choice(str(multi_options[8]["option_id"]))
	await _settle_rendered(4)
	if not _capture("choice-multi-limit.png"):
		_finish(1)
		return
	root.size = Vector2i(1280, 720)
	await _settle_rendered(4)
	if not _capture("choice-multi-1280x720.png"):
		_finish(1)
		return
	root.size = Vector2i(1600, 900)
	await _settle_rendered(4)
	ui._close_modal()
	await _wait_until_hidden(ui.modal_layer)

	var confirm_revealed_choice := ChoiceRequest.new(
		"preview-confirm-revealed",
		"confirm",
		0,
		"要将查看到的卡牌加入手牌吗？",
		[
			{"option_id": "confirm:yes", "label": "是，加入手牌", "value": true},
			{"option_id": "confirm:no", "label": "否，放入弃牌", "value": false},
		],
		1,
		1,
		false,
		false,
		{
			"top_card_id": "svf-potion",
			"revealed_card_ids": ["svf-potion"],
		},
	)
	ui.show_choice(confirm_revealed_choice)
	ui._toggle_choice("confirm:no")
	await _settle_rendered(4)
	if not _capture("choice-confirm-revealed.png"):
		_finish(1)
		return
	ui._close_modal()
	await _wait_until_hidden(ui.modal_layer)

	var empty_choice := ChoiceRequest.new(
		"preview-empty-choice",
		"resolve_empty",
		0,
		"没有找到符合条件的卡牌。",
		[],
		0,
		0,
	)
	ui.show_choice(empty_choice)
	await _settle_rendered(4)
	if not _capture("choice-empty.png"):
		_finish(1)
		return
	ui._close_modal()
	await _wait_until_hidden(ui.modal_layer)

	var energy_choice := ChoiceRequest.new(
		"preview-energy-choice",
		"distribute_energy",
		0,
		"为每张能量选择附着目标。",
		[
			{
				"option_id": "pokemon:0:active:svi-hrot",
				"label": "加热洛托姆",
				"value": {"slot": "active", "card_id": "svi-hrot"},
			},
			{
				"option_id": "pokemon:0:bench_0:svi-chim",
				"label": "小火焰猴",
				"value": {"slot": "bench_0", "card_id": "svi-chim"},
			},
		],
		2,
		2,
		true,
		false,
		{
			"purpose": "energy_attach_distribution",
			"card_ids": ["svi-jete", "svi-dtur"],
			"source_player": 0,
			"source_zone": "hand",
			"max_per_target": 2,
			"same_target": true,
		},
	)
	ui.show_choice(energy_choice)
	await process_frame
	await create_timer(0.25).timeout
	if not ui.selected_choice_ids.is_empty():
		push_error("Energy distribution preview did not start at 0/2")
		_finish(1)
		return
	if not _capture("choice-energy.png"):
		_finish(1)
		return
	ui._toggle_choice("pokemon:0:active:svi-hrot")
	await _settle_rendered(4)
	if ui.selected_choice_ids.size() != 1:
		push_error("Energy distribution preview did not advance to 1/2")
		_finish(1)
		return
	if not _capture("choice-energy-progress.png"):
		_finish(1)
		return
	ui._toggle_choice("pokemon:0:active:svi-hrot")
	await _settle_rendered(4)
	if ui.selected_choice_ids.size() != 2:
		push_error("Energy distribution preview did not advance to 2/2")
		_finish(1)
		return
	if not _capture("choice-energy-complete.png"):
		_finish(1)
		return
	if (
		not _captures_differ("choice-energy.png", "choice-energy-progress.png")
		or not _captures_differ(
			"choice-energy-progress.png", "choice-energy-complete.png"
		)
	):
		push_error("Energy distribution preview states are unexpectedly identical")
		_finish(1)
		return
	ui._close_modal()
	await _wait_until_hidden(ui.modal_layer)
	demo.resolution_stack = {
		"frames": [], "pending_request": null, "sequence": 0, "context": {},
	}
	demo.players[0].active.energy_card_ids = ["sv1-ener-2", "sv1-ener-5"]
	ui._refresh_game()
	await _settle_rendered(2)
	var attachment_options: Array[Dictionary] = []
	for index in range(demo.players[0].active.energy_card_ids.size()):
		var energy_id: String = demo.players[0].active.energy_card_ids[index]
		var option_id := "attachment:0:active:energy:%d:%s" % [index, energy_id]
		var attachment_ref := EntityRef.new(
			"attachment", 0, "", "active", index, "energy", energy_id,
		).to_dict()
		attachment_options.append({
			"option_id": option_id,
			"label": "己方 战斗区 · %s" % ui.catalog.card_name(energy_id),
			"ref": attachment_ref,
			"value": attachment_ref.duplicate(true),
		})
	var attachment_choice := ChoiceRequest.new(
		"preview-attachment-choice",
		"select_attachment",
		0,
		"从己方战斗宝可梦选择至多两张能量。",
		attachment_options,
		0,
		2,
		true,
		false,
		{
			"purpose": "energy_relocate_attachments",
			"attachment_refs": attachment_options.map(
				func(option: Dictionary) -> Dictionary:
					return Dictionary(option["ref"]).duplicate(true)),
			"card_ids": demo.players[0].active.energy_card_ids.duplicate(),
			"source_player": 0,
			"source_slot": "active",
			"same_source": true,
		},
	)
	ui.show_choice(attachment_choice)
	ui.battle_screen.table._on_card_activated(
		demo.players[0].active.card_id, -1, 0, "active")
	await _settle_rendered(4)
	var attachment_source_card: CardView = (
		ui.battle_screen.table.get_slot_view(0, "active")
	)
	if (
		attachment_source_card == null
		or attachment_source_card.interaction_hint.visible
		or not attachment_source_card.target_glow.visible
	):
		push_error(
			"Attachment source preview did not keep the outline while hiding its inline hint"
		)
		_finish(1)
		return
	if not _capture("choice-attachment-source.png"):
		_finish(1)
		return
	ui._toggle_choice(str(attachment_options[1]["option_id"]))
	await _settle_rendered(3)
	if not _capture("choice-attachment-selected.png"):
		_finish(1)
		return
	ui.battle_screen.table.attachment_choice_popover.dismiss(false)
	root.size = Vector2i(900, 540)
	await _settle_rendered(3)
	ui.battle_screen.table._on_card_activated(
		demo.players[0].active.card_id, -1, 0, "active")
	await _settle_rendered(4)
	attachment_source_card = ui.battle_screen.table.get_slot_view(0, "active")
	if (
		attachment_source_card == null
		or attachment_source_card.interaction_hint.visible
		or not attachment_source_card.target_glow.visible
	):
		push_error("Compact attachment source preview restored the inline hint")
		_finish(1)
		return
	if not _capture("choice-attachment-compact.png"):
		_finish(1)
		return
	ui.battle_screen.clear_choice_targets()
	ui.active_request = null
	root.size = Vector2i(1600, 900)
	await _settle_rendered(3)

	ui.battle_screen.play_presentation([
		{
			"event_type": "attack_declared",
			"actor": 0,
			"card_id": "svi-hrot",
			"source": {"player": 0, "slot": "active"},
			"target": {"player": 1, "slot": "active"},
			"data": {"attack_name": "高温冲击"},
		},
		{
			"event_type": "damage_dealt",
			"actor": 0,
			"amount": 90,
			"target": {"player": 1, "slot": "active"},
			"data": {"player": 1, "slot": "active", "amount": 90},
		},
	], demo.revision, 0)
	await create_timer(0.18).timeout
	if not _capture("attack.png"):
		_finish(1)
		return
	await create_timer(0.72).timeout
	if not _capture("impact.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	ui.battle_screen.play_presentation([{
		"event_type": "pokemon_ko",
		"actor": 0,
		"card_id": "sv2-keldeo",
		"source": {"player": 1, "slot": "active"},
		"target": {"player": 1, "zone": "discard"},
		"data": {
			"player": 1,
			"slot": "active",
			"card_id": "sv2-keldeo",
			"defer_leave_play": true,
		},
	}], demo.revision + 1, 0)
	await create_timer(0.18).timeout
	if not _capture("ko.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	demo.winner = 0
	demo.phase = "GAME_OVER"
	ui._show_end_screen()
	await _settle_frontend()
	if not _capture("end.png"):
		_finish(1)
		return
	ui.queue_free()
	await process_frame

	var workbench_scene := load("res://tools/ui_workbench.tscn") as PackedScene
	var workbench := workbench_scene.instantiate()
	root.add_child(workbench)
	workbench.call_deferred("show_preview", "title")
	await process_frame
	await create_timer(0.2).timeout
	if not _capture("workbench.png"):
		_finish(1)
		return
	print("UI_PREVIEWS_OK")
	_finish(0)


func _settle_frontend(frame_count: int = 3) -> void:
	# Explicit frame waits make container layout deterministic even when the
	# renderer is faster than the former timer-based preview cadence.
	for _frame in range(maxi(frame_count, 2)):
		await process_frame


func _click_control(control: Control) -> void:
	if control == null:
		return
	await _move_pointer_to_control(control)
	var pointer_position := _physical_control_rect(control).get_center()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pointer_position
	press.global_position = pointer_position
	Input.parse_input_event(press)
	await process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = pointer_position
	release.global_position = pointer_position
	Input.parse_input_event(release)
	await process_frame


func _move_pointer_to_control(control: Control) -> void:
	if control == null:
		return
	var pointer_position := _physical_control_rect(control).get_center()
	Input.warp_mouse(pointer_position)
	var motion := InputEventMouseMotion.new()
	motion.position = pointer_position
	motion.global_position = pointer_position
	Input.parse_input_event(motion)
	await process_frame


func _begin_mouse_press(control: Control) -> bool:
	if control == null:
		return false
	await _move_pointer_to_control(control)
	var pointer_position := _physical_control_rect(control).get_center()
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = pointer_position
	press.global_position = pointer_position
	Input.parse_input_event(press)
	await process_frame
	await RenderingServer.frame_post_draw
	return _is_pressed_draw_mode(control)


func _cancel_mouse_press(guard_button: BaseButton = null) -> void:
	var restore_disabled := false
	if guard_button != null:
		restore_disabled = guard_button.disabled
		guard_button.disabled = true
	var release_position := Vector2(4.0, 4.0)
	Input.warp_mouse(release_position)
	var motion := InputEventMouseMotion.new()
	motion.position = release_position
	motion.global_position = release_position
	Input.parse_input_event(motion)
	await process_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = release_position
	release.global_position = release_position
	Input.parse_input_event(release)
	await process_frame
	if guard_button != null and is_instance_valid(guard_button):
		guard_button.disabled = restore_disabled


func _begin_touch_press(control: Control, touch_index := 0) -> bool:
	if control == null:
		return false
	await _move_pointer_to_control(control)
	var pointer_position := _physical_control_rect(control).get_center()
	var touch := InputEventScreenTouch.new()
	touch.index = touch_index
	touch.pressed = true
	touch.position = pointer_position
	Input.parse_input_event(touch)
	# Synthetic ScreenTouch events do not pass through the platform's mouse-from-
	# touch translator on desktop. Feed the companion mouse event Godot emits on
	# Android as well; the preceding ScreenTouch keeps this distinct from the
	# ordinary mouse-only fixture above.
	var emulated_press := InputEventMouseButton.new()
	emulated_press.button_index = MOUSE_BUTTON_LEFT
	emulated_press.pressed = true
	emulated_press.position = pointer_position
	emulated_press.global_position = pointer_position
	Input.parse_input_event(emulated_press)
	await process_frame
	await RenderingServer.frame_post_draw
	return _is_pressed_draw_mode(control)


func _cancel_touch_press(touch_index := 0) -> void:
	var release_position := Vector2(4.0, 4.0)
	var release := InputEventScreenTouch.new()
	release.index = touch_index
	release.pressed = false
	release.position = release_position
	Input.parse_input_event(release)
	var emulated_release := InputEventMouseButton.new()
	emulated_release.button_index = MOUSE_BUTTON_LEFT
	emulated_release.pressed = false
	emulated_release.position = release_position
	emulated_release.global_position = release_position
	Input.parse_input_event(emulated_release)
	await process_frame


func _is_pressed_draw_mode(control: Control) -> bool:
	if not control is BaseButton:
		return false
	return (control as BaseButton).get_draw_mode() in [
		BaseButton.DRAW_PRESSED,
		BaseButton.DRAW_HOVER_PRESSED,
	]


func _physical_control_rect(control: Control) -> Rect2:
	if control == null:
		return Rect2()
	var logical_rect := control.get_global_rect()
	var final_transform := root.get_final_transform()
	var physical_start := final_transform * logical_rect.position
	var physical_end := final_transform * logical_rect.end
	return Rect2(physical_start, physical_end - physical_start).abs()


func _assert_physical_touch_targets(controls: Array, label: String) -> bool:
	var viewport_rect := Rect2(Vector2.ZERO, Vector2(root.size))
	for value in controls:
		var control := value as Control
		if control == null or not control.is_visible_in_tree():
			push_error("%s is missing a visible touch target" % label)
			return false
		var rect := _physical_control_rect(control)
		if rect.size.x < 48.0 or rect.size.y < 48.0:
			push_error("%s target %s is below physical 48x48: %s" % [
				label,
				control.get_path(),
				rect,
			])
			return false
		if not viewport_rect.encloses(rect):
			push_error("%s target %s escapes the physical viewport: %s / %s" % [
				label,
				control.get_path(),
				rect,
				viewport_rect,
			])
			return false
	return true


func _move_pointer_to_hand_card_exposed_edge(card: CardView) -> bool:
	if card == null:
		return false
	# The right half of a dense fan card is intentionally covered by its next
	# sibling. Probe a small deterministic grid inside the exposed leading strip,
	# using the same logical rectangle as GUI input. Every probe is routed as a real
	# mouse motion and accepted only when Viewport GUI picking names this card.
	for x_fraction in [0.08, 0.16, 0.24, 0.32, 0.40]:
		for y_fraction in [0.50, 0.36, 0.64, 0.22, 0.78]:
			# InputEvent positions use the same logical GUI coordinates reported by
			# get_global_rect(). A Canvas/global transform includes Window stretch and
			# maps this point a second time after a 900×540 resize.
			var card_rect := card.get_global_rect()
			var pointer_position := card_rect.position + Vector2(
				card_rect.size.x * float(x_fraction),
				card_rect.size.y * float(y_fraction),
			)
			await _move_pointer_to_position(pointer_position)
			if _pointer_is_over_card(card):
				return true
	return false


func _move_pointer_to_position(pointer_position: Vector2) -> void:
	# Parsed input uses physical Window coordinates. Map logical Control points
	# through the final transform; compact UI normally resolves to a 1:1 transform,
	# while large/ultrawide captures can still scale the design canvas upward.
	var window_position := root.get_final_transform() * pointer_position
	Input.warp_mouse(window_position)
	var motion := InputEventMouseMotion.new()
	motion.position = window_position
	motion.global_position = window_position
	Input.parse_input_event(motion)
	await process_frame
	await process_frame


func _pointer_is_over_card(card: CardView) -> bool:
	if card == null:
		return false
	var hovered_control := root.gui_get_hovered_control()
	return (
		hovered_control != null
		and (
			hovered_control == card
			or card.is_ancestor_of(hovered_control)
		)
	)


func _dense_hand_hover_failure_message(prefix: String, card: CardView) -> String:
	var hovered_control := root.gui_get_hovered_control()
	return "%s: target=%s rect=%s pointer=%s hovered=%s" % [
		prefix,
		str(card.get_path()) if card != null else "<null>",
		str(card.get_global_rect()) if card != null else "<null>",
		str(root.get_mouse_position()),
		(
			str(hovered_control.get_path())
			if hovered_control != null
			else "<null>"
		),
	]


func _preview_card_draws_above(upper: CardView, lower: CardView) -> bool:
	if upper == null or lower == null:
		return false
	return (
		upper.z_index > lower.z_index
		or (
			upper.z_index == lower.z_index
			and upper.get_index() > lower.get_index()
		)
	)


func _wait_until_hidden(control: Control, maximum_frames := 45) -> void:
	if control == null:
		return
	for _frame in range(maximum_frames):
		if not control.visible:
			return
		await process_frame


func _energy_count_badge_is_readable(card: CardView, expected: String) -> bool:
	if card == null:
		return false
	var badge := card.find_child("EnergyBadge", true, false) as Control
	var count_badge := (
		badge.find_child("CountBadge", true, false) as Control
		if badge != null
		else null
	)
	if count_badge == null:
		return false
	return (
		str(count_badge.get_meta("count_text", "")) == expected
		and int(count_badge.get_meta("font_size", 0)) >= 9
		and count_badge.size.x > count_badge.size.y
		and Rect2(Vector2.ZERO, badge.size).encloses(
			Rect2(count_badge.position, count_badge.size)
		)
	)


func _settle_rendered(frame_count := 3) -> void:
	for _frame in range(maxi(frame_count, 2)):
		await process_frame
		await RenderingServer.frame_post_draw


func _update_battle_preview(
	ui,
	preview_state: GameState,
	action_rows: Array[Dictionary],
	selected_source := "",
	ai_is_thinking := false,
	mode := "local",
) -> void:
	# Battle baselines exercise BattleScreen itself; no shell modal is part of
	# these states. Force a completed close so a previous inspector cannot leave
	# its 86% shade in a later capture on a very fast renderer.
	if ui.modal_layer:
		ui.modal_layer.visible = false
	ui.state = preview_state
	ui.current_view_player = 0
	ui.selected_entity_key = selected_source
	ui.ai_thinking = ai_is_thinking
	ui.game_mode = mode
	if ui.battle_screen:
		ui.battle_screen.update_view(
			preview_state,
			0,
			action_rows,
			selected_source,
			ai_is_thinking,
			mode,
		)


func _enable_deterministic_preview_mode() -> bool:
	_settings_node = root.get_node_or_null("AppSettings")
	if _settings_node == null:
		return false
	_settings_snapshot = {
		"master_volume": _settings_node.get("master_volume"),
		"music_volume": _settings_node.get("music_volume"),
		"sfx_volume": _settings_node.get("sfx_volume"),
		"muted": _settings_node.get("muted"),
		"reduced_motion": _settings_node.get("reduced_motion"),
		"card_cache_size": _settings_node.get("card_cache_size"),
		"animation_mode": _settings_node.get("animation_mode"),
		"quality_profile": _settings_node.get("quality_profile"),
	}
	_settings_node.call(
		"update",
		float(_settings_snapshot.master_volume),
		bool(_settings_snapshot.muted),
		true,
		int(_settings_snapshot.card_cache_size),
		"reduced",
		"high",
		float(_settings_snapshot.music_volume),
		float(_settings_snapshot.sfx_volume),
	)
	return true


func _set_preview_quality(profile: String) -> void:
	_set_preview_motion("reduced", profile)


func _set_preview_motion(mode: String, profile: String) -> void:
	if _settings_node == null:
		return
	_settings_node.call(
		"update",
		float(_settings_node.get("master_volume")),
		bool(_settings_node.get("muted")),
		mode == "reduced",
		int(_settings_node.get("card_cache_size")),
		mode,
		profile,
		float(_settings_node.get("music_volume")),
		float(_settings_node.get("sfx_volume")),
	)


func _restore_preview_settings() -> void:
	if _settings_node == null or _settings_snapshot.is_empty():
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


func _finish(exit_code: int) -> void:
	if _finished:
		return
	_finished = true
	_restore_preview_settings()
	quit(exit_code)


func _capture(filename: String) -> bool:
	var texture := root.get_texture()
	if texture == null:
		push_error("Unable to capture preview %s: viewport texture is unavailable" % filename)
		return false
	var image := texture.get_image()
	if image == null:
		push_error("Unable to capture preview %s: viewport image is unavailable" % filename)
		return false
	var result := image.save_png(ProjectSettings.globalize_path(
		"%s/%s" % [OUTPUT_ROOT, filename]))
	if result != OK:
		push_error("Unable to save preview %s" % filename)
		return false
	return true


func _captures_differ(first_filename: String, second_filename: String) -> bool:
	var first_path := ProjectSettings.globalize_path(
		"%s/%s" % [OUTPUT_ROOT, first_filename]
	)
	var second_path := ProjectSettings.globalize_path(
		"%s/%s" % [OUTPUT_ROOT, second_filename]
	)
	return FileAccess.get_file_as_bytes(first_path) != FileAccess.get_file_as_bytes(
		second_path
	)


func _assert_network_first_screen(page: NetworkLobbyPage, label: String) -> bool:
	if page == null or page.page_scroll == null or page.connect_button == null:
		push_error("%s preview is missing its network layout controls" % label)
		return false
	var scroll := page.page_scroll
	var viewport_rect := scroll.get_global_rect()
	var button_rect := page.connect_button.get_global_rect()
	var page_rect := page.page.get_global_rect()
	var top_bar := page.page.get_node("TopBar") as Control
	var steps := page.page.get_node("Steps") as Control
	var top_bar_rect := top_bar.get_global_rect()
	var steps_rect := steps.get_global_rect()
	var scrollbar := scroll.get_v_scroll_bar()
	var left_gutter := page_rect.position.x - viewport_rect.position.x
	var right_gutter := viewport_rect.end.x - page_rect.end.x
	var top_gutter := page_rect.position.y - viewport_rect.position.y
	var fits := (
		not scrollbar.visible
		and scroll.scroll_vertical == 0
		and viewport_rect.encloses(page_rect)
		and viewport_rect.encloses(top_bar_rect)
		and viewport_rect.encloses(steps_rect)
		and viewport_rect.encloses(button_rect)
		and left_gutter >= -0.5
		and right_gutter >= -0.5
		and absf(left_gutter - right_gutter) <= 2.0
		and absf(page_rect.get_center().x - viewport_rect.get_center().x) <= 1.0
		and absf(top_gutter) <= 1.0
		and page.page.get_parent() == page.page_center
	)
	if not fits:
		push_error(
			"%s must fit, top-align and remain horizontally centered at 1600x900 without vertical scrolling: viewport=%s page=%s top=%s steps=%s button=%s gutters=%.1f/%.1f/%.1f scroll=%d max=%.1f visible=%s"
			% [
				label,
				viewport_rect,
				page_rect,
				top_bar_rect,
				steps_rect,
				button_rect,
				left_gutter,
				right_gutter,
				top_gutter,
				scroll.scroll_vertical,
				scrollbar.max_value,
				scrollbar.visible,
			]
		)
	return fits
