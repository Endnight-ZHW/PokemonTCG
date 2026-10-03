extends SceneTree

var failures: Array[String] = []
var report := {"gray_samples": [], "shuffle_frames": 0, "max_packet_layers": 0.0}
const SYMMETRY = preload("res://tests/battle_3d_symmetry_checks.gd")
const REVEALS = preload("res://tests/battle_3d_reveal_checks.gd")
const MOTIONS = preload("res://tests/battle_3d_motion_checks.gd")

func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value and message not in failures:
		failures.append(message)

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Visual contract requires a graphics display")
		quit(1)
		return
	Engine.max_fps = 60
	report["mode"] = "layout_only" if "--layout-only" in OS.get_cmdline_user_args() else "full"
	Input.warp_mouse(Vector2(2, 2))
	await _check_ink_values()
	await _check_startup_and_alignment()
	var output := FileAccess.open("res://../build/battle3d-visual-contract.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t"))
	for failure in failures:
		push_error(failure)
	if failures.is_empty(): print("BATTLE_3D_VISUAL_CONTRACT_OK")
	quit(0 if failures.is_empty() else 1)

func _check_ink_values() -> void:
	root.size = Vector2i(900, 540)
	var container := SubViewportContainer.new()
	container.stretch = true
	root.add_child(container)
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	container.add_child(viewport)
	var world := BattleWorld3D.new()
	viewport.add_child(world)
	await process_frame
	world.resize(viewport, container.size)
	var card := world.acquire("ink_probe")
	card.transform = world.projection.pose_for_screen(container.size * 0.5, 250, 0, 0.1)
	var baseline: Dictionary = {}
	for quality in ["high", "medium", "low"]:
		world.apply_quality(quality, viewport)
		for ink in [0.1, 0.5, 0.9]:
			var source := Image.create(8, 8, false, Image.FORMAT_RGBA8)
			source.fill(Color(ink, ink, ink))
			card.set_surface(ImageTexture.create_from_image(source))
			for frame in range(4): await process_frame
			await RenderingServer.frame_post_draw
			var sample := viewport.get_texture().get_image().get_pixel(viewport.size.x / 2, viewport.size.y / 2)
			report.gray_samples.append({"quality": quality, "source": ink, "rendered": [sample.r, sample.g, sample.b]})
			check(absf(sample.r - ink) < 0.08 and absf(sample.b - ink) < 0.08, "Lighting changes printed gray values or clips ink contrast")
			if ink == 0.5: check(sample.r < 0.55, "50% gray is washed out by the lighting passes")
			if quality == "high": baseline[ink] = sample
			else: check(absf(sample.r - (baseline[ink] as Color).r) < 0.025, "Changing shadow quality changes card brightness")
	container.queue_free()
	await process_frame

func _check_startup_and_alignment() -> void:
	var settings := root.get_node("AppSettings")
	settings.animation_mode = "standard"
	settings.quality_profile = "high"
	report["raster_sizes"] = []
	report["symmetry"] = []
	report["hand_layout"] = []
	report["pile_faces"] = []
	for resolution in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(900, 540), Vector2i(2000, 900), Vector2i(2560, 1392)]:
		root.size = resolution
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		root.content_scale_size = Vector2i(1600, 900) if resolution.x == 2560 else resolution
		var table := preload("res://scenes/battle/components/battle_table.tscn").instantiate() as BattleTable
		root.add_child(table)
		var state := UIPreviewStateFactory.battle_stress_state()
		table.update_view(state, 0, [], "", false, "local")
		for frame in range(6): await process_frame
		var presenter := table.render3d
		check(presenter.viewport.size == presenter.render_pixel_size(), "3D buffer does not match the physical screen footprint")
		report.raster_sizes.append({"window": str(resolution), "logical": str(presenter.size), "buffer": str(presenter.viewport.size)})
		if resolution.x == 2560:
			check(presenter.viewport.size.x > presenter.size.x * 1.5, "High DPI rendering still upscales a logical-resolution texture")
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://../build/battle3d-sharp-2560.png")
		for index in range(5):
			var own := presenter.card_pose(table.own_bench[index])
			var opponent := presenter.card_pose(table.opponent_bench[index])
			var own_bounds := presenter.world.projection.project_pose_bounds(own)
			var opponent_bounds := presenter.world.projection.project_pose_bounds(opponent)
			check(absf(own_bounds.get_center().x - opponent_bounds.get_center().x) < 1.0, "Opposing bench columns are not visibly aligned")
			check(absf(own_bounds.size.x - opponent_bounds.size.x) < 1.0, "Opposing bench cards have different visible widths")
			var active_y := presenter.global_bounds(table.own_active).get_center().y + presenter.global_bounds(table.opponent_active).get_center().y
			var bench_y := presenter.global_bounds(table.own_bench[index]).get_center().y + presenter.global_bounds(table.opponent_bench[index]).get_center().y
			check(absf(active_y - bench_y) < 2.0, "Active and bench rows do not mirror about the same center line")
		for pair in [["own_deck", "opponent_deck"], ["own_discard", "opponent_discard"], ["own_prizes", "opponent_prizes"]]:
			var own := presenter.global_bounds(table.zones[pair[0]])
			var opponent := presenter.global_bounds(table.zones[pair[1]])
			if pair[0] == "own_prizes":
				own = presenter.world.projection.project_bounds(presenter.world.entities[presenter._key(table.zones[pair[0]], "0")])
				opponent = presenter.world.projection.project_bounds(presenter.world.entities[presenter._key(table.zones[pair[1]], "0")])
			check(absf(own.get_center().x - opponent.get_center().x) < 1.0, "Opposing pile columns are not visibly aligned")
		for hand in table.hand_views + table.opponent_hand_views:
			var entity := presenter.world.entities.get(presenter._key(hand)) as CardEntity3D
			check(entity != null and entity.visible and entity.body.visible and entity.body.mesh is ArrayMesh, "A hand card is missing its physical surface")
			check(hand.image.self_modulate.a == 0.0, "A hand is still drawing its 2D image")
		for scroll in [0, int(table.hand_scroll.get_h_scroll_bar().max_value)]:
			table.hand_scroll.scroll_horizontal = scroll
			presenter.sync_surfaces()
			for hand in table.hand_views:
				SYMMETRY.check_visible_hand(table, hand, check)
		for card in table.own_bench + table.opponent_bench:
			var bounds := presenter.global_bounds(card)
			for zone_name in ["own_deck", "opponent_deck", "own_discard", "opponent_discard"]:
				check(not bounds.intersects(presenter.global_bounds(table.zones[zone_name])), "A bench card overlaps a side pile")
		report.symmetry.append(SYMMETRY.layout_metrics(table, check).merged({"window": str(resolution)}))
		report.hand_layout.append((await SYMMETRY.check_hand_layout(self, table, check)).merged({"window": str(resolution)}))
		report.pile_faces.append((await SYMMETRY.check_pile_faces(self, table, check)).merged({"window": str(resolution)}))
		if "--layout-only" in OS.get_cmdline_user_args():
			table.queue_free()
			await process_frame
			await process_frame
			continue
		if resolution == Vector2i(1600, 900):
			report["hand_fans"] = await SYMMETRY.check_fans(self, table, check)
			report["reconciled_hand"] = await SYMMETRY.check_reconciled_hand(self, table, check)
			report["render_lifecycle"] = await _check_render_lifecycle(self, table, check)
			report["opening_draw"] = await REVEALS.check_draw(self, table, check)
			report["opponent_draw"] = await REVEALS.check_draw(self, table, check, 1)
			report["mulligan"] = await REVEALS.check_mulligan(self, table, check)
			report["mulligan_readability"] = await REVEALS.check_mulligan_readability(self, table, check)
			report["search_reveal"] = await REVEALS.check_search_reveal(self, table, check)
			report["card_transfers"] = await MOTIONS.check_transfers(self, table, check)
			report["shuffle_and_actions"] = await MOTIONS.check_shuffle_actions(self, table, check)
		var handle := table.play_startup_shuffle([1, 0])
		var frame_index := 0
		var saw_rotation := false
		while not handle.is_finished() and frame_index < 180:
			await process_frame
			frame_index += 1
			presenter.sync_surfaces()
			for motion in table.card_motion_layer.entities:
				if not motion.has_meta("shuffle_card") or not motion.visible: continue
				var card := motion as CardMotionEntity
				check(card != null and card.has_world_pose, "Shuffle still uses a 2D movement path")
				if card == null or card.physical_entity == null: continue
				saw_rotation = saw_rotation or absf(card.world_pose.basis.y.normalized().dot(Vector3.UP)) < 0.999
				report.max_packet_layers = maxf(report.max_packet_layers, card.physical_entity.paper_layers)
				check(Rect2(Vector2.ZERO, presenter.size).grow(1).encloses(presenter.world.projection.project_bounds(card.physical_entity)), "Opening shuffle packet is clipped by the viewport")
			if frame_index == 12 and resolution == Vector2i(1600, 900):
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png("res://../build/battle3d-startup-shuffle.png")
		check(saw_rotation and handle.is_finished(), "Opening shuffle never rotates physical packets or fails to finish")
		report.shuffle_frames += frame_index
		check(table._shuffle_source_masks.is_empty(), "Shuffle completion leaves a hidden deck")
		var cancelled := table.play_startup_shuffle()
		table.clear_presentation_for_resync()
		check(cancelled.is_finished() and table._shuffle_source_masks.is_empty(), "Resync leaves shuffle packets or masks behind")
		table.queue_free()
		await process_frame
		await process_frame
	if "--layout-only" not in OS.get_cmdline_user_args():
		check(report.max_packet_layers > 1.0, "Full decks still have single-card thickness")


## Check actual raster output. CPU transforms can be correct while deferred
## VisualInstance notifications leave a pooled mesh at the origin for one draw.
static func _check_render_lifecycle(tree: SceneTree, table: BattleTable, check_result: Callable) -> Dictionary:
	var lifecycle_report := {"rendered_frames": 0, "origin_pixels": 0, "marker_frames": 0}
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
			check_result.call(source._get_drag_data(Vector2.ZERO) == null and not tree.root.gui_is_dragging(), "Hand movement still starts a card drag")
			var start := table._effects_local(source.global_center())
			var flyer := table.motion_entities._spawn_flying_card(marker, start, table.size * Vector2(0.76, 0.76),
				0.35, 0, "pokemon_played", 0, source.size, source.size) as CardMotionEntity
			for frame in range(24): await _sample_lifecycle_frame(tree, table, lifecycle_report, check_result)
			if is_instance_valid(flyer): table.motion_entities._dispose_flyer(flyer)
			check_result.call(not source.is_presentation_hidden(), "Button action motion hid its hand source indefinitely")
	settings.animation_mode = "standard"
	# Allocate hidden flights first, then show them after a delay. Repeat with the
	# same object pool; check_result startup, every moving frame, disposal and cancellation.
	for cycle in range(4):
		var flyer := table.motion_entities._spawn_flying_card(marker, table.size * Vector2(0.77, 0.82), table.size * Vector2(0.26, 0.82),
			0.36, 0.08, "cards_drawn", 0) as CardMotionEntity
		for frame in range(36):
			if cycle == 3 and frame == 12: table.clear_presentation_for_resync()
			await _sample_lifecycle_frame(tree, table, lifecycle_report, check_result)
		if is_instance_valid(flyer): table.motion_entities._dispose_flyer(flyer)
		await _sample_lifecycle_frame(tree, table, lifecycle_report, check_result)
	check_result.call(lifecycle_report.marker_frames > 50, "Raster lifecycle check did not exercise visible motion cards")
	check_result.call(table.card_motion_layer.active_motion_count() == 0, "Raster lifecycle check leaves motion entities behind")
	table.clear_presentation_for_resync()
	return lifecycle_report

static func _sample_lifecycle_frame(tree: SceneTree, table: BattleTable, lifecycle_report: Dictionary, check_result: Callable) -> void:
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
	if center_marked > 0 and lifecycle_report.origin_pixels == 0:
		pixels.save_png("res://../build/battle3d-render-lifecycle-failure.png")
	check_result.call(center_marked == 0, "A motion card flashes at the world origin in a rendered frame")
	lifecycle_report.rendered_frames += 1
	lifecycle_report.origin_pixels += center_marked
	if marked > 25: lifecycle_report.marker_frames += 1
