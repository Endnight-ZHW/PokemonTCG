@tool
class_name TitleModeButton
extends Button

## The face moves inside a fixed full-row input target.
const TITLE_FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_bold.tres")
const BODY_FONT := preload("res://assets/ui/fonts/noto_sans_cjk_sc_medium.tres")
const ARROW_RIGHT := preload("res://assets/ui/frontend/arrow_right.svg")
@export var title_text := "对战入口"
@export var subtitle_text := "选择一种对战方式"
@export var mode_icon: Texture2D
@export var accent_color := HomePalette.CORAL
@export var fill_color := Color.WHITE
@export var foreground_color := HomePalette.TEXT
@export var subtitle_color := HomePalette.MUTED
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
	for style_name in [&"normal", &"hover", &"pressed", &"hover_pressed", &"disabled"]:
		add_theme_stylebox_override(style_name, StyleBoxEmpty.new())
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)
	resized.connect(queue_redraw)
	mouse_entered.connect(_animate_hover.bind(1.0))
	mouse_exited.connect(_animate_hover.bind(0.0))
	visibility_changed.connect(func() -> void:
		if not is_visible_in_tree():
			_animate_hover(0.0)
	)

func _draw() -> void:
	if size.x <= 0 or size.y <= 0:
		return
	var pressed := get_draw_mode() in [BaseButton.DRAW_PRESSED, BaseButton.DRAW_HOVER_PRESSED]
	var motion := Engine.is_editor_hint() or FrontendMotion.decorative_motion_enabled()
	var offset := (2.0 if pressed else -3.0 * _hover_amount) if motion else 0.0
	var face := Rect2(Vector2(2, 3 + offset), size - Vector2(4, 9))
	var shadow := HomePalette.surface(Color("c7cfd8"))
	shadow.shadow_color = Color(0.13, 0.21, 0.33, 0.07 + _hover_amount * 0.035)
	shadow.shadow_size = 8 if pressed else 12
	shadow.shadow_offset = Vector2(0, 4)
	draw_style_box(shadow, Rect2(Vector2(2, 9), size - Vector2(4, 13)))
	var panel := HomePalette.surface(Color("eef1f5") if pressed else fill_color)
	panel.border_color = HomePalette.BORDER.lerp(accent_color, _hover_amount * 0.5)
	panel.set_border_width_all(1)
	if disabled:
		panel.bg_color = Color("e8e9eb")
	draw_style_box(panel, face)
	var center_y := face.get_center().y
	var badge := Rect2(Vector2(20, center_y - 25), Vector2(50, 50))
	draw_style_box(HomePalette.surface(accent_color.lightened(0.87), 16), badge)
	var alpha := 0.4 if disabled else 1.0
	if mode_icon:
		draw_texture_rect(mode_icon, badge.grow(-10), false, Color(accent_color, alpha))
	var title_size := 27 if size.y >= 90 else 24
	var copy_left := 88.0
	var width := maxf(60, size.x - copy_left - 54)
	draw_string(TITLE_FONT, Vector2(copy_left, center_y - 1), title_text, HORIZONTAL_ALIGNMENT_LEFT, width, title_size, Color(foreground_color, alpha))
	draw_string(BODY_FONT, Vector2(copy_left, center_y + 23), subtitle_text, HORIZONTAL_ALIGNMENT_LEFT, width, 16, Color(subtitle_color, alpha))
	draw_texture_rect(ARROW_RIGHT, Rect2(Vector2(size.x - 43, center_y - 11), Vector2(22, 22)), false, Color(accent_color, alpha))

func _animate_hover(target: float) -> void:
	if _hover_tween and _hover_tween.is_valid():
		_hover_tween.kill()
	if Engine.is_editor_hint() or not FrontendMotion.decorative_motion_enabled() or not is_visible_in_tree():
		_hover_amount = target
		return
	_hover_tween = create_tween()
	_hover_tween.tween_property(self, "_hover_amount", target, 0.12)
