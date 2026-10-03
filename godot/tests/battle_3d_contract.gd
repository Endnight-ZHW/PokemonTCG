extends SceneTree

var _failures: Array[String] = []
const TABLE: PackedScene = preload("res://scenes/battle/components/battle_table.tscn")
const SYMMETRY = preload("res://tests/battle_3d_symmetry_checks.gd")
var _done := false


func _initialize() -> void:
	preload("res://tests/graphics_test_driver.gd").attach(self)
	call_deferred("_run")
	call_deferred("_watchdog")


func _run() -> void:
	await _check_hand_distribution()
	var settings := root.get_node("AppSettings")
	settings.animation_mode = "standard"
	root.size = Vector2i(1600, 900)
	# Resting-geometry checks must not inherit a hover from the previous window.
	if DisplayServer.get_name() != "headless": Input.warp_mouse(Vector2(2, 2))
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
	await _check_ai_highlights(table)
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
	await _check_lifecycle(table, _expect)
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


func _check_ai_highlights(table: BattleTable) -> void:
	Input.warp_mouse(Vector2(2, 2))
	var old_size := root.size
	var old_scale_size := root.content_scale_size
	var old_scale_mode := root.content_scale_mode
	var settings := root.get_node("AppSettings")
	var old_mode: String = settings.animation_mode
	var old_quality: String = settings.quality_profile
	var state := UIPreviewStateFactory.battle_state()
	for player in state.players:
		for index in range(5): player.bench[index] = null
		player.bench[0] = PokemonState.new("svi-chim")
		player.bench[2] = PokemonState.new("svi-hrot")
	var p := table.render3d
	for dimensions in [Vector2i(1600, 900), Vector2i(1280, 720), Vector2i(900, 540), Vector2i(2000, 900), Vector2i(2560, 1392)]:
		root.size = dimensions
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		root.content_scale_size = Vector2i(1600, 900) if dimensions.x == 2560 else dimensions
		for reduced in [false, true]:
			settings.set("animation_mode", "reduced" if reduced else "standard")
			settings.quality_profile = "low" if reduced else "high"
			# Both absolute player identities and an AI viewed from its own side.
			for case in [{"view": 0, "mode": "challenge", "ai": 1}, {"view": 1, "mode": "local", "ai": 0}, {"view": 1, "mode": "challenge", "ai": 1}]:
				state.active_player_idx = case.ai
				table.update_view(state, case.view, [], "", true, case.mode)
				for frame in range(3): await process_frame
				p.sync_surfaces()
				var overlay := table.ai_thinking_overlay
				_expect(overlay.active and overlay.card_highlights_in_3d and overlay.slot_rects.is_empty(),
					"AI thinking still paints a second set of 2D slot shadows")
				_expect(overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE, "AI thinking intercepts card inspection input")
				for card in table.slot_views.values():
					var entity := p.world.entities.get(p._key(card)) as CardEntity3D
					_expect(entity != null, "AI highlight check lost a field card")
					if entity == null: continue
					var expected := overlay.card_highlight_color() if card.owner_player == case.ai else Color.TRANSPARENT
					if card.empty:
						_expect(entity._outline_tint == DesignTokens.TABLE_STITCH, "AI adds a thinking shadow to an empty slot")
					elif card.owner_player == case.ai:
						_expect(entity.outline.visible and entity._outline_tint.is_equal_approx(expected), "AI thinking highlights the wrong player's cards")
						_check_ai_border_pose(p, entity)
					else:
						_expect(not entity.outline.visible, "AI thinking highlights a spectator's card")
				var source := table.get_slot_view(case.ai, "active")
				var source_entity := p.world.entities[p._key(source)] as CardEntity3D
				source.set_selected(true)
				p.sync_surfaces()
				_expect(source_entity._outline_tint == DesignTokens.STATE_SELECTED, "AI tint overrides a selected card")
				source.set_selected(false)
				source.set_targetable(true)
				p.sync_surfaces()
				_expect(source_entity._outline_tint == DesignTokens.STATE_TARGET, "AI tint overrides a legal target")
				source.set_targetable(false)
				# Move the physical pose without changing its legacy Control rectangle.
				var displaced := source_entity.transform
				displaced.origin += Vector3(0.25, 0.3, -0.2)
				displaced.basis = BattleProjection3D.rotate_card_basis(displaced.basis, Basis(Vector3.UP, 0.12))
				source.set_meta("physical_pose", displaced)
				p.sync_surfaces()
				_check_ai_border_pose(p, source_entity)
				source.remove_meta("physical_pose")
				source.set_presentation_hidden(true)
				p.sync_surfaces()
				_expect(not source_entity.outline.is_visible_in_tree(), "A masked AI card leaves its thinking highlight behind")
				source.set_presentation_hidden(false)
				var tint := overlay.card_highlight_color()
				overlay._time += 0.6
				if reduced:
					_expect(tint == overlay.card_highlight_color(), "Reduced motion still pulses the AI highlight")
				table.update_view(state, case.view, [], "", false, case.mode)
				p.sync_surfaces()
				_expect(not overlay.visible and not source_entity.outline.visible, "Completed AI thinking leaves a stale highlight")
	root.size = old_size
	root.content_scale_size = old_scale_size
	root.content_scale_mode = old_scale_mode
	settings.animation_mode = old_mode
	settings.quality_profile = old_quality
	for frame in range(3): await process_frame


func _check_ai_border_pose(p: Battle3DPresenter, entity: CardEntity3D) -> void:
	var face := p.world.projection.project_pose_bounds(entity.global_transform)
	var border := p.world.projection.project_pose_bounds(entity.outline.global_transform)
	_expect(face.get_center().distance_to(border.get_center()) < 1.0 and face.size.distance_to(border.size) < 1.0,
		"AI thinking outline does not follow the rendered card's pose")


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
	_done = true
	for message in _failures:
		push_error(message)
	if _failures.is_empty():
		print("BATTLE_3D_CONTRACT_OK")
	quit(0 if _failures.is_empty() else 1)


func _watchdog() -> void:
	await create_timer(180.0).timeout
	if not _done:
		push_error("3D and hand layout contract timed out")
		quit(1)


func _check_hand_distribution() -> void:
	var previous_size := root.size
	var previous_scale := root.content_scale_size
	var previous_fps := Engine.max_fps
	var settings := root.get_node("AppSettings")
	var previous_mode := str(settings.animation_mode)
	var previous_failures := _failures.size()
	var rows: Array[Dictionary] = []
	Engine.max_fps = 60
	root.get_node("AppSettings").animation_mode = "standard"
	var table := TABLE.instantiate() as BattleTable
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
					_expect(gaps.min() > 0.0, "Hand cards collapse or reverse while browsing: %s count=%d" % [dimensions, count])
					var ratio: float = gaps.max() / maxf(0.01, gaps.min())
					worst_ratio = maxf(worst_ratio, ratio)
					_expect(ratio < 1.065, "Hand spacing becomes uneven while browsing: %s count=%d ratio=%.4f" % [dimensions, count, ratio])
				_expect(bounds.position.x >= 12.0 and bounds.end.x <= table.size.x - 12.0, "Expanded hand leaves the horizontal viewport: %s count=%d" % [dimensions, count])
				_expect(absf(bounds.get_center().x - table.size.x * 0.5) < 2.0, "Expanded hand is not centered: %s count=%d" % [dimensions, count])
				for index in [0, count / 2, count - 1]:
					SYMMETRY.check_visible_hand(table, table.hand_views[index], _expect)
			if count >= 20:
				var available := table.render3d.layout.hand_area(true).size.x
				_expect(bounds.size.x >= available * 0.97, "Dense hand leaves usable side space empty: %s count=%d" % [dimensions, count])
				if dimensions.y > dimensions.x:
					_expect(bounds.size.x >= table.size.x * 0.90, "Portrait hand stays squeezed into the center")
			rows.append({"window": str(dimensions), "count": count, "span_px": bounds.size.x, "worst_gap_ratio": worst_ratio})
			if DisplayServer.get_name() != "headless" and count in [5, 10, 20]:
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(output.path_join("hand-%dx%d-%02d.png" % [dimensions.x, dimensions.y, count]))
	var file := FileAccess.open(output.path_join("metrics.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(rows, "\t"))
	table.queue_free()
	await process_frame
	root.size = previous_size
	root.content_scale_size = previous_scale
	Engine.max_fps = previous_fps
	settings.animation_mode = previous_mode
	await process_frame
	if _failures.size() == previous_failures:
		print("BATTLE_HAND_DISTRIBUTION_OK layouts=36 browsing_positions=108")


static func _check_lifecycle(table: BattleTable, check: Callable) -> void:
	var tree := table.get_tree()
	var settings := tree.root.get_node("AppSettings")
	settings.quality_profile = "auto"
	settings.begin_battle_quality(table.render3d.get_instance_id())
	settings.set("_battle_auto_profile", "low")
	table.hide()
	await tree.process_frame
	check.call(table.render3d.viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED,
		"A hidden table continues updating its 3D viewport")
	table.show()
	await tree.process_frame
	check.call(settings.resolved_quality_profile() == "low",
		"Hiding and restoring the same battle resets its automatic quality downgrade")
	check.call(settings.quality_profile == "auto", "Visibility changes overwrite the saved quality preference")

	# An empty view makes asset prefetch synchronous, exposing cancellation that
	# happens inside transition_started rather than during an awaited animation.
	var state := GameState.new()
	state.revision = 10
	table.update_view(state, 0, [], "", false, "local")
	var next_state := state.clone_state()
	next_state.revision = 11
	var view := BattleViewModel.capture(next_state, 0, [], "", false, "local")
	var coordinator := table.presentation_coordinator
	coordinator.transition_started.connect(func(_handle: PresentationHandle) -> void:
		coordinator.cancel_all("cancel_in_started_signal"), CONNECT_ONE_SHOT)
	var handle := coordinator.submit(BattleTransitionRequest.create(view))
	for frame in range(3):
		await tree.process_frame
	check.call(handle.is_completed() and handle.completion_reason == "cancel_in_started_signal",
		"Cancellation during transition_started did not resolve its completion handle")
	check.call(table.state_ref.revision == 10,
		"A cancelled transition still overwrites the rendered battle state")
	check.call(not coordinator.is_busy(), "Cancellation during transition_started leaves the queue blocked")
	var next_handle := coordinator.submit(BattleTransitionRequest.create(view))
	for frame in range(3):
		await tree.process_frame
	check.call(next_handle.status == PresentationHandle.COMPLETED and table.state_ref.revision == 11,
		"The queue cannot accept a new transition after cancellation during transition_started")
