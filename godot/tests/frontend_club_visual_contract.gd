extends SceneTree

## Reproducible frontend captures and real-renderer frame/lifecycle acceptance.
## Run with -- --skip-performance for layout-only iteration.
const OUTPUT := "res://../build/frontend-club/after"
const SIZES := [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(900, 540),
	Vector2i(2000, 900), Vector2i(640, 960)]
var main: Control
var settings: Node
var failures: Array[String] = []
var report := {"schema": "ptcg.frontend_club/1", "profiles": [], "lifecycle": []}


func _initialize() -> void:
	call_deferred("run")


func settle(frames: int = 12) -> void:
	for frame in range(frames):
		await process_frame
	await RenderingServer.frame_post_draw


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func capture(label: String) -> void:
	await settle()
	var path := "%s/%s-%dx%d.png" % [OUTPUT, label, root.size.x, root.size.y]
	check(root.get_texture().get_image().save_png(path) == OK, "Could not write " + path)


func inside(control: Control, label: String) -> void:
	if control and control.is_visible_in_tree():
		check(main.get_global_rect().grow(1).encloses(control.get_global_rect()), label + " escaped the screen")


func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Frontend acceptance requires a graphics display")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	settings = root.get_node("AppSettings")
	settings.muted = true
	settings.animation_mode = "reduced"
	settings.reduced_motion = true
	settings.quality_profile = "high"
	root.size = SIZES[0]
	main = load("res://scenes/main/main.tscn").instantiate() as Control
	root.add_child(main)
	report["godot"] = Engine.get_version_info().string
	report["gpu"] = RenderingServer.get_video_adapter_name()
	report["renderer"] = RenderingServer.get_current_rendering_method()
	for page_kind in ["title", "decks", "network", "end"]:
		match page_kind:
			"title": main.shell_view.show_title()
			"decks": main.shell_view.show_deck_select("local")
			"network": main.shell_view.show_network_setup("relay")
			"end":
				var victory: Control = main.shell_view.mount(load("res://scenes/end/victory_screen.tscn"))
				victory.configure(0, 18, "玩家 1", "svi-ente", {"mode": "local", "winner_deck_name": "烈焰猴"})
		var page: Control = main.screen_host.get_child(0)
		var page_id := page.get_instance_id()
		for target in SIZES:
			root.size = target
			await capture(page_kind)
			check(page.get_instance_id() == page_id, "Resize replaced the page instance")
			if page_kind == "title":
				for name in ["LocalTwoPlayerButton", "AIButton", "NetworkButton", "SettingsButton", "HelpButton"]:
					inside(page.find_child(name, true, false), "title/" + name)
				check(page.card_stage.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
					"Reduced animation must settle to a static real 3D viewport")
			elif page_kind == "decks":
				var assigned: String = page.selected_deck_key(0)
				page._on_deck_tile_pressed("water")
				check(page.selected_deck_key(0) == assigned, "Browsing changed a player's assigned deck")
				await capture("decks-browsing")
				inside(page.start_button, "decks/start")
				inside(page.assign_deck_button, "decks/assign")
				check((page.get_node("%DetailScroll") as ScrollContainer).size.y >= 100,
					"Deck detail lost its readable preview area")
				page._assign_preview()
				check(page.selected_deck_key(0) == "water", "Explicit deck assignment failed")
			elif page_kind == "network":
				page._set_compact_step(1)
				page.set_connection_state(NetworkLobbyPage.ConnectionState.WAITING, "等待另一位玩家加入", "CLUB24")
				await capture("network-waiting")
				inside(page.copy_room_button, "network/copy")
				inside(page.connect_button, "network/connect")
				check(page.matchup_toggle.disabled, "Waiting room failed to lock rules")
				page.set_connection_state(NetworkLobbyPage.ConnectionState.IDLE)
				page._set_compact_step(0)
			else:
				inside(page.winner_label, "end/result")
				inside(page.rematch_button, "end/rematch")
				inside(page.title_button, "end/home")
		print("FRONTEND_CAPTURED ", page_kind)
	main.shell_view.show_title()
	for modal_kind in ["settings", "help", "deck-detail", "card-inspector", "card-art"]:
		match modal_kind:
			"settings": main._show_settings()
			"help": main._show_help()
			"deck-detail": main._show_deck_details("fire")
			"card-inspector": main._show_card_inspector({"card_id": "svg2-tort"})
			"card-art":
				main._show_card_inspector({"card_id": "svg2-tort"})
				main.modal_body.get_child(0)._image_button.pressed.emit()
		for target in SIZES:
			root.size = target
			await capture(modal_kind)
			inside(main.modal_panel, modal_kind + "/panel")
			inside(main.modal_confirm, modal_kind + "/confirm")
			inside(main.modal_cancel, modal_kind + "/cancel")
			var title: Control = main.screen_host.get_child(0)
			check(not title.card_stage.is_processing(), "Covered title kept its loop running")
		main.modal_host_controller.close()
		await settle(3)
		print("FRONTEND_CAPTURED ", modal_kind)
	await check_lifecycle()
	if "--skip-performance" not in OS.get_cmdline_user_args():
		await measure_performance()
	report["failures"] = failures
	var report_name := "layout-validation.json" if report.profiles.is_empty() else "validation.json"
	var file := FileAccess.open("res://../build/frontend-club/" + report_name, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	main.queue_free()
	await process_frame
	if failures.is_empty():
		print("FRONTEND_CLUB_VISUAL_OK")
	else:
		for failure in failures:
			push_error(failure)
	quit(0 if failures.is_empty() else 1)


func check_lifecycle() -> void:
	root.size = Vector2i(1600, 900)
	var weak_stages: Array[WeakRef] = []
	for index in range(8):
		main.shell_view.show_title()
		await settle(8)
		var title: Control = main.screen_host.get_child(0)
		weak_stages.append(weakref(title.card_stage))
		var stage: Variant = title.card_stage
		var public_cards: Array[String] = ["svi-ente", "svi-ente", "missing", "svg2-tort", "sv2-grex", "sv1-151"]
		stage.set_cards(public_cards)
		await settle(5)
		check(stage.card_ids.size() == 3, "Showcase must cap valid unique public cards at three")
		main.shell_view.show_deck_select("local")
		await settle(8)
		report.lifecycle.append({"cycle": index,
			"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			"texture_bytes": int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))})
	for reference in weak_stages:
		check(reference.get_ref() == null, "Leaving title leaked a showcase or viewport")
	var first: Dictionary = report.lifecycle[2]
	var last: Dictionary = report.lifecycle[-1]
	check(int(last.nodes) <= int(first.nodes) + 2, "Repeated navigation accumulated nodes")
	check(int(last.texture_bytes) <= int(first.texture_bytes) + 1024 * 1024,
		"Repeated navigation accumulated texture memory after warmup")
	check(int(settings.get("_battle_owner")) == 0, "Frontend claimed the battle quality lifecycle")
	print("FRONTEND_LIFECYCLE_CHECKED")


func measure_performance() -> void:
	root.size = Vector2i(1600, 900)
	main.shell_view.show_title()
	settings.animation_mode = "standard"
	settings.reduced_motion = false
	for profile in ["high", "medium", "low"]:
		settings.quality_profile = profile
		settings.changed.emit()
		Engine.max_fps = settings.target_fps()
		await settle(Engine.max_fps * 5)
		var frames: Array[float] = []
		var previous := Time.get_ticks_usec()
		var drawn := Engine.get_frames_drawn()
		for index in range(Engine.max_fps * 5):
			await process_frame
			await RenderingServer.frame_post_draw
			var now := Time.get_ticks_usec()
			frames.append(float(now - previous) / 1000.0)
			previous = now
		frames.sort()
		var title: Control = main.screen_host.get_child(0)
		var row: Dictionary = title.card_stage.stats()
		row["p50_ms"] = frames[frames.size() / 2]
		row["p95_ms"] = frames[ceili(frames.size() * 0.95) - 1]
		row["target_fps"] = Engine.max_fps
		row["rendered_frames"] = Engine.get_frames_drawn() - drawn
		row["texture_bytes"] = int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
		row["nodes"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		row["passes_budget"] = row.p95_ms <= (36.0 if profile == "low" else 20.0)
		report.profiles.append(row)
		check(row.passes_budget, "Homepage frame budget exceeded: " + JSON.stringify(row))
		print("FRONTEND_FRAME_PROFILE ", JSON.stringify(row))
