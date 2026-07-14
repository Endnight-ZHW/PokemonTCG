class_name BattleEffectLayer
extends Control

var particles: Array[Dictionary] = []
var floating_texts: Array[Dictionary] = []
var impact_rings: Array[Dictionary] = []
var quality_profile := "high"
const MAX_PARTICLES := 220
const MAX_FLOATING_TEXTS := 18
const MAX_IMPACT_RINGS := 24
const REDUCED_SLOT_RADIUS := 14.0
const REDUCED_SLOT_OFFSET := Vector2(22.0, 32.0)
const FLOATING_TEXT_FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres")

var _reduced_slot_frame := -1
var _reduced_slot_groups: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func burst(position_value: Vector2, color: Color, kind: String) -> void:
	var count := 10 if quality_profile == "low" else 18 if quality_profile == "medium" else 28
	if kind in ["evolution", "ko"]:
		count = int(count * 1.5)
	var available := maxi(0, MAX_PARTICLES - particles.size())
	count = mini(count, available)
	for index in range(count):
		var angle := TAU * float(index) / float(maxi(1, count))
		angle += randf_range(-0.22, 0.22)
		var speed := randf_range(55.0, 150.0)
		particles.append({
			"position": position_value,
			"velocity": Vector2.from_angle(angle) * speed,
			"color": color.lightened(randf_range(-0.08, 0.2)),
			"life": randf_range(0.38, 0.76),
			"total": 0.76,
			"size": randf_range(2.0, 6.0),
			"gravity": Vector2(0, 65.0),
			"shape": "streak" if index % 3 == 0 else "spark" if index % 3 == 1 else "orb",
		})
	var ring_count_before := impact_rings.size()
	_add_impact_rings(position_value, color, kind)
	if count > 0 or impact_rings.size() > ring_count_before:
		_update_processing()
		queue_redraw()


func floating_text(
	text: String,
	position_value: Vector2,
	color: Color,
	drift: bool = true,
) -> MotionHandle:
	while floating_texts.size() >= MAX_FLOATING_TEXTS:
		var removed: Dictionary = floating_texts.pop_front()
		var removed_handle := removed.get("motion_handle") as MotionHandle
		if removed_handle != null:
			removed_handle.cancel()
	var handle := MotionHandle.new()
	var motion_duration := _floating_motion_duration(drift)
	var resolved_position := position_value
	if motion_duration <= 0.0:
		resolved_position = _reduced_slot_position(position_value)
		handle.finish()
	floating_texts.append({
		"text": text,
		"position": resolved_position,
		"anchor_position": position_value,
		"color": color,
		"life": 1.05,
		"total": 1.05,
		"velocity": Vector2(0.0, -38.0) if drift else Vector2.ZERO,
		"motion_remaining": motion_duration,
		"motion_handle": handle,
		"created_frame": Engine.get_process_frames(),
	})
	_update_processing()
	queue_redraw()
	return handle


func clear_transients() -> void:
	var removed_texts := floating_texts.duplicate()
	particles.clear()
	floating_texts.clear()
	impact_rings.clear()
	_reduced_slot_groups.clear()
	_reduced_slot_frame = -1
	set_process(false)
	queue_redraw()
	# Cancel after clearing local arrays so a completion callback that advances
	# the Director cannot have its newly-created feedback erased reentrantly.
	for row_value in removed_texts:
		var row: Dictionary = row_value
		var handle := row.get("motion_handle") as MotionHandle
		if handle != null:
			handle.cancel()


func _process(delta: float) -> void:
	var had_transients := (
		not particles.is_empty()
		or not floating_texts.is_empty()
		or not impact_rings.is_empty()
	)
	var live_particles: Array[Dictionary] = []
	for row in particles:
		row["life"] = float(row["life"]) - delta
		if float(row["life"]) <= 0.0:
			continue
		row["velocity"] = Vector2(row["velocity"]) + Vector2(row["gravity"]) * delta
		row["position"] = Vector2(row["position"]) + Vector2(row["velocity"]) * delta
		live_particles.append(row)
	particles = live_particles
	var live_texts: Array[Dictionary] = []
	for row in floating_texts:
		row["life"] = float(row["life"]) - delta
		if float(row["life"]) <= 0.0:
			var expired_handle := row.get("motion_handle") as MotionHandle
			if expired_handle != null:
				expired_handle.finish()
			continue
		var motion_remaining := float(row.get("motion_remaining", 0.0))
		if motion_remaining > 0.0:
			var motion_step := minf(delta, motion_remaining)
			row["position"] = (
				Vector2(row["position"])
				+ Vector2(row.get("velocity", Vector2(0.0, -38.0)))
				* motion_step
			)
			motion_remaining = maxf(0.0, motion_remaining - motion_step)
			row["motion_remaining"] = motion_remaining
			if motion_remaining <= 0.0:
				var motion_handle := row.get("motion_handle") as MotionHandle
				if motion_handle != null:
					motion_handle.finish()
		live_texts.append(row)
	floating_texts = live_texts
	var live_rings: Array[Dictionary] = []
	for row in impact_rings:
		row["life"] = float(row["life"]) - delta
		if float(row["life"]) > 0.0:
			live_rings.append(row)
	impact_rings = live_rings
	if had_transients:
		queue_redraw()
	_update_processing()


func _update_processing() -> void:
	set_process(
		not particles.is_empty()
		or not floating_texts.is_empty()
		or not impact_rings.is_empty()
	)


func _floating_motion_duration(drift: bool) -> float:
	if not drift or MotionPolicy.reduced():
		return 0.0
	# Finish positional writes before the shortest damage-event barrier. The text
	# may remain visible while fading, but its anchor is stable when input returns.
	# Keep more than one 30 FPS frame of headroom before the event barrier so
	# process ordering cannot produce a final positional write after input unlocks.
	return MotionPolicy.duration("damage") * 0.60


func _reduced_slot_position(anchor: Vector2) -> Vector2:
	var frame := Engine.get_process_frames()
	if frame != _reduced_slot_frame:
		_reduced_slot_frame = frame
		_reduced_slot_groups.clear()
	var slot := 0
	var matched := false
	for index in range(_reduced_slot_groups.size()):
		var group: Dictionary = _reduced_slot_groups[index]
		if Vector2(group.get("anchor", anchor)).distance_to(anchor) > REDUCED_SLOT_RADIUS:
			continue
		slot = int(group.get("count", 0))
		group["count"] = slot + 1
		_reduced_slot_groups[index] = group
		matched = true
		break
	if not matched:
		_reduced_slot_groups.append({"anchor": anchor, "count": 1})
	if slot <= 0:
		return anchor
	var row := ceili(float(slot) / 2.0)
	var side := -1.0 if slot % 2 == 1 else 1.0
	return anchor + Vector2(
		REDUCED_SLOT_OFFSET.x * side,
		-REDUCED_SLOT_OFFSET.y * float(row),
	)


func _draw() -> void:
	for row in impact_rings:
		var progress := 1.0 - clampf(float(row["life"]) / float(row["total"]), 0.0, 1.0)
		var ring_color: Color = row["color"]
		ring_color.a = (1.0 - progress) * float(row["alpha"])
		var radius := lerpf(float(row["start_radius"]), float(row["end_radius"]), progress)
		draw_arc(
			Vector2(row["position"]),
			radius,
			0.0,
			TAU,
			64 if quality_profile == "high" else 36,
			ring_color,
			lerpf(float(row["width"]), 1.0, progress),
			true,
		)
	for row in particles:
		var alpha := clampf(float(row["life"]) / float(row["total"]), 0.0, 1.0)
		var color: Color = row["color"]
		color.a = alpha
		var particle_position := Vector2(row["position"])
		var particle_size := float(row["size"]) * (0.55 + alpha * 0.45)
		match str(row.get("shape", "orb")):
			"streak":
				var direction := Vector2(row["velocity"]).normalized()
				draw_line(
					particle_position - direction * particle_size * 2.6,
					particle_position + direction * particle_size * 0.8,
					color,
					maxf(1.0, particle_size * 0.72),
					true,
				)
			"spark":
				draw_set_transform(particle_position, PI * 0.25, Vector2.ONE)
				draw_rect(
					Rect2(Vector2(-particle_size, -particle_size), Vector2.ONE * particle_size * 2.0),
					color,
					true,
				)
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			_:
				draw_circle(particle_position, particle_size, color)
	for row in floating_texts:
		var alpha := clampf(float(row["life"]) / float(row["total"]), 0.0, 1.0)
		var color: Color = row["color"]
		color.a = alpha
		var font := FLOATING_TEXT_FONT
		var text := str(row["text"])
		var position_value: Vector2 = row["position"]
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 28).x
		draw_string(
			font,
			position_value - Vector2(width * 0.5, 0),
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			28,
			color,
		)


func _add_impact_rings(position_value: Vector2, color: Color, kind: String) -> void:
	if quality_profile == "low" and kind not in ["impact", "ko", "evolution"]:
		return
	var ring_count := 1
	if quality_profile == "high" and kind in ["impact", "ko", "evolution", "charge"]:
		ring_count = 3
	elif quality_profile != "low" and kind in ["impact", "ko", "evolution"]:
		ring_count = 2
	while impact_rings.size() + ring_count > MAX_IMPACT_RINGS:
		impact_rings.pop_front()
	for index in range(ring_count):
		var duration := 0.42 + float(index) * 0.10
		impact_rings.append({
			"position": position_value,
			"color": color.lightened(0.12 * float(index)),
			"life": duration,
			"total": duration,
			"start_radius": 10.0 + float(index) * 8.0,
			"end_radius": 78.0 + float(index) * 26.0,
			"width": 4.0 - minf(1.5, float(index) * 0.5),
			"alpha": 0.72 - float(index) * 0.12,
		})
