class_name ZoneView
extends Control

signal activated(card_id: String)
signal stack_index_activated(index: int)
signal inspected(context: Dictionary)
signal detail_requested(card_id: String)
signal action_requested(action: GameAction)
signal card_dropped(
	hand_index: int,
	card_id: String,
	target_player: int,
	target_slot: String,
)

const CARD_BACK_TEXTURE: Texture2D = preload("res://assets/cards/card_back.webp")
const LONG_PRESS_MSEC := 350
const TAP_MOVE_THRESHOLD := 14.0
const MIN_CARD_CORNER_RADIUS := 3
const MAX_CARD_CORNER_RADIUS := 6
const DECK_MAX_LAYERS := 6
const DISCARD_MAX_LAYERS := 6
const STACK_MAX_DEPTH := 12.0
static var _fallback_card_back_cache: Texture2D

var title := ""
var card_id := ""
var count := 0
var is_hidden_zone := false
var target_player := -1
var target_slot := ""
var inspect_context: Dictionary = {}
var catalog: CardCatalog = CardCatalog.shared()
var stack_visual_mode := ""
var stack_visual_max_count := 0
var stack_visual_direction := "up"
var table_depth := 0.55
var _stack_card_size := Vector2.ZERO
var actionable := false
var _allowed_drop_hand_indices: Array[int] = []
var _drop_highlighted := false
var _texture_cache: Node
var _pressed := false
var _press_msec := 0
var _press_position := Vector2.ZERO

@onready var frame: Panel = %Frame
@onready var image: TextureRect = %Image
@onready var title_label: Label = %TitleLabel
@onready var count_label: Label = %CountLabel
@onready var empty_label: Label = %EmptyLabel
@onready var action_button: Button = %ActionButton
@onready var drop_hint: Label = %DropHint
var fallback_back_panel: Panel
var fallback_back_label: Label
var _pending_action_row: Dictionary = {}
var _presentation_hidden := false
var _stack_presentation_hidden := false
var _presentation_tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	gui_input.connect(_on_gui_input)
	action_button.pressed.connect(_on_action_pressed)
	resized.connect(_on_resized)
	_ensure_fallback_card_back()
	_refresh()
	set_action(_pending_action_row)


func set_catalog(value: CardCatalog) -> void:
	catalog = value if value != null else CardCatalog.shared()
	if is_node_ready():
		_refresh()


func configure(
	p_title: String,
	p_card_id: String,
	p_count: int,
	p_hidden: bool = false,
	p_context: Dictionary = {},
) -> void:
	title = p_title
	card_id = p_card_id
	count = p_count
	is_hidden_zone = p_hidden
	inspect_context = p_context.duplicate(true)
	inspect_context["title"] = title
	inspect_context["count"] = count
	inspect_context["card_id"] = card_id
	inspect_context["hidden"] = is_hidden_zone
	if not is_node_ready():
		call_deferred("_refresh")
		return
	_refresh()
	queue_redraw()


func set_stack_visual(
	mode: String,
	max_count: int,
	direction: String = "up",
) -> void:
	stack_visual_mode = mode
	stack_visual_max_count = maxi(0, max_count)
	stack_visual_direction = direction
	if stack_visual_mode == "prizes" and _stack_card_size.length_squared() <= 1.0:
		_stack_card_size = size if size.length_squared() > 1.0 else custom_minimum_size
	if is_node_ready():
		_apply_stack_geometry()
		_refresh()
	else:
		queue_redraw()


func set_stack_card_size(value: Vector2) -> void:
	_stack_card_size = Vector2(maxf(1.0, value.x), maxf(1.0, value.y))
	_apply_stack_geometry()
	_layout_count_badge()
	queue_redraw()


func get_stack_visual_rect() -> Rect2:
	var face_size := _stack_face_size()
	var result := Rect2(Vector2.ZERO, face_size)
	if stack_visual_mode.is_empty() or count <= 0 or stack_visual_max_count <= 0:
		return result
	return result.merge(Rect2(get_stack_visual_extent(), face_size))


func get_stack_visual_max_rect() -> Rect2:
	var face_size := _stack_face_size()
	var result := Rect2(Vector2.ZERO, face_size)
	if stack_visual_mode.is_empty() or stack_visual_max_count <= 0:
		return result
	return result.merge(Rect2(get_stack_visual_max_extent(), face_size))


func get_stack_face_size() -> Vector2:
	return _stack_face_size()


func get_stack_face_rect() -> Rect2:
	return Rect2(Vector2.ZERO, _stack_face_size())


func set_table_depth(value: float) -> void:
	table_depth = clampf(value, 0.0, 1.0)
	queue_redraw()
	_apply_frame_style()


func set_action(row: Dictionary = {}) -> void:
	_pending_action_row = row.duplicate()
	if not is_node_ready() or action_button == null:
		return
	var action: GameAction = row.get("action")
	action_button.visible = action != null
	if action == null:
		action_button.set_meta("action", null)
		return
	action_button.text = str(row.get("label", action.action))
	action_button.set_meta("action", action)


func set_actionable(value: bool) -> void:
	actionable = value
	_apply_frame_style()


func get_stack_visual_extent() -> Vector2:
	if stack_visual_mode.is_empty() or count <= 0 or stack_visual_max_count <= 0:
		return Vector2.ZERO
	return _stack_step() * float(_stack_layer_count())


func get_stack_visual_max_extent() -> Vector2:
	if stack_visual_mode in ["deck", "discard"]:
		return _stack_extent_for_depth(_stack_max_depth())
	if stack_visual_mode == "prizes":
		return _stack_step() * float(maxi(0, stack_visual_max_count - 1))
	return get_stack_visual_extent()


func get_stack_motion_step() -> Vector2:
	if stack_visual_mode in ["deck", "discard"]:
		# Motion choreography uses four stable depth stops, independent of the
		# current count and the number of decorative paper edges being drawn.
		return get_stack_visual_max_extent() / 4.0
	return _stack_step()


func is_actionable() -> bool:
	return actionable


func _has_point(point: Vector2) -> bool:
	if stack_visual_mode == "prizes":
		# The root reserves six-card capacity for stable layout, but only the cards
		# currently visible (plus their tray edge) should receive inspection input.
		return get_stack_visual_rect().grow(6.0).has_point(point)
	return Rect2(Vector2.ZERO, size).has_point(point)


func set_drop_target(
	player: int,
	slot: String,
	allowed_hand_indices: Array = [],
) -> void:
	target_player = player
	target_slot = slot
	_allowed_drop_hand_indices.clear()
	for value in allowed_hand_indices:
		var hand_index := int(value)
		if hand_index >= 0 and hand_index not in _allowed_drop_hand_indices:
			_allowed_drop_hand_indices.append(hand_index)
	if drop_hint:
		drop_hint.visible = _drop_highlighted and not _allowed_drop_hand_indices.is_empty()
		drop_hint.text = "打出竞技场"
	_apply_frame_style()


func get_allowed_drop_hand_indices() -> Array[int]:
	return _allowed_drop_hand_indices.duplicate()


func set_drop_highlight(value: bool) -> void:
	_drop_highlighted = value and not _allowed_drop_hand_indices.is_empty()
	if drop_hint:
		drop_hint.visible = _drop_highlighted
	_apply_frame_style()


func set_presentation_hidden(value: bool) -> void:
	_presentation_hidden = value
	_kill_presentation_tween()
	if stack_visual_mode == "prizes":
		# Prize fans are rendered as individual backs. Stage one incoming card by
		# shortening the fan at its right edge; only a one-card fan needs its Frame
		# hidden as well.
		_set_top_card_alpha(0.0 if value and count <= 1 else 1.0)
		queue_redraw()
		return
	_set_top_card_alpha(0.0 if value else 1.0)


func set_stack_presentation_hidden(value: bool) -> void:
	_stack_presentation_hidden = value
	if frame != null:
		frame.visible = not value
	queue_redraw()


func is_stack_presentation_hidden() -> bool:
	return _stack_presentation_hidden


func reveal_presentation(duration: float = 0.14, delay: float = 0.0) -> void:
	_presentation_hidden = false
	_kill_presentation_tween()
	if stack_visual_mode == "prizes":
		_set_top_card_alpha(1.0)
		queue_redraw()
		return
	if duration <= 0.0:
		_set_top_card_alpha(1.0)
		return
	_presentation_tween = create_tween()
	if delay > 0.0:
		_presentation_tween.tween_interval(delay)
	_presentation_tween.tween_method(_set_top_card_alpha, 0.0, 1.0, duration)


func clear_presentation_state() -> void:
	_presentation_hidden = false
	_stack_presentation_hidden = false
	_kill_presentation_tween()
	if frame != null:
		frame.visible = true
	_set_top_card_alpha(1.0)
	queue_redraw()


func is_presentation_hidden() -> bool:
	return _presentation_hidden


func has_visible_card_back() -> bool:
	if not is_hidden_zone or count <= 0:
		return false
	_ensure_fallback_card_back()
	if (
		fallback_back_panel != null
		and image != null
		and image.texture == null
	):
		fallback_back_panel.visible = true
		if not _presentation_hidden:
			fallback_back_panel.modulate.a = 1.0
	var image_visible := (
		image != null
		and image.texture != null
		and image.modulate.a > 0.01
	)
	var fallback_visible := (
		fallback_back_panel != null
		and fallback_back_panel.visible
		and fallback_back_panel.modulate.a > 0.01
	)
	return image_visible or fallback_visible


func _draw() -> void:
	if _stack_presentation_hidden:
		return
	var shadow_offset := Vector2(2.0 + table_depth * 2.0, 3.0 + table_depth * 3.0)
	var shadow_color := Color(0.0, 0.0, 0.0, 0.20 + table_depth * 0.14)
	var face_size := _stack_face_size()
	var visual_rect := get_stack_visual_rect()
	if stack_visual_mode == "prizes":
		var displayed_count := maxi(0, count - (1 if _presentation_hidden else 0))
		var displayed_rect := Rect2(Vector2.ZERO, face_size)
		if displayed_count > 1:
			displayed_rect = displayed_rect.merge(Rect2(
				_stack_step() * float(displayed_count - 1),
				face_size,
			))
		_draw_prize_fan(
			displayed_rect,
			face_size,
			shadow_offset,
			shadow_color,
			displayed_count,
		)
		return
	draw_rect(Rect2(visual_rect.position + shadow_offset, visual_rect.size), shadow_color, true)
	if stack_visual_mode.is_empty() or count <= 0 or stack_visual_max_count <= 0:
		return
	var layers := _stack_layer_count()
	var step := _stack_step()
	for layer in range(layers, 0, -1):
		var offset := step * float(layer)
		var layer_rect := Rect2(offset, face_size)
		var t := float(layer) / float(maxi(1, layers))
		var fill := _stack_color().darkened(0.02 + t * 0.07)
		fill.a = 0.90
		var paper_edge := _paper_edge_color().lerp(_stack_color(), t * 0.16)
		paper_edge.a = 0.96
		var border := _stack_border_color()
		border.a = 0.62
		draw_rect(layer_rect, paper_edge, true)
		draw_rect(layer_rect.grow(-1.35), fill, true)
		draw_rect(layer_rect, border, false, 1.0)
		var exposes_left := stack_visual_direction in ["down_left", "left"]
		var side_x := (
			layer_rect.position.x + 1.0
			if exposes_left
			else layer_rect.end.x - 1.0
		)
		var side := Color(0.0, 0.0, 0.0, 0.18 + t * 0.13)
		draw_line(
			Vector2(side_x, layer_rect.position.y + 3.0),
			Vector2(side_x, layer_rect.end.y - 3.0),
			side,
			1.35,
		)
		var edge_y := (
			layer_rect.end.y - 1.0
			if stack_visual_direction.begins_with("down")
			else layer_rect.position.y + 1.0
		)
		var highlight := Color(1.0, 1.0, 1.0, 0.18 - t * 0.04)
		draw_line(
			Vector2(layer_rect.position.x + 4.0, edge_y),
			Vector2(layer_rect.end.x - 4.0, edge_y),
			highlight,
			1.0,
		)


func _draw_prize_fan(
	visual_rect: Rect2,
	face_size: Vector2,
	shadow_offset: Vector2,
	shadow_color: Color,
	displayed_count: int,
) -> void:
	if displayed_count <= 0 or stack_visual_max_count <= 0:
		draw_rect(
			Rect2(visual_rect.position + shadow_offset, visual_rect.size),
			shadow_color,
			true,
		)
		return
	var tray_rect := visual_rect.grow(5.0)
	draw_rect(
		Rect2(tray_rect.position + shadow_offset, tray_rect.size),
		shadow_color,
		true,
	)
	draw_rect(tray_rect, Color(0.018, 0.032, 0.058, 0.92), true)
	var tray_border := _stack_border_color()
	tray_border.a = 0.80
	draw_rect(tray_rect, tray_border, false, 1.5)
	var layers := maxi(0, displayed_count - 1)
	var step := _stack_step()
	for layer in range(layers, 0, -1):
		var layer_rect := Rect2(step * float(layer), face_size)
		draw_rect(layer_rect, _paper_edge_color(), true)
		draw_texture_rect(
			CARD_BACK_TEXTURE,
			layer_rect.grow(-2.0),
			false,
			Color(0.96, 0.97, 1.0, 1.0),
		)
		var border := _stack_border_color()
		border.a = 0.82
		draw_rect(layer_rect, border, false, 1.15)


func _refresh() -> void:
	if not is_node_ready():
		return
	_ensure_fallback_card_back()
	title_label.text = title
	title_label.visible = stack_visual_mode.is_empty()
	count_label.text = str(count)
	count_label.visible = count > 0
	_layout_count_badge()
	tooltip_text = "%s · %d 张" % [title, count]
	var texture_path := ""
	var texture: Texture2D = null
	if is_hidden_zone and count > 0:
		texture_path = "res://assets/cards/card_back.webp"
		texture = CARD_BACK_TEXTURE
	elif not card_id.is_empty():
		texture_path = str(catalog.get_card(card_id).get("image_path", ""))
	if texture == null and not texture_path.is_empty():
		texture = _card_texture(texture_path)
	if texture == null and is_hidden_zone and count > 0:
		texture = _fallback_card_back_texture()
	image.texture = texture
	var show_fallback := is_hidden_zone and count > 0 and image.texture == null
	if fallback_back_panel:
		fallback_back_panel.visible = show_fallback
	empty_label.visible = image.texture == null and not show_fallback
	empty_label.text = "空%s" % title
	if not _presentation_hidden:
		_set_top_card_alpha(1.0)
	if frame != null:
		frame.visible = not _stack_presentation_hidden
	_apply_frame_style()
	queue_redraw()


func _ensure_fallback_card_back() -> void:
	if frame == null:
		frame = get_node_or_null("Frame") as Panel
	if image == null and frame != null:
		image = frame.get_node_or_null("Image") as TextureRect
	if fallback_back_panel != null or frame == null:
		return
	fallback_back_panel = Panel.new()
	fallback_back_panel.name = "FallbackCardBack"
	fallback_back_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fallback_back_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fallback_back_panel.offset_left = 2.0
	fallback_back_panel.offset_top = 2.0
	fallback_back_panel.offset_right = -2.0
	fallback_back_panel.offset_bottom = -2.0
	fallback_back_panel.visible = false
	fallback_back_panel.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color("#174ea6"),
			_card_corner_radius(),
			Color("#f1d35a"),
			3,
			0,
		),
	)
	frame.add_child(fallback_back_panel)
	frame.move_child(fallback_back_panel, max(1, image.get_index() + 1))

	fallback_back_label = Label.new()
	fallback_back_label.name = "FallbackCardBackLabel"
	fallback_back_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fallback_back_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fallback_back_label.text = "Pokémon"
	fallback_back_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fallback_back_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	fallback_back_label.add_theme_color_override("font_color", Color("#fff2a6"))
	fallback_back_label.add_theme_font_size_override("font_size", 12)
	fallback_back_panel.add_child(fallback_back_label)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressed = true
			_press_msec = Time.get_ticks_msec()
			_press_position = event.position
			accept_event()
		elif _pressed:
			_pressed = false
			_finish_pointer_interaction(event.position)
			accept_event()


func _finish_pointer_interaction(release_position: Vector2) -> void:
	var held := Time.get_ticks_msec() - _press_msec
	var moved := release_position.distance_to(_press_position)
	if held >= LONG_PRESS_MSEC and not card_id.is_empty():
		detail_requested.emit(card_id)
	elif moved < TAP_MOVE_THRESHOLD:
		if stack_visual_mode == "prizes" and count > 0:
			stack_index_activated.emit(_prize_index_at_point(release_position))
			return
		if not inspect_context.is_empty():
			inspected.emit(inspect_context.duplicate(true))
		elif not card_id.is_empty():
			activated.emit(card_id)


func _prize_index_at_point(point: Vector2) -> int:
	var step_x := maxf(1.0, absf(_stack_step().x))
	return clampi(int(floor(maxf(0.0, point.x) / step_x)), 0, maxi(0, count - 1))


func _on_action_pressed() -> void:
	var action: GameAction = action_button.get_meta("action") as GameAction
	if action:
		action_requested.emit(action)


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if (
		target_slot.is_empty()
		or not data is Dictionary
		or str(data.get("kind", "")) != "hand_card"
	):
		return false
	return _allowed_drop_hand_indices.has(int(data.get("hand_index", -1)))


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if not _can_drop_data(Vector2.ZERO, data):
		return
	card_dropped.emit(
		int(data.get("hand_index", -1)),
		str(data.get("card_id", "")),
		target_player,
		target_slot,
	)


func _card_texture(path: String) -> Texture2D:
	var texture_cache := _card_texture_cache()
	if texture_cache and texture_cache.has_method("get_texture"):
		return texture_cache.call("get_texture", path) as Texture2D
	return load(path) as Texture2D


static func _fallback_card_back_texture() -> Texture2D:
	if _fallback_card_back_cache != null:
		return _fallback_card_back_cache
	var width := 96
	var height := 136
	var image_value := Image.create(width, height, false, Image.FORMAT_RGBA8)
	image_value.fill(Color("#102c74"))
	image_value.fill_rect(Rect2i(0, 0, width, height), Color("#d4b12a"))
	image_value.fill_rect(Rect2i(4, 4, width - 8, height - 8), Color("#f5e07c"))
	image_value.fill_rect(Rect2i(8, 8, width - 16, height - 16), Color("#123b91"))
	image_value.fill_rect(Rect2i(14, 14, width - 28, height - 28), Color("#1f62c9"))
	image_value.fill_rect(Rect2i(22, 22, width - 44, height - 44), Color("#f7f1d0"))
	image_value.fill_rect(Rect2i(28, 28, width - 56, height - 56), Color("#2c77d8"))
	image_value.fill_rect(Rect2i(8, height / 2 - 4, width - 16, 8), Color("#f5e07c"))
	image_value.fill_rect(Rect2i(width / 2 - 4, 8, 8, height - 16), Color("#f5e07c"))
	_fallback_card_back_cache = ImageTexture.create_from_image(image_value)
	return _fallback_card_back_cache


func _card_texture_cache() -> Node:
	if _texture_cache and is_instance_valid(_texture_cache):
		return _texture_cache
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	_texture_cache = tree.root.get_node_or_null("CardTextureCache")
	return _texture_cache


func _set_top_card_alpha(alpha: float) -> void:
	for node in [image, empty_label, fallback_back_panel]:
		if node:
			node.modulate.a = alpha


func _kill_presentation_tween() -> void:
	if _presentation_tween and _presentation_tween.is_valid():
		_presentation_tween.kill()
	_presentation_tween = null


func _stack_face_size() -> Vector2:
	if stack_visual_mode == "prizes" and _stack_card_size.length_squared() > 1.0:
		return _stack_card_size
	if size.length_squared() > 1.0:
		return size
	return custom_minimum_size


func _apply_stack_geometry() -> void:
	if stack_visual_mode == "prizes":
		var required_size := get_stack_visual_max_rect().size
		custom_minimum_size = required_size
		if not size.is_equal_approx(required_size):
			size = required_size
	_layout_stack_face()


func _layout_stack_face() -> void:
	if frame == null:
		return
	if stack_visual_mode == "prizes":
		var face_size := _stack_face_size()
		frame.anchor_left = 0.0
		frame.anchor_top = 0.0
		frame.anchor_right = 0.0
		frame.anchor_bottom = 0.0
		frame.offset_left = 0.0
		frame.offset_top = 0.0
		frame.offset_right = face_size.x
		frame.offset_bottom = face_size.y
		return
	frame.anchor_left = 0.0
	frame.anchor_top = 0.0
	frame.anchor_right = 1.0
	frame.anchor_bottom = 1.0
	frame.offset_left = 0.0
	frame.offset_top = 0.0
	frame.offset_right = 0.0
	frame.offset_bottom = 0.0


func _stack_layer_count() -> int:
	if count <= 1 or stack_visual_max_count <= 1:
		return 0
	if stack_visual_mode in ["deck", "discard"]:
		var max_layers := (
			DECK_MAX_LAYERS
			if stack_visual_mode == "deck"
			else DISCARD_MAX_LAYERS
		)
		var layer_spacing := maxf(1.5, 2.0 * _stack_size_scale())
		return clampi(
			int(ceil(_stack_depth_for_count() / layer_spacing)),
			1,
			mini(count - 1, max_layers),
		)
	var ratio := clampf(
		float(count - 1) / float(maxi(1, stack_visual_max_count - 1)),
		0.0,
		1.0,
	)
	var max_layers := maxi(1, stack_visual_max_count - 1)
	return clampi(int(ceil(ratio * float(max_layers))), 1, max_layers)


func _stack_step() -> Vector2:
	var layers := maxi(1, _stack_layer_count())
	if stack_visual_mode in ["deck", "discard"]:
		# Divide the count-driven physical depth across a bounded number of paper
		# edges, so the pile grows continuously without ballooning off the table.
		return _stack_total_extent() / float(layers)
	if stack_visual_mode == "prizes":
		return Vector2(clampf(_stack_face_size().x * 0.17, 11.0, 18.0), 0.0)
	var depth_scale := 0.75 + table_depth * 0.55
	match stack_visual_direction:
		"down_left":
			return Vector2(-3.6, 2.4) * depth_scale
		"up_right":
			return Vector2(3.6, -2.4) * depth_scale
		"down":
			return Vector2(3.6, 3.2) * depth_scale
		"left":
			return Vector2(-3.6, 2.4) * depth_scale
		"right":
			return Vector2(3.6, 2.4) * depth_scale
	return Vector2(3.6, -3.2) * depth_scale


func _stack_total_extent() -> Vector2:
	return _stack_extent_for_depth(_stack_depth_for_count())


func _stack_depth_for_count() -> float:
	if count <= 1 or stack_visual_max_count <= 1:
		return 0.0
	var ratio := clampf(
		float(count - 1) / float(stack_visual_max_count - 1),
		0.0,
		1.0,
	)
	var scale_value := _stack_size_scale()
	return maxf(
		1.25 * scale_value,
		_stack_max_depth() * pow(ratio, 0.65),
	)


func _stack_max_depth() -> float:
	return STACK_MAX_DEPTH * _stack_size_scale()


func _stack_size_scale() -> float:
	var card_width := _stack_face_size().x
	return clampf(card_width / 96.0, 0.82, 1.12)


func _stack_extent_for_depth(total_depth: float) -> Vector2:
	match stack_visual_direction:
		"down_left":
			return Vector2(-total_depth * 0.42, total_depth)
		"up_right":
			return Vector2(total_depth * 0.42, -total_depth)
		"down":
			return Vector2(total_depth * 0.42, total_depth)
		"left":
			return Vector2(-total_depth, total_depth * 0.42)
		"right":
			return Vector2(total_depth, total_depth * 0.42)
	return Vector2(total_depth * 0.42, -total_depth)


func _stack_color() -> Color:
	match stack_visual_mode:
		"deck":
			return Color("#2b3342")
		"prizes":
			return Color("#48313c")
		"discard":
			return Color("#28323d")
	return Color("#253240")


func _paper_edge_color() -> Color:
	if stack_visual_mode == "prizes":
		return Color("#d6c8d2")
	return Color("#d9dde2")


func _stack_border_color() -> Color:
	match stack_visual_mode:
		"deck":
			return DesignTokens.GOLD.darkened(0.25)
		"discard":
			return DesignTokens.CYAN.darkened(0.25)
		"prizes":
			return DesignTokens.PURPLE.lightened(0.10)
	return DesignTokens.BORDER.lightened(0.18)


func _apply_frame_style() -> void:
	if frame == null:
		return
	var fill := Color(0.045, 0.07, 0.11, 0.90)
	var border := DesignTokens.BORDER.lightened(table_depth * 0.16)
	if is_hidden_zone and count > 0:
		fill = Color("#172038")
		border = DesignTokens.GOLD.darkened(0.16)
	elif stack_visual_mode == "discard" and count > 0:
		fill = Color(0.052, 0.070, 0.088, 0.94)
		border = DesignTokens.CYAN.darkened(0.18)
	elif not card_id.is_empty():
		fill = Color(0.055, 0.08, 0.12, 0.92)
		border = DesignTokens.CYAN.darkened(0.18)
	if actionable or _drop_highlighted:
		border = DesignTokens.CYAN
	var frame_style := DesignTokens.panel_style(
		fill,
		_card_corner_radius(),
		border,
		2 if actionable or _drop_highlighted or stack_visual_mode in ["deck", "discard"] else 1,
		0,
	)
	if actionable or _drop_highlighted:
		frame_style.shadow_color = Color(0.20, 0.78, 1.0, 0.46)
		frame_style.shadow_size = 3
		frame_style.shadow_offset = Vector2.ZERO
	frame.add_theme_stylebox_override("panel", frame_style)
	if count_label:
		var badge_fill := DesignTokens.GOLD
		var badge_border := Color(1, 1, 1, 0.70)
		var badge_text := DesignTokens.BG_DEEP
		if stack_visual_mode in ["deck", "discard"]:
			badge_fill = Color(0.025, 0.055, 0.095, 0.98)
			badge_border = DesignTokens.GOLD
			badge_text = Color("#ffe071")
		count_label.add_theme_color_override("font_color", badge_text)
		count_label.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				badge_fill,
				10 if stack_visual_mode in ["deck", "discard"] else 4,
				badge_border,
				1,
				0,
			),
		)


func _on_resized() -> void:
	_layout_stack_face()
	_layout_count_badge()
	_apply_frame_style()
	queue_redraw()


func _layout_count_badge() -> void:
	if count_label == null:
		return
	count_label.anchor_top = 1.0
	count_label.anchor_bottom = 1.0
	count_label.offset_top = -24.0
	count_label.offset_bottom = 2.0
	if stack_visual_mode == "deck":
		# Keep the deck count away from the discard-card seam.
		count_label.anchor_left = 0.0
		count_label.anchor_right = 0.0
		count_label.offset_left = -2.0
		count_label.offset_right = 30.0
	elif stack_visual_mode == "prizes":
		var badge_right := _stack_face_size().x + get_stack_visual_extent().x + 2.0
		count_label.anchor_left = 0.0
		count_label.anchor_right = 0.0
		count_label.offset_left = badge_right - 32.0
		count_label.offset_right = badge_right
	else:
		count_label.anchor_left = 1.0
		count_label.anchor_right = 1.0
		count_label.offset_left = -30.0
		count_label.offset_right = 2.0


func _card_corner_radius() -> int:
	var card_width := _stack_face_size().x
	return clampi(
		int(round(card_width / 24.0)),
		MIN_CARD_CORNER_RADIUS,
		MAX_CARD_CORNER_RADIUS,
	)
