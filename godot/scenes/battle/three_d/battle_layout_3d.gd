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
	var gap := maxf(8.0, presenter.size.y * 0.014)
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
	var top := maxf(104.0, size.y * 0.14)
	var bottom := size.y * 0.785
	return Rect2(Vector2(size.x * 0.27, top), Vector2(size.x * 0.46, bottom - top))

func zone_base(zone: ZoneView) -> Transform3D:
	var table := presenter.table
	var center := _zone_center(zone)
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
	if key.ends_with("deck") or key.ends_with("discard"):
		reference_center.x += clampf((1180.0 - presenter.size.x) * 0.08, 0.0, 24.0)
	if zone != reference:
		reference_center.y = center.y
	var signature := [reference_center, width, zone.count, zone.stack_visual_mode, projection.viewport.size, projection.camera.transform]
	var cache_key := "zone:%d" % zone.get_instance_id()
	if _poses.has(cache_key) and _poses[cache_key].signature == signature: return _poses[cache_key].pose
	var layers := 1 if zone.stack_visual_mode == "prizes" else maxi(0, zone.count)
	var edge := width * CardEntity3D.THICKNESS * 0.38
	var rect := Rect2(reference_center - Vector2(width, width * 1.20) * 0.5, Vector2(width, width * 1.20))
	var top_rect := Rect2(rect.position - Vector2(0, edge * layers), rect.size)
	var face_rect := top_rect
	var pose := projection.pose_for_screen(reference_center, width, 0.0, 0.015)
	pose.basis.y = projection.paper_axis_for_pixels(pose, edge)
	for iteration in range(5):
		pose = projection.fit_pose_rect(pose, face_rect, layers * CardEntity3D.THICKNESS)
		var base_bounds := projection.project_pose_bounds(pose, 0.0)
		var top_bounds := projection.project_pose_bounds(pose, layers * CardEntity3D.THICKNESS)
		if layers > 0:
			pose.basis.y *= edge * layers / maxf(0.001, base_bounds.end.y - top_bounds.end.y)
		var volume := base_bounds.merge(top_bounds)
		var center_x := face_rect.get_center().x + reference_center.x - volume.get_center().x
		face_rect.size.x *= width / maxf(0.001, volume.size.x)
		face_rect.position.x = center_x - face_rect.size.x * 0.5
	pose = projection.fit_pose_rect(pose, face_rect, layers * CardEntity3D.THICKNESS)
	_poses[cache_key] = {"signature": signature, "pose": pose}
	return pose

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
