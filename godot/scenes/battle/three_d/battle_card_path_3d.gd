class_name BattleCardPath3D
extends RefCounted

## Smooth projected travel and size between the close-up display and the table.
static func transfer(projection: BattleProjection3D, start: Transform3D, finish: Transform3D, progress: float, arc: float = 24.0) -> Transform3D:
	var t := clampf(progress, 0, 1)
	if t <= 0.0: return start
	if t >= 1.0: return finish
	var camera := projection.camera
	var a := projection.world_to_screen(start.origin)
	var b := projection.world_to_screen(finish.origin)
	var point := a.lerp(b, t) - Vector2(0, sin(t * PI) * arc)
	var depth_a := maxf(0.1, -camera.to_local(start.origin).z)
	var depth_b := maxf(0.1, -camera.to_local(finish.origin).z)
	var depth := lerpf(depth_a, depth_b, t)
	var rotation := start.basis.orthonormalized().get_rotation_quaternion().slerp(finish.basis.orthonormalized().get_rotation_quaternion(), t)
	var scale := (start.basis.get_scale() / depth_a).lerp(finish.basis.get_scale() / depth_b, t) * depth
	var pose := Transform3D(Basis(rotation) * Basis.from_scale(scale), projection.camera_plane_point(point, depth))
	# Turning a revealed card toward the opposite hand rotates its long axis
	# across the screen. Keep the displayed width on the same smooth path as its
	# travel, so that rotation does not briefly enlarge the card.
	var width := lerpf(projection.project_pose_bounds(start).size.x, projection.project_pose_bounds(finish).size.x, t)
	var projected_width := projection.project_pose_bounds(pose).size.x
	pose.basis = pose.basis.scaled(Vector3.ONE * width / maxf(0.001, projected_width))
	return pose

static func attachment(start: Transform3D, finish: Transform3D, progress: float, departing: bool, arriving: bool) -> Transform3D:
	var exit_pose := start
	var entry := finish
	if departing: exit_pose.origin += start.basis.x * 1.02
	if arriving: entry.origin += finish.basis.x * 1.02
	var departure_end := 0.18 if departing else 0.0
	var entry_start := 0.76 if arriving else 1.0
	if departing and progress < departure_end:
		return start.interpolate_with(exit_pose, smoothstep(0.0, 1.0, progress / departure_end))
	if arriving and progress >= entry_start:
		return entry.interpolate_with(finish, smoothstep(0.0, 1.0, (progress - entry_start) / (1.0 - entry_start)))
	var t := clampf((progress - departure_end) / maxf(0.01, entry_start - departure_end), 0, 1)
	t = smoothstep(0.0, 1.0, t)
	var pose := exit_pose.interpolate_with(entry, t)
	pose.origin.y += sin(t * PI) * 0.35
	return pose
