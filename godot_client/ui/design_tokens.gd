class_name DesignTokens
extends RefCounted

const BG_DEEP := Color("#07101d")
const BG_SURFACE := Color("#0d1828")
const PANEL := Color("#111d30")
const PANEL_RAISED := Color("#172842")
const PANEL_GLASS := Color(0.055, 0.10, 0.17, 0.94)
const BORDER := Color("#304764")
const BORDER_SOFT := Color(0.26, 0.39, 0.56, 0.45)
const TEXT := Color("#f4f7ff")
const TEXT_MUTED := Color("#9eb0ca")
const GOLD := Color("#f4c84a")
const BLUE := Color("#45a6ff")
const CYAN := Color("#62d7ff")
const RED := Color("#ef6572")
const GREEN := Color("#68d391")
const PURPLE := Color("#b78cff")

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


static func shadow_style(radius: int = RADIUS_MEDIUM) -> StyleBoxFlat:
	var style := panel_style(Color(0.0, 0.0, 0.0, 0.34), radius, Color.TRANSPARENT, 0, 0)
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.48)
	style.shadow_size = 10
	style.shadow_offset = Vector2(0, 5)
	return style

