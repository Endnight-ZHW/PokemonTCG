class_name HomePalette
extends RefCounted

## Homepage-only surfaces. Shared frontend and battle themes stay independent.
const BACKGROUND := Color("faf7f0")
const TEXT := Color("213653")
const MUTED := Color("56677e")
const CORAL := Color("df6655")
const BLUE := Color("477fbd")
const GOLD := Color("c29a36")
const SUNLIGHT := Color("f6d878")
const BORDER := Color("d3dbe4")

static func surface(fill: Color, radius: int = 20) -> StyleBoxFlat:
	return FrontendPalette.panel(fill, radius, Color.TRANSPARENT, 0, 0)

static func utility_style(pressed: bool = false, hovered: bool = false) -> StyleBoxFlat:
	var result := FrontendPalette.panel(Color("e9edf3") if pressed else Color("fffdf9"), 24, BORDER, 1, 16)
	if hovered and not pressed:
		result.bg_color = Color.WHITE
		result.border_color = Color("8b9eb6")
	result.content_margin_top = 9
	result.content_margin_bottom = 9
	return result
