class_name ZoneView
extends Control

signal activated(card_id: String)
signal inspected(context: Dictionary)
signal action_requested(action: GameAction)

const CARD_BACK_TEXTURE: Texture2D = preload("res://assets/cards/card_back.webp")
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
var _texture_cache: Node

@onready var frame: Panel = %Frame
@onready var image: TextureRect = %Image
@onready var title_label: Label = %TitleLabel
@onready var count_label: Label = %CountLabel
@onready var empty_label: Label = %EmptyLabel
@onready var action_button: Button = %ActionButton
var fallback_back_panel: Panel
var fallback_back_label: Label
var _pending_action_row: Dictionary = {}
var _presentation_hidden := false
var _presentation_tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	gui_input.connect(_on_gui_input)
	action_button.pressed.connect(_on_action_pressed)
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
	queue_redraw()


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


func set_presentation_hidden(value: bool) -> void:
	_presentation_hidden = value
	_kill_presentation_tween()
	_set_top_card_alpha(0.0 if value else 1.0)


func reveal_presentation(duration: float = 0.14, delay: float = 0.0) -> void:
	_presentation_hidden = false
	_kill_presentation_tween()
	if duration <= 0.0:
		_set_top_card_alpha(1.0)
		return
	_presentation_tween = create_tween()
	if delay > 0.0:
		_presentation_tween.tween_interval(delay)
	_presentation_tween.tween_method(_set_top_card_alpha, 0.0, 1.0, duration)


func clear_presentation_state() -> void:
	_presentation_hidden = false
	_kill_presentation_tween()
	_set_top_card_alpha(1.0)


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
	var shadow_offset := Vector2(4.0 + table_depth * 4.0, 6.0 + table_depth * 5.0)
	var shadow_color := Color(0.0, 0.0, 0.0, 0.22 + table_depth * 0.18)
	draw_rect(Rect2(shadow_offset, size), shadow_color, true)
	if stack_visual_mode.is_empty() or count <= 0 or stack_visual_max_count <= 0:
		return
	var layers := _stack_layer_count()
	var step := _stack_step()
	for layer in range(layers, 0, -1):
		var offset := step * float(layer)
		var layer_rect := Rect2(offset, size)
		var t := float(layer) / float(maxi(1, layers))
		var fill := _stack_color().darkened(0.04 + t * 0.08)
		fill.a = 0.78
		var paper_edge := _paper_edge_color().lerp(_stack_color(), t * 0.16)
		paper_edge.a = 0.92
		var border := _stack_border_color()
		border.a = 0.70
		draw_rect(layer_rect, paper_edge, true)
		draw_rect(layer_rect.grow(-2.0), fill, true)
		draw_rect(layer_rect, border, false, 1.15)
		var side := Color(0.0, 0.0, 0.0, 0.16 + t * 0.14)
		draw_line(
			layer_rect.position + Vector2(layer_rect.size.x, 4.0),
			layer_rect.position + layer_rect.size + Vector2(0.0, -4.0),
			side,
			2.0,
		)
		var highlight := Color(1.0, 1.0, 1.0, 0.08 - t * 0.025)
		draw_line(
			layer_rect.position + Vector2(5.0, 3.0),
			layer_rect.position + Vector2(layer_rect.size.x - 5.0, 3.0),
			highlight,
			1.0,
		)


func _refresh() -> void:
	if not is_node_ready():
		return
	_ensure_fallback_card_back()
	title_label.text = title
	count_label.text = str(count)
	count_label.visible = count > 0
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
	fallback_back_panel.offset_left = 4.0
	fallback_back_panel.offset_top = 4.0
	fallback_back_panel.offset_right = -4.0
	fallback_back_panel.offset_bottom = -4.0
	fallback_back_panel.visible = false
	fallback_back_panel.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color("#174ea6"),
			7,
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
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and not event.pressed
	):
		if not inspect_context.is_empty():
			inspected.emit(inspect_context.duplicate(true))
		elif not card_id.is_empty():
			activated.emit(card_id)


func _on_action_pressed() -> void:
	var action: GameAction = action_button.get_meta("action") as GameAction
	if action:
		action_requested.emit(action)


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


func _stack_layer_count() -> int:
	var ratio := clampf(
		float(count) / float(maxi(1, stack_visual_max_count)),
		0.0,
		1.0,
	)
	var max_layers := 7
	if stack_visual_mode == "deck":
		max_layers = 9
	elif stack_visual_mode == "discard":
		max_layers = 8
	return clampi(int(ceil(ratio * float(max_layers))), 1, max_layers)


func _stack_step() -> Vector2:
	var depth_scale := 0.75 + table_depth * 0.55
	match stack_visual_direction:
		"down":
			return Vector2(3.6, 3.2) * depth_scale
		"left":
			return Vector2(-3.6, 2.4) * depth_scale
		"right":
			return Vector2(3.6, 2.4) * depth_scale
	return Vector2(3.6, -3.2) * depth_scale


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
	frame.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(fill, 8, border, 2, 0),
	)
	if count_label:
		count_label.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				DesignTokens.GOLD,
				12,
				Color(1, 1, 1, 0.70),
				1,
				0,
			),
		)
