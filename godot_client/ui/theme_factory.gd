class_name GameUITheme
extends RefCounted

const COLOR_BG := Color("#09111f")
const COLOR_PANEL := Color("#111d31")
const COLOR_PANEL_ALT := Color("#17263d")
const COLOR_ACCENT := Color("#f4c84a")
const COLOR_ACCENT_BLUE := Color("#45a6ff")
const COLOR_TEXT := Color("#f2f6ff")
const COLOR_MUTED := Color("#9cacc5")
const COLOR_DANGER := Color("#ef6a72")


static func create() -> Theme:
	var result := Theme.new()
	result.default_font_size = 18
	result.set_color("font_color", "Label", COLOR_TEXT)
	result.set_color("font_color", "Button", COLOR_TEXT)
	result.set_color("font_hover_color", "Button", Color.WHITE)
	result.set_color("font_pressed_color", "Button", COLOR_BG)
	result.set_color("font_disabled_color", "Button", Color("#66748a"))
	result.set_color("font_color", "CheckButton", COLOR_TEXT)
	result.set_color("font_color", "OptionButton", COLOR_TEXT)
	result.set_color("font_color", "RichTextLabel", COLOR_TEXT)
	result.set_color("default_color", "RichTextLabel", COLOR_TEXT)
	result.set_constant("separation", "VBoxContainer", 12)
	result.set_constant("separation", "HBoxContainer", 12)
	result.set_constant("outline_size", "Label", 2)
	result.set_color("font_outline_color", "Label", Color(0, 0, 0, 0.55))

	result.set_stylebox("normal", "Button", _box(COLOR_PANEL_ALT, 12, Color("#304663")))
	result.set_stylebox("hover", "Button", _box(Color("#213754"), 12, COLOR_ACCENT_BLUE, 2))
	result.set_stylebox("pressed", "Button", _box(COLOR_ACCENT, 12, COLOR_ACCENT, 2))
	result.set_stylebox("disabled", "Button", _box(Color("#0c1626"), 12, Color("#24334a")))
	result.set_stylebox("focus", "Button", _box(Color(0, 0, 0, 0), 12, COLOR_ACCENT, 2))

	result.set_stylebox("normal", "PanelContainer", _box(COLOR_PANEL, 16, Color("#2b3d58")))
	result.set_stylebox("panel", "Panel", _box(COLOR_PANEL, 16, Color("#2b3d58")))
	result.set_stylebox("normal", "OptionButton", _box(COLOR_PANEL_ALT, 10, Color("#304663")))
	result.set_stylebox("hover", "OptionButton", _box(Color("#213754"), 10, COLOR_ACCENT_BLUE, 2))
	result.set_stylebox("pressed", "OptionButton", _box(COLOR_ACCENT, 10, COLOR_ACCENT))
	result.set_stylebox("focus", "OptionButton", _box(Color(0, 0, 0, 0), 10, COLOR_ACCENT, 2))
	result.set_stylebox("normal", "LineEdit", _box(COLOR_PANEL_ALT, 8, Color("#304663")))
	result.set_stylebox("focus", "LineEdit", _box(COLOR_PANEL_ALT, 8, COLOR_ACCENT_BLUE, 2))
	return result


static func panel_style(
	color: Color = COLOR_PANEL,
	radius: int = 16,
	border_color: Color = Color("#2b3d58"),
	border_width: int = 1,
) -> StyleBoxFlat:
	return _box(color, radius, border_color, border_width)


static func _box(
	color: Color,
	radius: int,
	border_color: Color,
	border_width: int = 1,
) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.border_color = border_color
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(radius)
	box.content_margin_left = 16
	box.content_margin_right = 16
	box.content_margin_top = 12
	box.content_margin_bottom = 12
	return box
