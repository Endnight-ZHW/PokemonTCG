extends RefCounted

## Check actual raster output. CPU transforms can be correct while deferred
## VisualInstance notifications leave a pooled mesh at the origin for one draw.
static func run(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
	var report := {"rendered_frames": 0, "origin_pixels": 0, "marker_frames": 0, "drag_tilt_degrees": 0.0, "return_gap_px": 0.0}
	table.clear_presentation_for_resync()
	var state := GameState.new()
	for index in range(7): state.players[0].hand.append("sv1-151")
	table.update_view(state, 0, [], "", false, "local")
	for frame in range(5): await tree.process_frame
	var pixels := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	pixels.fill(Color.MAGENTA)
	var marker := ImageTexture.create_from_image(pixels)
	var settings := tree.root.get_node("AppSettings")
	for mode in ["cinematic", "standard", "fast", "reduced"]:
		settings.animation_mode = mode
		settings.reduced_motion = mode == "reduced"
		for index in [0, 6]:
			var source := table.hand_views[index]
			source._press_position = source.size * 0.5
			table.hand_view._on_hand_drag_started(index)
			table.set_process(false) # The harness supplies deterministic pointer positions.
			var proxy := table._drag_session.proxy as CardMotionEntity
			proxy.texture = marker
			proxy.position = Vector2(table.size.x * 0.23, table.size.y * 0.66) - proxy.size * 0.5
			for frame in range(3): await _sample(tree, table, report, check)
			var tilt := rad_to_deg(acos(clampf(proxy.physical_entity.basis.y.normalized().dot(Vector3.UP), -1, 1)))
			report.drag_tilt_degrees = maxf(report.drag_tilt_degrees, tilt)
			check.call(tilt < 5.0 and absf(proxy.rotation_degrees) <= 3.01, "Held cards are too steeply tilted")
			if mode == "standard" and index == 0:
				proxy.texture = table.card_motion_layer._texture_for_card_id(source.card_id)
				await _sample(tree, table, report, check)
				tree.root.get_texture().get_image().save_png("res://../build/battle3d-drag-after.png")
				proxy.texture = marker
			if index == 0:
				table.hand_view._on_hand_drag_ended()
				var return_target := Transform3D.IDENTITY
				if mode != "reduced":
					check.call(proxy.has_world_pose, "Returning drag only animates its screen rectangle")
					return_target = proxy.target_pose
					var target_tilt := rad_to_deg(acos(clampf(return_target.basis.y.normalized().dot(Vector3.UP), -1, 1)))
					check.call(absf(target_tilt - 24.0) < 0.1, "Returning drag does not blend back into the hand fan")
				for frame in range(24): await _sample(tree, table, report, check)
				check.call(table._drag_session == null, "Cancelled drag does not return and release its entity")
				if mode != "reduced":
					var projection := table.render3d.world.projection
					var target_bounds := projection.project_pose_bounds(return_target)
					var final_bounds := projection.project_pose_bounds(table.render3d.card_pose(source))
					var gap := maxf(target_bounds.position.distance_to(final_bounds.position), target_bounds.end.distance_to(final_bounds.end))
					report.return_gap_px = maxf(report.return_gap_px, gap)
					check.call(gap < 1.0, "Returning drag snaps on its final handoff frame")
			else:
				table.mark_drag_pending("render-lifecycle:%s" % mode, true)
				var retained := proxy.physical_entity.transform
				var start := proxy.position + proxy.size * 0.5
				var flyer := table.motion_entities._spawn_flying_card(marker, start, Vector2(table.size.x * 0.76, table.size.y * 0.76),
					0.35, 0, "pokemon_played", 0, proxy.size, proxy.size, proxy.rotation_degrees, 0, null, proxy) as CardMotionEntity
				check.call(flyer == proxy and flyer.world_pose.is_equal_approx(retained), "Committing a drag replaces or resets its physical card")
				for frame in range(24): await _sample(tree, table, report, check)
				table.clear_pending_drag_immediately("resync")
				await _sample(tree, table, report, check)
			check.call(not source.is_drag_masked(), "Drag cleanup leaves its hand source hidden")
	settings.animation_mode = "standard"
	settings.reduced_motion = false
	# Allocate hidden flights first, then show them after a delay. Repeat with the
	# same object pool; check startup, every moving frame, disposal and cancellation.
	for cycle in range(4):
		var flyer := table.motion_entities._spawn_flying_card(marker, table.size * Vector2(0.77, 0.82), table.size * Vector2(0.26, 0.82),
			0.36, 0.08, "cards_drawn", 0) as CardMotionEntity
		for frame in range(36):
			if cycle == 3 and frame == 12: table.clear_presentation_for_resync()
			await _sample(tree, table, report, check)
		if is_instance_valid(flyer): table.motion_entities._dispose_flyer(flyer)
		await _sample(tree, table, report, check)
	check.call(report.marker_frames > 50, "Raster lifecycle check did not exercise visible motion cards")
	check.call(table.card_motion_layer.active_motion_count() == 0, "Raster lifecycle check leaves motion entities behind")
	table.clear_presentation_for_resync()
	return report

static func _sample(tree: SceneTree, table: BattleTable, report: Dictionary, check: Callable) -> void:
	await tree.process_frame
	await RenderingServer.frame_post_draw
	var pixels := table.render3d.viewport.get_texture().get_image()
	var origin := table.render3d.world.projection.world_to_screen(Vector3.ZERO) * Vector2(pixels.get_size()) / table.size
	var marked := 0
	var center_marked := 0
	for y in range(0, pixels.get_height(), 4):
		for x in range(0, pixels.get_width(), 4):
			var color := pixels.get_pixel(x, y)
			if color.r > 0.45 and color.b > 0.4 and color.g < 0.25:
				marked += 1
				if absf(x - origin.x) < 70 and absf(y - origin.y) < 70: center_marked += 1
	if center_marked > 0 and report.origin_pixels == 0:
		pixels.save_png("res://../build/battle3d-render-lifecycle-failure.png")
	check.call(center_marked == 0, "A drag or motion card flashes at the world origin in a rendered frame")
	report.rendered_frames += 1
	report.origin_pixels += center_marked
	if marked > 25: report.marker_frames += 1
