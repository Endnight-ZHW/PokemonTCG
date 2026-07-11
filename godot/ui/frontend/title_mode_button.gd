@tool
class_name TitleModeButton
extends Button

## Focusable title-screen CTA whose chrome is drawn in code so it stays crisp
## across desktop, ultrawide and Android canvas scales.

const TITLE_FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres")
const BODY_FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_semibold.tres")

@export var title_text := "对战入口":
	set(value):
		title_text = value
		queue_redraw()
@export var subtitle_text := "选择一种对战方式":
	set(value):
		subtitle_text = value
		queue_redraw()
@export var mode_icon: Texture2D:
	set(value):
		mode_icon = value
		queue_redraw()
@export var accent_color := Color("#55b8ff"):
	set(value):
		accent_color = value
		queue_redraw()
@export var fill_color := Color("#246fce"):
	set(value):
		fill_color = value
		queue_redraw()
@export var foreground_color := Color.WHITE:
	set(value):
		foreground_color = value
		queue_redraw()


func _ready() -> void:
	flat = true
	text = ""
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var empty_style := StyleBoxEmpty.new()
	for style_name in [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled", &"focus"]:
		add_theme_stylebox_override(style_name, empty_style)
	for signal_name in [
		&"mouse_entered", &"mouse_exited", &"focus_entered", &"focus_exited",
		&"button_down", &"button_up",
	]:
		var callback := Callable(self, "queue_redraw")
		if not is_connected(signal_name, callback):
			connect(signal_name, callback)
	resized.connect(queue_redraw)
	queue_redraw()


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var mode := get_draw_mode()
	var disabled_state := disabled or mode == BaseButton.DRAW_DISABLED
	var pressed_state := mode in [BaseButton.DRAW_PRESSED, BaseButton.DRAW_HOVER_PRESSED]
	var hover_state := mode in [BaseButton.DRAW_HOVER, BaseButton.DRAW_HOVER_PRESSED]
	var state_fill := fill_color
	var state_accent := accent_color
	if disabled_state:
		state_fill = state_fill.lerp(Color("#70819a"), 0.62)
		state_accent = state_accent.lerp(Color("#aab5c4"), 0.68)
	elif pressed_state:
		state_fill = state_fill.darkened(0.18)
		state_accent = state_accent.lightened(0.04)
	elif hover_state:
		state_fill = state_fill.lightened(0.05)
		state_accent = state_accent.lightened(0.14)

	var shadow_points := _banner_points(Rect2(Vector2(0, 7), size - Vector2(0, 8)))
	draw_colored_polygon(shadow_points, Color(0.025, 0.09, 0.22, 0.34))
	var outer_points := _banner_points(Rect2(Vector2.ZERO, size - Vector2(0, 3)))
	draw_colored_polygon(outer_points, state_accent)
	var inset := 4.0
	var inner_rect := Rect2(Vector2(inset, inset), size - Vector2(inset * 2.0, inset * 2.0 + 3.0))
	var inner_points := _banner_points(inner_rect)
	draw_colored_polygon(inner_points, state_fill)

	var highlight := state_accent
	highlight.a = 0.34 if not disabled_state else 0.14
	draw_line(
		Vector2(size.y * 0.29, 8),
		Vector2(size.x - size.y * 0.29, 8),
		highlight,
		2.0,
		true,
	)

	var icon_zone := minf(102.0, size.y * 0.88)
	var divider_x := icon_zone
	var divider := foreground_color
	divider.a = 0.28 if not disabled_state else 0.14
	draw_line(Vector2(divider_x, 14), Vector2(divider_x, size.y - 17), divider, 2.0, true)
	_draw_icon(icon_zone, disabled_state)
	_draw_copy(icon_zone, disabled_state)

	if has_focus() and _focus_indicator_visible() and not disabled_state:
		var dark_focus := Color("#071b3c")
		var focus_points := outer_points.duplicate()
		focus_points.append(focus_points[0])
		draw_polyline(focus_points, dark_focus, 4.0, true)
		var focus_inner := inner_points.duplicate()
		focus_inner.append(focus_inner[0])
		var inner_focus := dark_focus.lightened(0.12)
		if foreground_color.get_luminance() >= 0.5:
			inner_focus = Color.WHITE
		draw_polyline(focus_inner, inner_focus, 2.0, true)


func _focus_indicator_visible() -> bool:
	if Engine.is_editor_hint() or not is_inside_tree():
		return true
	var focus_controller := get_node_or_null("/root/FrontendFocus")
	if focus_controller and focus_controller.has_method("is_focus_visible"):
		return bool(focus_controller.call("is_focus_visible"))
	return true


func _banner_points(rect: Rect2) -> PackedVector2Array:
	var notch := minf(rect.size.y * 0.28, 30.0)
	return PackedVector2Array([
		rect.position + Vector2(notch, 0),
		rect.position + Vector2(rect.size.x - notch, 0),
		rect.position + Vector2(rect.size.x, rect.size.y * 0.5),
		rect.position + Vector2(rect.size.x - notch, rect.size.y),
		rect.position + Vector2(notch, rect.size.y),
		rect.position + Vector2(0, rect.size.y * 0.5),
	])


func _draw_icon(icon_zone: float, disabled_state: bool) -> void:
	if mode_icon == null:
		return
	var icon_size := clampf(size.y * 0.39, 30.0, 48.0)
	var rect := Rect2(
		Vector2(icon_zone * 0.5 - icon_size * 0.5, size.y * 0.5 - icon_size * 0.5 - 1.0),
		Vector2.ONE * icon_size,
	)
	var color := foreground_color
	color.a = 0.52 if disabled_state else 1.0
	draw_texture_rect(mode_icon, rect, false, color)


func _draw_copy(icon_zone: float, disabled_state: bool) -> void:
	var color := foreground_color
	color.a = 0.54 if disabled_state else 1.0
	var available_width := maxf(80.0, size.x - icon_zone - 42.0)
	var title_size := clampi(int(round(size.y * 0.26)), 22, 31)
	var subtitle_size := clampi(int(round(size.y * 0.145)), 13, 17)
	var copy_left := icon_zone + 25.0
	var title_y := size.y * 0.49
	draw_string(
		TITLE_FONT,
		Vector2(copy_left, title_y),
		title_text,
		HORIZONTAL_ALIGNMENT_LEFT,
		available_width,
		title_size,
		color,
	)
	var muted := color
	muted.a = 0.62 if disabled_state else 1.0
	draw_string(
		BODY_FONT,
		Vector2(copy_left, title_y + subtitle_size + 12.0),
		subtitle_text,
		HORIZONTAL_ALIGNMENT_LEFT,
		available_width,
		subtitle_size,
		muted,
	)
