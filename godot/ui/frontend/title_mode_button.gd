@tool
class_name TitleModeButton
extends Button

## Focusable title-screen CTA whose chrome is drawn in code so it stays crisp
## across desktop, ultrawide and Android canvas scales.

const TITLE_FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres")
const BODY_FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_semibold.tres")
const ARROW_RIGHT := preload("res://assets/ui/icons/arrow_right.svg")

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
@export var accent_color := Color("#62d7ff"):
	set(value):
		accent_color = value
		queue_redraw()
@export var fill_color := Color("#101c2d"):
	set(value):
		fill_color = value
		queue_redraw()
@export var foreground_color := Color("#f4f7ff"):
	set(value):
		foreground_color = value
		queue_redraw()
@export var subtitle_color := Color("#afc0d8"):
	set(value):
		subtitle_color = value
		queue_redraw()


func _ready() -> void:
	flat = true
	text = ""
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var empty_style := StyleBoxEmpty.new()
	for style_name in [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled"]:
		add_theme_stylebox_override(style_name, empty_style)
	for signal_name in [
		&"mouse_entered", &"mouse_exited", &"button_down", &"button_up",
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
		state_fill = state_fill.lerp(Color("#111a27"), 0.52)
		state_accent = state_accent.lerp(Color("#657083"), 0.72)
	elif pressed_state:
		state_fill = state_fill.darkened(0.12)
		state_accent = state_accent.lightened(0.06)
	elif hover_state:
		state_fill = state_fill.lightened(0.065)
		state_accent = state_accent.lightened(0.12)

	var shadow_points := _banner_points(Rect2(Vector2(0, 8), size - Vector2(0, 9)))
	var shadow_color := Color(0.0, 0.015, 0.045, 0.55 if not disabled_state else 0.28)
	draw_colored_polygon(shadow_points, shadow_color)
	var outer_points := _banner_points(Rect2(Vector2.ZERO, size - Vector2(0, 3)))
	var border_color := state_accent
	border_color.a = 1.0 if hover_state or pressed_state else 0.72
	if disabled_state:
		border_color.a = 0.36
	draw_colored_polygon(outer_points, border_color)
	var inset := 4.0
	var inner_rect := Rect2(Vector2(inset, inset), size - Vector2(inset * 2.0, inset * 2.0 + 3.0))
	var inner_points := _banner_points(inner_rect)
	draw_colored_polygon(inner_points, state_fill)
	if hover_state and not disabled_state:
		var glow := state_accent
		glow.a = 0.07
		draw_colored_polygon(inner_points, glow)

	var icon_zone := minf(102.0, size.y * 0.88)
	var divider_x := icon_zone
	var divider := state_accent
	divider.a = 0.30 if not disabled_state else 0.13
	draw_line(Vector2(divider_x, 14), Vector2(divider_x, size.y - 17), divider, 2.0, true)
	_draw_icon(icon_zone, state_accent, disabled_state)
	_draw_copy(icon_zone, disabled_state)
	_draw_chevron(state_accent, disabled_state)

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


func _draw_icon(icon_zone: float, state_accent: Color, disabled_state: bool) -> void:
	if mode_icon == null:
		return
	var icon_size := clampf(size.y * 0.39, 30.0, 48.0)
	var rect := Rect2(
		Vector2(icon_zone * 0.5 - icon_size * 0.5, size.y * 0.5 - icon_size * 0.5 - 1.0),
		Vector2.ONE * icon_size,
	)
	var color := state_accent
	color.a = 0.42 if disabled_state else 1.0
	draw_texture_rect(mode_icon, rect, false, color)


func _draw_copy(icon_zone: float, disabled_state: bool) -> void:
	var title_color := foreground_color
	title_color.a = 0.42 if disabled_state else 1.0
	var available_width := maxf(80.0, size.x - icon_zone - 82.0)
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
		title_color,
	)
	var muted := subtitle_color
	muted.a = 0.38 if disabled_state else 1.0
	draw_string(
		BODY_FONT,
		Vector2(copy_left, title_y + subtitle_size + 12.0),
		subtitle_text,
		HORIZONTAL_ALIGNMENT_LEFT,
		available_width,
		subtitle_size,
		muted,
	)


func _draw_chevron(state_accent: Color, disabled_state: bool) -> void:
	var chevron_size := clampf(size.y * 0.20, 18.0, 24.0)
	var right_padding := maxf(27.0, size.y * 0.25)
	var rect := Rect2(
		Vector2(size.x - right_padding - chevron_size, size.y * 0.5 - chevron_size * 0.5 - 1.0),
		Vector2.ONE * chevron_size,
	)
	var color := state_accent
	color.a = 0.35 if disabled_state else 0.92
	draw_texture_rect(ARROW_RIGHT, rect, false, color)
