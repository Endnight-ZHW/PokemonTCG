class_name CardMotionEntity
extends Control

var visual_id := ""
var source_pose: Dictionary = {}
var target_pose: Dictionary = {}
var drag_session_id := ""


func configure_motion(
	p_visual_id: String,
	p_source_pose: Dictionary = {},
	p_target_pose: Dictionary = {},
	p_drag_session_id: String = "",
) -> void:
	visual_id = p_visual_id
	source_pose = p_source_pose.duplicate(true)
	target_pose = p_target_pose.duplicate(true)
	drag_session_id = p_drag_session_id
	set_meta("card_motion_entity", true)
	set_meta("visual_id", visual_id)
	if not drag_session_id.is_empty():
		set_meta("drag_session_id", drag_session_id)


func snap_to_pose(pose: Dictionary) -> void:
	if pose.get("position") is Vector2:
		position = pose["position"]
	if pose.get("size") is Vector2:
		size = pose["size"]
	if pose.has("rotation_degrees"):
		rotation_degrees = float(pose["rotation_degrees"])
	if pose.has("scale") and pose["scale"] is Vector2:
		scale = pose["scale"]
