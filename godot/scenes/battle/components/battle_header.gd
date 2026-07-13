class_name BattleHeader
extends HBoxContainer

signal menu_requested

@onready var menu_button: Button = %MenuButton
@onready var turn_label: Label = %TurnLabel
@onready var task_hint_label: Label = %TaskHint
@onready var ai_thinking_chip: Label = %AIThinkingChip

var _connected := false
var _ai_thinking := false
var _task_hint_override := ""


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()
	_hide_compatibility_nodes()
	_apply_responsive_layout()
	resized.connect(_apply_responsive_layout)
	set_process(false)


func update_header(
	state: GameState,
	view_player: int,
	ai_thinking: bool,
	task_hint: String = "",
) -> void:
	_resolve_nodes()
	_hide_compatibility_nodes()
	_ai_thinking = ai_thinking
	if state == null:
		turn_label.text = "等待对局"
		_update_task_hint("正在载入对局")
		return
	var display_actor := view_player if state.phase == "SETUP" else state.active_player_idx
	turn_label.text = "第 %d 回合 · 玩家 %d · %s" % [
		state.turn_number,
		display_actor + 1,
		_phase_name(state.phase),
	]
	var effective_hint := task_hint.strip_edges()
	if effective_hint.is_empty():
		effective_hint = _task_hint_override
	if effective_hint.is_empty():
		effective_hint = _default_task_hint(state, view_player, ai_thinking)
	_update_task_hint(effective_hint)


func set_task_hint(task_hint: String) -> void:
	_task_hint_override = task_hint.strip_edges()
	if not _task_hint_override.is_empty():
		_update_task_hint(_task_hint_override)


func clear_task_hint() -> void:
	_task_hint_override = ""


func set_ai_thinking(
	active: bool,
	_ai_name: String = "AI",
	_started_msec: int = 0,
	_animate: bool = true,
) -> void:
	_ai_thinking = active
	_hide_compatibility_nodes()
	set_process(false)


func is_ai_thinking_visible() -> bool:
	return false


func _resolve_nodes() -> void:
	menu_button = get_node("MenuButton") as Button
	turn_label = get_node("TurnLabel") as Label
	task_hint_label = get_node("TaskHint") as Label
	ai_thinking_chip = get_node_or_null("AIThinkingChip") as Label


func _ensure_connections() -> void:
	if _connected:
		return
	_connected = true
	menu_button.pressed.connect(menu_requested.emit)


func _hide_compatibility_nodes() -> void:
	var battle_title := get_node_or_null("BattleTitle") as CanvasItem
	if battle_title:
		battle_title.visible = false
	if ai_thinking_chip:
		ai_thinking_chip.visible = false


func _phase_name(phase: String) -> String:
	return {
		"SETUP": "准备阶段",
		"DRAW": "抽牌阶段",
		"MAIN": "主要阶段",
		"ATTACK": "攻击结算",
		"POKEMON_CHECKUP": "宝可梦检查",
		"GAME_OVER": "对局结束",
	}.get(phase, phase)


func _default_task_hint(
	state: GameState,
	view_player: int,
	ai_thinking: bool,
) -> String:
	if ai_thinking:
		return "等待对手行动"
	if state.phase == "SETUP":
		if (
			view_player in [0, 1]
			and view_player < state.setup_ready.size()
			and state.setup_ready[view_player]
		):
			return "等待对手完成准备"
		if view_player in [0, 1] and state.get_player(view_player).active == null:
			return "选择基础宝可梦放到战斗场"
		return "可继续放置备战宝可梦，或完成准备"
	if state.phase == "MAIN":
		return (
			"选择卡牌进行操作"
			if state.active_player_idx == view_player
			else "等待对手行动"
		)
	if state.phase == "DRAW":
		return "正在抽牌"
	if state.phase == "ATTACK":
		return "正在结算攻击"
	if state.phase == "POKEMON_CHECKUP":
		return "正在进行宝可梦检查"
	if state.phase == "GAME_OVER":
		return "对局已结束"
	return "查看牌桌并选择卡牌"


func _update_task_hint(value: String) -> void:
	if task_hint_label == null:
		return
	task_hint_label.text = value
	task_hint_label.tooltip_text = value


func _apply_responsive_layout() -> void:
	# Keep all battle context in one continuous group beside the menu. Extra
	# width belongs after the group, so ultrawide screens do not pull the task
	# hint away from the turn information.
	if menu_button == null or turn_label == null or task_hint_label == null:
		return
	menu_button.custom_minimum_size = Vector2(84.0, 48.0)
	turn_label.custom_minimum_size = Vector2(
		276.0 if size.x < 1080.0 else 292.0,
		44.0,
	)
	task_hint_label.custom_minimum_size = Vector2(
		clampf(size.x * 0.22, 270.0, 330.0),
		44.0,
	)
