class_name BattleLayout3D
extends RefCounted

var presenter: Battle3DPresenter
var _poses: Dictionary = {}

func _init(value: Battle3DPresenter) -> void:
	presenter = value

func _center(control: Control) -> Vector2:
	return presenter.table.get_global_transform_with_canvas().affine_inverse() * (control.get_global_transform_with_canvas() * (control.size * 0.5))

func field_pose(card: CardView, root: Control, height: float) -> Transform3D:
	var projection := presenter.world.projection
	var rect := field_rect(card)
	rect.position += _center(root) - _center(card)
	var key := "field:%d" % card.get_instance_id()
	var signature := [rect, height, projection.viewport.size, projection.camera.transform]
	if _poses.has(key) and _poses[key].signature == signature: return _poses[key].pose
	var pose := projection.pose_for_screen(rect.get_center(), rect.size.x, 0.0, height)
	pose.basis.y = projection.paper_axis_for_pixels(pose, rect.size.x * CardEntity3D.THICKNESS * 0.38)
	pose = projection.fit_pose_rect(pose, rect)
	_poses[key] = {"signature": signature, "pose": pose}
	return pose

func field_rect(card: CardView) -> Rect2:
	var area := field_area()
	# Leave room for the exposed edges of a fully attached Pokemon stack.
	var gap := maxf(8.0, presenter.size.y * 0.016)
	var row_height := (area.size.y - gap * 3.0) * 0.5
	var bench := card.slot.begins_with("bench_")
	var bench_height := row_height * 0.41
	var active_height := row_height * 0.59
	var target_height := bench_height if bench else active_height
	var near_y := area.end.y - bench_height * 0.5 if bench else area.end.y - bench_height - gap - active_height * 0.5
	var far_y := area.position.y + area.end.y - near_y
	var width := target_height / 1.20
	var x := area.get_center().x
	if bench:
		width = minf(width, (area.size.x - 4.0 * gap) / 5.0)
		x += (card.slot.trim_prefix("bench_").to_int() - 2) * (width + gap * 1.5)
	var own := card.owner_player == presenter.table.view_player
	var center := Vector2(x, near_y if own else far_y)
	return Rect2(center - Vector2(width, target_height) * 0.5, Vector2(width, target_height))

func field_area() -> Rect2:
	var size := presenter.size
	var center := presenter.world.playmat_center
	var table := presenter.table
	var header_end := table.get_global_transform_with_canvas().affine_inverse() * (
		table.header.get_global_transform_with_canvas() * Vector2(0, table.header.size.y))
	# Keep the enlarged field independent of the hand's full card height. Hands
	# now extend beyond the viewport instead of squeezing the four playing rows.
	var far_edge := maxf(48.0, header_end.y - 12.0) + 6.0
	far_edge += clampf(size.y * 0.09 - 10.0, 32.0, 100.0) + maxf(4.0, size.y * 0.007)
	# Panning changes placement, not the size of the four playing rows.
	var half_height := center.y - presenter.world.framing_offset.y - far_edge
	return Rect2(Vector2(center.x - size.x * 0.23, center.y - half_height),
		Vector2(size.x * 0.46, half_height * 2.0))

func hand_mirror_center() -> Vector2:
	# The hands belong to the screen edges; the field belongs to the cloth.
	return presenter.size * 0.5 + presenter.world.framing_offset

func hand_area(own: bool) -> Rect2:
	var size := presenter.size
	var center := hand_mirror_center()
	var table := presenter.table
	var to_table := table.get_global_transform_with_canvas().affine_inverse()
	var turn := to_table * table.header.turn_label.get_global_rect()
	var task := to_table * table.header.task_hint_label.get_global_rect()
	var half_width := minf(center.x - turn.end.x, task.position.x - center.x) - 12.0
	var width := maxf(120.0, minf(size.x * 0.60, half_width * 2.0))
	var height := table.hand_view._current_hand_card_size().y * 1.65
	var near_top := field_area().end.y + maxf(4.0, size.y * 0.007)
	var y := near_top if own else center.y * 2.0 - near_top - height
	return Rect2(Vector2(center.x - width * 0.5, y), Vector2(width, height))

func zone_base(zone: ZoneView) -> Transform3D:
	var table := presenter.table
	var width := zone.get_stack_face_size().x
	var reference := zone
	var key := ""
	for candidate in table.zones:
		if table.zones[candidate] == zone:
			key = str(candidate)
			break
	if key.begins_with("own_") or key.begins_with("opponent_"):
		reference = table.zones.get(key.replace("opponent_", "own_"), zone) as ZoneView
		width = reference.get_stack_face_size().x
	var to_table := table.get_global_transform_with_canvas().affine_inverse() * reference.get_global_transform_with_canvas()
	width *= to_table.x.length()
	var projection := presenter.world.projection
	var reference_center := _zone_center(reference)
	reference_center += presenter.world.framing_offset
	if key.ends_with("deck") or key.ends_with("discard"):
		var phase_panel := table.hud.get_node("PhasePanel") as Control
		var phase_left := (table.get_global_transform_with_canvas().affine_inverse() * phase_panel.get_global_transform_with_canvas().origin).x
		var dock_right := phase_left - 8.0
		var dock_left := field_rect(table.own_bench[4]).end.x + 8.0
		var pile_gap := 8.0
		if dock_right > dock_left + pile_gap:
			width = minf(width, (dock_right - dock_left - pile_gap) * 0.5)
			reference_center.x = dock_right - width * (1.5 if key.ends_with("deck") else 0.5)
			if key.ends_with("deck"):
				reference_center.x -= pile_gap
	if key.begins_with("own_") or key.begins_with("opponent_"):
		var canvas_to_table := table.get_global_transform_with_canvas().affine_inverse()
		var header_bottom := canvas_to_table * (table.header.get_global_transform_with_canvas() * Vector2(0, table.header.size.y))
		var top_clearance := header_bottom.y + 8.0
		if key.ends_with("prizes"):
			# The opponent summary sits beside Prizes, leaving both six-card fans
			# free to move outward by the same distance from the cloth midpoint.
			var menu := table.header.menu_button
			var menu_bottom := canvas_to_table * (menu.get_global_transform_with_canvas() * Vector2(0, menu.size.y))
			var caption := table.header.turn_label
			var caption_bottom := canvas_to_table * (caption.get_global_transform_with_canvas() * Vector2(0, caption.size.y))
			top_clearance = maxf(menu_bottom.y, caption_bottom.y) + 8.0
		var clearance_layers := 6 if key.ends_with("prizes") else 0
		var minimum_far_center := top_clearance + width * 0.60 + width * CardEntity3D.THICKNESS * 0.38 * clearance_layers
		if key.ends_with("prizes"):
			var maximum_near_center := presenter.size.y + presenter.world.framing_offset.y - 16.0 - width * 0.60
			var offset := minf(presenter.world.playmat_center.y - minimum_far_center,
				maximum_near_center - presenter.world.playmat_center.y)
			reference_center.y = presenter.world.playmat_center.y + maxf(0.0, offset)
		else:
			reference_center.y = minf(reference_center.y, presenter.world.playmat_center.y * 2.0 - minimum_far_center)
	if zone != reference:
		reference_center.y = presenter.world.playmat_center.y * 2.0 - reference_center.y
	elif key == "stadium":
		reference_center.y = presenter.world.playmat_center.y
	var signature := [reference_center, width, zone.count, zone.stack_visual_mode, projection.viewport.size, projection.camera.transform]
	var cache_key := "zone:%d" % zone.get_instance_id()
	if _poses.has(cache_key) and _poses[cache_key].signature == signature: return _poses[cache_key].pose
	var layers := 1 if zone.stack_visual_mode == "prizes" else maxi(0, zone.count)
	var edge := width * CardEntity3D.THICKNESS * 0.38
	var rect := Rect2(reference_center - Vector2(width, width * 1.20) * 0.5, Vector2(width, width * 1.20))
	# Anchor the visible face of Deck and Discard to the same row. Their paper
	# thickness extends below that face, independent of how many cards remain.
	var face_rect := Rect2(rect.position - Vector2(0, edge * layers), rect.size) if zone.stack_visual_mode == "prizes" else rect
	var pose := projection.pose_for_screen(reference_center, width, 0.0, 0.015)
	pose.basis.y = projection.paper_axis_for_pixels(pose, edge)
	for iteration in range(5):
		pose = projection.fit_pose_rect(pose, face_rect, layers * CardEntity3D.THICKNESS)
		var base_bounds := projection.project_pose_bounds(pose, 0.0)
		var top_bounds := projection.project_pose_bounds(pose, layers * CardEntity3D.THICKNESS)
		if layers > 0:
			pose.basis.y *= edge * layers / maxf(0.001, base_bounds.end.y - top_bounds.end.y)
		if zone.stack_visual_mode == "prizes":
			var volume := base_bounds.merge(top_bounds)
			var center_x := face_rect.get_center().x + reference_center.x - volume.get_center().x
			face_rect.size.x *= width / maxf(0.001, volume.size.x)
			face_rect.position.x = center_x - face_rect.size.x * 0.5
	pose = projection.fit_pose_rect(pose, face_rect, layers * CardEntity3D.THICKNESS)
	_poses[cache_key] = {"signature": signature, "pose": pose}
	return pose

func stadium_rect() -> Rect2:
	return presenter.world.projection.project_pose_bounds(zone_base(presenter.table.zones["stadium"]), 0.0)

func prize_capacity_rect(zone: ZoneView) -> Rect2:
	var projection := presenter.world.projection
	return projection.project_pose_bounds(presenter.zone_pose(zone, 0)).merge(
		projection.project_pose_bounds(presenter.zone_pose(zone, 5)))

func release(anchor: Control) -> void:
	_poses.erase("field:%d" % anchor.get_instance_id())
	_poses.erase("zone:%d" % anchor.get_instance_id())

func _zone_center(zone: ZoneView) -> Vector2:
	return presenter.table.get_global_transform_with_canvas().affine_inverse() * (zone.get_global_transform_with_canvas() * (zone.get_stack_face_size() * 0.5))

static func packet_span(card_count: int, index: int, packets: int = 6, separate_top: bool = true) -> Vector2i:
	packets = maxi(1, mini(card_count, packets))
	index = clampi(index, 0, packets - 1)
	if separate_top and packets > 1:
		if index == packets - 1:
			return Vector2i(card_count - 1, card_count)
		card_count -= 1
		packets -= 1
	return Vector2i(floori(float(card_count * index) / packets), floori(float(card_count * (index + 1)) / packets))
