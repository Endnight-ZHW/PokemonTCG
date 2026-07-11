class_name ModalHost
extends Node

const FRONTEND_THEME := preload("res://ui/frontend/front_end_theme.tres")

var modal_layer: Control
var modal_panel: PanelContainer
var modal_body: VBoxContainer
var modal_confirm: Button
var modal_cancel: Button
var previous_focus: Control
var pending_focus: Control
var active_spec: ModalSpec
var _focus_scheduled := false


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
	if modal_layer and not modal_layer.visible:
		var viewport := modal_layer.get_viewport()
		previous_focus = viewport.gui_get_focus_owner() if viewport else null
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


func focus_initial(preferred: Control = null) -> void:
	pending_focus = preferred
	if _focus_scheduled:
		return
	_focus_scheduled = true
	call_deferred("_focus_initial_deferred")


func restore_focus() -> void:
	if (
		previous_focus
		and is_instance_valid(previous_focus)
		and previous_focus.is_inside_tree()
		and previous_focus.is_visible_in_tree()
	):
		previous_focus.grab_focus.call_deferred()
	previous_focus = null
	active_spec = null


func reset_surface() -> void:
	if modal_panel:
		modal_panel.theme = null


func _focus_initial_deferred() -> void:
	_focus_scheduled = false
	if modal_layer == null or not modal_layer.visible:
		pending_focus = null
		return
	var preferred := pending_focus
	pending_focus = null
	var focusables: Array[Control] = []
	_collect_focusables(modal_body, focusables)
	if modal_cancel and modal_cancel.visible and not modal_cancel.disabled:
		focusables.append(modal_cancel)
	if modal_confirm and modal_confirm.visible and not modal_confirm.disabled:
		focusables.append(modal_confirm)
	if focusables.is_empty():
		return
	for index in range(focusables.size()):
		var control := focusables[index]
		var next_control := focusables[(index + 1) % focusables.size()]
		var previous_control := focusables[posmod(index - 1, focusables.size())]
		var next_path := control.get_path_to(next_control)
		var previous_path := control.get_path_to(
			previous_control
		)
		control.focus_next = next_path
		control.focus_previous = previous_path
		# Preserve page-authored directional navigation (for example the Help
		# category row's left/right loop), while repairing missing or stale paths
		# so directional focus still cannot escape the active modal.
		_ensure_direction_neighbor(
			control, &"focus_neighbor_bottom", next_control, focusables
		)
		_ensure_direction_neighbor(
			control, &"focus_neighbor_right", next_control, focusables
		)
		_ensure_direction_neighbor(
			control, &"focus_neighbor_top", previous_control, focusables
		)
		_ensure_direction_neighbor(
			control, &"focus_neighbor_left", previous_control, focusables
		)
	var target := preferred
	if (
		target == null
		or not is_instance_valid(target)
		or not target.is_inside_tree()
		or not target.is_visible_in_tree()
		or target.focus_mode != Control.FOCUS_ALL
	):
		target = focusables[0]
	if not target.is_inside_tree():
		return
	target.grab_focus()


func _ensure_direction_neighbor(
	control: Control,
	property: StringName,
	fallback: Control,
	focusables: Array[Control],
) -> void:
	var path: NodePath = control.get(property)
	var existing := control.get_node_or_null(path) as Control if not path.is_empty() else null
	var usable := (
		existing != null
		and existing in focusables
		and existing.is_visible_in_tree()
		and existing.focus_mode == Control.FOCUS_ALL
		and not (existing is BaseButton and (existing as BaseButton).disabled)
	)
	if not usable:
		control.set(property, control.get_path_to(fallback))


func _collect_focusables(node: Node, output: Array[Control]) -> void:
	if node == null:
		return
	for child in node.get_children():
		if child is Control:
			var control := child as Control
			if not control.is_inside_tree() or not control.is_visible_in_tree():
				continue
			if (
				not control.mouse_filter == Control.MOUSE_FILTER_IGNORE
				and control.focus_mode == Control.FOCUS_ALL
				and not (control is BaseButton and (control as BaseButton).disabled)
			):
				output.append(control)
		_collect_focusables(child, output)


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
