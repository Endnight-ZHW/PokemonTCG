class_name FrontendPalette
extends RefCounted

## Front-end-only colors. The battle table keeps DesignTokens.
const BACKGROUND := Color("faf7f0")
const PANEL := Color.WHITE
const RAISED := Color.WHITE
const INSET := Color("eceef2")
const TEXT := Color("213653")
const MUTED := Color("56677e")
const GOLD := Color("c83b35") # Existing semantic accent API.
const BORDER := Color("8490a1")
const BORDER_SOFT := Color("d7dce3")
const CONTROL_BORDER := Color("697991")
const CARD_PAPER := Color("f5f2e9")
const SUCCESS := Color("35654c")
const DANGER := Color("b63038")
const INK := Color.WHITE
const HOVER := Color("ebeef3")
const PRESSED := Color("dde3ec")
const DISABLED := Color("e5e7eb")
const SHADOW := Color(0.125, 0.18, 0.286, 0.12)


static func panel(fill: Color = PANEL, radius: int = 8, border: Color = BORDER, width: int = 1, padding: int = 16) -> StyleBoxFlat:
	return DesignTokens.panel_style(fill, radius, border, width, padding)


static func style_scrollbar(bar: ScrollBar) -> void:
	if bar == null:
		return
	bar.add_theme_stylebox_override("scroll", panel(INSET, 5, Color.TRANSPARENT, 0, 0))
	bar.add_theme_stylebox_override("grabber", panel(MUTED, 5, Color.TRANSPARENT, 0, 0))
	bar.add_theme_stylebox_override("grabber_highlight", panel(GOLD, 5, Color.TRANSPARENT, 0, 0))
	bar.add_theme_stylebox_override("grabber_pressed", panel(GOLD, 5, Color.TRANSPARENT, 0, 0))
	# Give the native scrollbar a real style minimum. A custom Control minimum
	# alone can leave the scroll viewport measuring the old arrow icon width.
	var track := bar.get_theme_stylebox("scroll") as StyleBoxFlat
	if bar is VScrollBar:
		track.content_margin_left = 5
		track.content_margin_right = 5
		bar.custom_minimum_size.x = 10
	else:
		track.content_margin_top = 5
		track.content_margin_bottom = 5
		bar.custom_minimum_size.y = 10
