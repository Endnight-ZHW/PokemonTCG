extends RefCounted

## Check actual raster output. CPU transforms can be correct while deferred
## VisualInstance notifications leave a pooled mesh at the origin for one draw.
static func run(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
	var report := {"rendered_frames": 0, "origin_pixels": 0, "marker_frames": 0}
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
		for index in [0, 6]:
			var source := table.hand_views[index]
			check.call(source._get_drag_data(Vector2.ZERO) == null and not tree.root.gui_is_dragging(), "Hand movement still starts a card drag")
			var start := table._effects_local(source.global_center())
			var flyer := table.motion_entities._spawn_flying_card(marker, start, table.size * Vector2(0.76, 0.76),
				0.35, 0, "pokemon_played", 0, source.size, source.size) as CardMotionEntity
			for frame in range(24): await _sample(tree, table, report, check)
			if is_instance_valid(flyer): table.motion_entities._dispose_flyer(flyer)
			check.call(not source.is_presentation_hidden(), "Button action motion hid its hand source indefinitely")
	settings.animation_mode = "standard"
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
	check.call(center_marked == 0, "A motion card flashes at the world origin in a rendered frame")
	report.rendered_frames += 1
	report.origin_pixels += center_marked
	if marked > 25: report.marker_frames += 1
