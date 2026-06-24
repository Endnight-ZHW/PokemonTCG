class_name ZoneView
extends Control

signal activated(card_id: String)
signal inspected(context: Dictionary)
signal action_requested(action: GameAction)

var title := ""
var card_id := ""
var count := 0
var is_hidden_zone := false
var target_player := -1
var target_slot := ""
var inspect_context: Dictionary = {}
var catalog := CardCatalog.new()
var stack_visual_mode := ""
var stack_visual_max_count := 0
var stack_visual_direction := "up"

@onready var frame: Panel = %Frame
@onready var image: TextureRect = %Image
@onready var title_label: Label = %TitleLabel
@onready var count_label: Label = %CountLabel
@onready var empty_label: Label = %EmptyLabel
@onready var action_button: Button = %ActionButton
var _pending_action_row: Dictionary = {}
var _presentation_hidden := false
var _presentation_tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	gui_input.connect(_on_gui_input)
	action_button.pressed.connect(_on_action_pressed)
	_refresh()
	set_action(_pending_action_row)


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
	_set_content_alpha(0.0 if value else 1.0)


func reveal_presentation(duration: float = 0.14, delay: float = 0.0) -> void:
	_presentation_hidden = false
	_kill_presentation_tween()
	if duration <= 0.0:
		_set_content_alpha(1.0)
		return
	_presentation_tween = create_tween()
	if delay > 0.0:
		_presentation_tween.tween_interval(delay)
	_presentation_tween.tween_method(_set_content_alpha, 0.0, 1.0, duration)


func clear_presentation_state() -> void:
	_presentation_hidden = false
	_kill_presentation_tween()
	_set_content_alpha(1.0)


func is_presentation_hidden() -> bool:
	return _presentation_hidden


func _draw() -> void:
	if stack_visual_mode.is_empty() or count <= 0 or stack_visual_max_count <= 0:
		return
	var layers := _stack_layer_count()
	var step := _stack_step()
	for layer in range(layers, 0, -1):
		var offset := step * float(layer)
		var layer_rect := Rect2(offset, size)
		var t := float(layer) / float(maxi(1, layers))
		var fill := _stack_color().darkened(0.08 + t * 0.12)
		fill.a = 0.64
		var border := DesignTokens.BORDER.lightened(0.18)
		border.a = 0.62
		draw_rect(layer_rect, fill, true)
		draw_rect(layer_rect, border, false, 1.0)


func _refresh() -> void:
	if not is_node_ready():
		return
	title_label.text = title
	count_label.text = str(count)
	count_label.visible = count > 0
	var texture_path := ""
	if is_hidden_zone and count > 0:
		texture_path = "res://assets/cards/card_back.webp"
	elif not card_id.is_empty():
		texture_path = str(catalog.get_card(card_id).get("image_path", ""))
	image.texture = (
		load(texture_path) as Texture2D
		if not texture_path.is_empty() and ResourceLoader.exists(texture_path)
		else null
	)
	empty_label.visible = image.texture == null
	empty_label.text = "空%s" % title
	queue_redraw()


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


func _set_content_alpha(alpha: float) -> void:
	for node in [image, count_label, empty_label]:
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
	var max_layers := 7 if stack_visual_mode == "deck" else 6
	return clampi(int(ceil(ratio * float(max_layers))), 1, max_layers)


func _stack_step() -> Vector2:
	match stack_visual_direction:
		"down":
			return Vector2(3.0, 3.0)
		"left":
			return Vector2(-3.0, 2.0)
		"right":
			return Vector2(3.0, 2.0)
	return Vector2(3.0, -3.0)


func _stack_color() -> Color:
	match stack_visual_mode:
		"deck":
			return Color("#2b3342")
		"prizes":
			return Color("#48313c")
	return Color("#253240")
