class_name BattleTableLayout
extends RefCounted

const MINIMUM_CARD_HIT_SIZE := 48.0

## Pure layout planner for BattleTable. The returned dictionaries contain only
## value types, so presentation code can consume them without scene-tree access.


static func board_metrics(width: float, height: float, config: Dictionary) -> Dictionary:
	var layout_scale := clampf(minf(width / 1500.0, height / 840.0), 0.76, 1.08)
	# The playmat fills the viewport. Interactive content still observes two
	# lightweight safe areas used by the floating phase HUD and command dock.
	var layout_width := width
	var layout_origin_x := 0.0
	var top_interaction_clearance := maxf(56.0, 60.0 * layout_scale)
	var command_dock_width := maxf(
		BattlePhaseHud.RESERVED_BOARD_WIDTH,
		clampf(120.0 * layout_scale, 104.0, 132.0),
	)
	var battle_card_boost := 1.32
	var active_size: Vector2 = config["active_card_size"] * layout_scale * battle_card_boost
	var bench_size: Vector2 = config["bench_card_size"] * layout_scale * battle_card_boost
	var zone_visual_size: Vector2 = config["zone_size"] * layout_scale
	var own_hand_size: Vector2 = config["hand_card_size"] * layout_scale
	var hidden_hand_size: Vector2 = (
		config["opponent_hand_card_size"] * layout_scale * 0.76
	)
	var side_margin := maxf(14.0, float(config["table_side_margin"]) * layout_scale)
	var top_margin := maxf(10.0, float(config["table_top_margin"]) * layout_scale)
	var bottom_margin := maxf(8.0, float(config["table_bottom_margin"]) * layout_scale)
	var zone_gap := 12.0 * layout_scale
	# Deck and discard share one physical dock but keep a narrow strip of table
	# between their top cards, matching two separate piles on the same tray.
	var pile_gap := clampf(8.0 * layout_scale, 7.0, 9.0)
	var command_dock_left := layout_origin_x + layout_width - side_margin - command_dock_width
	var left_zone_x := layout_origin_x + side_margin
	var side_zone_x := command_dock_left - zone_visual_size.x - zone_gap
	var discard_zone_x := side_zone_x - zone_visual_size.x - pile_gap
	var field_left := left_zone_x + zone_visual_size.x + 36.0 * layout_scale
	var field_right := discard_zone_x - 28.0 * layout_scale
	if field_right <= field_left + 360.0 * layout_scale:
		field_left = left_zone_x + zone_visual_size.x * 0.72
		field_right = side_zone_x - zone_visual_size.x * 0.45
	# Keep the duel centered on the physical screen even though the command dock
	# makes the usable margins asymmetric. table_width is the symmetric space
	# available around that center, so hands and bench trays cannot enter zones.
	var viewport_center_x := layout_origin_x + layout_width * 0.5
	var available_field_width := maxf(1.0, field_right - field_left)
	var minimum_symmetric_half := minf(150.0, available_field_width * 0.5)
	var center_lower := field_left + minimum_symmetric_half
	var center_upper := maxf(center_lower, field_right - minimum_symmetric_half)
	var center_x := clampf(viewport_center_x, center_lower, center_upper)
	var symmetric_half_width := maxf(
		1.0,
		minf(center_x - field_left, field_right - center_x),
	)
	var table_width := symmetric_half_width * 2.0
	var hidden_hand_visible_height := maxf(24.0, hidden_hand_size.y * 0.36)
	var top_hand_height := hidden_hand_visible_height + 12.0 * layout_scale
	var opponent_hand_upper := maxf(1.0, minf(table_width, 520.0 * layout_scale))
	var opponent_hand_lower := minf(270.0 * layout_scale, opponent_hand_upper)
	var opponent_hand_width := clampf(
		table_width * 0.42,
		opponent_hand_lower,
		opponent_hand_upper,
	)
	var own_hand_height := own_hand_size.y + 22.0 * layout_scale
	var own_hand_peek := clampf(
		own_hand_height * 0.72,
		118.0 * layout_scale,
		own_hand_height,
	)
	var own_hand_y := (
		height
		- own_hand_peek
		- bottom_margin
		- float(config["hand_bottom_padding"]) * layout_scale
	)
	var hand_width_upper := maxf(1.0, minf(table_width, 850.0 * layout_scale))
	var hand_width_lower := minf(520.0 * layout_scale, hand_width_upper)
	var hand_width := clampf(
		table_width * 0.64,
		hand_width_lower,
		hand_width_upper,
	)
	# The floating header owns the first visual row. Keep the lower half of the
	# hidden hand peeking out beneath it so cards remain readable without
	# competing with the round/task labels.
	var opponent_hand_y := top_interaction_clearance - hidden_hand_size.y * 0.50
	var opponent_info_y := top_interaction_clearance + hidden_hand_visible_height * 0.48
	var arena_top := opponent_info_y + 28.0 * layout_scale
	var arena_bottom := own_hand_y - 10.0 * layout_scale
	var stadium_x := clampf(
		center_x - active_size.x * 1.05 - zone_visual_size.x - zone_gap,
		field_left + 8.0 * layout_scale,
		center_x - zone_visual_size.x - 18.0 * layout_scale,
	)
	return {
		"width": width,
		"height": height,
		"layout_width": layout_width,
		"layout_origin_x": layout_origin_x,
		"layout_scale": layout_scale,
		"active_size": active_size,
		"bench_size": bench_size,
		"zone_size": zone_visual_size,
		"own_hand_size": own_hand_size,
		"hidden_hand_size": hidden_hand_size,
		"side_margin": side_margin,
		"top_margin": top_margin,
		"bottom_margin": bottom_margin,
		"zone_gap": zone_gap,
		"pile_gap": pile_gap,
		"top_interaction_clearance": top_interaction_clearance,
		"command_dock_width": command_dock_width,
		"command_dock_left": command_dock_left,
		"left_zone_x": left_zone_x,
		"side_zone_x": side_zone_x,
		"discard_zone_x": discard_zone_x,
		"stadium_x": stadium_x,
		"field_left": field_left,
		"field_right": field_right,
		"table_width": table_width,
		"center_x": center_x,
		"top_hand_height": top_hand_height,
		"opponent_hand_y": opponent_hand_y,
		"opponent_hand_visible_height": hidden_hand_visible_height,
		"opponent_hand_width": opponent_hand_width,
		"own_hand_height": own_hand_height,
		"own_hand_y": own_hand_y,
		"hand_width": hand_width,
		"opponent_info_y": opponent_info_y,
		"arena_top": arena_top,
		"arena_bottom": arena_bottom,
	}


static func field_plan(metrics: Dictionary, base_bench_spacing: float) -> Dictionary:
	var active_size: Vector2 = metrics["active_size"]
	var bench_size: Vector2 = metrics["bench_size"]
	var layout_scale := float(metrics["layout_scale"])
	var table_width := float(metrics["table_width"])
	var center_x := float(metrics["center_x"])
	var arena_top := float(metrics["arena_top"])
	var arena_bottom := float(metrics["arena_bottom"])
	var arena_height := maxf(1.0, arena_bottom - arena_top)
	var active_gap := 30.0 * layout_scale
	var active_clearance := 20.0 * layout_scale
	var bench_edge_gap := 10.0 * layout_scale
	var minimum_bench_gap := base_bench_spacing * layout_scale
	var required_field_height := (
		active_size.y * 2.0
		+ bench_size.y * 2.0
		+ active_gap
		+ active_clearance * 2.0
		+ bench_edge_gap * 2.0
	)
	var required_field_width := bench_size.x * 5.0 + minimum_bench_gap * 4.0
	var battle_scale := minf(
		1.0,
		minf(
			arena_height / maxf(1.0, required_field_height),
			table_width / maxf(1.0, required_field_width),
		),
	)
	if battle_scale < 1.0:
		active_size *= battle_scale
		bench_size *= battle_scale
		active_gap *= battle_scale
		active_clearance *= battle_scale
		bench_edge_gap *= battle_scale
		minimum_bench_gap *= battle_scale
	var arena_middle := (arena_top + arena_bottom) * 0.5
	var preferred_bench_gap := minf(
		minimum_bench_gap + table_width * 0.018,
		30.0 * layout_scale,
	)
	var maximum_bench_gap := maxf(0.0, (table_width - bench_size.x * 5.0) / 4.0)
	var far_bench_center_y := arena_top + bench_edge_gap + bench_size.y * 0.5
	var far_spread := lerpf(
		0.96,
		1.035,
		perspective_depth(far_bench_center_y, metrics),
	)
	var minimum_raw_center_spacing := MINIMUM_CARD_HIT_SIZE / maxf(0.01, far_spread)
	var minimum_touch_gap := maxf(
		0.0,
		minimum_raw_center_spacing - bench_size.x,
	)
	var bench_gap := minf(
		maxf(preferred_bench_gap, minimum_touch_gap),
		maximum_bench_gap,
	)
	var bench_total := bench_size.x * 5.0 + bench_gap * 4.0
	var bench_x := center_x - bench_total * 0.5
	# Bench trays hug the top and bottom field rails. The active Pokemon remain
	# paired around the table center, producing the near/far duel composition.
	var top_bench_y := arena_top + bench_edge_gap
	var bottom_bench_y := arena_bottom - bench_edge_gap - bench_size.y
	var opponent_active_y := arena_middle - active_gap * 0.5 - active_size.y
	var own_active_y := arena_middle + active_gap * 0.5
	var opponent_bench_centers: Array[Vector2] = []
	var own_bench_centers: Array[Vector2] = []
	var opponent_bench_rects: Array[Rect2] = []
	var own_bench_rects: Array[Rect2] = []
	for index in range(5):
		var opponent_center := Vector2(
			bench_x + index * (bench_size.x + bench_gap) + bench_size.x * 0.5,
			top_bench_y + bench_size.y * 0.5,
		)
		var own_center := Vector2(
			bench_x + index * (bench_size.x + bench_gap) + bench_size.x * 0.5,
			bottom_bench_y + bench_size.y * 0.5,
		)
		opponent_bench_centers.append(opponent_center)
		own_bench_centers.append(own_center)
		opponent_bench_rects.append(
			perspective_card_rect(opponent_center, bench_size, metrics)["rect"]
		)
		own_bench_rects.append(perspective_card_rect(own_center, bench_size, metrics)["rect"])
	var opponent_active_center := Vector2(
		center_x,
		opponent_active_y + active_size.y * 0.5,
	)
	var own_active_center := Vector2(center_x, own_active_y + active_size.y * 0.5)
	var opponent_tray_rect := union_rects(opponent_bench_rects).grow(
		maxf(8.0, 10.0 * layout_scale * battle_scale)
	)
	var own_tray_rect := union_rects(own_bench_rects).grow(
		maxf(8.0, 10.0 * layout_scale * battle_scale)
	)
	return {
		"active_size": active_size,
		"bench_size": bench_size,
		"battle_scale": battle_scale,
		"bench_gap": bench_gap,
		"opponent_bench_centers": opponent_bench_centers,
		"own_bench_centers": own_bench_centers,
		"opponent_bench_rects": opponent_bench_rects,
		"own_bench_rects": own_bench_rects,
		"opponent_bench_tray_rect": opponent_tray_rect,
		"own_bench_tray_rect": own_tray_rect,
		"opponent_active_center": opponent_active_center,
		"own_active_center": own_active_center,
		"opponent_active_rect": perspective_card_rect(
			opponent_active_center, active_size, metrics
		)["rect"],
		"own_active_rect": perspective_card_rect(own_active_center, active_size, metrics)["rect"],
	}


static func zone_plan(metrics: Dictionary, field: Dictionary = {}) -> Dictionary:
	var layout_scale := float(metrics["layout_scale"])
	var left_zone_x := float(metrics["left_zone_x"])
	# The right-side dock reads from the arena toward the command dock as
	# Deck -> Discard. A small gap keeps both original ZoneView hit areas fully
	# independent while the surrounding dock still groups them visually.
	var discard_outer_x := float(metrics["side_zone_x"])
	var deck_inner_x := float(metrics.get("discard_zone_x", discard_outer_x))
	var stadium_x := float(metrics.get("stadium_x", left_zone_x))
	var zone_visual_size: Vector2 = metrics["zone_size"]
	if not field.is_empty():
		# Use the field plan's final, scaled active card rather than the larger
		# pre-fit design size. Compact layouts shrink the duel substantially; the
		# old estimate left Stadium unnecessarily far left and consumed the fixed
		# detail corridor between the prize rows.
		var opponent_active: Rect2 = field.get("opponent_active_rect", Rect2())
		var own_active: Rect2 = field.get("own_active_rect", Rect2())
		var active_left := minf(opponent_active.position.x, own_active.position.x)
		var stadium_gap := clampf(14.0 * layout_scale, 10.0, 16.0)
		var maximum_stadium_x := active_left - zone_visual_size.x - stadium_gap
		var prize_step := clampf(zone_visual_size.x * 0.17, 11.0, 18.0)
		var prize_corridor_right := (
			left_zone_x
			+ zone_visual_size.x
			+ prize_step * 5.0
			+ stadium_gap
		)
		if maximum_stadium_x >= prize_corridor_right:
			stadium_x = maximum_stadium_x
	var arena_middle := (float(metrics["arena_top"]) + float(metrics["arena_bottom"])) * 0.5
	var top_zone_y := float(metrics["arena_top"]) + 6.0 * layout_scale
	var own_zone_y := (
		float(metrics["height"])
		- zone_visual_size.y
		- float(metrics["bottom_margin"])
		- 4.0 * layout_scale
	)
	# Lift the Stadium slightly above the center rail so it reads as a shared
	# field card without colliding with the own-side status/allowance group.
	var stadium_y := arena_middle - zone_visual_size.y * 0.7
	return {
		"size": zone_visual_size,
		"stadium_scale": clampf(float(metrics["height"]) / 720.0, 0.62, 1.0),
		"positions": {
			"opponent_prizes": Vector2(left_zone_x, top_zone_y),
			"opponent_deck": Vector2(deck_inner_x, top_zone_y),
			"opponent_discard": Vector2(discard_outer_x, top_zone_y),
			"stadium": Vector2(stadium_x, stadium_y),
			"own_discard": Vector2(discard_outer_x, own_zone_y),
			"own_deck": Vector2(deck_inner_x, own_zone_y),
			"own_prizes": Vector2(left_zone_x, own_zone_y),
		},
	}


static func own_status_plan(
	metrics: Dictionary,
	own_active_rect: Rect2,
	status_size: Vector2 = Vector2(304.0, 56.0),
	stadium_rect: Rect2 = Rect2(),
) -> Dictionary:
	var layout_scale := float(metrics["layout_scale"])
	var active_gap := clampf(16.0 * layout_scale, 12.0, 18.0)
	var minimum_active_gap := clampf(8.0 * layout_scale, 6.0, 10.0)
	var left_zone_clearance := (
		float(metrics["left_zone_x"])
		+ Vector2(metrics["zone_size"]).x * 1.08
		+ clampf(12.0 * layout_scale, 9.0, 14.0)
	)
	# Prefer the full status width and gap, but shrink/slide the group inside the
	# actual corridor on compact landscape instead of allowing it under prizes.
	var preferred_right := own_active_rect.position.x - active_gap
	var maximum_right := own_active_rect.position.x - minimum_active_gap
	var available_width := maxf(1.0, maximum_right - left_zone_clearance)
	var resolved_width := minf(status_size.x, available_width)
	var status_x := maxf(
		left_zone_clearance,
		minf(preferred_right - resolved_width, maximum_right - resolved_width),
	)
	var clears_left_column := (
		status_x >= left_zone_clearance
		and status_x + resolved_width <= maximum_right + 0.01
	)
	var preferred_y := own_active_rect.get_center().y - status_size.y * 0.5
	var minimum_y := float(metrics["arena_top"]) + 4.0 * layout_scale
	var maximum_y := float(metrics["own_hand_y"]) - status_size.y - 8.0 * layout_scale
	var status_y := clampf(
		preferred_y,
		minimum_y,
		maxf(minimum_y, maximum_y),
	)
	var resolved_size := Vector2(resolved_width, status_size.y)
	var group_rect := Rect2(Vector2(status_x, status_y), resolved_size)
	if (
		stadium_rect.size.x > 0.0
		and stadium_rect.size.y > 0.0
		and group_rect.position.x < stadium_rect.end.x
		and group_rect.end.x > stadium_rect.position.x
	):
		var cleared_y := stadium_rect.end.y + clampf(5.0 * layout_scale, 4.0, 6.0)
		if cleared_y <= maximum_y:
			group_rect.position.y = maxf(group_rect.position.y, cleared_y)
	var row_gap := 4.0
	var row_height := maxf(20.0, (status_size.y - row_gap) * 0.5)
	return {
		"rect": group_rect,
		"clears_left_column": clears_left_column,
		"info_rect": Rect2(group_rect.position, Vector2(resolved_width, row_height)),
		"allowance_rect": Rect2(
			group_rect.position + Vector2(0.0, row_height + row_gap),
			Vector2(resolved_width, row_height),
		),
	}


static func own_hand_plan(
	visible_count: int,
	available_width: float,
	card_size: Vector2,
	minimum_spacing: float,
	maximum_rotation: float,
) -> Dictionary:
	var available := maxf(220.0, available_width)
	var spacing := card_size.x
	if visible_count > 1:
		spacing = clampf(
			(available - card_size.x) / float(visible_count - 1),
			minimum_spacing,
			card_size.x + 6.0,
		)
	var content_width := 0.0
	if visible_count == 1:
		content_width = card_size.x
	elif visible_count > 1:
		content_width = card_size.x + spacing * float(visible_count - 1)
	var surface_width := maxf(available, content_width)
	var start_x := maxf(0.0, (surface_width - content_width) * 0.5)
	return {
		"content_width": content_width,
		"surface_width": surface_width,
		# ScrollContainer starts at the leading edge when its child overflows.
		# Centering that overflow gives both ends of a large hand equal access.
		"center_scroll": maxf(0.0, (content_width - available) * 0.5),
		"items": _fan_items(
			visible_count,
			start_x,
			spacing,
			14.0,
			0.0,
			maximum_rotation,
			70,
		),
	}


static func opponent_hand_plan(
	visible_count: int,
	available_width: float,
	card_size: Vector2,
	minimum_spacing: float,
	maximum_rotation: float,
) -> Dictionary:
	var available := maxf(180.0, available_width)
	var spacing := card_size.x * 0.42
	if visible_count > 1:
		spacing = clampf(
			(available - card_size.x) / float(visible_count - 1),
			minimum_spacing,
			card_size.x * 0.58,
		)
	var content_width := (
		card_size.x
		if visible_count <= 1
		else card_size.x + spacing * float(visible_count - 1)
	)
	var start_x := maxf(0.0, (available - content_width) * 0.5)
	return {
		"items": _fan_items(
			visible_count,
			start_x,
			spacing,
			-4.0,
			5.0,
			-maximum_rotation,
			5,
		),
	}


static func perspective_card_rect(
	center: Vector2,
	base_size: Vector2,
	metrics: Dictionary,
) -> Dictionary:
	var depth := perspective_depth(center.y, metrics)
	var scale := lerpf(0.86, 1.08, depth)
	var size_value := base_size * scale
	var center_x := float(metrics["center_x"])
	var spread := lerpf(0.96, 1.035, depth)
	var projected_center := Vector2(
		center_x + (center.x - center_x) * spread,
		center.y,
	)
	return {
		"depth": depth,
		"rect": Rect2(projected_center - size_value * 0.5, size_value),
	}


static func perspective_depth(y: float, metrics: Dictionary) -> float:
	return clampf(
		(y - float(metrics["arena_top"]))
		/ maxf(1.0, float(metrics["arena_bottom"]) - float(metrics["arena_top"])),
		0.0,
		1.0,
	)


static func union_rects(rects: Array[Rect2]) -> Rect2:
	if rects.is_empty():
		return Rect2()
	var result := rects[0]
	for index in range(1, rects.size()):
		result = result.merge(rects[index])
	return result


static func _fan_items(
	count: int,
	start_x: float,
	spacing: float,
	base_y: float,
	curve_height: float,
	maximum_rotation: float,
	base_z: int,
) -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	for index in range(count):
		var normalized := (
			0.0 if count <= 1 else float(index) / float(count - 1) - 0.5
		)
		var y_value := base_y + absf(normalized) * curve_height
		items.append({
			"position": Vector2(start_x + index * spacing, y_value),
			"rotation_degrees": normalized * minf(absf(maximum_rotation), float(count) * 0.55) * signf(maximum_rotation),
			"z_index": base_z + index,
		})
	return items
