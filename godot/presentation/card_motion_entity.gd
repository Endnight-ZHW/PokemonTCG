class_name CardMotionEntity
extends Control

var visual_id := ""
var source_pose := Transform3D.IDENTITY
var target_pose := Transform3D.IDENTITY
var physical_entity: CardEntity3D
var world_pose := Transform3D.IDENTITY
var has_world_pose := false
var texture: Texture2D
var resolved_world_pose := Transform3D.IDENTITY
var has_resolved_world_pose := false

func current_pose() -> Variant:
	if has_world_pose: return world_pose
	if has_resolved_world_pose: return resolved_world_pose
	return null


func configure_motion(p_visual_id: String) -> void:
	visual_id = p_visual_id
	set_meta("card_motion_entity", true)
	set_meta("visual_id", visual_id)
