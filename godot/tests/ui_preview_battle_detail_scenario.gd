extends RefCounted

var harness: Variant


func configure(preview_harness: Variant) -> void:
	harness = preview_harness


func run(ui: Control) -> void:
	var demo := UIPreviewStateFactory.battle_state()
	demo.players[0].active.damage_counters = 2
	demo.players[0].active.status_conditions.assign(["BURNED"])
	demo.players[0].active.attached_tool_id = "sv1-202"
	ui.state = demo
	ui.current_view_player = 0
	ui.game_mode = "local"
	ui.shell_view.build_game_screen()
	ui.battle_screen.set_local_hand_privacy_hidden(false)
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
	await harness._settle_rendered(5)
	if not harness._capture("battle-card-detail-redesign.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(1280, 720)
	await harness._settle_rendered(4)
	if not harness._capture("battle-card-detail-redesign-1280x720.png"):
		harness._finish(1)
		return
	harness.tree.root.size = Vector2i(900, 540)
	await harness._settle_rendered(4)
	if not harness._capture("battle-card-detail-redesign-compact.png"):
		harness._finish(1)
		return
	print("BATTLE_DETAIL_PREVIEWS_OK")
	harness._finish(0)
