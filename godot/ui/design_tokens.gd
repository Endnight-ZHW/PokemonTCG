class_name DesignTokens
extends RefCounted

## Shared cream surfaces. Keep card art, energy types and physical lighting neutral.
const BG_DEEP := Color("#f3eadb")
const BG_SURFACE := Color("#eee0cc")
const PANEL := Color("#fff9f0")
const PANEL_RAISED := Color("#fffcf7")
const PANEL_INSET := Color("#eadcc9")
const PANEL_HOVER := Color("#f3e5d2")
const PANEL_PRESSED := Color("#e8d5ba")
const PANEL_HOVER_PRESSED := Color("#e1ccb0")
const PANEL_DISABLED := Color("#e6ddcf")
const PANEL_GLASS := Color(1.0, 0.976471, 0.941176, 0.98)
const SURFACE_BASE := BG_SURFACE
const SURFACE_PANEL := PANEL
const SURFACE_ELEVATED := PANEL_RAISED
const SURFACE_OVERLAY := PANEL_GLASS
const BORDER := Color("#a18a73")
const BORDER_SOFT := Color("#cebba6")
const TEXT := Color("#45372f")
const TEXT_MUTED := Color("#796757")
const TEXT_DISABLED := Color("#8d7c69")
const TEXT_ON_ACCENT := Color("#fff9f0")
const STATUS_INK := Color("#201811")
const GOLD := Color("#a35f32")
const ACCENT_HOVER := Color("#98592e")
const ACCENT_PRESSED := Color("#804b29")
const BLUE := Color("#466d86")
const CYAN := Color("#49786b")
const RED := Color("#ad5147")
const DANGER_HOVER := Color("#99453d")
const DANGER_PRESSED := Color("#833b34")
const GREEN := Color("#4f7153")
const PURPLE := Color("#805c91")
const SUCCESS_SURFACE := Color("#e5ecdf")
const DANGER_SURFACE := Color("#f3dfd8")
const SHADOW := Color(0.270588, 0.215686, 0.184314, 0.12)
const SCRIM := Color("#45372f")
const TABLE_WOOD := Color("#c9a77e")
const TABLE_CLOTH := Color("#d9c9ad")
const TABLE_STITCH := Color("#a18a73")
const STATE_SELECTED := GOLD
const STATE_TARGET := CYAN
const STATE_INFO := BLUE
const STATE_SUCCESS := GREEN
const STATE_DANGER := RED

const SPACE_XS := 4
const SPACE_SM := 8
const SPACE_MD := 12
const SPACE_LG := 16
const SPACE_XL := 24
const SPACE_XXL := 32

const TYPE_COLORS := {
	"Grass": Color("#55b96a"),
	"Fire": Color("#ef6547"),
	"Water": Color("#48a7e8"),
	"Lightning": Color("#f0cf4d"),
	"Psychic": Color("#b56ac3"),
	"Fighting": Color("#c18455"),
	"Darkness": Color("#655b78"),
	"Metal": Color("#aeb7c2"),
	"Dragon": Color("#d4a83e"),
	"Colorless": Color("#d6d9d5"),
	"Trainer": Color("#73a9bf"),
	"Energy": Color("#d9ddd8"),
}

const STATUS_COLORS := {
	"POISONED": Color("#a75bd5"),
	"BURNED": Color("#ef623f"),
	"ASLEEP": Color("#67a7e8"),
	"PARALYZED": Color("#e9d24e"),
	"CONFUSED": Color("#e99a45"),
}

const RADIUS_SMALL := 8
const RADIUS_MEDIUM := 14
const RADIUS_LARGE := 20
const TOUCH_MIN := 48


static func type_color(energy_type: String) -> Color:
	return TYPE_COLORS.get(energy_type, TYPE_COLORS["Colorless"])


static func status_color(status: String) -> Color:
	return STATUS_COLORS.get(status, TEXT_MUTED)


static func panel_style(
	color: Color = PANEL,
	radius: int = RADIUS_MEDIUM,
	border_color: Color = BORDER,
	border_width: int = 1,
	content_margin: int = 12,
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border_color
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = content_margin
	style.content_margin_right = content_margin
	style.content_margin_top = content_margin
	style.content_margin_bottom = content_margin
	return style


static func style_scrollbar(scrollbar: ScrollBar) -> void:
	if scrollbar == null:
		return
	var track := panel_style(
		PANEL_INSET, 6, Color.TRANSPARENT, 0, 0)
	var thumb := panel_style(
		TEXT_MUTED, 6, Color.TRANSPARENT, 0, 0)
	var hover := panel_style(
		GOLD, 6, Color.TRANSPARENT, 0, 0)
	scrollbar.add_theme_stylebox_override("scroll", track)
	scrollbar.add_theme_stylebox_override("grabber", thumb)
	scrollbar.add_theme_stylebox_override("grabber_highlight", hover)
	scrollbar.add_theme_stylebox_override("grabber_pressed", hover)
	if scrollbar is VScrollBar:
		track.content_margin_left = 6
		track.content_margin_right = 6
		scrollbar.custom_minimum_size.x = 12.0
	else:
		track.content_margin_top = 6
		track.content_margin_bottom = 6
		scrollbar.custom_minimum_size.y = 12.0


## Format only the UI template, before inserting escaped card text with %.
static func rich_text(template: String) -> String:
	return template.format({
		"text": TEXT.to_html(false), "muted": TEXT_MUTED.to_html(false),
		"accent": GOLD.to_html(false), "target": CYAN.to_html(false),
		"success": GREEN.to_html(false), "danger": RED.to_html(false),
	})


## Colored artwork must not inherit the ink tint used by monochrome UI icons.
static func preserve_art_icon(button: Button) -> void:
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
		button.add_theme_color_override("icon_%s_color" % state, Color.WHITE)


static func label(text_value: String, font_size: int, color: Color) -> Label:
	var result := Label.new()
	result.text = text_value
	result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	result.add_theme_font_size_override("font_size", font_size)
	result.add_theme_color_override("font_color", color)
	result.add_theme_constant_override("outline_size", 0)
	result.add_theme_color_override("font_outline_color", Color.TRANSPARENT)
	return result
