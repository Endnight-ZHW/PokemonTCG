class_name FrontendPalette
extends RefCounted

const BACKGROUND := DesignTokens.BG_DEEP
const PANEL := DesignTokens.PANEL
const RAISED := DesignTokens.PANEL_RAISED
const INSET := DesignTokens.PANEL_INSET
const TEXT := DesignTokens.TEXT
const MUTED := DesignTokens.TEXT_MUTED
const DISABLED := DesignTokens.TEXT_DISABLED
const GOLD := DesignTokens.GOLD
const BORDER := DesignTokens.BORDER
const SUCCESS := DesignTokens.STATE_SUCCESS
const DANGER := DesignTokens.STATE_DANGER
const INK := DesignTokens.TEXT_ON_ACCENT
const WOOD := DesignTokens.TABLE_WOOD


static func panel(fill: Color = PANEL, radius: int = 14, border: Color = BORDER, width: int = 1, padding: int = 16) -> StyleBoxFlat:
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
