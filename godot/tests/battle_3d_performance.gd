extends SceneTree

## This probe requires actual graphics. Headless timings cannot pass GPU acceptance.
const TABLE: PackedScene = preload("res://scenes/battle/components/battle_table.tscn")
var _report := {"schema": "ptcg.battle3d_performance/1", "profiles": []}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Battle 3D performance requires a graphics display")
		quit(1)
		return
	root.size = Vector2i(1920, 1080)
	_report["godot"] = Engine.get_version_info().string
	_report["gpu"] = RenderingServer.get_video_adapter_name()
	_report["renderer"] = RenderingServer.get_current_rendering_method()
	var settings := root.get_node("AppSettings")
	settings.reset_defaults(false)
	settings.animation_mode = "standard"
	var table := TABLE.instantiate() as BattleTable
	root.add_child(table)
	var state := UIPreviewStateFactory.battle_state()
	for player in state.players:
		for i in range(5):
			player.bench[i] = PokemonState.new("svi-chim")
			player.bench[i].energy_card_ids.assign(["sv1-ener-2", "sv1-ener-2", "sv1-ener-2"])
	for i in range(15):
		state.players[0].hand.append("svi-chim" if i % 2 == 0 else "sv1-ener-2")
	state.players[1].hand.assign(state.players[0].hand)
	_report["hand_counts"] = [state.players[0].hand.size(), state.players[1].hand.size()]
	table.update_view(state, 0, UIPreviewStateFactory.action_rows(state), "", false, "local")
	await create_timer(5.0).timeout
	table.render3d.viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	for quality in ["high", "medium", "low"]:
		settings.quality_profile = quality
		settings.changed.emit()
		Engine.max_fps = settings.target_fps()
		await create_timer(2.0).timeout
		var frames: Array[float] = []
		var drawn_before := Engine.get_frames_drawn()
		var previous := Time.get_ticks_usec()
		for i in range(300):
			if i % 60 == 0:
				table.world_feedback.burst(Vector2(800, 500), Color("72bfac"), "impact")
				for n in range(4):
					table.motion_entities._spawn_flying_card(table.hand_views[0].image.texture,
						Vector2(1200, 180 + n * 15), Vector2(650 + n * 50, 800), 0.45,
						n * 0.06, "cards_drawn", n, Vector2(100, 140), Vector2(100, 140))
			await process_frame
			await RenderingServer.frame_post_draw
			var now := Time.get_ticks_usec()
			frames.append(float(now - previous) / 1000.0)
			previous = now
		frames.sort()
		var row := table.render3d.stats()
		row["profile"] = quality
		row["rendered_frames"] = Engine.get_frames_drawn() - drawn_before
		row["shadow_enabled"] = table.render3d.world.key_light.shadow_enabled
		row["p50_ms"] = frames[frames.size() / 2]
		row["p95_ms"] = frames[ceili(frames.size() * 0.95) - 1]
		row["max_ms"] = frames[-1]
		row["target_fps"] = settings.target_fps()
		row["passes_budget"] = row.p95_ms <= (36.0 if quality == "low" else 20.0)
		row["nodes"] = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
		row["texture_bytes"] = int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
		_report.profiles.append(row)
		table.motion_entities._clear_active_flyers()
		table.render3d.world.feedback.clear()
	var output := ProjectSettings.globalize_path("res://../build/battle3d-performance.json")
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(_report, "\t"))
	file.close()
	print("BATTLE_3D_PERFORMANCE_JSON=" + JSON.stringify(_report))
	table.queue_free()
	await process_frame
	quit(0)
