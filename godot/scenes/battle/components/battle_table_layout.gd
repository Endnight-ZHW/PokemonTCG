class_name BattleTableLayout
extends RefCounted

## Pure layout planner for BattleTable. The returned dictionaries contain only
## value types, so presentation code can consume them without scene-tree access.


static func board_metrics(width: float, height: float, config: Dictionary) -> Dictionary:
	var layout_scale := clampf(minf(width / 1500.0, height / 840.0), 0.76, 1.08)
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
	var left_zone_x := side_margin
	var side_zone_x := width - zone_visual_size.x - side_margin
	var field_left := left_zone_x + zone_visual_size.x + 36.0 * layout_scale
	var field_right := side_zone_x - 36.0 * layout_scale
	if field_right <= field_left + 360.0 * layout_scale:
		field_left = side_margin
		field_right = width - side_margin
	var table_width := maxf(300.0, field_right - field_left)
	var center_x := (field_left + field_right) * 0.5
	var top_hand_height := hidden_hand_size.y + 20.0 * layout_scale
	var opponent_hand_width := clampf(
		table_width * 0.38,
		270.0 * layout_scale,
		minf(table_width, 500.0 * layout_scale),
	)
	var own_hand_height := own_hand_size.y + 22.0 * layout_scale
	var own_hand_peek := clampf(own_hand_height * 0.72, 118.0 * layout_scale, own_hand_height)
	var own_hand_y := (
		height
		- own_hand_peek
		- bottom_margin
		- float(config["hand_bottom_padding"]) * layout_scale
	)
	var hand_width := clampf(
		table_width * 0.64,
		520.0 * layout_scale,
		minf(table_width, 850.0 * layout_scale),
	)
	var hidden_hand_visible_height := maxf(24.0, hidden_hand_size.y * 0.32)
	top_hand_height = hidden_hand_visible_height + 10.0 * layout_scale
	var opponent_hand_y := top_margin - hidden_hand_size.y * 0.72
	var opponent_info_y := top_margin + hidden_hand_visible_height + 3.0
	var own_info_y := own_hand_y - 28.0
	return {
		"width": width,
		"height": height,
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
		"left_zone_x": left_zone_x,
		"side_zone_x": side_zone_x,
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
		"own_info_y": own_info_y,
		"arena_top": opponent_info_y + 8.0,
		"arena_bottom": own_hand_y - 6.0,
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
	var required_field_height := (
		active_size.y * 2.0
		+ bench_size.y * 2.0
		+ active_gap
		+ active_clearance * 2.0
		+ bench_edge_gap * 2.0
	)
	var battle_scale := minf(1.0, arena_height / maxf(1.0, required_field_height))
	if battle_scale < 1.0:
		active_size *= battle_scale
		bench_size *= battle_scale
		active_gap *= battle_scale
		active_clearance *= battle_scale
		bench_edge_gap *= battle_scale
	var arena_middle := (arena_top + arena_bottom) * 0.5
	var bench_gap := clampf(
		base_bench_spacing * layout_scale * battle_scale + table_width * 0.018,
		base_bench_spacing * layout_scale * battle_scale,
		30.0 * layout_scale,
	)
	var bench_total := bench_size.x * 5.0 + bench_gap * 4.0
	var bench_x := center_x - bench_total * 0.5
	var opponent_active_y := arena_middle - active_gap * 0.5 - active_size.y
	var own_active_y := arena_middle + active_gap * 0.5
	var top_bench_y := opponent_active_y - bench_size.y - active_clearance
	var bottom_bench_y := own_active_y + active_size.y + active_clearance
	if top_bench_y < arena_top + bench_edge_gap:
		var shift_down := arena_top + bench_edge_gap - top_bench_y
		top_bench_y += shift_down
		opponent_active_y += shift_down * 0.42
	if bottom_bench_y + bench_size.y > arena_bottom - bench_edge_gap:
		var shift_up := bottom_bench_y + bench_size.y - (arena_bottom - bench_edge_gap)
		bottom_bench_y -= shift_up
		own_active_y -= shift_up * 0.42
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
	return {
		"active_size": active_size,
		"bench_size": bench_size,
		"battle_scale": battle_scale,
		"bench_gap": bench_gap,
		"opponent_bench_centers": opponent_bench_centers,
		"own_bench_centers": own_bench_centers,
		"opponent_bench_rects": opponent_bench_rects,
		"own_bench_rects": own_bench_rects,
		"opponent_active_center": opponent_active_center,
		"own_active_center": own_active_center,
		"opponent_active_rect": perspective_card_rect(
			opponent_active_center, active_size, metrics
		)["rect"],
		"own_active_rect": perspective_card_rect(own_active_center, active_size, metrics)["rect"],
	}


static func zone_plan(metrics: Dictionary) -> Dictionary:
	var layout_scale := float(metrics["layout_scale"])
	var top_margin := float(metrics["top_margin"])
	var left_zone_x := float(metrics["left_zone_x"])
	var side_zone_x := float(metrics["side_zone_x"])
	var zone_visual_size: Vector2 = metrics["zone_size"]
	var zone_gap := float(metrics["zone_gap"])
	var own_hand_y := float(metrics["own_hand_y"])
	var arena_middle := (float(metrics["arena_top"]) + float(metrics["arena_bottom"])) * 0.5
	var top_zone_y := top_margin + 18.0 * layout_scale
	var own_zone_y := own_hand_y - zone_visual_size.y - 12.0 * layout_scale
	var own_zone_shift_down := 110.0 * layout_scale
	own_zone_y = minf(
		own_zone_y + own_zone_shift_down,
		float(metrics["height"]) - zone_visual_size.y - float(metrics["bottom_margin"]),
	)
	var opponent_discard_y := top_zone_y + zone_visual_size.y + zone_gap
	var own_discard_y := own_zone_y - zone_visual_size.y - zone_gap
	var stadium_y := arena_middle - zone_visual_size.y * 0.5
	var stadium_min_y := opponent_discard_y + zone_visual_size.y + zone_gap
	var stadium_max_y := own_discard_y - zone_visual_size.y - zone_gap
	if stadium_max_y > stadium_min_y:
		stadium_y = clampf(stadium_y, stadium_min_y, stadium_max_y)
	return {
		"size": zone_visual_size,
		"positions": {
			"opponent_prizes": Vector2(left_zone_x, top_zone_y),
			"opponent_deck": Vector2(side_zone_x, top_zone_y),
			"opponent_discard": Vector2(side_zone_x, opponent_discard_y),
			"stadium": Vector2(left_zone_x, stadium_y),
			"own_discard": Vector2(side_zone_x, own_discard_y),
			"own_deck": Vector2(side_zone_x, own_zone_y),
			"own_prizes": Vector2(left_zone_x, own_zone_y),
		},
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
	var content_width := (
		card_size.x
		if visible_count <= 1
		else card_size.x + spacing * float(visible_count - 1)
	)
	var surface_width := maxf(available, content_width)
	var start_x := maxf(0.0, (surface_width - content_width) * 0.5)
	return {
		"surface_width": surface_width,
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


static func detail_drawer_rect(
	board_rect: Rect2,
	drawer_width: float,
	default_height: float,
	discard_rect: Rect2,
	own_discard_rect: Rect2,
	own_deck_rect: Rect2,
) -> Rect2:
	var margin := 14.0
	var gap := 18.0
	var detail_gap := 26.0
	var minimum_height := 120.0
	var right_edge := (
		discard_rect.end.x if discard_rect.size != Vector2.ZERO else board_rect.end.x - margin
	)
	var x_value := clampf(
		right_edge - drawer_width,
		board_rect.position.x + margin,
		board_rect.end.x - drawer_width - margin,
	)
	var preferred_y := (
		discard_rect.end.y + detail_gap
		if discard_rect.size != Vector2.ZERO
		else board_rect.position.y + margin
	)
	var lower_zone_top := board_rect.end.y - margin
	if own_discard_rect.size != Vector2.ZERO:
		lower_zone_top = minf(lower_zone_top, own_discard_rect.position.y - gap)
	if own_deck_rect.size != Vector2.ZERO:
		lower_zone_top = minf(lower_zone_top, own_deck_rect.position.y - gap)
	var max_height := maxf(minimum_height, lower_zone_top - preferred_y)
	var height_value := minf(default_height, max_height)
	var y_value := clampf(
		preferred_y,
		board_rect.position.y + margin,
		maxf(board_rect.position.y + margin, lower_zone_top - height_value),
	)
	return Rect2(Vector2(x_value, y_value), Vector2(drawer_width, height_value))


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
