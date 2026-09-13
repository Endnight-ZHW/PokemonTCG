extends RefCounted

static func layout_metrics(table: BattleTable, check: Callable) -> Dictionary:
	var p := table.render3d
	check.call(not table.zones["stadium"].count_label.visible, "Stadium still displays a redundant count badge")
	var report := {"width_error": 0.0, "height_error": 0.0, "gap_error": 0.0, "pile_width_error": 0.0, "pile_height_error": 0.0}
	var own_active := p.global_bounds(table.own_active)
	var opponent_active := p.global_bounds(table.opponent_active)
	for pair in [[table.own_active, table.opponent_active]] + _bench_pairs(table):
		var a := p.global_bounds(pair[0])
		var b := p.global_bounds(pair[1])
		report.width_error = maxf(report.width_error, absf(a.size.x - b.size.x))
		report.height_error = maxf(report.height_error, absf(a.size.y - b.size.y))
		check.call(pair[0].self_modulate.a == 0 and pair[1].self_modulate.a == 0,
			"Legacy 2D card panels draw over the physical playing areas")
	for index in range(5):
		var own := p.global_bounds(table.own_bench[index])
		var opponent := p.global_bounds(table.opponent_bench[index])
		var near_gap := own.position.y - own_active.end.y
		var far_gap := opponent_active.position.y - opponent.end.y
		report.gap_error = maxf(report.gap_error, absf(near_gap - far_gap))
	for pair in [["own_deck", "opponent_deck"], ["own_discard", "opponent_discard"]]:
		if table.zones[pair[0]].count != table.zones[pair[1]].count: continue
		var a := p.global_bounds(table.zones[pair[0]])
		var b := p.global_bounds(table.zones[pair[1]])
		report.pile_width_error = maxf(report.pile_width_error, absf(a.size.x - b.size.x))
		report.pile_height_error = maxf(report.pile_height_error, absf(a.size.y - b.size.y))
	for key in report:
		check.call(report[key] < 1.0, "Projected symmetry differs by more than one pixel: %s=%s" % [key, report[key]])
	return report

static func _bench_pairs(table: BattleTable) -> Array:
	var result: Array = []
	for index in range(5): result.append([table.own_bench[index], table.opponent_bench[index]])
	return result

static func check_fans(tree: SceneTree, table: BattleTable, check: Callable) -> Array:
	var result: Array = []
	for count in [5, 7, 10, 20]:
		var state := UIPreviewStateFactory.battle_state()
		state.players[0].hand.clear()
		for index in range(count): state.players[0].hand.append("sv1-151")
		table.update_view(state, 0, [], "", false, "local")
		for frame in range(4): await tree.process_frame
		table.hand_scroll.scroll_horizontal = roundi(maxf(0, table.hand_surface.custom_minimum_size.x - table.hand_scroll.size.x) * 0.5)
		table.render3d.sync_surfaces()
		var previous := Vector2.ZERO
		var gaps: Array[float] = []
		for index in range(count):
			var card := table.hand_views[index]
			var pose := table.render3d.card_pose(card)
			var point := table.render3d.world.projection.world_to_screen(pose.origin)
			if index > 0: gaps.append(point.x - previous.x)
			previous = point
		var ratio: float = gaps.max() / maxf(0.01, gaps.min())
		check.call(ratio < 1.12, "Resting fan has uneven neighbouring gaps: count=%d ratio=%s" % [count, ratio])
		check.call(table.render3d.hand_fan._radius <= BattleHandFan3D.REST_RADIUS + 0.01, "Hand fan exceeds its fitted radius")
		if count <= 7:
			check.call(table.render3d.hand_fan._radius > 9.0, "Ordinary hands do not use the gentler fan radius")
		result.append({"count": count, "gap_ratio": ratio, "radius": table.render3d.hand_fan._radius})
	return result

static func check_reconciled_hand(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
	table.clear_presentation_for_resync()
	table.update_view(GameState.new(), 0, [], "", false, "local")
	for frame in range(4): await tree.process_frame
	var pixels := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	pixels.fill(Color.MAGENTA)
	var marker := ImageTexture.create_from_image(pixels)
	_check_rigid_flip(table, marker, check)
	var total_origin := 0
	for count in [3, 4, 1, 6]:
		# Exercise the exact late-frame reconciliation path, including incremental
		# additions and pooled replacements. Node poses alone missed this artifact.
		var populate := func() -> void:
			table.hand_presentation._presentation_opponent_hand_stage_count = count
			table.hand_presentation._sync_opponent_hand_stage_visuals()
			for control in table.hand_presentation._presentation_opponent_hand_proxies:
				var card := control as CardMotionEntity
				check.call(card.has_world_pose and card.world_pose.origin.length() > 0.5,
					"A newly reconciled hand proxy starts at the world origin")
				card.texture = marker
			table.render3d.sync_surfaces()
		RenderingServer.frame_pre_draw.connect(populate, CONNECT_ONE_SHOT)
		await tree.process_frame
		await RenderingServer.frame_post_draw
		var image := table.render3d.viewport.get_texture().get_image()
		var origin := Vector2(image.get_size()) * 0.5
		var marked := 0
		var at_origin := 0
		for y in range(0, image.get_height(), 4):
			for x in range(0, image.get_width(), 4):
				var color := image.get_pixel(x, y)
				if color.r > 0.45 and color.b > 0.4 and color.g < 0.25:
					marked += 1
					if absf(x - origin.x) < 80 and absf(y - origin.y) < 90: at_origin += 1
		check.call(marked > 25, "Reconciliation pixel check did not render its marker cards")
		check.call(at_origin == 0, "A card flashes at the center of the actual rendered image")
		total_origin += at_origin
		for frame in range(15): await tree.process_frame
	table.clear_presentation_for_resync()
	check.call(table.hand_presentation._presentation_opponent_hand_proxies.is_empty(), "Resync leaves opponent hand proxies alive")
	return {"origin_pixels": total_origin, "cases": 4}

static func _check_rigid_flip(table: BattleTable, marker: Texture2D, check: Callable) -> void:
	var proxy := table.motion_entities._create_paper_card_token(CardEntity3D.BACK, Vector2(100, 140), "FlipDimensionProbe", 100) as CardMotionEntity
	proxy.world_pose = table.render3d.zone_pose(table.zones["own_deck"])
	proxy.has_world_pose = true
	proxy.set_meta("physical_flip_source", CardEntity3D.BACK)
	proxy.set_meta("motion_flip_texture", marker)
	table.effects.add_child(proxy)
	var original_size := proxy.world_pose.basis.get_scale()
	for phase in [0.0, 0.25, 0.5, 0.75, 1.0]:
		proxy.set_meta("physical_flip_progress", phase)
		table.render3d._sync_token(proxy)
		check.call(proxy.physical_entity.basis.get_scale().distance_to(original_size) < 0.001,
			"Flipping changes the calibrated physical card dimensions")
	table.motion_entities._dispose_flyer(proxy)
