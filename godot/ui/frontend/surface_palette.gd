class_name SurfacePalette
extends RefCounted

## The modal host owns the surface. Scene-local themes must not override it.
const FRONT_THEME := preload("res://ui/frontend/front_end_theme.tres")
const BATTLE_THEME := preload("res://ui/frontend/battle_modal_theme.tres")

static func is_frontend(control: Node) -> bool:
	var current := control
	while current != null:
		if current.has_meta("ui_surface"):
			return int(current.get_meta("ui_surface")) == ModalSpec.Surface.FRONTEND
		current = current.get_parent()
	return true

static func for_control(control: Node) -> Script:
	return FrontendPalette if is_frontend(control) else BattleModalPalette

static func apply(control: Control) -> void:
	control.theme = FRONT_THEME if is_frontend(control) else BATTLE_THEME

static func format_card_text(control: Node, text: String) -> String:
	if not is_frontend(control):
		return text
	for pair in [[DesignTokens.TEXT, FrontendPalette.TEXT],
		[DesignTokens.TEXT_MUTED, FrontendPalette.MUTED],
		[DesignTokens.GOLD, FrontendPalette.GOLD]]:
		text = text.replace("#" + (pair[0] as Color).to_html(false), "#" + (pair[1] as Color).to_html(false))
	return text
