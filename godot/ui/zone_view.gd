class_name ZoneView
extends Control

signal activated(card_id: String)
signal action_requested(action: GameAction)

var title := ""
var card_id := ""
var count := 0
var is_hidden_zone := false
var target_player := -1
var target_slot := ""

var frame: Panel
var image: TextureRect
var title_label: Label
var count_label: Label
var empty_label: Label
var action_button: Button
var _pending_action_row: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_build()
	gui_input.connect(_on_gui_input)
	_refresh()
	set_action(_pending_action_row)


func configure(
	p_title: String,
	p_card_id: String,
	p_count: int,
	p_hidden: bool = false,
) -> void:
	title = p_title
	card_id = p_card_id
	count = p_count
	is_hidden_zone = p_hidden
	_refresh()


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


func _build() -> void:
	frame = Panel.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_theme_stylebox_override(
		"panel",
		DesignTokens.panel_style(
			Color(0.045, 0.075, 0.12, 0.88),
			10,
			DesignTokens.BORDER_SOFT,
			1,
			0,
		),
	)
	add_child(frame)
	image = TextureRect.new()
	image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	image.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	image.offset_left = 4
	image.offset_top = 20
	image.offset_right = -4
	image.offset_bottom = -4
	frame.add_child(image)
	title_label = Label.new()
	title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_label.position = Vector2(6, 2)
	title_label.add_theme_font_size_override("font_size", 11)
	title_label.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
	frame.add_child(title_label)
	count_label = Label.new()
	count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count_label.custom_minimum_size = Vector2(30, 30)
	count_label.add_theme_color_override("font_color", DesignTokens.BG_DEEP)
	count_label.add_theme_font_size_override("font_size", 13)
	count_label.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(
			DesignTokens.GOLD,
			15,
			DesignTokens.TEXT,
			1,
			0,
		),
	)
	count_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	count_label.position = Vector2(-35, -35)
	frame.add_child(count_label)
	empty_label = Label.new()
	empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	empty_label.add_theme_font_size_override("font_size", 12)
	empty_label.add_theme_color_override("font_color", DesignTokens.TEXT_MUTED)
	empty_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.add_child(empty_label)
	action_button = Button.new()
	action_button.visible = false
	action_button.custom_minimum_size.y = 32
	action_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	action_button.add_theme_font_size_override("font_size", 11)
	action_button.add_theme_stylebox_override(
		"normal",
		DesignTokens.panel_style(
			Color(0.035, 0.075, 0.12, 0.96),
			7,
			DesignTokens.CYAN,
			1,
			0,
		),
	)
	action_button.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	action_button.offset_left = 5
	action_button.offset_right = -5
	action_button.offset_bottom = -5
	action_button.pressed.connect(func() -> void:
		var action: GameAction = action_button.get_meta("action") as GameAction
		if action:
			action_requested.emit(action)
	)
	add_child(action_button)


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
		texture_path = str(CardDatabase.get_card(card_id).get("image_path", ""))
	image.texture = CardTextureCache.get_texture(texture_path)
	empty_label.visible = image.texture == null
	empty_label.text = "空%s" % title


func _on_gui_input(event: InputEvent) -> void:
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and not event.pressed
		and not card_id.is_empty()
	):
		activated.emit(card_id)
