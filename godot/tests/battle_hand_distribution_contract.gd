extends SceneTree

const TABLE: PackedScene = preload("res://scenes/battle/components/battle_table.tscn")
const SYMMETRY = preload("res://tests/battle_3d_symmetry_checks.gd")
var failures: Array[String] = []
var rows: Array[Dictionary] = []
var table: BattleTable
var done := false


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("_run")
	call_deferred("_watchdog")


func _watchdog() -> void:
	await create_timer(120.0).timeout
	if not done:
		push_error("Hand distribution contract timed out")
		quit(1)


func check(value: bool, message: String) -> void:
	if not value and message not in failures: failures.append(message)


func _run() -> void:
	Engine.max_fps = 60
	root.get_node("AppSettings").animation_mode = "standard"
	table = TABLE.instantiate() as BattleTable
	root.add_child(table)
	Input.warp_mouse(Vector2(2, 2))
	var output := ProjectSettings.globalize_path("res://../build/hand-layout/validated")
	DirAccess.make_dir_recursive_absolute(output)
	for dimensions in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(900, 540), Vector2i(640, 960), Vector2i(2000, 900), Vector2i(2560, 1392)]:
		root.size = dimensions
		# The high-DPI case uses the game's normal logical canvas.
		root.content_scale_size = Vector2i(1600, 900) if dimensions.x == 2560 else dimensions
		for count in [1, 5, 7, 10, 20, 40]:
			var state := UIPreviewStateFactory.battle_state()
			state.players[0].hand.clear()
			state.players[1].hand.clear()
			for index in range(count):
				state.players[0].hand.append(["sv1-ener-1", "svi-chim", "sv1-151", "sv1-189", "svf-potion", "sv1-180", "sv1-171"][index % 7])
				state.players[1].hand.append("sv1-151")
			table.update_view(state, 0, [], "", false, "local")
			for frame in range(6): await process_frame
			var maximum := maxi(0, roundi(table.hand_surface.custom_minimum_size.x - table.hand_scroll.size.x))
			var worst_ratio := 1.0
			var bounds := Rect2()
			for scroll in [0, maximum, maximum / 2]:
				table.hand_scroll.scroll_horizontal = scroll
				table.render3d.sync_surfaces()
				var centers: Array[float] = []
				bounds = Rect2()
				for card in table.hand_views:
					if not card.visible: continue
					var pose := table.render3d.card_pose(card)
					var rect := table.render3d.world.projection.project_pose_bounds(pose)
					bounds = rect if centers.is_empty() else bounds.merge(rect)
					centers.append(table.render3d.world.projection.world_to_screen(pose.origin).x)
				var gaps: Array[float] = []
				for index in range(1, centers.size()): gaps.append(centers[index] - centers[index - 1])
				if not gaps.is_empty():
					check(gaps.min() > 0.0, "Hand cards collapse or reverse while browsing: %s count=%d" % [dimensions, count])
					var ratio: float = gaps.max() / maxf(0.01, gaps.min())
					worst_ratio = maxf(worst_ratio, ratio)
					check(ratio < 1.065, "Hand spacing becomes uneven while browsing: %s count=%d ratio=%.4f" % [dimensions, count, ratio])
				check(bounds.position.x >= 12.0 and bounds.end.x <= table.size.x - 12.0, "Expanded hand leaves the horizontal viewport: %s count=%d" % [dimensions, count])
				check(absf(bounds.get_center().x - table.size.x * 0.5) < 2.0, "Expanded hand is not centered: %s count=%d" % [dimensions, count])
				for index in [0, count / 2, count - 1]:
					SYMMETRY.check_visible_hand(table, table.hand_views[index], check)
			if count >= 20:
				var available := table.render3d.layout.hand_area(true).size.x
				check(bounds.size.x >= available * 0.97, "Dense hand leaves usable side space empty: %s count=%d" % [dimensions, count])
				if dimensions.y > dimensions.x:
					check(bounds.size.x >= table.size.x * 0.90, "Portrait hand stays squeezed into the center")
			rows.append({"window": str(dimensions), "count": count, "span_px": bounds.size.x, "worst_gap_ratio": worst_ratio})
			if DisplayServer.get_name() != "headless" and count in [5, 10, 20]:
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(output.path_join("hand-%dx%d-%02d.png" % [dimensions.x, dimensions.y, count]))
	var file := FileAccess.open(output.path_join("metrics.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(rows, "\t"))
	table.queue_free()
	await process_frame
	done = true
	for failure in failures: push_error(failure)
	if failures.is_empty(): print("BATTLE_HAND_DISTRIBUTION_OK layouts=36 browsing_positions=108")
	quit(0 if failures.is_empty() else 1)
