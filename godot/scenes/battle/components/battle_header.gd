class_name BattleHeader
extends HBoxContainer

signal menu_requested

@onready var menu_button: Button = %MenuButton
@onready var turn_label: Label = %TurnLabel
@onready var ai_thinking_chip: Label = %AIThinkingChip

var _connected := false
var _ai_thinking := false
var _ai_name := "AI"
var _ai_started_msec := 0
var _chip_tween: Tween


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()
	set_process(false)


func update_header(
	state: GameState,
	view_player: int,
	ai_thinking: bool,
) -> void:
	_resolve_nodes()
	if state == null:
		turn_label.text = "等待对局"
		set_ai_thinking(false)
		return
	var display_actor := view_player if state.phase == "SETUP" else state.active_player_idx
	turn_label.text = "第 %d 回合 · %s · 玩家 %d" % [
		state.turn_number,
		_phase_name(state.phase),
		display_actor + 1,
	]
	if not ai_thinking:
		set_ai_thinking(false)


func set_ai_thinking(
	active: bool,
	ai_name: String = "AI",
	started_msec: int = 0,
	animate: bool = true,
) -> void:
	_resolve_nodes()
	var was_active := _ai_thinking
	_ai_thinking = active
	_ai_name = ai_name if not ai_name.strip_edges().is_empty() else "AI"
	_ai_started_msec = started_msec
	if ai_thinking_chip == null:
		return
	if _chip_tween != null and _chip_tween.is_valid():
		_chip_tween.kill()
	if active:
		ai_thinking_chip.visible = true
		_update_ai_thinking_chip()
		if animate and not was_active:
			ai_thinking_chip.modulate.a = 0.0
			_chip_tween = create_tween()
			_chip_tween.tween_property(ai_thinking_chip, "modulate:a", 1.0, 0.14)
		else:
			ai_thinking_chip.modulate.a = 1.0
	else:
		ai_thinking_chip.visible = false
		ai_thinking_chip.modulate.a = 0.0
	set_process(active)


func is_ai_thinking_visible() -> bool:
	return ai_thinking_chip != null and ai_thinking_chip.visible


func _process(_delta: float) -> void:
	if _ai_thinking:
		_update_ai_thinking_chip()


func _resolve_nodes() -> void:
	menu_button = get_node("MenuButton") as Button
	turn_label = get_node("TurnLabel") as Label
	ai_thinking_chip = get_node("AIThinkingChip") as Label


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


func _update_ai_thinking_chip() -> void:
	if ai_thinking_chip == null:
		return
	var elapsed := 0.0
	if _ai_started_msec > 0:
		elapsed = float(Time.get_ticks_msec() - _ai_started_msec) / 1000.0
	ai_thinking_chip.text = "%s 思考中 · %.1fs" % [_ai_name, maxf(0.0, elapsed)]
