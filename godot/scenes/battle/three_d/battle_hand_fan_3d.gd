class_name BattleHandFan3D
extends RefCounted

## One physical circular fan. Existing semantic positions still drive reflow and
## identity-preserving browsing. Card tops stay visible at the screen edge while
## the lower bodies extend off screen, preserving a readable printed size.
var presenter: Battle3DPresenter
var _signature := ""
var _rig := Transform3D.IDENTITY
var _radius := 1.0
var _half_angle := 0.0
var _mirrored_poses: Dictionary = {}
var _mirror_camera_transform := Transform3D.IDENTITY
var _mirror_transform := Transform3D.IDENTITY
const REST_RADIUS := 13.0
const CARD_SCALE := 1.22

func _init(value: Battle3DPresenter) -> void:
	presenter = value

func return_drag(proxy: CardMotionEntity, source: CardView, center: Vector2, tween: Tween, duration: float) -> void:
	if proxy == null or source == null or not presenter.is_projection_ready(): return
	presenter._sync_token(proxy)
	var start := proxy.physical_entity.transform
	var old_position := proxy.position
	proxy.position = center - proxy.size * 0.5
	var ordinal := source.hand_index
	var count := presenter.table.hand_views.filter(func(card: CardView) -> bool: return card.visible).size()
	var highlighted := source.selected or source._hovered
	var height := 0.36 + ordinal * 0.025 + (0.6 if highlighted else 0.0)
	var finish := presenter._hand_surface_pose(proxy, source.size.x, ordinal, count, height, true, highlighted)
	proxy.position = old_position
	proxy.source_pose = start
	proxy.target_pose = finish
	proxy.world_pose = start
	proxy.has_world_pose = true
	# Return the held card to the fan's actual orientation and scale. A screen
	# position-only return snaps from the held tilt to the fan on its last frame.
	tween.tween_method(func(progress: float) -> void:
		if is_instance_valid(proxy): proxy.world_pose = start.interpolate_with(finish, progress),
		0.0, 1.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func reflow_card(card: CardView, target_position: Vector2, target_rotation: float, tween: Tween, duration: float) -> void:
	if not presenter.is_projection_ready(): return
	var start := presenter.card_pose(card)
	var old_position := card.position
	var old_rotation := card.rotation_degrees
	if card.has_meta("physical_pose"): card.remove_meta("physical_pose")
	card.position = target_position
	card.rotation_degrees = target_rotation
	var finish := presenter.card_pose(card)
	card.position = old_position
	card.rotation_degrees = old_rotation
	card.set_meta("physical_pose", start)
	presenter.card_pose(card)
	tween.tween_method(func(progress: float) -> void:
		if is_instance_valid(card): card.set_meta("physical_pose", start.interpolate_with(finish, progress)),
		0.0, 1.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func reflow_proxy(control: Control, target_position: Vector2, target_rotation: float, tween: Tween, duration: float) -> void:
	var proxy := control as CardMotionEntity
	if proxy == null or not presenter.is_projection_ready(): return
	var own := proxy.has_meta("snapshot_hand_key")
	var stage := presenter.table.hand_presentation
	var index := stage._presentation_hand_virtual_keys.find(str(proxy.get_meta("snapshot_hand_key", ""))) if own else stage._presentation_opponent_hand_proxies.find(proxy)
	var count := stage._presentation_hand_virtual_keys.size() if own else stage._presentation_opponent_hand_stage_count
	if index < 0 or count < 1: return
	var start: Variant = proxy.world_pose if proxy.has_world_pose else null
	if start == null and is_instance_valid(proxy.physical_entity):
		start = proxy.physical_entity.transform
	var old_position := proxy.position
	var old_rotation := proxy.rotation_degrees
	proxy.position = target_position
	proxy.rotation_degrees = target_rotation
	var finish := presenter._hand_surface_pose(proxy, proxy.size.x, index, count, 0.36 + index * 0.025, own, false)
	proxy.position = old_position
	proxy.rotation_degrees = old_rotation
	proxy.set_meta("physical_reflow", true)
	# Reconciled placeholders have no previous flight. Never promote their
	# default identity transform into a visible starting pose at the table origin.
	proxy.world_pose = start if start is Transform3D else finish
	proxy.has_world_pose = true
	if tween == null:
		proxy.world_pose = finish
		return
	start = proxy.world_pose
	tween.tween_method(func(progress: float) -> void:
		if is_instance_valid(proxy): proxy.world_pose = start.interpolate_with(finish, progress),
		0.0, 1.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func pose(root: Control, width: float, ordinal: int, count: int, height: float, highlighted: bool) -> Transform3D:
	var table := presenter.table
	var to_table := table.get_global_transform_with_canvas().affine_inverse()
	var scroll_rect := to_table * table.hand_scroll.get_global_rect()
	_ensure_rig(width, count)
	var center := to_table * (root.get_global_transform_with_canvas() * (root.size * 0.5))
	var card_size := table.hand_view._current_hand_card_size()
	var available := maxf(220.0, table.hand_scroll.size.x)
	var spacing := clampf((available - card_size.x) / maxi(1, count - 1),
		maxf(table.hand_minimum_spacing, card_size.x * 0.49), card_size.x + 6.0)
	var content_width := card_size.x + spacing * maxi(0, count - 1)
	var surface_width := maxf(available, content_width)
	var span := maxf(1.0, content_width - card_size.x)
	var surface_start := to_table * table.hand_surface.get_global_transform_with_canvas().origin
	var leading := surface_start.x + (surface_width - content_width + card_size.x) * 0.5
	var trailing := leading + span
	var focus := scroll_rect.get_center().x
	var u := (center.x - leading) / span
	if content_width > available + 1.0:
		var lens := 0.6 / maxf(1.0, scroll_rect.size.x)
		var a := atan((leading - focus) * lens)
		var b := atan((trailing - focus) * lens)
		var browsed := (atan((center.x - focus) * lens) - a) / maxf(0.0001, b - a)
		var centered_scroll := (content_width - available) * 0.5
		var browsing := clampf(absf(table.hand_scroll.scroll_horizontal - centered_scroll) / maxf(1.0, centered_scroll), 0.0, 1.0)
		u = lerpf(u, browsed, browsing * 0.25)
	return _pose_at(u, ordinal, count, height, highlighted)

func _ensure_rig(width: float, count: int) -> void:
	var corridor := presenter.layout.hand_area(true)
	var signature := "%s|%s|%s|%d" % [presenter.size, corridor, width, count]
	if signature != _signature:
		_signature = signature
		_build_rig(corridor, width, count)
		_mirrored_poses.clear()
		_mirror_camera_transform = Transform3D.IDENTITY

func _pose_at(u: float, ordinal: int, count: int, height: float, highlighted: bool) -> Transform3D:
	var angle := lerpf(-_half_angle, _half_angle, clampf(u, 0.0, 1.0)) if count > 1 else 0.0
	var result := _rig * _local_pose(angle)
	# Layer along the shared fan normal so neighbouring cards never interpenetrate.
	result.origin += _rig.basis.y * (ordinal * CardEntity3D.THICKNESS * 1.35)
	if highlighted:
		result.origin += _rig.basis.y * 0.38
		result.origin += _rig.basis * Vector3(sin(angle), 0, -cos(angle)) * 0.12
	result.origin.y += maxf(0.0, height - 0.36 - ordinal * 0.025 - (0.6 if highlighted else 0.0))
	return result

func opponent_pose(ordinal: int, count: int, height: float) -> Transform3D:
	# Rotate the entire near fan around the camera axis. Mirroring just each
	# bounding box leaves different silhouettes and can bury large tilted cards
	# in the table. One shared transform also preserves parallel paper layers.
	_ensure_rig(presenter.table.hand_view._current_hand_card_size().x, count)
	var projection := presenter.world.projection
	if _mirror_camera_transform != projection.camera.transform:
		_mirror_camera_transform = projection.camera.transform
		_mirrored_poses.clear()
		_build_mirror(count)
	var key := Vector2(ordinal, height)
	if _mirrored_poses.has(key):
		return _mirrored_poses[key]
	var u := float(ordinal) / maxf(1.0, count - 1.0) if count > 1 else 0.5
	var near_pose := _pose_at(u, ordinal, count, height, false)
	var result := _mirror_transform * near_pose
	_mirrored_poses[key] = result
	return result

func _build_mirror(count: int) -> void:
	var camera := presenter.world.camera
	var turn := Basis(camera.global_basis.z.normalized(), PI)
	var mirrored := Transform3D(turn, camera.global_position - turn * camera.global_position)
	var lowest := INF
	var nearest := INF
	var farthest := 0.0
	var view_axis := camera.global_basis.z
	for index in range(maxi(1, count)):
		var u := float(index) / maxf(1.0, count - 1.0) if count > 1 else 0.5
		var pose := mirrored * _pose_at(u, index, count, 0.36 + index * 0.025, false)
		var half_extent := absf(pose.basis.x.y) * 0.5 + absf(pose.basis.z.y) * CardEntity3D.ASPECT * 0.5
		half_extent += absf(pose.basis.y.y) * CardEntity3D.THICKNESS * 0.5
		lowest = minf(lowest, pose.origin.y - half_extent)
		var view_depth := (camera.global_position - pose.origin).dot(view_axis)
		var half_depth := absf(pose.basis.x.dot(view_axis)) * 0.5 + absf(pose.basis.z.dot(view_axis)) * CardEntity3D.ASPECT * 0.5
		half_depth += absf(pose.basis.y.dot(view_axis)) * CardEntity3D.THICKNESS * 0.5
		nearest = minf(nearest, view_depth - half_depth)
		farthest = maxf(farthest, view_depth + half_depth)
	# Keep both fans moving up. A camera-centered half turn alone would move
	# the far hand down. Use the middle depth of the whole fan, including paper
	# layers, to keep the off-axis perspective error below a pixel at either edge.
	var projection := presenter.world.projection
	var reference_depth := 2.0 * nearest * farthest / maxf(0.001, nearest + farthest)
	var viewport_center := presenter.size * 0.5
	var offset := projection.camera_plane_point(viewport_center + presenter.world.framing_offset * 2.0, reference_depth)
	offset -= projection.camera_plane_point(viewport_center, reference_depth)
	mirrored.origin += offset
	lowest += offset.y
	# Move the whole fan along camera rays until its lowest corner rests above
	# the cloth. Uniform depth scaling leaves the exact projected shape intact.
	var depth_scale := (camera.global_position.y - 0.12) / maxf(0.001, camera.global_position.y - lowest)
	var depth := Transform3D(Basis.from_scale(Vector3.ONE * depth_scale), camera.global_position * (1.0 - depth_scale))
	_mirror_transform = depth * mirrored

func _local_pose(angle: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, -angle), Vector3(sin(angle) * _radius, 0, (1.0 - cos(angle)) * _radius))

func _build_rig(corridor: Rect2, width: float, count: int) -> void:
	var projection := presenter.world.projection
	_half_angle = deg_to_rad(minf(8.0, maxf(0.0, (count - 1) * 1.6)))
	_radius = REST_RADIUS
	_rig = projection.pose_for_screen(corridor.get_center(), width * CARD_SCALE, 0.0, 1.0, deg_to_rad(24.0))
	var maximum_scale := _rig.basis.x.length()
	for iteration in range(3):
		var bounds := _fan_bounds(count)
		var fit := minf(maximum_scale / _rig.basis.x.length(), corridor.size.y / maxf(1.0, bounds.size.y))
		_rig.basis = _rig.basis.scaled(Vector3.ONE * fit)
		bounds = _fan_bounds(count)
		if bounds.size.x > corridor.size.x and _half_angle > 0.001:
			# Increase overlap before reducing card size. Uniformly shrinking a
			# wide 20-card fan made every card unnecessarily tiny on small screens.
			var edge_width := projection.project_pose_bounds(_rig * _local_pose(_half_angle)).size.x
			_radius *= maxf(0.05, (corridor.size.x - edge_width) / maxf(1.0, bounds.size.x - edge_width))
			bounds = _fan_bounds(count)
		# Anchor the readable upper edge. Fitting the bottom to the viewport made
		# hand cards smaller than the bench whenever the field needed more space.
		var offset := Vector2(corridor.get_center().x - bounds.get_center().x, corridor.position.y - bounds.position.y)
		_rig.origin = projection.screen_to_world(projection.world_to_screen(_rig.origin) + offset, _rig.origin.y)

func _fan_bounds(count: int) -> Rect2:
	var bounds := Rect2()
	for index in range(5):
		var pose := _rig * _local_pose(lerpf(-_half_angle, _half_angle, index / 4.0))
		pose.origin += _rig.basis.y * (maxi(0, count - 1) * index / 4.0 * CardEntity3D.THICKNESS * 1.35)
		var current := presenter.world.projection.project_pose_bounds(pose)
		bounds = current if index == 0 else bounds.merge(current)
	return bounds
