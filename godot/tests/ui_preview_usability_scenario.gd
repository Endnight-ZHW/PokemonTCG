extends RefCounted

var harness: Variant


func configure(preview_harness: Variant) -> void:
	harness = preview_harness


func run(ui: Control) -> void:
	var demo := UIPreviewStateFactory.battle_state()
	demo.players[0].active.damage_counters = 2
	demo.players[0].active.attached_tool_id = "sv1-202"
	demo.players[0].active.status_conditions.assign(["BURNED"])
	ui.state = demo
	ui.current_view_player = 0
	ui.game_mode = "local"
	ui.shell_view.build_game_screen()
	ui.battle_screen.set_local_hand_privacy_hidden(false)
	for dimensions in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(900, 540), Vector2i(2000, 900)]:
		harness.tree.root.size = dimensions
		await harness._settle_rendered(4)
		harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo), "pokemon:0:active")
		ui.battle_screen.show_card_detail(demo.players[0].active.card_id, demo.players[0].active)
		await harness._settle_rendered(4)
		var table := ui.battle_screen as BattleTable
		var rail := table.hud.get_node("PhasePanel") as Control
		var action_rect := table.action_popover.panel_global_rect()
		if action_rect.intersects(rail.get_global_rect()) or action_rect.intersects(table.own_active.visual_global_bounds()):
			push_error("Action panel blocks source or phase controls at %s" % dimensions)
			harness._finish(1)
			return
		if table.detail_panel.visible and table.detail_panel.get_global_rect().intersects(table.own_info.get_global_rect()):
			push_error("Card details cover player counters at %s" % dimensions)
			harness._finish(1)
			return
		if not harness._capture("battle-ui-%dx%d.png" % [dimensions.x, dimensions.y]):
			harness._finish(1)
			return
	harness.tree.root.size = Vector2i(900, 540)
	await harness._settle_rendered(4)
	for edge in ["left", "top", "right", "bottom"]:
		ui.shell_view.safe_area.add_theme_constant_override("margin_%s" % edge, 48)
	await harness._settle_rendered(4)
	harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo), "hand:0")
	await harness._settle_rendered(4)
	if not harness._capture("battle-ui-target-safe-compact.png"):
		harness._finish(1)
		return
	ui.shell_view.apply_safe_area()
	await harness._settle_rendered(4)
	ui.selected_entity_key = "pokemon:0:active"
	ui.selected_entity_identity = ui._entity_identity_for_key(ui.selected_entity_key)
	ui._show_card_inspector({"card_id": demo.players[0].active.card_id, "pokemon": demo.players[0].active, "player": 0, "slot": "active"})
	await harness._settle_rendered(4)
	if not harness._capture("battle-ui-inspector-compact.png"):
		harness._finish(1)
		return
	ui.modal_confirm.pressed.emit()
	await harness._settle_rendered(4)
	ui._show_pause_overlay()
	ui.modal_cancel.pressed.emit()
	await harness._settle_rendered(4)
	if not harness._capture("battle-ui-exit-confirm.png"):
		harness._finish(1)
		return
	ui.modal_host_controller.close()
	await harness._settle_rendered(4)
	harness.tree.root.size = Vector2i(1600, 900)
	harness._set_preview_quality("low")
	await harness._settle_rendered(4)
	harness._update_battle_preview(ui, demo, UIPreviewStateFactory.action_rows(demo))
	await harness._settle_rendered(4)
	if not harness._capture("battle-ui-low-reduced.png"):
		harness._finish(1)
		return
	harness._set_preview_quality("high")
	var stress := UIPreviewStateFactory.battle_stress_state()
	ui.battle_screen.set_local_hand_privacy_hidden(false)
	for dimensions in [Vector2i(1600, 900), Vector2i(900, 540)]:
		harness.tree.root.size = dimensions
		harness._update_battle_preview(ui, stress, UIPreviewStateFactory.action_rows(stress))
		await harness._settle_rendered(5)
		if not harness._capture("battle-ui-audit-%dx%d.png" % [dimensions.x, dimensions.y]):
			harness._finish(1)
			return
	print("BATTLE_USABILITY_PREVIEWS_OK")
	harness._finish(0)
