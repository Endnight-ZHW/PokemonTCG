class_name ModalHost
extends Node

const FRONTEND_THEME := preload("res://ui/frontend/front_end_theme.tres")

var modal_layer: Control
var modal_panel: PanelContainer
var modal_body: VBoxContainer
var modal_confirm: Button
var modal_cancel: Button
var active_spec: ModalSpec


func configure(
	layer: Control,
	body: VBoxContainer,
	confirm_button: Button,
	cancel_button: Button,
	panel: PanelContainer = null,
) -> void:
	modal_layer = layer
	modal_panel = panel
	modal_body = body
	modal_confirm = confirm_button
	modal_cancel = cancel_button


func begin(spec: ModalSpec, available_size: Vector2) -> void:
	active_spec = spec
	if modal_panel:
		modal_panel.theme = FRONTEND_THEME if spec.surface == ModalSpec.Surface.FRONTEND else null
		modal_panel.custom_minimum_size = _resolved_size(
			spec.preferred_size,
			available_size,
			spec.surface == ModalSpec.Surface.FRONTEND,
		)


func update_available_size(available_size: Vector2) -> void:
	if active_spec and modal_panel:
		modal_panel.custom_minimum_size = _resolved_size(
			active_spec.preferred_size,
			available_size,
			active_spec.surface == ModalSpec.Surface.FRONTEND,
		)


func clear_body() -> void:
	if modal_body == null:
		return
	for child in modal_body.get_children():
		modal_body.remove_child(child)
		child.queue_free()


func finish() -> void:
	active_spec = null


func reset_surface() -> void:
	if modal_panel:
		modal_panel.theme = null


func _resolved_size(
	preferred: Vector2,
	available: Vector2,
	fill_compact: bool = false,
) -> Vector2:
	var compact := available.x / maxf(available.y, 1.0) < 1.5 or available.x < 1360.0
	var inset := Vector2(24, 24) if compact else Vector2(96, 72)
	var cap := Vector2(
		maxf(1.0, available.x - inset.x),
		maxf(1.0, available.y - inset.y),
	)
	if compact and fill_compact:
		return cap
	var minimum := Vector2(
		minf(560.0, cap.x),
		minf(480.0, cap.y),
	)
	return Vector2(
		clampf(preferred.x, minimum.x, cap.x),
		clampf(preferred.y, minimum.y, cap.y),
	)
