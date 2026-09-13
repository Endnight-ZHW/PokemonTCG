class_name BattleEffectLayer
extends Control

var table: BattleTable
var floating_texts: Array[Dictionary] = []
const MAX_FLOATING_TEXTS := 18
const REDUCED_SLOT_RADIUS := 14.0
const REDUCED_SLOT_OFFSET := Vector2(22.0, 32.0)
const FLOATING_TEXT_FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres")

var _reduced_slot_frame := -1
var _reduced_slot_groups: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func configure(owner_table: BattleTable) -> void:
	table = owner_table


func burst(position_value: Vector2, color: Color, kind: String) -> void:
	if table == null or table.render3d == null:
		return
	var handle := table.render3d.burst_from(self, position_value, color, kind)
	table.presentation_runtime._register_presentation_feedback_motion(handle)


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
	if table != null and table.render3d != null and table.render3d.world != null:
		table.render3d.world.feedback.clear()
	var removed_texts := floating_texts.duplicate()
	floating_texts.clear()
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
	var had_transients := not floating_texts.is_empty()
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
	if had_transients:
		queue_redraw()
	_update_processing()


func _update_processing() -> void:
	set_process(not floating_texts.is_empty())


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
