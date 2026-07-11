extends Node

## Implements a `:focus-visible`-style policy for the whole application.
## Pointer/touch activation keeps the real focus owner for accessibility and
## modal restoration, but hides BaseButton focus chrome until navigation input
## resumes from the keyboard or a controller.

signal focus_visibility_changed(visible: bool)

const POINTER_BUTTON := MOUSE_BUTTON_LEFT
const JOYPAD_AXIS_THRESHOLD := 0.5

var _focus_visible := true
var _styled_control: Control
var _styled_state: Dictionary = {}
var _empty_focus_style := StyleBoxEmpty.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var viewport := get_viewport()
	if viewport and not viewport.gui_focus_changed.is_connected(_on_gui_focus_changed):
		viewport.gui_focus_changed.connect(_on_gui_focus_changed)
	call_deferred("_refresh_focus_style")


func _exit_tree() -> void:
	_restore_styled_control()


func _input(event: InputEvent) -> void:
	if _is_pointer_activation(event):
		_set_focus_visible(false)
		# The GUI may assign focus after the autoload receives the input event.
		call_deferred("_refresh_focus_style")
	elif _is_navigation_input(event):
		_set_focus_visible(true)


func is_focus_visible() -> bool:
	return _focus_visible


func _set_focus_visible(value: bool) -> void:
	if _focus_visible == value:
		_refresh_focus_style()
		return
	_focus_visible = value
	_refresh_focus_style()
	focus_visibility_changed.emit(_focus_visible)


func _on_gui_focus_changed(_control: Control) -> void:
	_refresh_focus_style()


func _refresh_focus_style() -> void:
	_restore_styled_control()
	var viewport := get_viewport()
	var owner := viewport.gui_get_focus_owner() if viewport else null
	if owner:
		owner.queue_redraw()
	if _focus_visible or not (owner is BaseButton):
		return
	_hide_button_focus(owner as BaseButton)


func _hide_button_focus(control: BaseButton) -> void:
	_styled_control = control
	_styled_state = {
		"had_style": control.has_theme_stylebox_override(&"focus"),
		"style": control.get_theme_stylebox(&"focus"),
		"had_font_color": control.has_theme_color_override(&"font_focus_color"),
		"font_color": control.get_theme_color(&"font_focus_color"),
		"had_icon_color": control.has_theme_color_override(&"icon_focus_color"),
		"icon_color": control.get_theme_color(&"icon_focus_color"),
	}
	control.add_theme_stylebox_override(&"focus", _empty_focus_style)
	if control.has_theme_color(&"font_color"):
		control.add_theme_color_override(
			&"font_focus_color", control.get_theme_color(&"font_color")
		)
	if control.has_theme_color(&"icon_normal_color"):
		control.add_theme_color_override(
			&"icon_focus_color", control.get_theme_color(&"icon_normal_color")
		)
	control.queue_redraw()


func _restore_styled_control() -> void:
	if _styled_control == null or not is_instance_valid(_styled_control):
		_styled_control = null
		_styled_state.clear()
		return
	if bool(_styled_state.get("had_style", false)):
		_styled_control.add_theme_stylebox_override(
			&"focus", _styled_state.get("style") as StyleBox
		)
	else:
		_styled_control.remove_theme_stylebox_override(&"focus")
	if bool(_styled_state.get("had_font_color", false)):
		_styled_control.add_theme_color_override(
			&"font_focus_color", _styled_state.get("font_color", Color.WHITE)
		)
	else:
		_styled_control.remove_theme_color_override(&"font_focus_color")
	if bool(_styled_state.get("had_icon_color", false)):
		_styled_control.add_theme_color_override(
			&"icon_focus_color", _styled_state.get("icon_color", Color.WHITE)
		)
	else:
		_styled_control.remove_theme_color_override(&"icon_focus_color")
	_styled_control.queue_redraw()
	_styled_control = null
	_styled_state.clear()


func _is_pointer_activation(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		return mouse_event.pressed and mouse_event.button_index == POINTER_BUTTON
	if event is InputEventScreenTouch:
		return (event as InputEventScreenTouch).pressed
	return false


func _is_navigation_input(event: InputEvent) -> bool:
	if event is InputEventKey:
		var key_event := event as InputEventKey
		return key_event.pressed and not key_event.echo
	if event is InputEventJoypadButton:
		return (event as InputEventJoypadButton).pressed
	if event is InputEventJoypadMotion:
		return absf((event as InputEventJoypadMotion).axis_value) >= JOYPAD_AXIS_THRESHOLD
	return false
