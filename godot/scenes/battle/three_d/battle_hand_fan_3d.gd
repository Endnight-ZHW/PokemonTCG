class_name BattleHandFan3D
extends RefCounted

## One physical circular fan. Existing semantic positions still drive reflow and
## identity-preserving browsing; a bounded lens keeps both end cards on screen.
var presenter: Battle3DPresenter
var _signature := ""
var _rig := Transform3D.IDENTITY
var _radius := 1.0
var _half_angle := 0.0
const REST_RADIUS := 11.0
const CARD_SCALE := 1.12

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
	var finish := presenter._hand_surface_pose(proxy, proxy.size.x * (1.0 if own else 0.72), index, count, 0.36 + index * 0.025, own, false)
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
	var projection := presenter.world.projection
	var to_table := table.get_global_transform_with_canvas().affine_inverse()
	var scroll_rect := to_table * table.hand_scroll.get_global_rect()
	var corridor := Rect2(scroll_rect.position.x + 12.0, presenter._hand_top,
		scroll_rect.size.x - 24.0, presenter.size.y - 6.0 - presenter._hand_top)
	# Give the entire fan one scale and one vertical fit, including its end corners.
	var signature := "%s|%s|%s|%d" % [presenter.size, corridor, width, count]
	if signature != _signature:
		_signature = signature
		_build_rig(corridor, width, count)
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
	var angle := lerpf(-_half_angle, _half_angle, clampf(u, 0.0, 1.0)) if count > 1 else 0.0
	var result := _rig * _local_pose(angle)
	# Layer along the shared fan normal so neighbouring cards never interpenetrate.
	result.origin += _rig.basis.y * (ordinal * CardEntity3D.THICKNESS * 1.35)
	if highlighted:
		result.origin += _rig.basis.y * 0.38
		result.origin += _rig.basis * Vector3(sin(angle), 0, -cos(angle)) * 0.12
	result.origin.y += maxf(0.0, height - 0.36 - ordinal * 0.025 - (0.6 if highlighted else 0.0))
	return result

func _local_pose(angle: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, -angle), Vector3(sin(angle) * _radius, 0, (1.0 - cos(angle)) * _radius))

func _build_rig(corridor: Rect2, width: float, count: int) -> void:
	var projection := presenter.world.projection
	_half_angle = deg_to_rad(minf(15.0, maxf(0.0, (count - 1) * 2.3)))
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
		var offset := Vector2(corridor.get_center().x - bounds.get_center().x, corridor.end.y - bounds.end.y)
		_rig.origin = projection.screen_to_world(projection.world_to_screen(_rig.origin) + offset, _rig.origin.y)

func _fan_bounds(count: int) -> Rect2:
	var bounds := Rect2()
	for index in range(5):
		var pose := _rig * _local_pose(lerpf(-_half_angle, _half_angle, index / 4.0))
		pose.origin += _rig.basis.y * (maxi(0, count - 1) * index / 4.0 * CardEntity3D.THICKNESS * 1.35)
		var current := presenter.world.projection.project_pose_bounds(pose)
		bounds = current if index == 0 else bounds.merge(current)
	return bounds
