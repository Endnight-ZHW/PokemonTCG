class_name BattleCardPath3D
extends RefCounted

## Every purpose has its own anticipation, travel and approach. Progress is
## wall-clock normalized; applying a second Tween ease would distort contacts.
static func travel(start: Transform3D, finish: Transform3D, progress: float, kind: String, ordinal: int = 0, from_hand: bool = false) -> Transform3D:
	var t := clampf(progress, 0.0, 1.0)
	if t <= 0.0: return start
	if t >= 1.0: return finish
	if kind in ["cards_drawn", "prize_taken"] or from_hand:
		return _clear_flight(start, finish, t, kind, ordinal, from_hand)
	var profile := MotionPolicy.PROFILE
	var width := lerpf(start.basis.x.length(), finish.basis.x.length(), t)
	var u := float(Tween.interpolate_value(0.0, 1.0, t, 1.0, profile.flight_transition as Tween.TransitionType, Tween.EASE_IN_OUT))
	var lift := sin(t * PI) * profile.flight_lift_ratio
	var bank := 0.0
	var pitch := 0.0
	match kind:
		"pokemon_evolved":
			u = smoothstep(0.0, 0.72, t)
			lift = smoothstep(0.0, 0.18, t) * (1.0 - smoothstep(0.78, 1.0, t)) * 0.26
			pitch = sin(t * PI) * -0.10
		"pokemon_played", "trainer_played", "stadium_changed", "tool_attached":
			u = smoothstep(0.08, 0.92, t)
			lift = sin(t * PI) * profile.play_lift
			bank = sin(t * PI) * (0.10 if kind == "trainer_played" else -0.055)
			pitch = -sin(t * PI) * 0.10
		"cards_discarded", "card_moved":
			u = smoothstep(0.0, 1.0, pow(t, 1.15))
			lift = sin(t * PI) * 0.10
			bank = sin(t * PI) * (0.11 + mini(ordinal, 3) * 0.015)
		"ko_leave_play":
			u = smoothstep(0.10, 1.0, t)
			lift = sin(t * PI) * 0.09
			pitch = sin(t * PI) * 0.045
	var pose := start.interpolate_with(finish, u)
	pose.origin.y += width * lift
	pose.basis = BattleProjection3D.rotate_card_basis(pose.basis,
		Basis(Vector3.FORWARD, bank) * Basis(Vector3.RIGHT, pitch))
	return pose


static func _clear_flight(start: Transform3D, finish: Transform3D, t: float, kind: String, ordinal: int, from_hand: bool) -> Transform3D:
	var width := maxf(start.basis.x.length(), finish.basis.x.length())
	var departure := start
	var takeoff_end := 0.20
	if from_hand:
		# Slide parallel to the fan first: lifting a buried hand card immediately
		# would cut through every higher paper layer, even with a tall flight arc.
		var side := signf((finish.origin - start.origin).dot(start.basis.z))
		departure.origin += start.basis.z * (side if side != 0.0 else -1.0) * CardEntity3D.ASPECT * 1.04
	else:
		departure.origin += start.basis.y.normalized() * width * (MotionPolicy.PROFILE.prize_lift if kind == "prize_taken" else MotionPolicy.PROFILE.draw_peel + 0.10)
	if t < takeoff_end:
		return start.interpolate_with(departure, smoothstep(0.0, takeoff_end, t))
	var approach := finish
	approach.origin += finish.basis.y.normalized() * width * 0.30
	if t >= 0.80:
		return approach.interpolate_with(finish, smoothstep(0.80, 1.0, t))
	var u := smoothstep(takeoff_end, 0.80, t)
	var pose := departure.interpolate_with(approach, u)
	pose.origin.y += sin(u * PI) * width * (MotionPolicy.PROFILE.flight_clearance + float(ordinal % 3) * 0.12)
	return pose


static func settle(pose: Transform3D, progress: float) -> Transform3D:
	var p := clampf(progress, 0.0, 1.0)
	var rebound := sin(pow(p, 0.68) * PI) * pow(1.0 - p, 1.5)
	pose.origin.y += pose.basis.x.length() * rebound * MotionPolicy.PROFILE.landing_rebound
	pose.basis = BattleProjection3D.rotate_card_basis(pose.basis,
		Basis(Vector3.RIGHT, -rebound * MotionPolicy.PROFILE.landing_rock))
	return pose


static func flip_progress(kind: String, progress: float) -> float:
	var begin := 0.26
	var end := 0.68
	return smoothstep(begin, end, progress)

## Smooth projected travel and size between the close-up display and the table.
static func transfer(projection: BattleProjection3D, start: Transform3D, finish: Transform3D, progress: float, arc: float = 24.0) -> Transform3D:
	var t := clampf(progress, 0, 1)
	if t <= 0.0: return start
	if t >= 1.0: return finish
	var camera := projection.camera
	var a := projection.world_to_screen(start.origin)
	var b := projection.world_to_screen(finish.origin)
	var travel := smoothstep(0.0, 1.0, t)
	var point := a.lerp(b, travel) - Vector2(0, sin(t * PI) * arc)
	var depth_a := maxf(0.1, -camera.to_local(start.origin).z)
	var depth_b := maxf(0.1, -camera.to_local(finish.origin).z)
	var depth := lerpf(depth_a, depth_b, travel)
	var rotation := start.basis.orthonormalized().get_rotation_quaternion().slerp(finish.basis.orthonormalized().get_rotation_quaternion(), travel)
	var scale := (start.basis.get_scale() / depth_a).lerp(finish.basis.get_scale() / depth_b, travel) * depth
	var pose := Transform3D(Basis(rotation) * Basis.from_scale(scale), projection.camera_plane_point(point, depth))
	# Turning a revealed card toward the opposite hand rotates its long axis
	# across the screen. Keep the displayed width on the same smooth path as its
	# travel, so that rotation does not briefly enlarge the card.
	var width := lerpf(projection.project_pose_bounds(start).size.x, projection.project_pose_bounds(finish).size.x, travel)
	var projected_width := projection.project_pose_bounds(pose).size.x
	pose.basis = pose.basis.scaled(Vector3.ONE * width / maxf(0.001, projected_width))
	return pose

static func attachment(start: Transform3D, finish: Transform3D, progress: float, departing: bool, arriving: bool) -> Transform3D:
	if progress <= 0.0: return start
	if progress >= 1.0: return finish
	var exit_pose := start
	var entry := finish
	if departing:
		exit_pose.origin += start.basis.x * 1.08
	if arriving:
		# Align outside the Pokemon's edge, then slide between parallel paper
		# layers. Descending or banking while already overlapping cuts through it.
		entry.origin += finish.basis.x * 1.08
	var departure_end := 0.22 if departing else 0.0
	var entry_start := 0.70 if arriving else 1.0
	if departing and progress < departure_end:
		return start.interpolate_with(exit_pose, smoothstep(0.0, 1.0, progress / departure_end))
	if arriving and progress >= entry_start:
		var docking := smoothstep(0.0, 1.0, (progress - entry_start) / (1.0 - entry_start))
		return entry.interpolate_with(finish, docking)
	var t := clampf((progress - departure_end) / maxf(0.01, entry_start - departure_end), 0, 1)
	t = smoothstep(0.0, 1.0, t)
	var pose := exit_pose.interpolate_with(entry, t)
	pose.origin.y += sin(t * PI) * finish.basis.x.length() * 0.18
	return pose
