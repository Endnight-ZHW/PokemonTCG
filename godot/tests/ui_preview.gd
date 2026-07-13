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
	ui._close_modal()
	await _settle_frontend(2)

	ui.show_network_setup("lan")
	await _settle_frontend()
	if not _capture("network-lan.png"):
		_finish(1)
		return

	ui.show_network_setup("relay")
	await _settle_frontend()
	if not _capture("network.png"):
		_finish(1)
		return
	ui.current_network_page.set_connection_state(
		NetworkLobbyPage.ConnectionState.WAITING,
		"房间已创建，等待挑战者加入。",
		"ROOM42",
	)
	await _settle_frontend()
	if not _capture("network-waiting.png"):
		_finish(1)
		return
	ui.current_network_page.set_connection_state(
		NetworkLobbyPage.ConnectionState.ERROR,
		"连接中断：无法联系 Relay 服务，请检查网络地址后重新尝试。",
	)
	await _settle_frontend()
	if not _capture("network-error.png"):
		_finish(1)
		return

	ui.show_title()
	ui.show_settings()
	await _settle_frontend()
	if not _capture("settings.png"):
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
	if not _capture("network-compact.png"):
		_finish(1)
		return
	ui.show_title()
	ui.show_settings()
	await _settle_frontend()
	if not _capture("settings-compact.png"):
		_finish(1)
		return
	ui._close_modal()
	await _settle_frontend(2)
	ui._show_help()
	await _settle_frontend()
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
	ui.battle_screen.play_presentation([{
		"event_type": "deck_shuffled",
		"actor": 0,
		"source": {"player": 0, "zone": "deck"},
		"target": {"player": 0, "zone": "deck"},
		"data": {"player": 0},
	}], demo.revision + 111, 0)
	await create_timer(0.24).timeout
	if not _capture("shuffle.png"):
		_finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()

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
				"value": {"index": 0, "card_id": "sv1-104"},
			},
			{
				"option_id": "card:deck:1:sv1-151",
				"label": "高级球",
				"value": {"index": 1, "card_id": "sv1-151"},
			},
			{
				"option_id": "card:deck:2:svf-potion",
				"label": "伤药",
				"value": {"index": 2, "card_id": "svf-potion"},
			},
		],
		1,
		1,
	)
	ui.show_choice(choice)
	await process_frame
	await create_timer(0.25).timeout
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
		{"max_per_target": 2, "same_target": true},
	)
	var energy_stack := ResolutionStack.new()
	energy_stack.push_continuation("energy_attach_distribution", {
		"player_idx": 0,
		"source_zone": "hand",
		"card_ids": ["svi-jete", "svi-dtur"],
	})
	energy_stack.pending_request = energy_choice
	demo.resolution_stack = energy_stack.to_dict()
	ui.show_choice(energy_choice)
	ui._toggle_choice("pokemon:0:active:svi-hrot")
	await _settle_rendered(4)
	if not _capture("choice-energy.png"):
		_finish(1)
		return
	if not _capture("choice-energy-progress.png"):
		_finish(1)
		return
	ui._toggle_choice("pokemon:0:active:svi-hrot")
	await _settle_rendered(4)
	if not _capture("choice-energy-complete.png"):
		_finish(1)
		return
	ui._close_modal()
	await _wait_until_hidden(ui.modal_layer)

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
		"data": {"player": 1, "slot": "active", "card_id": "sv2-keldeo"},
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
	var pointer_position := control.get_global_rect().get_center()
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
	var pointer_position := control.get_global_rect().get_center()
	Input.warp_mouse(pointer_position)
	var motion := InputEventMouseMotion.new()
	motion.position = pointer_position
	motion.global_position = pointer_position
	Input.parse_input_event(motion)
	await process_frame


func _wait_until_hidden(control: Control, maximum_frames := 45) -> void:
	if control == null:
		return
	for _frame in range(maximum_frames):
		if not control.visible:
			return
		await process_frame


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
	if _settings_node == null:
		return
	_settings_node.call(
		"update",
		float(_settings_node.get("master_volume")),
		bool(_settings_node.get("muted")),
		true,
		int(_settings_node.get("card_cache_size")),
		"reduced",
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
