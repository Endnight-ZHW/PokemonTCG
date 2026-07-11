class_name ModalSpec
extends RefCounted

enum Surface {
	FRONTEND,
	BATTLE,
}

enum StackBehavior {
	REPLACE,
	RESTORE_PARENT,
}

var preferred_size := Vector2(720, 620)
var surface := Surface.FRONTEND
var opaque_shade := false
var shade_alpha := 0.72
var cancellable := true
var initial_focus: Control
var stack_behavior := StackBehavior.REPLACE


static func frontend(
	size: Vector2 = Vector2(820, 680),
	focus: Control = null,
) -> ModalSpec:
	var spec := ModalSpec.new()
	spec.preferred_size = size
	spec.surface = Surface.FRONTEND
	spec.shade_alpha = 0.72
	spec.initial_focus = focus
	return spec


static func battle(
	size: Vector2 = Vector2(720, 620),
	opaque: bool = false,
) -> ModalSpec:
	var spec := ModalSpec.new()
	spec.preferred_size = size
	spec.surface = Surface.BATTLE
	spec.opaque_shade = opaque
	spec.shade_alpha = 0.86
	return spec
