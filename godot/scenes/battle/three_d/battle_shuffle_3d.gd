class_name BattleShuffle3D
extends RefCounted

static func apply(progress: float, flyer: CardMotionEntity, presenter: Battle3DPresenter, index: int, count: int) -> void:
	var zone := flyer.get_meta("shuffle_source_zone") as ZoneView
	if not is_instance_valid(zone):
		return
	var span := BattleLayout3D.packet_span(zone.count, index, count, false)
	var base := presenter.layout.zone_base(zone)
	flyer.set_meta("shuffle_paper_layers", maxf(1.0, span.y - span.x))
	flyer.set_meta("shuffle_packet_index", index)
	flyer.set_meta("shuffle_packet_count", count)
	var t := clampf(progress, 0.0, 1.0)
	var pose := _packet_pose(base, zone.count, index, count, t)
	# Correct the whole cut as a rigid group. Correcting packets independently
	# near the opposite deck's screen edge pushes their tilted paper planes
	# through one another, even when their original paper intervals are disjoint.
	var volume := Rect2()
	var projection := presenter.world.projection
	for packet in range(count):
		var packet_span := BattleLayout3D.packet_span(zone.count, packet, count, false)
		var half := CardEntity3D.THICKNESS * float(packet_span.y - packet_span.x) * 0.5
		var packet_pose := _packet_pose(base, zone.count, packet, count, t)
		var bounds := projection.project_pose_bounds(packet_pose, half).merge(projection.project_pose_bounds(packet_pose, -half))
		volume = bounds if packet == 0 else volume.merge(bounds)
	var resting_top := base
	resting_top.origin += base.basis.y * CardEntity3D.THICKNESS * zone.count
	var top_limit := minf(78.0, projection.project_pose_bounds(resting_top, 0.0).position.y)
	var dock := presenter.table.get_global_transform_with_canvas().affine_inverse() * presenter.global_bounds(zone)
	var allowed := dock.grow(dock.size.x * 0.20).intersection(Rect2(16, top_limit, presenter.size.x - 32, presenter.size.y - 16 - top_limit))
	var correction := Vector2.ZERO
	if volume.position.x < allowed.position.x: correction.x = allowed.position.x - volume.position.x
	if volume.end.x > allowed.end.x: correction.x = allowed.end.x - volume.end.x
	if volume.position.y < allowed.position.y: correction.y = allowed.position.y - volume.position.y
	if volume.end.y > allowed.end.y: correction.y = allowed.end.y - volume.end.y
	if not correction.is_zero_approx():
		pose.origin += projection.screen_to_world(projection.world_to_screen(base.origin) + correction, base.origin.y) - base.origin
	flyer.set_meta("paper_glint", sin(t * PI) * 0.20)
	flyer.set_meta("paper_sweep", t)
	flyer.world_pose = pose
	flyer.has_world_pose = true
	flyer.visible = true
	var to_effects := presenter.table.effects.get_global_transform_with_canvas().affine_inverse() * presenter.table.get_global_transform_with_canvas()
	flyer.position = to_effects * projection.world_to_screen(pose.origin) - flyer.size * 0.5
	flyer.scale = Vector2.ONE
	flyer.rotation = 0.0


static func _packet_pose(base: Transform3D, cards: int, index: int, count: int, t: float) -> Transform3D:
	var span := BattleLayout3D.packet_span(cards, index, count, false)
	var width := base.basis.x.length()
	var opening := smoothstep(0.0, 0.20, t) * (1.0 - smoothstep(0.76, 0.96, t))
	var side := -1.0 if index % 2 == 0 else 1.0
	var release_delay := float(index) / float(maxi(1, count - 1)) * 0.18
	var insertion := smoothstep(0.27 + release_delay, 0.52 + release_delay, t)
	var spread := opening * (1.0 - insertion) if count > 1 else 0.0
	# Alternating thin packets represent the two interleaving halves. They keep
	# their own paper intervals, so the rapid insertion never passes solid blocks
	# through one another. The entire motion stays within the original deck dock.
	# Cut diagonally, riffle thin slices, then square the whole stack with one
	# shared compression. Parallel packet planes preserve all paper intervals.
	var rig := BattleProjection3D.rotate_card_basis(base.basis,
		Basis(Vector3.RIGHT, deg_to_rad(-6.0 * opening)) * Basis(Vector3.FORWARD, deg_to_rad(1.5 * sin(t * TAU) * opening)))
	var pose := base
	pose.origin += rig.y * (CardEntity3D.THICKNESS * float(span.x + span.y) * 0.5)
	pose.origin += rig.x * side * MotionPolicy.PROFILE.shuffle_spread * spread
	pose.origin += rig.z * side * 0.09 * spread
	pose.origin += rig.y.normalized() * width * 0.008 * index * opening
	var square := sin(smoothstep(0.78, 1.0, t) * PI) * 0.012
	pose.origin += Vector3.UP * width * (MotionPolicy.PROFILE.shuffle_lift * opening + square)
	pose.basis = BattleProjection3D.rotate_card_basis(rig, Basis(Vector3.UP, deg_to_rad(side * 3.0 * spread)))
	return pose
