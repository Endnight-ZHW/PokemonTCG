extends RefCounted

static func layout_metrics(table: BattleTable, check: Callable) -> Dictionary:
	var p := table.render3d
	check.call(not table.zones["stadium"].count_label.visible, "Stadium still displays a redundant count badge")
	var report := {"width_error": 0.0, "height_error": 0.0, "gap_error": 0.0, "pile_width_error": 0.0, "pile_height_error": 0.0,
		"cloth_midline_error": 0.0, "pile_midline_error": 0.0}
	var cloth_center := table.get_global_transform_with_canvas() * p.world.playmat_center
	var own_active := p.global_bounds(table.own_active)
	var opponent_active := p.global_bounds(table.opponent_active)
	for pair in [[table.own_active, table.opponent_active]] + _bench_pairs(table):
		var a := p.global_bounds(pair[0])
		var b := p.global_bounds(pair[1])
		report.cloth_midline_error = maxf(report.cloth_midline_error,
			absf((a.get_center().y + b.get_center().y) * 0.5 - cloth_center.y))
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
	for pair in [["own_deck", "opponent_deck"], ["own_discard", "opponent_discard"], ["own_prizes", "opponent_prizes"]]:
		# Prize fans remain symmetric on the cloth. Deck/Discard are calibrated
		# by their visible faces so different card counts do not stagger the row.
		var own_zone := table.zones[pair[0]] as ZoneView
		var far_zone := table.zones[pair[1]] as ZoneView
		var prize := own_zone.stack_visual_mode == "prizes"
		var a := p.world.projection.project_pose_bounds(p.layout.zone_base(own_zone), 0.0 if prize else own_zone.count * CardEntity3D.THICKNESS)
		var b := p.world.projection.project_pose_bounds(p.layout.zone_base(far_zone), 0.0 if prize else far_zone.count * CardEntity3D.THICKNESS)
		report.pile_midline_error = maxf(report.pile_midline_error,
			absf((a.get_center().y + b.get_center().y) * 0.5 - p.world.playmat_center.y))
	for key in report:
		check.call(report[key] < 1.0, "Projected symmetry differs by more than one pixel: %s=%s" % [key, report[key]])
	return report

static func check_pile_faces(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
	var p := table.render3d
	var report := {"row_error": 0.0, "size_error": 0.0, "cases": 0}
	for counts in [[27, 17], [1, 0], [0, 60], [60, 1], [18, 18]]:
		var state := UIPreviewStateFactory.battle_state()
		for player in state.players:
			player.deck.clear()
			player.discard.clear()
			for index in range(counts[0]): player.deck.append("sv1-151")
			for index in range(counts[1]): player.discard.append("sv1-151")
		table.update_view(state, 0, [], "", false, "local")
		for frame in range(3): await tree.process_frame
		p.sync_surfaces()
		for side in ["own", "opponent"]:
			var deck := table.zones[side + "_deck"] as ZoneView
			var discard := table.zones[side + "_discard"] as ZoneView
			var a := p.world.projection.project_pose_bounds(p.layout.zone_base(deck), deck.count * CardEntity3D.THICKNESS)
			var b := p.world.projection.project_pose_bounds(p.layout.zone_base(discard), discard.count * CardEntity3D.THICKNESS)
			report.row_error = maxf(report.row_error, maxf(absf(a.position.y - b.position.y), absf(a.end.y - b.end.y)))
			report.size_error = maxf(report.size_error, (a.size - b.size).length())
			check.call(a.end.x < b.position.x, "Aligned piles overlap each other")
			report.cases += 1
	check.call(report.row_error < 1.0 and report.size_error < 1.0,
		"Different Deck/Discard counts shift their visible faces at %s: %s" % [p.size, report])
	return report

static func _bench_pairs(table: BattleTable) -> Array:
	var result: Array = []
	for index in range(5): result.append([table.own_bench[index], table.opponent_bench[index]])
	return result

static func check_hand_layout(tree: SceneTree, table: BattleTable, check: Callable) -> Dictionary:
	var p := table.render3d
	var report := {"position_error": 0.0, "size_error": 0.0, "silhouette_error": 0.0, "minimum_card_width": INF,
		"minimum_visible_height": INF, "minimum_visible_fraction": 1.0, "minimum_visibility_advantage": INF,
		"framing_offset": str(p.world.framing_offset), "counts": [1, 5, 7, 10, 20]}
	var viewport := Rect2(Vector2.ZERO, p.size)
	var to_table := table.get_global_transform_with_canvas().affine_inverse()
	for count in report.counts:
		var state := UIPreviewStateFactory.battle_state()
		state.players[0].hand.clear()
		state.players[1].hand.clear()
		for index in range(count):
			state.players[0].hand.append("sv1-151")
			state.players[1].hand.append("sv1-151")
		table.update_view(state, 0, [], "", false, "local")
		for frame in range(5): await tree.process_frame
		# Compare neutral fans; local browsing deliberately shifts retained cards.
		table.hand_scroll.scroll_horizontal = roundi(maxf(0.0,
			table.hand_surface.custom_minimum_size.x - table.hand_scroll.size.x) * 0.5)
		p.sync_surfaces()
		check.call(table.opponent_hand_views.filter(func(card: CardView) -> bool: return card.visible).size() == count,
			"Opponent hand silently caps its rendered card count")
		for index in range(count):
			var a := p.world.projection.project_pose_bounds(p.card_pose(table.hand_views[index]))
			var b := p.world.projection.project_pose_bounds(p.card_pose(table.opponent_hand_views[index]))
			report.position_error = maxf(report.position_error, (a.get_center() + b.get_center() - p.layout.hand_mirror_center() * 2.0).length())
			report.size_error = maxf(report.size_error, (a.size - b.size).length())
			var visible := a.intersection(viewport)
			var opponent_visible := b.intersection(viewport)
			var advantage := visible.size.y - opponent_visible.size.y
			report.minimum_visibility_advantage = minf(report.minimum_visibility_advantage, advantage)
			check.call(advantage >= -p.world.framing_offset.y * 1.8,
				"Framing does not expose more of the local hand than the opponent hand")
			check.call(opponent_visible.size.y >= 48.0, "Framing hides too much of an opponent card back")
			report.minimum_card_width = minf(report.minimum_card_width, a.size.x)
			report.minimum_visible_height = minf(report.minimum_visible_height, visible.size.y)
			report.minimum_visible_fraction = minf(report.minimum_visible_fraction, visible.size.y / a.size.y)
			check.call(a.end.y > p.size.y and b.position.y < 0.0,
				"Resting hands no longer dock beyond their respective screen edges")
			check_visible_hand(table, table.hand_views[index], check)
			for caption in [table.header.turn_label, table.header.task_hint_label]:
				check.call(not b.intersects(to_table * caption.get_global_rect()),
					"Top corner caption covers an opponent hand card")
			var entity := p.world.entities.get(p._key(table.opponent_hand_views[index])) as CardEntity3D
			check.call(entity != null and entity.face_down and entity.face_texture == null,
				"Symmetric opponent fan exposes a private face")
			var near_pose := p.card_pose(table.hand_views[index])
			var far_pose := p.card_pose(table.opponent_hand_views[index])
			for x in [-0.5, 0.5]:
				for z in [-CardEntity3D.ASPECT * 0.5, CardEntity3D.ASPECT * 0.5]:
					var corner := Vector3(x, CardEntity3D.THICKNESS * 0.5, z)
					var near_point := p.world.projection.world_to_screen(near_pose * corner)
					var far_point := p.world.projection.world_to_screen(far_pose * corner)
					report.silhouette_error = maxf(report.silhouette_error,
						(near_point + far_point - p.layout.hand_mirror_center() * 2.0).length())
					check.call((far_pose * corner).y > 0.05,
						"A large opponent hand card penetrates the tabletop")
			if index > 0:
				var pose := p.card_pose(table.opponent_hand_views[index])
				var previous := p.card_pose(table.opponent_hand_views[index - 1])
				var normal := pose.basis.y.normalized()
				var layer_gap := normal.dot(pose.origin - previous.origin)
				var paper_depth := (pose.basis.y.length() + previous.basis.y.length()) * CardEntity3D.THICKNESS * 0.5
				check.call(layer_gap > paper_depth,
					"Opponent hand layers intersect at %s, count=%d index=%d" % [p.size, count, index])
			for bench in table.own_bench + table.opponent_bench:
				var bounds := p.world.projection.project_pose_bounds(p.card_pose(bench))
				check.call(not a.intersects(bounds) and not b.intersects(bounds),
					"Enlarged field card overlaps a hand at %s, count=%d" % [p.size, count])
	check.call(report.position_error < 1.0 and report.size_error < 1.0 and report.silhouette_error < 1.0,
		"Opposing hands differ in projected size or placement at %s: %s" % [p.size, report])
	# Historical sizes must use the historical cloth center. Recentring the mat
	# for edge-docked hands must not silently redefine the enlargement baseline.
	var previous_center := p.size.y * 0.5255
	var previous_half := minf(previous_center - maxf(104.0, p.size.y * 0.14), p.size.y * 0.81 - previous_center)
	var previous_row := (previous_half * 2.0 - maxf(8.0, p.size.y * 0.014) * 3.0) * 0.5
	report["active_growth"] = p.layout.field_rect(table.own_active).size.y / (previous_row * 0.59)
	report["bench_growth"] = p.layout.field_rect(table.own_bench[0]).size.y / (previous_row * 0.41)
	check.call(report.active_growth >= 1.05 and report.bench_growth >= 1.05,
		"Field cards were not enlarged at %s: %s" % [p.size, report])
	var header_end := to_table * (table.header.get_global_transform_with_canvas() * Vector2(0, table.header.size.y))
	var old_edge := maxf(48.0, header_end.y - 12.0) + 6.0 + clampf(p.size.y * 0.115 - 10.0, 48.0, 120.0) + maxf(4.0, p.size.y * 0.007)
	var retained_row := previous_center - old_edge - maxf(8.0, p.size.y * 0.016) * 1.5
	report["field_retained_ratio"] = p.layout.field_rect(table.own_active).size.y / (retained_row * 0.59)
	check.call(report.field_retained_ratio >= 0.99, "Larger hands shrank the previously enlarged field cards")
	return report

static func check_visible_hand(table: BattleTable, hand: CardView, check: Callable) -> void:
	var p := table.render3d
	var bounds := p.world.projection.project_pose_bounds(p.card_pose(hand))
	var visible := bounds.intersection(Rect2(Vector2.ZERO, p.size))
	check.call(bounds.position.x >= 4.0 and bounds.end.x <= p.size.x - 4.0,
		"Browsing cuts off the left or right end of the hand")
	check.call(bounds.size.x >= table.hand_view._current_hand_card_size().x * 1.1,
		"Edge docking shrinks the hand back into miniature cards")
	check.call(visible.size.y >= 48.0 and visible.size.y / bounds.size.y >= 0.4,
		"An edge-docked card no longer exposes enough of its title and artwork")
	var picked := false
	for y in [0.2, 0.45, 0.7, 0.9]:
		for x in [0.03, 0.08, 0.14, 0.23, 0.36, 0.5, 0.68, 0.83, 0.93]:
			var point := visible.position + visible.size * Vector2(x, y)
			if p._pick_surface(point).get("anchor") == hand:
				picked = true
				break
		if picked: break
	check.call(picked, "An overlapping hand card has no selectable visible face: index=%d at %s" % [hand.hand_index, p.size])

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
