extends SceneTree

var _failures: Array[String] = []
const TABLE: PackedScene = preload("res://scenes/battle/components/battle_table.tscn")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var settings := root.get_node("AppSettings")
	settings.animation_mode = "standard"
	settings.reduced_motion = false
	root.size = Vector2i(1600, 900)
	var table := TABLE.instantiate() as BattleTable
	root.add_child(table)
	var state := UIPreviewStateFactory.battle_state()
	table.update_view(state, 0, UIPreviewStateFactory.action_rows(state), "", false, "local")
	for i in range(4):
		await process_frame
	var presenter := table.render3d
	_expect(presenter != null and presenter.is_projection_ready(), "3D viewport did not initialize")
	if presenter == null or not presenter.is_projection_ready():
		_finish()
		return
	_expect(presenter.viewport.own_world_3d, "Battle shares a World3D with unrelated previews")
	_expect(presenter.world.camera.projection == Camera3D.PROJECTION_PERSPECTIVE, "Table camera is not perspective")
	for resolution in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(900, 540), Vector2i(2000, 900)]:
		root.size = resolution
		for i in range(3):
			await process_frame
		presenter.sync_surfaces()
		var projection := presenter.world.projection
		var point := Vector2(resolution) * Vector2(0.52, 0.54)
		var roundtrip := projection.world_to_screen(projection.screen_to_world(point, 0.3))
		_expect(point.distance_to(roundtrip) < 0.1, "Projection roundtrip failed at %s" % resolution)
		var center := table.get_global_transform_with_canvas().affine_inverse() * table.own_active.global_center()
		_expect(presenter.pick(center) == table.own_active, "Ray picked a different card at %s" % resolution)
		for quality in ["high", "medium", "low"]:
			presenter.world.apply_quality(quality, presenter.viewport)
			_expect(presenter.pick(center) == table.own_active, "Render scale changed input coordinates: %s" % quality)
	for card in table.opponent_hand_views:
		var key := presenter._key(card)
		var entity := presenter.world.entities.get(key) as CardEntity3D
		if entity != null:
			_expect(entity.face_down and entity.face_texture == null, "Opponent's hidden hand retained a face texture")
	var active := presenter.world.entities.get(presenter._key(table.own_active)) as CardEntity3D
	var visible_bounds := table.own_active.visual_global_bounds()
	table.own_active.set_presentation_hidden(true)
	var masked_bounds := table.own_active.visual_global_bounds()
	_expect(visible_bounds.is_equal_approx(masked_bounds), "Masking a landing destination changed its physical geometry")
	table.own_active.set_presentation_hidden(false)
	preload("res://tests/battle_3d_interaction_checks.gd").run(table, _expect)
	await preload("res://tests/battle_3d_interaction_checks.gd").check_layouts(table, _expect)
	table.update_view(state, 0, UIPreviewStateFactory.action_rows(state), "", false, "local")
	for frame in range(4):
		await process_frame
	_expect(active != null and active.body.mesh.get_aabb().size.y >= CardEntity3D.THICKNESS * 0.99, "Card has no physical thickness")
	if active != null:
		var colors: PackedColorArray = active.body.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		_expect(Color.RED in colors and Color.GREEN in colors and Color.BLUE in colors, "Card lacks front, reverse or paper-edge geometry")
	var before_count := presenter.world.entities.size()
	for i in range(120):
		presenter.world.acquire("pool-contract:%d" % i)
	for i in range(120):
		presenter.world.release_entity("pool-contract:%d" % i)
	_expect(presenter.world._pool.size() <= BattleWorld3D.POOL_LIMIT, "Card pool grew beyond its bound")
	_expect(presenter.world.entities.size() == before_count, "Released cards remain in the entity registry")
	for recycled in presenter.world._pool:
		_expect(recycled.face_texture == null and recycled._front.get_shader_parameter("face_image") == null, "Pool retained a private texture")
	table.set_local_hand_privacy_hidden(true)
	_expect(presenter.world.entities.is_empty(), "Handoff did not clear previous player's physical entities immediately")
	table.set_local_hand_privacy_hidden(false)
	presenter.sync_surfaces()
	var texture := table.hand_views[0].image.texture
	var flyer := table.motion_entities._spawn_flying_card(texture, Vector2(900, 150), Vector2(700, 650),
		0.4, 0.0, "cards_drawn", 0, Vector2(100, 140), Vector2(100, 140)) as CardMotionEntity
	await create_timer(0.15).timeout
	presenter.sync_surfaces()
	_expect(flyer != null and flyer.has_world_pose and flyer.physical_entity != null, "Card flight did not produce a physical entity")
	if flyer != null:
		_expect(flyer.world_pose.origin.y > 0.2, "Card flight has no physical lift")
		table.motion_entities._clear_active_flyers()
		_expect(table.card_motion_layer.active_motion_count() == 0, "Resync left a flight alive")
	for heads in [true, false]:
		presenter.world.coin.pose_for_toss(presenter.world.projection, Vector2(600, 300), 100, 1.0, heads, not heads, false)
		_expect(presenter.world.coin.result_heads == heads, "Coin changed an authoritative result")
		var normal := presenter.world.coin.transform.basis.y.normalized()
		_expect((normal.y > 0.0) == heads, "Coin's visible physical face disagrees with the result")
	await preload("res://tests/battle_3d_lifecycle_review_checks.gd").run(table, _expect)
	_test_auto_quality(settings)
	table.queue_free()
	await process_frame
	await process_frame
	var baseline := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	for iteration in range(6):
		var next := TABLE.instantiate() as BattleTable
		root.add_child(next)
		next.update_view(state, 0, UIPreviewStateFactory.action_rows(state), "", false, "local")
		for frame in range(4):
			await process_frame
		var preflight := MotionHandle.new()
		next.presentation_coordinator.set_preflight(preflight)
		next.queue_free()
		await process_frame
		await process_frame
		_expect(preflight.status == MotionHandle.CANCELLED, "Exiting left an asset preflight alive")
		_expect(int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) <= baseline + 2, "Repeated battle exits leaked nodes at iteration %d" % iteration)
	_finish()


func _test_auto_quality(settings: Node) -> void:
	settings.quality_profile = "auto"
	settings.begin_battle_quality(987654)
	settings.set("_battle_auto_profile", "medium")
	settings.reset_battle_frame_samples()
	for i in range(1000):
		settings.record_battle_frame(0.025, false)
	_expect(settings.resolved_quality_profile() == "medium", "Quality changed during an active motion")
	settings.record_battle_frame(0.025, true)
	_expect(settings.resolved_quality_profile() == "low" and settings.target_fps() == 30, "Sustained slow frames did not trigger the 30 FPS profile")
	_expect(settings.quality_profile == "auto", "Auto downgrade overwrote the saved preference")
	for i in range(1500):
		settings.record_battle_frame(0.01, true)
	_expect(settings.resolved_quality_profile() == "low", "Quality oscillated upward in the same match")
	settings.quality_profile = "high"
	for i in range(1000):
		settings.record_battle_frame(0.1, true)
	_expect(settings.resolved_quality_profile() == "high", "Automatic policy overrode manual quality")
	settings.end_battle_quality(987654)
	settings.reset_defaults()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	for message in _failures:
		push_error(message)
	if _failures.is_empty():
		print("BATTLE_3D_CONTRACT_OK")
	quit(0 if _failures.is_empty() else 1)
