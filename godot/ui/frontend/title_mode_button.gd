@tool
class_name TitleModeButton
extends Button

## Equal-weight, frameless menu rows. Geometry stays stable in every state.

const TITLE_FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres")
const BODY_FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_medium.tres")
const ARROW_RIGHT := preload("res://assets/ui/frontend/arrow_right.svg")

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
@export var accent_color := FrontendPalette.GOLD:
	set(value):
		accent_color = value
		queue_redraw()
@export var fill_color := FrontendPalette.PANEL:
	set(value):
		fill_color = value
		queue_redraw()
@export var foreground_color := FrontendPalette.TEXT:
	set(value):
		foreground_color = value
		queue_redraw()
@export var subtitle_color := FrontendPalette.MUTED:
	set(value):
		subtitle_color = value
		queue_redraw()

var _hover_amount := 0.0:
	set(value):
		_hover_amount = value
		queue_redraw()
var _hover_tween: Tween


func _ready() -> void:
	flat = true
	text = ""
	accessibility_name = title_text
	accessibility_description = subtitle_text
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
	mouse_entered.connect(_animate_hover.bind(1.0))
	mouse_exited.connect(_animate_hover.bind(0.0))
	queue_redraw()


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var mode := get_draw_mode()
	var disabled_state := disabled or mode == BaseButton.DRAW_DISABLED
	var pressed_state := mode in [BaseButton.DRAW_PRESSED, BaseButton.DRAW_HOVER_PRESSED]
	var hover_state := mode in [BaseButton.DRAW_HOVER, BaseButton.DRAW_HOVER_PRESSED]
	var state_accent := FrontendPalette.TEXT
	var surface := FrontendPalette.panel(fill_color, 8, FrontendPalette.BORDER, 1, 0)
	if disabled_state:
		surface.bg_color = FrontendPalette.DISABLED
	draw_style_box(surface, Rect2(Vector2(1, 1), size - Vector2(2, 2)))
	if _hover_amount > 0.001 or hover_state or pressed_state:
		state_accent = accent_color
		var fill := FrontendPalette.PRESSED if pressed_state else FrontendPalette.HOVER
		fill.a = 1.0 if pressed_state else _hover_amount
		draw_style_box(FrontendPalette.panel(fill, 6, Color.TRANSPARENT, 0, 0), Rect2(Vector2.ZERO, size))
		draw_line(Vector2(2, 18), Vector2(2, size.y - 18), accent_color, 4, true)
	var icon_zone := 72.0
	_draw_icon(icon_zone, state_accent, disabled_state)
	_draw_copy(icon_zone, disabled_state)
	_draw_chevron(state_accent, disabled_state)

func _draw_icon(icon_zone: float, state_accent: Color, disabled_state: bool) -> void:
	if mode_icon == null:
		return
	var icon_size := 32.0
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
	var title_size := 28 if size.y >= 90 else 24
	var subtitle_size := 16
	var copy_left := icon_zone + 16.0
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
		Vector2(copy_left, title_y + subtitle_size + 8.0),
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
	draw_style_box(FrontendPalette.panel(Color(color, 0.10), 6, Color.TRANSPARENT, 0, 0), rect.grow(7))
	draw_texture_rect(ARROW_RIGHT, rect, false, color)

func _animate_hover(target: float) -> void:
	if _hover_tween and _hover_tween.is_valid():
		_hover_tween.kill()
	if not FrontendMotion.decorative_motion_enabled():
		_hover_amount = target
		return
	_hover_tween = create_tween()
	_hover_tween.tween_property(self, "_hover_amount", target, 0.12)
