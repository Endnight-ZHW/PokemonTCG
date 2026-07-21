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

enum SizeMode {
	FIT_CONTENT,
	PREFERRED,
	FILL_SAFE,
}

enum ButtonRole {
	DEFAULT,
	PRIMARY,
	SECONDARY,
	DANGER,
}

var preferred_size := Vector2(720, 620)
var size_mode := SizeMode.PREFERRED
var surface := Surface.FRONTEND
var opaque_shade := false
var shade_alpha := 0.72
var cancellable := true
var stack_behavior := StackBehavior.REPLACE
var confirm_role := ButtonRole.PRIMARY
var cancel_role := ButtonRole.SECONDARY


static func frontend(
	size: Vector2 = Vector2(820, 680),
	mode: SizeMode = SizeMode.PREFERRED,
) -> ModalSpec:
	var spec := ModalSpec.new()
	spec.preferred_size = size
	spec.size_mode = mode
	spec.surface = Surface.FRONTEND
	spec.shade_alpha = 0.72
	return spec


static func battle(
	size: Vector2 = Vector2(720, 620),
	opaque: bool = false,
	mode: SizeMode = SizeMode.PREFERRED,
) -> ModalSpec:
	var spec := ModalSpec.new()
	spec.preferred_size = size
	spec.size_mode = mode
	spec.surface = Surface.BATTLE
	spec.opaque_shade = opaque
	spec.shade_alpha = 0.86
	return spec


func with_button_roles(
	confirm: ButtonRole,
	cancel: ButtonRole = ButtonRole.SECONDARY,
) -> ModalSpec:
	confirm_role = confirm
	cancel_role = cancel
	return self
