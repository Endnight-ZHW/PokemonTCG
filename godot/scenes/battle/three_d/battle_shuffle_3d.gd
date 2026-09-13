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
	var width := base.basis.x.length()
	var opening := smoothstep(0.0, 0.18, t) * (1.0 - smoothstep(0.74, 0.92, t))
	var side := -1.0 if index % 2 == 0 else 1.0
	var release_delay := float(index) / float(maxi(1, count - 1)) * 0.16
	var insertion := smoothstep(0.30 + release_delay, 0.53 + release_delay, t)
	var spread := opening * (1.0 - insertion) if count > 1 else 0.0
	# Alternating thin packets represent the two interleaving halves. They keep
	# their own paper intervals, so the rapid insertion never passes solid blocks
	# through one another. The entire motion stays within the original deck dock.
	var rig := BattleProjection3D.rotate_card_basis(base.basis, Basis(Vector3.RIGHT, deg_to_rad(-4.0 * opening)))
	var pose := base
	pose.origin += rig.y * (CardEntity3D.THICKNESS * float(span.x + span.y) * 0.5)
	pose.origin += rig.x * side * 0.13 * spread
	pose.origin += rig.y.normalized() * width * 0.006 * index * opening
	pose.origin += Vector3.UP * width * 0.055 * opening
	pose.basis = BattleProjection3D.rotate_card_basis(rig, Basis(Vector3.UP, deg_to_rad(side * 2.8 * spread)))
	# Keep the entire volume on screen without moving the resting pile away
	# from its real anchor on compact screens.
	var half := CardEntity3D.THICKNESS * float(flyer.get_meta("shuffle_paper_layers")) * 0.5
	var bounds := presenter.world.projection.project_pose_bounds(pose, half).merge(presenter.world.projection.project_pose_bounds(pose, -half))
	var resting_top := base
	resting_top.origin += base.basis.y * CardEntity3D.THICKNESS * zone.count
	var top_limit := minf(78.0, presenter.world.projection.project_pose_bounds(resting_top, 0.0).position.y)
	var correction := Vector2.ZERO
	if bounds.position.x < 16.0: correction.x = 16.0 - bounds.position.x
	if bounds.end.x > presenter.size.x - 16.0: correction.x = presenter.size.x - 16.0 - bounds.end.x
	if bounds.position.y < top_limit: correction.y = top_limit - bounds.position.y
	if bounds.end.y > presenter.size.y - 16.0: correction.y = presenter.size.y - 16.0 - bounds.end.y
	if not correction.is_zero_approx():
		pose.origin = presenter.world.projection.screen_to_world(presenter.world.projection.world_to_screen(pose.origin) + correction, pose.origin.y)
	flyer.world_pose = pose
	flyer.has_world_pose = true
	flyer.visible = true
	var to_effects := presenter.table.effects.get_global_transform_with_canvas().affine_inverse() * presenter.table.get_global_transform_with_canvas()
	flyer.position = to_effects * presenter.world.projection.world_to_screen(pose.origin) - flyer.size * 0.5
	flyer.scale = Vector2.ONE
	flyer.rotation = 0.0
