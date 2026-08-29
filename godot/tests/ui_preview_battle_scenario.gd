extends RefCounted

var harness: Variant


func configure(preview_harness: Variant) -> void:
	harness = preview_harness


func run(ui: Control) -> void:
	if not ui._start_local_match("fire", "water"):
		push_error("Unable to start preview match")
		harness._finish(1)
		return
	await harness.tree.process_frame
	await harness.tree.create_timer(0.25).timeout
	if not harness._capture("privacy.png"):
		harness._finish(1)
		return

	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)
	var empty_demo := UIPreviewStateFactory.setup_state()
	for empty_player in empty_demo.players:
		empty_player.active = null
		for bench_index in range(empty_player.bench.size()):
			empty_player.bench[bench_index] = null
	harness._update_battle_preview(ui, empty_demo, [])
	await harness._settle_rendered(4)
	if not harness._capture("battle-empty.png"):
		harness._finish(1)
		return

	var setup_demo := UIPreviewStateFactory.setup_state()
	harness._update_battle_preview(
		ui,
		setup_demo,
		UIPreviewStateFactory.setup_action_rows(setup_demo),
		"hand:0",
	)
	await harness._settle_rendered(4)
	if not harness._capture("game.png"):
		harness._finish(1)
		return
	if not harness._capture("battle-setup.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1280, 720)
	await harness._settle_rendered(3)
	if not harness._capture("battle-setup-1280x720.png"):
		harness._finish(1)
		return
	var bonus_setup_demo := setup_demo.clone_state()
	bonus_setup_demo.setup_stage = GameState.SETUP_BONUS_PLACEMENT
	bonus_setup_demo.setup_actor_idx = 0
	bonus_setup_demo.setup_ready.assign([true, true])
	bonus_setup_demo.players[0].bench[0] = PokemonState.new("svi-chim")
	harness._update_battle_preview(
		ui,
		bonus_setup_demo,
		UIPreviewStateFactory.setup_action_rows(bonus_setup_demo),
	)
	await harness._settle_rendered(3)
	if not harness._capture("battle-bonus-placement-1280x720.png"):
		harness._finish(1)
		return
	harness._update_battle_preview(
		ui,
		setup_demo,
		UIPreviewStateFactory.setup_action_rows(setup_demo),
		"hand:0",
	)
	harness.tree.root.size = Vector2i(2000, 900)
	await harness._settle_rendered(3)
	if not harness._capture("game-20x9.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1600, 900)
	await harness.tree.process_frame

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
		"sv1-ener-2",
		"sv1-ener-2",
		"svi-mirc",
		"svi-dtur",
		"svi-jete",
		"svi-trea",
		"svg2-lume",
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
	ui.shell_view.build_game_screen()
	harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await harness._settle_rendered(4)
	var special_stack_card: CardView = ui.battle_screen.get_slot_view(0, "active")
	var special_colorless_badge: Control = harness._energy_badge_for_group(
		special_stack_card,
		"energy:type:Colorless",
	)
	var special_colorless_count := (
		special_colorless_badge.find_child("CountBadge", true, false) as Control
		if special_colorless_badge != null
		else null
	)
	if (
		special_colorless_badge == null
		or special_colorless_badge.find_child("SpecialMarker", true, false) != null
		or special_colorless_badge.get_meta("energy_card_ids", [])
		!= ["svi-mirc", "svi-dtur", "svi-jete", "svi-trea", "svg2-lume"]
		or int(special_colorless_badge.get_meta("provided_unit_count", 0)) != 6
		or special_colorless_count == null
		or str(special_colorless_count.get_meta("count_text", "")) != "6"
	):
		push_error("Colorless Special Energy preview did not render one unit-counted stack")
		harness._finish(1)
		return
	if not harness._capture("battle-colorless-special-stack.png"):
		harness._finish(1)
		return
	if not harness._capture("battle-populated.png"):
		harness._finish(1)
		return
	if not harness._capture("battle-main.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1280, 720)
	await harness._settle_rendered(4)
	if not harness._capture("battle-main-1280x720.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(2000, 900)
	await harness._settle_rendered(4)
	if not harness._capture("battle-main-20x9.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(900, 540)
	await harness._settle_rendered(4)
	if not harness._capture("battle-main-compact.png"):
		harness._finish(1)
		return
	var previous_battle_window_min_size: Vector2i = harness.tree.root.min_size
	harness.tree.root.min_size = Vector2i.ZERO
	harness.tree.root.size = Vector2i(640, 360)
	await harness._settle_rendered(4)
	if not harness._capture("battle-main-minimum.png"):
		harness._finish(1)
		return
	harness.tree.root.min_size = previous_battle_window_min_size
	harness.tree.root.size = Vector2i(1600, 900)
	await harness._settle_rendered(4)
	var energy_count_demo := demo.clone_state()
	energy_count_demo.players[0].active.energy_card_ids.clear()
	energy_count_demo.players[0].bench[0].energy_card_ids.clear()
	for _energy_index in range(12):
		energy_count_demo.players[0].active.energy_card_ids.append("sv1-ener-2")
	for _energy_index in range(10):
		energy_count_demo.players[0].bench[0].energy_card_ids.append("sv1-ener-2")
	harness._update_battle_preview(
		ui,
		energy_count_demo,
		UIPreviewStateFactory.action_rows(energy_count_demo),
	)
	await harness._settle_rendered(4)
	if (
		not harness._energy_count_badge_is_readable(
			ui.battle_screen.get_slot_view(0, "active"), "12"
		)
		or not harness._energy_count_badge_is_readable(
			ui.battle_screen.get_slot_view(0, "bench_0"), "10"
		)
	):
		push_error("Standard battle energy count badges are unreadable or clipped")
		harness._finish(1)
		return
	if not harness._capture("battle-energy-counts.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(900, 540)
	await harness._settle_rendered(4)
	if (
		not harness._energy_count_badge_is_readable(
			ui.battle_screen.get_slot_view(0, "active"), "12"
		)
		or not harness._energy_count_badge_is_readable(
			ui.battle_screen.get_slot_view(0, "bench_0"), "10"
		)
	):
		push_error("Compact battle energy count badges are unreadable or clipped")
		harness._finish(1)
		return
	if not harness._capture("battle-energy-counts-compact.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1600, 900)
	harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await harness._settle_rendered(4)
	var full_bench_demo := demo.clone_state()
	var bench_cards := [
		"svi-chim", "svi-ente", "sv2-starm", "sv2-keldeo", "svi-hrot",
	]
	for player_index in range(2):
		for bench_index in range(5):
			full_bench_demo.players[player_index].bench[bench_index] = PokemonState.new(
				str(bench_cards[(bench_index + player_index) % bench_cards.size()])
			)
	harness._update_battle_preview(
		ui,
		full_bench_demo,
		UIPreviewStateFactory.action_rows(full_bench_demo),
	)
	await harness._settle_rendered(4)
	if not harness._capture("battle-full-bench.png"):
		harness._finish(1)
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
	harness._update_battle_preview(ui, discard_stack_demo, [])
	await harness._settle_rendered(4)
	if not harness._capture("battle-discard-stack-30.png"):
		harness._finish(1)
		return

	var three_prize_demo := demo.clone_state()
	three_prize_demo.players[0].prizes = [
		"sv1-ener-2", "sv1-151", "sv1-189",
	]
	three_prize_demo.players[1].prizes = ["", "", ""]
	harness._update_battle_preview(
		ui,
		three_prize_demo,
		UIPreviewStateFactory.action_rows(three_prize_demo),
		"pokemon:0:active",
	)
	ui.battle_screen.show_card_detail(
		three_prize_demo.players[0].active.card_id,
		three_prize_demo.players[0].active,
	)
	await harness._settle_rendered(4)
	if not harness._capture("battle-prizes-3.png"):
		harness._finish(1)
		return
	ui.battle_screen.hide_card_detail()
	harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await harness._settle_rendered(3)
	# Two adjacent Energy cards are both actionable here. This baseline guards
	# the parent-card Z ordering: a lower card's cyan outline must disappear
	# behind the next card instead of drawing across its face.
	var overlapping_highlight_demo := demo.clone_state()
	overlapping_highlight_demo.players[0].hand = [
		"sv1-ener-2", "sv1-ener-2", "sv1-189", "svf-potion", "sv1-151",
		"svi-jete", "sv1-189", "svf-potion", "sv1-151",
	]
	harness._update_battle_preview(
		ui,
		overlapping_highlight_demo,
		UIPreviewStateFactory.action_rows(overlapping_highlight_demo),
	)
	await harness._settle_rendered(4)
	if not harness._capture("battle-overlapping-highlights.png"):
		harness._finish(1)
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
	# _start_local_match intentionally enters pass-and-play privacy mode.
	# Reveal only this fixture's local hand, just as completing the handoff does.
	ui.battle_screen.set_local_hand_privacy_hidden(false)
	harness._update_battle_preview(
		ui,
		dense_hover_demo,
		UIPreviewStateFactory.action_rows(dense_hover_demo),
	)
	await harness._settle_rendered(4)
	var dense_hover_index := 7
	var dense_hover_view := (
		ui.battle_screen.hand_views[dense_hover_index] as CardView
	)
	var dense_hover_routed: bool = await harness._move_pointer_to_hand_card_exposed_edge(
		dense_hover_view,
	)
	if not dense_hover_routed or not dense_hover_view._hovered:
		push_error(harness._dense_hand_hover_failure_message(
			"Dense-hand preview did not produce a real middle-card hover",
			dense_hover_view,
		))
		harness._finish(1)
		return
	var dense_hover_right := (
		ui.battle_screen.hand_views[dense_hover_index + 1] as CardView
	)
	if not harness._preview_card_draws_above(dense_hover_right, dense_hover_view):
		push_error("Dense-hand hover raised the middle card above its right neighbor")
		harness._finish(1)
		return
	await harness._settle_rendered(3)
	if not harness._capture("battle-dense-hand-hover-1600x900.png"):
		harness._finish(1)
		return

	await harness._move_pointer_to_position(Vector2(4.0, 4.0))
	harness.tree.root.size = Vector2i(900, 540)
	await harness._settle_rendered(4)
	dense_hover_view = ui.battle_screen.hand_views[dense_hover_index] as CardView
	dense_hover_routed = await harness._move_pointer_to_hand_card_exposed_edge(
		dense_hover_view,
	)
	if not dense_hover_routed or not dense_hover_view._hovered:
		push_error(harness._dense_hand_hover_failure_message(
			"Compact dense-hand preview did not produce a real middle-card hover",
			dense_hover_view,
		))
		harness._finish(1)
		return
	dense_hover_right = (
		ui.battle_screen.hand_views[dense_hover_index + 1] as CardView
	)
	if not harness._preview_card_draws_above(dense_hover_right, dense_hover_view):
		push_error(
			"Compact dense-hand hover raised the middle card above its right neighbor"
		)
		harness._finish(1)
		return
	await harness._settle_rendered(3)
	if not harness._capture("battle-dense-hand-hover-900x540.png"):
		harness._finish(1)
		return
	await harness._move_pointer_to_position(Vector2(4.0, 4.0))
	ui.battle_screen.set_local_hand_privacy_hidden(true)
	harness.tree.root.size = Vector2i(1600, 900)
	await harness._settle_rendered(4)
	harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await harness._settle_rendered(3)
	ui.shell_view.show_toast("能量已附着。")
	await harness._settle_rendered(4)
	if not harness._capture("battle-toast.png"):
		harness._finish(1)
		return
	ui.toast_label.visible = false
	var ai_demo := demo.clone_state()
	ai_demo.active_player_idx = 1
	ai_demo.players[1].name = "Challenge AI"
	harness._update_battle_preview(ui, ai_demo, [], "", true, "challenge")
	await harness._settle_rendered(4)
	if not harness._capture("ai-thinking.png"):
		harness._finish(1)
		return
	if not harness._capture("battle-ai.png"):
		harness._finish(1)
		return
	harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await harness._settle_frontend(3)
	harness._update_battle_preview(
		ui,
		demo,
		UIPreviewStateFactory.action_rows(demo),
		"hand:1",
	)
	ui.battle_screen.show_card_detail(str(demo.players[0].hand[1]))
	await harness._settle_rendered(4)
	if not harness._capture("card-actions.png"):
		harness._finish(1)
		return
	if not harness._capture("battle-card-preview.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1280, 720)
	await harness._settle_rendered(4)
	if not harness._capture("battle-card-preview-1280x720.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(900, 540)
	await harness._settle_rendered(4)
	var compact_detail := ui.battle_screen.detail_panel as BattleDetailPanel
	if (
		compact_detail == null
		or not compact_detail.is_compact_layout()
		or not compact_detail.scale.is_equal_approx(Vector2.ONE)
		or not compact_detail.size.is_equal_approx(
			BattleDetailPanel.COMPACT_PANEL_SIZE
		)
		or not harness._physical_control_rect(compact_detail).size.is_equal_approx(
			BattleDetailPanel.COMPACT_PANEL_SIZE
		)
		or not harness._assert_physical_touch_targets(
			[compact_detail.close_button],
			"battle detail compact",
		)
	):
		push_error(
			"Compact battle detail did not use the configured unscaled bottom surface: "
			+ "detail=%s physical=%s expected=%s close=%s" % [
				compact_detail.size if compact_detail else Vector2.ZERO,
				harness._physical_control_rect(compact_detail).size if compact_detail else Vector2.ZERO,
				BattleDetailPanel.COMPACT_PANEL_SIZE,
				compact_detail.close_button.get_global_rect() if compact_detail else Rect2(),
			]
		)
		harness._finish(1)
		return
	var compact_action_popover := ui.battle_screen.action_popover as CardActionPopover
	if (
		compact_action_popover
		and compact_action_popover.visible
		and compact_detail.get_global_rect().intersects(
			compact_action_popover.panel_global_rect()
		)
	):
		push_error("Compact battle detail overlaps the card action popover")
		harness._finish(1)
		return
	if not harness._capture("battle-card-preview-compact.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1600, 900)
	await harness._settle_rendered(4)
	harness._update_battle_preview(
		ui,
		demo,
		UIPreviewStateFactory.action_rows(demo),
		"pokemon:1:active",
	)
	ui.battle_screen.show_card_detail(
		demo.players[1].active.card_id,
		demo.players[1].active,
	)
	await harness._settle_rendered(4)
	if not harness._capture("battle-card-preview-opponent.png"):
		harness._finish(1)
		return
	ui.battle_screen.hide_card_detail()
	harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	var preview_hud := ui.battle_screen.hud as BattlePhaseHud
	if preview_hud == null:
		push_error("Battle preview HUD is unavailable")
		harness._finish(1)
		return
	preview_hud.set_log_drawer_open(true)
	await harness._settle_rendered(4)
	if not harness._capture("battle-log-open.png"):
		harness._finish(1)
		return
	preview_hud.close_log_drawer()
	await harness._settle_rendered(3)
	if not harness._capture("battle-log-closed.png"):
		harness._finish(1)
		return
	harness._update_battle_preview(
		ui,
		demo,
		UIPreviewStateFactory.action_rows(demo),
		"pokemon:0:active",
	)
	ui.battle_screen.show_card_detail(
		demo.players[0].active.card_id,
		demo.players[0].active,
	)
	await harness._settle_rendered(4)
	if not harness._capture("battle-attack-actions.png"):
		harness._finish(1)
		return
	var retreat_preview_action: GameAction
	for row_value in UIPreviewStateFactory.action_rows(demo):
		var candidate := Dictionary(row_value).get("action") as GameAction
		if candidate != null and candidate.kind == "RETREAT":
			retreat_preview_action = candidate
			break
	if retreat_preview_action == null:
		push_error("Battle preview exposes no retreat action for confirmation QA")
		harness._finish(1)
		return
	ui._show_retreat_confirmation(retreat_preview_action)
	await harness._settle_rendered(4)
	var retreat_confirmation_copy := ""
	for label_node in ui.modal_body.find_children("*", "Label", true, false):
		retreat_confirmation_copy += (label_node as Label).text + "\n"
	if (
		"无需丢弃能量" in retreat_confirmation_copy
		or "卡面撤退费用：1 点" not in retreat_confirmation_copy
		or "下一步选择" not in retreat_confirmation_copy
	):
		push_error("Retreat confirmation still misrepresents deferred Energy payment")
		harness._finish(1)
		return
	if not harness._capture("retreat-confirmation.png"):
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)
	harness._update_battle_preview(
		ui,
		demo,
		UIPreviewStateFactory.action_rows(demo),
		"pokemon:0:active",
	)
	ui.battle_screen.show_card_detail(
		demo.players[0].active.card_id,
		demo.players[0].active,
	)
	await harness._settle_rendered(3)
	var preview_source_card := ui.battle_screen.own_active as CardView
	await harness._move_pointer_to_control(preview_source_card)
	var hovered_card_control: Control = harness.tree.root.gui_get_hovered_control()
	if (
		hovered_card_control == null
		or (
			hovered_card_control != preview_source_card
			and not preview_source_card.is_ancestor_of(hovered_card_control)
		)
	):
		push_error("Battle card became unreachable through transparent layout surfaces")
		harness._finish(1)
		return
	var preview_action_button := ui.battle_screen.action_popover.action_buttons.get_child(
		0
	) as Button
	await harness._move_pointer_to_control(preview_action_button)
	var hovered_action_control: Control = harness.tree.root.gui_get_hovered_control()
	if (
		hovered_action_control == null
		or (
			hovered_action_control != preview_action_button
			and not preview_action_button.is_ancestor_of(hovered_action_control)
		)
	):
		push_error("Card action button became unreachable through its transparent harness.tree.root: button=%s hovered=%s popover=%s detail=%s window=%s" % [
			harness._physical_control_rect(preview_action_button),
			hovered_action_control.get_path() if hovered_action_control else "<none>",
			ui.battle_screen.action_popover.panel_global_rect(),
			ui.battle_screen.detail_panel.get_global_rect(),
			harness.tree.root.size,
		])
		harness._finish(1)
		return
	# Reproduce the reported state exactly: a card action popover and detail panel
	# are visible, then the player clicks the system menu. Use routed pointer input
	# instead of emitting Button.pressed so z-order and full-screen blockers are
	# covered by this visual smoke test.
	ui.battle_screen.input_blocker.visible = true
	await harness._click_control(ui.battle_screen.header.menu_button)
	await harness._settle_rendered(3)
	if not ui.modal_layer.visible or ui.modal_title.text != "对局菜单":
		push_error("Battle menu click was intercepted by a table overlay")
		harness._finish(1)
		return
	if not harness._capture("battle-menu-open.png"):
		harness._finish(1)
		return
	var danger_mouse_pressed: bool = await harness._begin_mouse_press(ui.modal_cancel)
	if not danger_mouse_pressed:
		push_error("Battle Danger action did not enter a real pressed draw state")
		harness._finish(1)
		return
	if not harness._capture("battle-menu-danger-pressed.png"):
		harness._finish(1)
		return
	await harness._cancel_mouse_press(ui.modal_cancel)
	if (
		not ui.modal_layer.visible
		or not harness._captures_differ(
			"battle-menu-open.png", "battle-menu-danger-pressed.png"
		)
	):
		push_error("Battle Danger pressed fixture did not remain visible and distinct")
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)
	ui.battle_screen.input_blocker.visible = false

	var promotion_demo := UIPreviewStateFactory.promotion_state()
	harness._update_battle_preview(
		ui,
		promotion_demo,
		UIPreviewStateFactory.promotion_action_rows(promotion_demo),
		"pokemon:0:bench_0",
	)
	await harness._settle_rendered(4)
	if not harness._capture("battle-promotion.png"):
		harness._finish(1)
		return
	harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await harness._settle_frontend(3)
	ui._show_card_inspector({
		"card_id": "svi-hrot",
		"pokemon": demo.players[0].active,
		"location": "玩家 1 战斗区",
	})
	await harness.tree.process_frame
	await harness.tree.create_timer(0.2).timeout
	if not harness._capture("card-inspector.png"):
		harness._finish(1)
		return
	var inspector_panel := ui.modal_body.get_child(0) as CardInspectorPanel
	if inspector_panel == null or inspector_panel._image_button == null:
		push_error("Card inspector did not expose its image zoom action")
		harness._finish(1)
		return
	inspector_panel._image_button.pressed.emit()
	await harness._settle_rendered(3)
	if inspector_panel.get_node_or_null("CardArtZoom") == null:
		push_error("Card inspector image action did not open the art zoom surface")
		harness._finish(1)
		return
	if not harness._capture("card-inspector-art-zoom.png"):
		harness._finish(1)
		return
	(inspector_panel.get_node("CardArtZoom") as PopupPanel).hide()
	await harness._settle_rendered(2)
	harness.tree.root.size = Vector2i(560, 720)
	await harness._settle_rendered(4)
	inspector_panel._apply_responsive_layout()
	if inspector_panel._content_grid.columns != 1:
		push_error("Compact card inspector did not switch to a single-column layout: panel=%s window=%s viewport=%s columns=%d" % [
			inspector_panel.size,
			inspector_panel.get_window().size,
			inspector_panel.get_viewport_rect().size,
			inspector_panel._content_grid.columns,
		])
		harness._finish(1)
		return
	if not harness._capture("card-inspector-compact.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1600, 900)
	await harness._settle_rendered(3)
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)
	ui._show_zone_inspector({
		"title": "弃牌",
		"player": 0,
		"zone": "discard",
		"card_ids": ["sv1-180", "sv1-189", "svf-potion"],
		"count": 3,
		"hidden": false,
	})
	await harness.tree.process_frame
	await harness.tree.create_timer(0.2).timeout
	if not harness._capture("zone-inspector.png"):
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)
	await harness._settle_frontend(2)
	harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await harness._settle_frontend(3)

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
	await harness.tree.create_timer(0.24).timeout
	if not harness._capture("draw.png"):
		harness._finish(1)
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
	await harness.tree.create_timer(0.26).timeout
	if not harness._capture("discard.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	harness._set_preview_motion("standard", "high")
	await harness._settle_rendered(2)
	ui.battle_screen.play_presentation([{
		"event_type": "deck_shuffled",
		"actor": 0,
		"source": {"player": 0, "zone": "deck"},
		"target": {"player": 0, "zone": "deck"},
		"data": {"player": 0},
	}], demo.revision + 111, 0)
	await harness.tree.create_timer(0.24).timeout
	if not harness._capture("shuffle-high.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	harness._set_preview_motion("standard", "low")
	await harness._settle_rendered(2)
	ui.battle_screen.play_presentation([{
		"event_type": "deck_shuffled",
		"actor": 0,
		"source": {"player": 0, "zone": "deck"},
		"target": {"player": 0, "zone": "deck"},
		"data": {"player": 0},
	}], demo.revision + 112, 0)
	await harness.tree.create_timer(0.24).timeout
	if not harness._capture("shuffle-low.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	harness._set_preview_motion("reduced", "high")
	await harness._settle_rendered(2)
	ui.battle_screen.play_presentation([{
		"event_type": "deck_shuffled",
		"actor": 0,
		"source": {"player": 0, "zone": "deck"},
		"target": {"player": 0, "zone": "deck"},
		"data": {"player": 0},
	}], demo.revision + 113, 0)
	await harness.tree.create_timer(0.08).timeout
	if not harness._capture("shuffle-reduced.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	harness._set_preview_motion("standard", "high")
	await harness._settle_rendered(2)
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
	await harness.tree.create_timer(0.82).timeout
	if not harness._capture("reveal-public.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	harness._set_preview_motion("reduced", "high")
	await harness._settle_rendered(2)
	ui.battle_screen.play_presentation(
		[reveal_preview_event], demo.revision + 115, 0)
	await harness.tree.create_timer(0.12).timeout
	if not harness._capture("reveal-public-reduced.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	harness._set_preview_motion("standard", "high")
	await harness._settle_rendered(2)
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
	await harness.tree.create_timer(0.82).timeout
	if not harness._capture("reveal-public-no-energy.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	await harness._settle_rendered(2)
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
	await harness.tree.create_timer(0.82).timeout
	if not harness._capture("reveal-public-all-energy.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	await harness._settle_rendered(2)
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
	await harness.tree.create_timer(0.72).timeout
	if not harness._capture("coin-public-single.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	await harness._settle_rendered(2)
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
	await harness.tree.create_timer(1.95).timeout
	if not harness._capture("coin-public-multi.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	harness._set_preview_motion("reduced", "high")
	await harness._settle_rendered(2)
	ui.battle_screen.play_presentation(
		[coin_preview_event], demo.revision + 120, 1)
	await harness.tree.create_timer(0.08).timeout
	if not harness._capture("coin-public-reduced.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	harness._set_preview_motion("standard", "high")
	await harness._settle_rendered(2)

	var energy_snapshot: Dictionary = ui.battle_screen.capture_presentation_snapshot()
	if not demo.players[0].hand.is_empty():
		demo.players[0].hand.remove_at(0)
	demo.players[0].active.energy_card_ids.append("sv1-ener-2")
	ui._refresh_game()
	await harness.tree.process_frame
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
	await harness.tree.create_timer(0.24).timeout
	if not harness._capture("energy-attach.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	await harness._settle_rendered(2)

	# Capture the complete stack during a real switch. The outgoing active has
	# both an attached Tool and the energy added above, so any regression to
	# independent paper-card attachment flyers is visible and asserted here.
	var switch_snapshot: Dictionary = ui.battle_screen.capture_presentation_snapshot()
	var outgoing_active: PokemonState = demo.players[0].active
	var incoming_bench: PokemonState = demo.players[0].bench[0]
	if outgoing_active == null or incoming_bench == null:
		push_error("Switch preview fixture requires an active and bench Pokemon")
		harness._finish(1)
		return
	demo.players[0].active = incoming_bench
	demo.players[0].bench[0] = outgoing_active
	ui._refresh_game()
	await harness.tree.process_frame
	ui.battle_screen.play_presentation([{
		"event_type": "switched",
		"actor": 0,
		"source": {"player": 0, "slot": "active"},
		"target": {"player": 0, "slot": "bench_0"},
		"data": {"player": 0, "slot": "bench_0"},
	}], demo.revision + 121, 0, switch_snapshot)
	await harness.tree.create_timer(0.08).timeout
	var switch_movers: Array[Control] = []
	for flyer_value in ui.battle_screen.card_motion_layer.entities:
		var flyer := flyer_value as Control
		if flyer != null and bool(flyer.get_meta("slot_composite_motion", false)):
			switch_movers.append(flyer)
	if switch_movers.size() != 2:
		push_error(
			"Switch preview expected two Pokemon composites, got %d"
			% switch_movers.size()
		)
		harness._finish(1)
		return
	for mover in switch_movers:
		if mover.get_node_or_null("PaperImage") != null:
			push_error("Switch preview regressed to a paper-card attachment flyer")
			harness._finish(1)
			return
	if not harness._capture("battle-switch-25.png"):
		harness._finish(1)
		return
	await harness.tree.create_timer(0.11).timeout
	if not harness._capture("battle-switch-50.png"):
		harness._finish(1)
		return
	await harness.tree.create_timer(0.11).timeout
	if not harness._capture("battle-switch-75.png"):
		harness._finish(1)
		return
	await harness.tree.create_timer(0.34).timeout
	ui.battle_screen.clear_presentation_for_resync()
	demo.players[0].active = outgoing_active
	demo.players[0].bench[0] = incoming_bench
	ui._refresh_game()
	await harness._settle_rendered(2)

	var evolution_card_id := "svi-infr"
	demo.players[0].hand.append(evolution_card_id)
	ui._refresh_game()
	await harness.tree.process_frame
	var evolve_snapshot: Dictionary = ui.battle_screen.capture_presentation_snapshot()
	var evolve_hand_index := demo.players[0].hand.size() - 1
	var old_active_card_id: String = demo.players[0].active.card_id
	demo.players[0].hand.remove_at(evolve_hand_index)
	demo.players[0].active.evolution_stack_ids.append(old_active_card_id)
	demo.players[0].active.card_id = evolution_card_id
	ui._refresh_game()
	await harness.tree.process_frame
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
	await harness.tree.create_timer(0.34).timeout
	if not harness._capture("evolve.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	demo.players[0].active.card_id = old_active_card_id
	demo.players[0].active.evolution_stack_ids.erase(old_active_card_id)
	ui._refresh_game()
	await harness.tree.process_frame

	var choice := ChoiceView.new(
		"preview-choice",
		demo.revision,
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
			},
		],
		1,
		1,
	)
	ui._show_choice_overlay(choice)
	await harness.tree.process_frame
	await harness.tree.create_timer(0.25).timeout
	if ui.active_choice_panel == null or ui.active_choice_panel.card_option_count() != 3:
		push_error("Choice preview fixture did not render its card options")
		harness._finish(1)
		return
	if not harness._capture("choice.png"):
		harness._finish(1)
		return
	var first_choice_card := (
		ui.active_choice_panel._option_cards.get("card:deck:0:sv1-104") as CardView
		if ui.active_choice_panel
		else null
	)
	if first_choice_card:
		first_choice_card.activated.emit("sv1-104", -1, 0, "")
	await harness.tree.process_frame
	await harness.tree.create_timer(0.18).timeout
	if not harness._capture("choice-selected.png"):
		harness._finish(1)
		return
	var second_choice_card := (
		ui.active_choice_panel._option_cards.get("card:deck:1:sv1-151") as CardView
		if ui.active_choice_panel
		else null
	)
	if second_choice_card:
		second_choice_card.activated.emit("sv1-151", -1, 0, "")
	await harness.tree.process_frame
	await harness.tree.create_timer(0.18).timeout
	if not harness._capture("choice-switched.png"):
		harness._finish(1)
		return
	if (
		not harness._captures_differ("choice.png", "choice-selected.png")
		or not harness._captures_differ("choice-selected.png", "choice-switched.png")
	):
		push_error("Choice preview state captures are unexpectedly identical")
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(560, 720)
	await harness._settle_rendered(4)
	if not harness._capture("choice-compact-preview.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1600, 900)
	await harness._settle_rendered(4)
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)

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
		})
	var multi_choice := ChoiceView.new(
		"preview-multi-choice",
		demo.revision,
		"search",
		0,
		"从这些卡牌中选择两至三张加入手牌。",
		multi_options,
		2,
		3,
	)
	ui._show_choice_overlay(multi_choice)
	ui._toggle_choice(str(multi_options[0]["option_id"]))
	ui._toggle_choice(str(multi_options[4]["option_id"]))
	ui._toggle_choice(str(multi_options[8]["option_id"]))
	await harness._settle_rendered(4)
	if not harness._capture("choice-multi-limit.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1280, 720)
	await harness._settle_rendered(4)
	if not harness._capture("choice-multi-1280x720.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1600, 900)
	await harness._settle_rendered(4)
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)

	var confirm_revealed_choice := ChoiceView.new(
		"preview-confirm-revealed",
		demo.revision,
		"confirm",
		0,
		"查看了牌库顶的卡牌。请选择处理方式。",
		[
			{"option_id": "confirm:yes", "label": "将这张卡牌加入手牌"},
			{"option_id": "confirm:no", "label": "丢弃这张卡牌，再抽1张卡牌"},
		],
		1,
		1,
		false,
		false,
		{
			"domain": "effect",
			"purpose": "trekking_shoes",
			"top_card_id": "svf-potion",
			"revealed_card_ids": ["svf-potion"],
		},
	)
	ui._show_choice_overlay(confirm_revealed_choice)
	ui._toggle_choice("confirm:no")
	await harness._settle_rendered(4)
	if not harness._capture("choice-confirm-revealed.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(900, 540)
	await harness._settle_rendered(4)
	if not harness._capture("choice-confirm-revealed-compact.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1600, 900)
	await harness._settle_rendered(4)
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)

	var switch_choice := ChoiceView.new(
		"preview-switch-confirm",
		demo.revision,
		"confirm",
		0,
		"是否将这只宝可梦与备战宝可梦互换？",
		[
			{"option_id": "confirm:yes", "label": "进行换位"},
			{"option_id": "confirm:no", "label": "不进行换位"},
		],
		1,
		1,
		false,
		false,
		{
			"domain": "effect",
			"purpose": "switch_confirm",
			"source_player": 0,
			"source_slot": "active",
			"source_card_id": "sv1-114",
			"target_player": 0,
		},
	)
	ui._show_choice_overlay(switch_choice)
	ui._toggle_choice("confirm:yes")
	await harness._settle_rendered(4)
	if not harness._capture("choice-switch-confirm.png"):
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)

	var treasure_options: Array[Dictionary] = []
	for row in [
		{"slot": "active", "card_id": demo.players[0].active.card_id},
		{"slot": "bench_0", "card_id": demo.players[0].bench[0].card_id},
	]:
		treasure_options.append({
			"option_id": "pokemon:0:%s:%s" % [row["slot"], row["card_id"]],
			"label": ui.catalog.card_name(row["card_id"]),
			"ref": EntityRef.new(
				"pokemon", 0, "", row["slot"], -1, "", row["card_id"],
			).to_dict(),
		})
	var treasure_choice := ChoiceView.new(
		"preview-treasure-energy",
		demo.revision,
		"select_prize_energy_target",
		0,
		"请选择宝藏能量的附着目标，或不发动效果。",
		treasure_options,
		0,
		1,
		false,
		true,
		{
			"domain": "trigger",
			"purpose": "treasure_energy_target",
			"source_player": 0,
			"source_zone": "prizes",
			"source_card_id": "svi-trea",
			"card_id": "svi-trea",
			"revealed_card_ids": ["svi-trea"],
		},
	)
	ui._show_choice_overlay(treasure_choice)
	ui._toggle_choice(str(treasure_options[1]["option_id"]))
	await harness._settle_rendered(4)
	if not harness._capture("choice-treasure-energy.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(900, 540)
	await harness._settle_rendered(4)
	if not harness._capture("choice-treasure-energy-compact.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1600, 900)
	await harness._settle_rendered(3)
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)

	if ui.battle_screen == null:
		ui.state = demo
		ui.current_view_player = 0
		ui.game_mode = "local"
		ui.shell_view.build_game_screen()
		ui.battle_screen.set_local_hand_privacy_hidden(false)
	harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await harness._settle_rendered(4)
	var bench_slot_options: Array[Dictionary] = []
	for bench_index in [2, 3, 4]:
		var bench_slot := "bench_%d" % bench_index
		bench_slot_options.append({
			"option_id": "slot:%s" % bench_slot,
			"label": "备战席 %d" % (bench_index + 1),
			"ref": EntityRef.new(
				"slot", 0, "", bench_slot,
			).to_dict(),
		})
	var nest_ball_slot_choice := ChoiceView.new(
		"preview-nest-ball-slot-only",
		demo.revision,
		"select_bench_slot",
		0,
		"请选择「小火焰猴」要放置的备战席。",
		bench_slot_options,
		1,
		1,
		false,
		false,
		{
			"domain": "effect",
			"purpose": "search_bench_slot",
			"source_player": 0,
			"source_card_id": "svi-chim",
			"target_player": 0,
			"target_slots": ["bench_2", "bench_3", "bench_4"],
		},
	)
	ui._show_choice_overlay(nest_ball_slot_choice)
	await harness._settle_rendered(4)
	if not harness._capture("choice-nest-ball-bench-slot.png"):
		harness._finish(1)
		return

	var exp_share_choice := ChoiceView.new(
		"preview-exp-share-confirm",
		demo.revision,
		"confirm_trigger",
		0,
		"是否发动学习装置，将昏厥宝可梦的1张基本能量转附到备战宝可梦？",
		[
			{"option_id": "confirm:yes", "label": "发动学习装置"},
			{"option_id": "confirm:no", "label": "不发动"},
		],
		1,
		1,
		false,
		false,
		{
			"domain": "trigger",
			"purpose": "confirm_exp_share_trigger",
			"source_player": 0,
			"source_slot": "active",
			"source_card_id": demo.players[0].active.card_id,
			"target_player": 0,
			"target_slot": "bench_0",
			"card_id": "svg2-exps",
			"revealed_card_ids": ["svg2-exps"],
		},
	)
	ui._show_choice_overlay(exp_share_choice)
	ui._toggle_choice("confirm:yes")
	await harness._settle_rendered(4)
	if not harness._capture("choice-exp-share-confirm.png"):
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)

	var empty_choice := ChoiceView.new(
		"preview-empty-choice",
		demo.revision,
		"resolve_empty",
		0,
		"没有找到符合条件的卡牌。",
		[],
		0,
		0,
	)
	ui._show_choice_overlay(empty_choice)
	await harness._settle_rendered(4)
	if not harness._capture("choice-empty.png"):
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)

	var distribution_energy_ids: Array[String] = ["svi-jete", "svi-dtur"]
	var distribution_targets: Array[Dictionary] = [
		{
			"player": 0,
			"slot": "active",
			"card_id": "svi-hrot",
			"label": "加热洛托姆",
		},
		{
			"player": 0,
			"slot": "bench_0",
			"card_id": "svi-chim",
			"label": "小火焰猴",
		},
	]
	var distribution_options: Array[Dictionary] = []
	for target in distribution_targets:
		for energy_index in range(distribution_energy_ids.size()):
			var energy_id := distribution_energy_ids[energy_index]
			distribution_options.append({
				"option_id": "energy:%d:%s->pokemon:%d:%s:%s" % [
					energy_index,
					energy_id,
					int(target["player"]),
					str(target["slot"]),
					str(target["card_id"]),
				],
				"label": str(target["label"]),
				"ref": EntityRef.new(
					"pokemon",
					int(target["player"]),
					"",
					str(target["slot"]),
					-1,
					"",
					str(target["card_id"]),
				).to_dict(),
			})
	var energy_choice := ChoiceView.new(
		"preview-energy-choice",
		demo.revision,
		"distribute_energy",
		0,
		"为每张能量选择附着目标。",
		distribution_options,
		2,
		2,
		false,
		false,
		{
			"purpose": "energy_attach_distribution",
			"card_ids": distribution_energy_ids,
			"source_player": 0,
			"source_zone": "hand",
			"max_per_target": 2,
			"same_target": true,
		},
	)
	ui._show_choice_overlay(energy_choice)
	await harness.tree.process_frame
	await harness.tree.create_timer(0.25).timeout
	var original_active_energy: Array[String] = []
	original_active_energy.assign(demo.players[0].active.energy_card_ids)
	var original_bench_energy: Array[String] = []
	original_bench_energy.assign(demo.players[0].bench[0].energy_card_ids)
	var energy_panel := ui.active_choice_panel as ChoicePanel
	var active_target_tile := (
		energy_panel.energy_distribution._energy_target_tiles.get("0:active") as Control
		if energy_panel
		else null
	)
	if (
		not ui.selected_choice_ids.is_empty()
		or energy_panel == null
		or energy_panel.card_option_count() != 2
		or active_target_tile == null
	):
		push_error("Native-format energy distribution did not group into two Pokemon targets")
		harness._finish(1)
		return
	if not harness._capture("choice-energy.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1280, 720)
	await harness._settle_rendered(4)
	if not harness._capture("choice-energy-1280x720.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(900, 540)
	await harness._settle_rendered(4)
	if not harness._capture("choice-energy-compact.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1600, 900)
	await harness._settle_rendered(4)
	await harness._click_control(active_target_tile)
	await harness._settle_rendered(4)
	var first_distribution_id := str(distribution_options[0]["option_id"])
	var second_distribution_id := str(distribution_options[1]["option_id"])
	if (
		ui.selected_choice_ids != [first_distribution_id]
		or demo.players[0].active.energy_card_ids != original_active_energy
		or demo.players[0].bench[0].energy_card_ids != original_bench_energy
	):
		push_error("First energy target did not emit index 0 or mutated authoritative state")
		harness._finish(1)
		return
	if not harness._capture("choice-energy-progress.png"):
		harness._finish(1)
		return
	await harness._click_control(active_target_tile)
	await harness._settle_rendered(4)
	var completed_status := energy_panel.energy_distribution._energy_target_status_labels.get(
		"0:active") as Label
	if (
		ui.selected_choice_ids != [first_distribution_id, second_distribution_id]
		or completed_status == null
		or "不可选择" in completed_status.text
		or demo.players[0].active.energy_card_ids != original_active_energy
	):
		push_error("Second energy target did not emit index 1 or complete cleanly")
		harness._finish(1)
		return
	if not harness._capture("choice-energy-complete.png"):
		harness._finish(1)
		return
	if (
		not harness._captures_differ("choice-energy.png", "choice-energy-progress.png")
		or not harness._captures_differ(
			"choice-energy-progress.png", "choice-energy-complete.png"
		)
	):
		push_error("Energy distribution preview states are unexpectedly identical")
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._wait_until_hidden(ui.modal_layer)
	demo.resolution_stack = {
		"frames": [], "pending_request": null, "sequence": 0, "context": {},
	}
	demo.players[0].active.energy_card_ids = ["sv1-ener-2", "sv1-ener-5"]
	ui._refresh_game()
	await harness._settle_rendered(2)
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
		})
	var attachment_choice := ChoiceView.new(
		"preview-attachment-choice",
		demo.revision,
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
	ui._show_choice_overlay(attachment_choice)
	ui.battle_screen.board_view._on_card_activated(
		demo.players[0].active.card_id, -1, 0, "active")
	await harness._settle_rendered(4)
	var attachment_source_card: CardView = (
		ui.battle_screen.get_slot_view(0, "active")
	)
	if (
		attachment_source_card == null
		or attachment_source_card.interaction_hint.visible
		or not attachment_source_card.target_glow.visible
	):
		push_error(
			"Attachment source preview did not keep the outline while hiding its inline hint"
		)
		harness._finish(1)
		return
	if not harness._capture("choice-attachment-source.png"):
		harness._finish(1)
		return
	ui._toggle_choice(str(attachment_options[1]["option_id"]))
	await harness._settle_rendered(3)
	if not harness._capture("choice-attachment-selected.png"):
		harness._finish(1)
		return
	ui.battle_screen.attachment_choice_popover.dismiss(false)
	harness.tree.root.size = Vector2i(900, 540)
	await harness._settle_rendered(3)
	ui.battle_screen.board_view._on_card_activated(
		demo.players[0].active.card_id, -1, 0, "active")
	await harness._settle_rendered(4)
	attachment_source_card = ui.battle_screen.get_slot_view(0, "active")
	if (
		attachment_source_card == null
		or attachment_source_card.interaction_hint.visible
		or not attachment_source_card.target_glow.visible
	):
		push_error("Compact attachment source preview restored the inline hint")
		harness._finish(1)
		return
	if not harness._capture("choice-attachment-compact.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_choice_targets()
	ui.active_request = null
	harness.tree.root.size = Vector2i(1600, 900)
	await harness._settle_rendered(3)

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
	await harness.tree.create_timer(0.18).timeout
	if not harness._capture("attack.png"):
		harness._finish(1)
		return
	await harness.tree.create_timer(0.72).timeout
	if not harness._capture("impact.png"):
		harness._finish(1)
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
	await harness.tree.create_timer(0.18).timeout
	if not harness._capture("ko.png"):
		harness._finish(1)
		return
	ui.battle_screen.clear_presentation_for_resync()
	demo.winner = 0
	demo.phase = "GAME_OVER"
	harness._set_preview_motion("reduced", "high")
	ui.shell_view.show_end_screen()
	await harness._settle_frontend()
	if not harness._capture("end.png"):
		harness._finish(1)
		return
	ui.queue_free()
	await harness.tree.process_frame

	var workbench_scene := load("res://tools/ui_workbench.tscn") as PackedScene
	var workbench := workbench_scene.instantiate()
	harness.tree.root.add_child(workbench)
	workbench.call_deferred("show_preview", "title")
	await harness.tree.process_frame
	await harness.tree.create_timer(0.2).timeout
	if not harness._capture("workbench.png"):
		harness._finish(1)
		return
	print("UI_PREVIEWS_OK")
	harness._finish(0)
