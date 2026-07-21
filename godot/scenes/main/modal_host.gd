class_name ModalHost
extends Node

const FRONTEND_THEME := preload("res://ui/frontend/front_end_theme.tres")

var modal_layer: Control
var modal_panel: PanelContainer
var modal_scroll: ScrollContainer
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
	scroll: ScrollContainer = null,
) -> void:
	modal_layer = layer
	modal_panel = panel
	modal_body = body
	modal_confirm = confirm_button
	modal_cancel = cancel_button
	modal_scroll = scroll


func begin(spec: ModalSpec, available_size: Vector2) -> void:
	active_spec = spec
	if modal_panel:
		modal_panel.theme = FRONTEND_THEME if spec.surface == ModalSpec.Surface.FRONTEND else null
		_apply_layout(spec, available_size)


func update_available_size(available_size: Vector2) -> void:
	if active_spec and modal_panel:
		_apply_layout(active_spec, available_size)


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


func _apply_layout(spec: ModalSpec, available_size: Vector2) -> void:
	var panel_size := _resolved_size(spec, available_size)
	# Reset the previous viewport's scroll floor before changing the panel. A
	# stale 420 px floor can otherwise become the panel's effective minimum and
	# push a resized modal outside the current safe center.
	if modal_scroll:
		modal_scroll.custom_minimum_size.y = 0.0
	modal_panel.custom_minimum_size = panel_size
	if modal_scroll:
		modal_scroll.custom_minimum_size.y = _resolved_scroll_minimum(spec, panel_size)


func _resolved_scroll_minimum(spec: ModalSpec, panel_size: Vector2) -> float:
	if spec.size_mode == ModalSpec.SizeMode.FIT_CONTENT:
		return 0.0
	return minf(420.0, maxf(0.0, panel_size.y - _fixed_vertical_extent()))


func _fixed_vertical_extent() -> float:
	if modal_panel == null:
		return 200.0
	var fixed := 0.0
	var panel_style := modal_panel.get_theme_stylebox(&"panel")
	if panel_style:
		fixed += panel_style.get_minimum_size().y
	var margin := modal_panel.get_node_or_null("Margin") as MarginContainer
	if margin:
		fixed += margin.get_theme_constant(&"margin_top")
		fixed += margin.get_theme_constant(&"margin_bottom")
	var content := modal_panel.get_node_or_null("Margin/Content") as VBoxContainer
	if content:
		var visible_fixed_children := 0
		for child in content.get_children():
			if child is Control and (child as Control).visible:
				visible_fixed_children += 1
				if child != modal_scroll:
					fixed += (child as Control).get_combined_minimum_size().y
		fixed += maxf(0.0, float(visible_fixed_children - 1)) * content.get_theme_constant(
			&"separation"
		)
	return fixed


func _resolved_size(spec: ModalSpec, available: Vector2) -> Vector2:
	var compact := available.x / maxf(available.y, 1.0) < 1.5 or available.x < 1360.0
	var inset := Vector2(24, 24) if compact else Vector2(96, 72)
	var cap := Vector2(
		maxf(1.0, available.x - inset.x),
		maxf(1.0, available.y - inset.y),
	)
	if spec.size_mode == ModalSpec.SizeMode.FILL_SAFE:
		return cap
	var preferred := spec.preferred_size
	if spec.size_mode == ModalSpec.SizeMode.FIT_CONTENT:
		return Vector2(
			clampf(preferred.x, minf(320.0, cap.x), cap.x),
			clampf(preferred.y, 1.0, cap.y),
		)
	var minimum := Vector2(
		minf(560.0, cap.x),
		minf(480.0, cap.y),
	)
	return Vector2(
		clampf(preferred.x, minimum.x, cap.x),
		clampf(preferred.y, minimum.y, cap.y),
	)
