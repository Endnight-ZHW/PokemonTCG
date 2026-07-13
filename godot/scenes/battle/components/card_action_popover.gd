class_name CardActionPopover
extends Control

signal action_chosen(action: GameAction)
signal dismissed
signal outside_pressed(global_position: Vector2)

@export_range(200.0, 260.0, 1.0) var preferred_width := 236.0
@export_range(200.0, 260.0, 1.0) var minimum_width := 200.0
@export_range(200.0, 260.0, 1.0) var maximum_width := 260.0
@export var action_button_height := 48.0
@export_range(1, 8, 1) var maximum_visible_actions := 4
@export var anchor_gap := 10.0
@export var pointer_max_length := 34.0

@onready var pointer_line: Line2D = %PointerLine
@onready var panel: PanelContainer = %Panel
@onready var title_label: Label = %TitleLabel
@onready var hint_label: Label = %HintLabel
@onready var empty_hint: Label = %EmptyHint
@onready var action_scroll: ScrollContainer = %ActionScroll
@onready var action_buttons: VBoxContainer = %ActionButtons
@onready var compact_scroll: ScrollContainer = %CompactScroll
@onready var compact_action_buttons: HBoxContainer = %CompactActionButtons

var current_placement := ""

var _rows: Array[Dictionary] = []
var _source_rect := Rect2()
var _safe_rect := Rect2()
var _avoid_rects: Array[Rect2] = []
var _source_control_ref: WeakRef
var _avoid_control_refs: Array[WeakRef] = []
var _uses_viewport_safe_rect := false
var _compact_layout := false
var _last_tracked_source_rect := Rect2()
var _icon_thumbnail_cache: Dictionary[int, Texture2D] = {}


func _ready() -> void:
	_resolve_nodes()
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(false)
	visible = false
	var viewport := get_viewport()
	if viewport and not viewport.size_changed.is_connected(_on_viewport_size_changed):
		viewport.size_changed.connect(_on_viewport_size_changed)


## Rectangles are expressed in global canvas coordinates. Row metadata is kept
## on each generated button under `row`, `hint`, and `icon`.
func show_actions(
	rows: Array[Dictionary],
	source_rect: Rect2,
	safe_rect: Rect2 = Rect2(),
	avoid_rects: Array = [],
	title := "可执行动作",
	hint := "",
) -> void:
	_source_control_ref = null
	_avoid_control_refs.clear()
	set_process(false)
	_present(rows, source_rect, safe_rect, _rect_array(avoid_rects), title, hint)


## Tracks a source card while it moves or the table is relaid out.
func show_for_control(
	rows: Array[Dictionary],
	source_control: Control,
	safe_rect: Rect2 = Rect2(),
	avoid_controls: Array = [],
	title := "可执行动作",
	hint := "",
) -> void:
	if source_control == null or not is_instance_valid(source_control):
		return
	_source_control_ref = weakref(source_control)
	_avoid_control_refs.clear()
	for value in avoid_controls:
		if value is Control and is_instance_valid(value):
			_avoid_control_refs.append(weakref(value))
	var tracked_avoid_rects := _tracked_avoid_rects()
	_present(
		rows,
		source_control.get_global_rect(),
		safe_rect,
		tracked_avoid_rects,
		title,
		hint,
	)
	_last_tracked_source_rect = source_control.get_global_rect()
	set_process(true)


## Compatibility alias for callers that use "present" terminology.
func present(
	rows: Array[Dictionary],
	source_rect: Rect2,
	safe_rect: Rect2 = Rect2(),
	avoid_rects: Array = [],
	title := "可执行动作",
	hint := "",
) -> void:
	show_actions(rows, source_rect, safe_rect, avoid_rects, title, hint)


func reposition(
	source_rect: Rect2,
	safe_rect: Rect2 = Rect2(),
	avoid_rects: Array = [],
) -> void:
	_source_rect = source_rect
	if safe_rect.size.x > 0.0 and safe_rect.size.y > 0.0:
		_safe_rect = safe_rect
		_uses_viewport_safe_rect = false
	elif _uses_viewport_safe_rect:
		_safe_rect = _default_safe_rect()
	_avoid_rects = _rect_array(avoid_rects)
	if visible:
		_layout_popover()


func refresh_position() -> void:
	if visible:
		_layout_popover()


func dismiss(emit_dismissed := true) -> void:
	if not visible:
		return
	visible = false
	pointer_line.visible = false
	set_process(false)
	if emit_dismissed:
		dismissed.emit()


func panel_global_rect() -> Rect2:
	return panel.get_global_rect() if panel else Rect2()


func is_compact_layout() -> bool:
	return _compact_layout


func button_count() -> int:
	return _rows.size()


func overlaps_avoid_rects() -> bool:
	var panel_rect := panel_global_rect()
	for avoid_rect in _avoid_rects:
		if panel_rect.intersects(avoid_rect):
			return true
	return false


func _present(
	rows: Array[Dictionary],
	source_rect: Rect2,
	safe_rect: Rect2,
	avoid_rects: Array[Rect2],
	title: String,
	hint: String,
) -> void:
	_resolve_nodes()
	_rows = rows.duplicate()
	_source_rect = source_rect
	_uses_viewport_safe_rect = safe_rect.size.x <= 0.0 or safe_rect.size.y <= 0.0
	_safe_rect = _default_safe_rect() if _uses_viewport_safe_rect else safe_rect
	_avoid_rects = avoid_rects.duplicate()
	_build_content(title, hint)
	visible = true
	_layout_popover()


func _build_content(title: String, hint: String) -> void:
	_clear_buttons(action_buttons)
	_clear_buttons(compact_action_buttons)
	_compact_layout = false
	action_scroll.visible = true
	compact_scroll.visible = false

	title_label.text = title
	title_label.visible = not title.is_empty()
	hint_label.text = hint
	hint_label.visible = not hint.is_empty() and not _rows.is_empty()
	empty_hint.text = hint if not hint.is_empty() else "当前没有可执行动作"
	empty_hint.visible = _rows.is_empty()
	action_scroll.visible = not _rows.is_empty()

	for row in _rows:
		action_buttons.add_child(_action_button(row))

	var visible_count := mini(maximum_visible_actions, maxi(1, _rows.size()))
	var actions_height := (
		float(visible_count) * action_button_height
		+ float(maxi(0, visible_count - 1)) * 4.0
	)
	action_scroll.custom_minimum_size.y = actions_height
	action_scroll.vertical_scroll_mode = (
		ScrollContainer.SCROLL_MODE_AUTO
		if _rows.size() > maximum_visible_actions
		else ScrollContainer.SCROLL_MODE_DISABLED
	)
	compact_scroll.custom_minimum_size.y = action_button_height


func _action_button(row: Dictionary) -> Button:
	var action: GameAction = row.get("action") as GameAction
	if action == null and row.get("action") is Dictionary:
		action = GameAction.from_dict(row.get("action"))
	var button := Button.new()
	var label := str(row.get("label", action.action if action else "动作"))
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0.0, action_button_height)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.text = label
	button.tooltip_text = str(row.get("hint", ""))
	button.accessibility_name = label
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.add_theme_font_size_override("font_size", 13)
	button.disabled = action == null or bool(row.get("disabled", false))
	button.set_meta("row", row.duplicate())
	button.set_meta("hint", row.get("hint", ""))
	button.set_meta("icon", row.get("icon"))
	var icon_texture := _resolve_icon_texture(row.get("icon"))
	if icon_texture:
		# A native Button includes the source texture dimensions in its minimum
		# size. Build a tiny presentation copy first so high-resolution energy art
		# cannot stretch the 48 px action row, while retaining native text layout.
		button.icon = _thumbnail_icon(icon_texture)
		button.expand_icon = false
	if action:
		button.pressed.connect(_on_action_button_pressed.bind(action))
	return button


func _resolve_icon_texture(value: Variant) -> Texture2D:
	if value is Texture2D:
		return value as Texture2D
	if value is String:
		var path := str(value)
		if path.begins_with("res://") and ResourceLoader.exists(path, "Texture2D"):
			return load(path) as Texture2D
	return null


func _thumbnail_icon(texture: Texture2D) -> Texture2D:
	var cache_key := texture.get_instance_id()
	if _icon_thumbnail_cache.has(cache_key):
		return _icon_thumbnail_cache[cache_key]
	var source_image := texture.get_image()
	if source_image == null or source_image.is_empty():
		return null
	var thumbnail := source_image.duplicate() as Image
	thumbnail.resize(22, 22, Image.INTERPOLATE_LANCZOS)
	var result := ImageTexture.create_from_image(thumbnail)
	_icon_thumbnail_cache[cache_key] = result
	return result


func _layout_popover() -> void:
	if panel == null or _safe_rect.size.x <= 0.0 or _safe_rect.size.y <= 0.0:
		return
	_set_compact_layout(false)
	var panel_size := _desired_panel_size(false)
	var placement := _preferred_placement(panel_size)
	if not bool(placement.get("valid", false)):
		_set_compact_layout(true)
		panel_size = _desired_panel_size(true)
		placement = _preferred_placement(panel_size)
	if not bool(placement.get("valid", false)):
		placement = _nearest_free_placement(panel_size)

	panel.custom_minimum_size = panel_size
	panel.size = panel_size
	panel.global_position = placement.get("position", _safe_rect.position)
	current_placement = str(placement.get("direction", "compact"))
	if _compact_layout and not current_placement.begins_with("compact_"):
		current_placement = "compact_" + current_placement
	_update_pointer()


func _desired_panel_size(compact_layout: bool) -> Vector2:
	var width := clampf(preferred_width, minimum_width, maximum_width)
	width = minf(width, _safe_rect.size.x)
	var content_height := action_button_height
	if not _rows.is_empty() and not compact_layout:
		var visible_count := mini(maximum_visible_actions, _rows.size())
		content_height = (
			float(visible_count) * action_button_height
			+ float(maxi(0, visible_count - 1)) * 4.0
		)
	var height := 20.0 + content_height
	if title_label.visible:
		height += 22.0
	if hint_label.visible:
		height += 34.0
	if title_label.visible or hint_label.visible:
		height += 6.0
	height = minf(height, _safe_rect.size.y)
	return Vector2(width, height)


## Returns the first non-overlapping placement in the required order:
## above, right, left, below.
func _preferred_placement(panel_size: Vector2) -> Dictionary:
	for candidate in _placement_candidates(panel_size):
		var raw_position: Vector2 = candidate["position"]
		var position := _clamp_to_safe_rect(raw_position, panel_size)
		var rect := Rect2(position, panel_size)
		if not _collides(rect):
			return {
				"valid": true,
				"position": position,
				"direction": candidate["direction"],
			}
	return {"valid": false}


func _placement_candidates(panel_size: Vector2) -> Array[Dictionary]:
	var center := _source_rect.get_center()
	return [
		{
			"direction": "above",
			"position": Vector2(
				center.x - panel_size.x * 0.5,
				_source_rect.position.y - anchor_gap - panel_size.y,
			),
		},
		{
			"direction": "right",
			"position": Vector2(
				_source_rect.end.x + anchor_gap,
				center.y - panel_size.y * 0.5,
			),
		},
		{
			"direction": "left",
			"position": Vector2(
				_source_rect.position.x - anchor_gap - panel_size.x,
				center.y - panel_size.y * 0.5,
			),
		},
		{
			"direction": "below",
			"position": Vector2(
				center.x - panel_size.x * 0.5,
				_source_rect.end.y + anchor_gap,
			),
		},
	]


func _nearest_free_placement(panel_size: Vector2) -> Dictionary:
	var best_position := _safe_rect.position
	var best_score := INF
	var step := 24.0
	var max_x := maxf(_safe_rect.position.x, _safe_rect.end.x - panel_size.x)
	var max_y := maxf(_safe_rect.position.y, _safe_rect.end.y - panel_size.y)
	var y := _safe_rect.position.y
	while y <= max_y + 0.1:
		var x := _safe_rect.position.x
		while x <= max_x + 0.1:
			var position := Vector2(minf(x, max_x), minf(y, max_y))
			var rect := Rect2(position, panel_size)
			if not _collides(rect):
				var score := rect.get_center().distance_squared_to(_source_rect.get_center())
				if score < best_score:
					best_score = score
					best_position = position
			x += step
		y += step
	if best_score < INF:
		return {
			"valid": true,
			"position": best_position,
			"direction": "free",
		}

	# Extremely small safe areas may have no collision-free solution. Keep the
	# panel in bounds and choose the candidate with the least covered target area.
	for candidate in _placement_candidates(panel_size):
		var position := _clamp_to_safe_rect(candidate["position"], panel_size)
		var rect := Rect2(position, panel_size)
		var score := _collision_area(rect)
		if score < best_score:
			best_score = score
			best_position = position
			current_placement = str(candidate["direction"])
	return {
		"valid": false,
		"position": best_position,
		"direction": current_placement if not current_placement.is_empty() else "fallback",
	}


func _clamp_to_safe_rect(position: Vector2, panel_size: Vector2) -> Vector2:
	var maximum := _safe_rect.end - panel_size
	return Vector2(
		clampf(position.x, _safe_rect.position.x, maxf(_safe_rect.position.x, maximum.x)),
		clampf(position.y, _safe_rect.position.y, maxf(_safe_rect.position.y, maximum.y)),
	)


func _collides(rect: Rect2) -> bool:
	if rect.intersects(_source_rect.grow(2.0)):
		return true
	for avoid_rect in _avoid_rects:
		if rect.intersects(avoid_rect.grow(2.0)):
			return true
	return false


func _collision_area(rect: Rect2) -> float:
	var result := _intersection_area(rect, _source_rect.grow(2.0))
	for avoid_rect in _avoid_rects:
		result += _intersection_area(rect, avoid_rect.grow(2.0))
	return result


func _intersection_area(first: Rect2, second: Rect2) -> float:
	if not first.intersects(second):
		return 0.0
	return first.intersection(second).get_area()


func _set_compact_layout(value: bool) -> void:
	if _compact_layout == value:
		return
	_compact_layout = value
	var from_container: Container = (
		action_buttons if value else compact_action_buttons
	)
	var to_container: Container = (
		compact_action_buttons if value else action_buttons
	)
	var children := from_container.get_children()
	for child in children:
		from_container.remove_child(child)
		to_container.add_child(child)
		if child is Button:
			(child as Button).custom_minimum_size = Vector2(
				112.0 if value else 0.0,
				action_button_height,
			)
	action_scroll.visible = not value and not _rows.is_empty()
	compact_scroll.visible = value and not _rows.is_empty()


func _update_pointer() -> void:
	var panel_rect := panel_global_rect()
	var panel_point := _closest_point(panel_rect, _source_rect.get_center())
	var source_point := _closest_point(_source_rect, panel_rect.get_center())
	var delta := source_point - panel_point
	if delta.length_squared() <= 1.0:
		pointer_line.visible = false
		return
	if delta.length() > pointer_max_length:
		source_point = panel_point + delta.normalized() * pointer_max_length
	var inverse := get_global_transform_with_canvas().affine_inverse()
	pointer_line.points = PackedVector2Array([
		inverse * panel_point,
		inverse * source_point,
	])
	pointer_line.visible = true


func _closest_point(rect: Rect2, point: Vector2) -> Vector2:
	return Vector2(
		clampf(point.x, rect.position.x, rect.end.x),
		clampf(point.y, rect.position.y, rect.end.y),
	)


func _tracked_avoid_rects() -> Array[Rect2]:
	var result: Array[Rect2] = []
	for ref in _avoid_control_refs:
		var control = ref.get_ref()
		if control is Control and is_instance_valid(control) and control.visible:
			result.append(control.get_global_rect())
	return result


func _process(_delta: float) -> void:
	if not visible or _source_control_ref == null:
		return
	var source_control = _source_control_ref.get_ref()
	if not (source_control is Control) or not is_instance_valid(source_control):
		dismiss()
		return
	var next_source_rect: Rect2 = source_control.get_global_rect()
	var next_avoid_rects := _tracked_avoid_rects()
	if (
		next_source_rect != _last_tracked_source_rect
		or next_avoid_rects != _avoid_rects
	):
		_source_rect = next_source_rect
		_last_tracked_source_rect = next_source_rect
		_avoid_rects = next_avoid_rects
		_layout_popover()


func _gui_input(event: InputEvent) -> void:
	if (
		event is InputEventMouseButton
		and event.pressed
		and event.button_index == MOUSE_BUTTON_LEFT
		and not panel_global_rect().has_point(get_global_mouse_position())
	):
		outside_pressed.emit(get_global_mouse_position())
		accept_event()
		dismiss()
	elif event is InputEventScreenTouch and event.pressed:
		var touch := event as InputEventScreenTouch
		var global_touch: Vector2 = get_global_transform_with_canvas() * touch.position
		if not panel_global_rect().has_point(global_touch):
			outside_pressed.emit(global_touch)
			accept_event()
			dismiss()


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		dismiss()


func _on_action_button_pressed(action: GameAction) -> void:
	if action == null:
		return
	dismiss(false)
	action_chosen.emit(action)


func _on_viewport_size_changed() -> void:
	if not visible:
		return
	if _uses_viewport_safe_rect:
		_safe_rect = _default_safe_rect()
	_layout_popover()


func _default_safe_rect() -> Rect2:
	var viewport := get_viewport()
	if viewport:
		return viewport.get_visible_rect()
	if size.x > 0.0 and size.y > 0.0:
		return Rect2(global_position, size)
	return Rect2(Vector2.ZERO, Vector2(1280.0, 720.0))


func _rect_array(values: Array) -> Array[Rect2]:
	var result: Array[Rect2] = []
	for value in values:
		if value is Rect2:
			result.append(value)
	return result


func _clear_buttons(container: Container) -> void:
	if container == null:
		return
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


func _resolve_nodes() -> void:
	pointer_line = get_node_or_null("PointerLine") as Line2D
	panel = get_node_or_null("Panel") as PanelContainer
	title_label = get_node_or_null("Panel/Margin/Content/TitleLabel") as Label
	hint_label = get_node_or_null("Panel/Margin/Content/HintLabel") as Label
	empty_hint = get_node_or_null("Panel/Margin/Content/EmptyHint") as Label
	action_scroll = get_node_or_null("Panel/Margin/Content/ActionScroll") as ScrollContainer
	action_buttons = get_node_or_null(
		"Panel/Margin/Content/ActionScroll/ActionButtons"
	) as VBoxContainer
	compact_scroll = get_node_or_null("Panel/Margin/Content/CompactScroll") as ScrollContainer
	compact_action_buttons = get_node_or_null(
		"Panel/Margin/Content/CompactScroll/CompactActionButtons"
	) as HBoxContainer
