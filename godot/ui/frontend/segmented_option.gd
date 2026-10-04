class_name FrontendSegmentedOption
extends OptionButton

## Keeps OptionButton's item/metadata contract, with direct pointer choices.
var _row: HBoxContainer
var _buttons: Array[Button] = []

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	for state in [&"normal", &"hover", &"pressed", &"disabled", &"focus"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
	for state in [&"font_color", &"font_hover_color", &"font_pressed_color", &"font_disabled_color"]:
		add_theme_color_override(state, Color.TRANSPARENT)
	var blank := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	blank.fill(Color.TRANSPARENT)
	add_theme_icon_override("arrow", ImageTexture.create_from_image(blank))
	add_theme_constant_override("arrow_margin", 0)
	_row = HBoxContainer.new()
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_theme_constant_override("separation", 4)
	add_child(_row)
	_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	call_deferred("refresh_segments")

func refresh_segments() -> void:
	if _row == null:
		return
	custom_minimum_size.x = item_count * 100 + maxi(0, item_count - 1) * 4
	if _buttons.size() != item_count:
		for child in _row.get_children():
			_row.remove_child(child)
			child.queue_free()
		_buttons.clear()
		for index in range(item_count):
			var button := Button.new()
			button.name = "Segment%d" % index
			button.focus_mode = Control.FOCUS_NONE
			button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			button.toggle_mode = true
			button.custom_minimum_size = Vector2(100, 48)
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			button.theme_type_variation = &"FrontCategoryButton"
			button.pressed.connect(_choose.bind(index))
			_row.add_child(button)
			_buttons.append(button)
	for index in range(item_count):
		_buttons[index].text = get_item_text(index)
		_buttons[index].disabled = disabled or is_item_disabled(index)
		_buttons[index].set_pressed_no_signal(selected == index)
		_buttons[index].accessibility_name = "%s：%s" % [accessibility_name, get_item_text(index)]

func _choose(index: int) -> void:
	if disabled or is_item_disabled(index):
		return
	select(index)
	item_selected.emit(index)
	refresh_segments()
