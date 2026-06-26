class_name BattleHeader
extends HBoxContainer

signal menu_requested

@onready var menu_button: Button = %MenuButton
@onready var turn_label: Label = %TurnLabel

var _connected := false


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()


func update_header(
	state: GameState,
	view_player: int,
	ai_thinking: bool,
) -> void:
	_resolve_nodes()
	if state == null:
		turn_label.text = "等待对局"
		return
	var display_actor := view_player if state.phase == "SETUP" else state.active_player_idx
	turn_label.text = "第 %d 回合 · %s · 玩家 %d%s" % [
		state.turn_number,
		_phase_name(state.phase),
		display_actor + 1,
		" · AI 思考中" if ai_thinking else "",
	]


func _resolve_nodes() -> void:
	menu_button = get_node("MenuButton") as Button
	turn_label = get_node("TurnLabel") as Label


func _ensure_connections() -> void:
	if _connected:
		return
	_connected = true
	menu_button.pressed.connect(menu_requested.emit)


func _phase_name(phase: String) -> String:
	return {
		"SETUP": "准备",
		"DRAW": "抽牌",
		"MAIN": "主要",
		"ATTACK": "攻击",
		"POKEMON_CHECKUP": "宝可梦检查",
		"GAME_OVER": "对局结束",
	}.get(phase, phase)
