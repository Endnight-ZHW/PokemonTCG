class_name FrontendPalette
extends RefCounted

const BACKGROUND := Color("171e22")
const PANEL := Color("20343c")
const RAISED := Color("29434b")
const INSET := Color("192a30")
const TEXT := Color("eee8dc")
const MUTED := Color("a9babd")
const DISABLED := Color("7f9398")
const GOLD := Color("c9a665")
const BORDER := Color("496169")
const SUCCESS := Color("91c5ac")
const DANGER := Color("edaa9e")
const INK := Color("171e22")
const WOOD := Color("68503b")


static func panel(fill: Color = PANEL, radius: int = 14, border: Color = BORDER, width: int = 1, padding: int = 16) -> StyleBoxFlat:
	return DesignTokens.panel_style(fill, radius, border, width, padding)


static func style_scrollbar(bar: ScrollBar) -> void:
	if bar == null:
		return
	bar.add_theme_stylebox_override("scroll", panel(INSET, 5, Color.TRANSPARENT, 0, 0))
	bar.add_theme_stylebox_override("grabber", panel(Color("758d91"), 5, Color.TRANSPARENT, 0, 0))
	bar.add_theme_stylebox_override("grabber_highlight", panel(MUTED, 5, Color.TRANSPARENT, 0, 0))
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
