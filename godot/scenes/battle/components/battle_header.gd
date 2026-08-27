class_name BattleHeader
extends HBoxContainer

signal menu_requested

@onready var menu_button: Button = %MenuButton
@onready var turn_label: Label = %TurnLabel
@onready var task_hint_label: Label = %TaskHint

var _connected := false
var _ai_thinking := false
var _task_hint_override := ""


func _ready() -> void:
	initialize_ui()
	_apply_responsive_layout()
	resized.connect(_apply_responsive_layout)
	set_process(false)


## BattleTable supports explicit synchronous initialization for tests and tools,
## before child _ready callbacks have run. Keep the public menu signal wired in
## both that path and the normal scene-tree ready path.
func initialize_ui() -> void:
	_resolve_nodes()
	_ensure_connections()


func update_header(
	state: GameState,
	view_player: int,
	ai_thinking: bool,
	task_hint: String = "",
) -> void:
	_resolve_nodes()
	_ai_thinking = ai_thinking
	if state == null:
		turn_label.text = "等待对局"
		turn_label.tooltip_text = turn_label.text
		turn_label.accessibility_name = turn_label.text
		_update_task_hint("正在载入对局")
		return
	var display_actor := state.active_player_idx
	if state.phase == "SETUP" and state.setup_actor_idx in [0, 1]:
		display_actor = state.setup_actor_idx
	turn_label.text = "第 %d 回合 · 玩家 %d · %s" % [
		state.turn_number,
		display_actor + 1,
		_phase_name(state.phase),
	]
	turn_label.tooltip_text = turn_label.text
	turn_label.accessibility_name = "当前对局：%s" % turn_label.text
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
	set_process(false)


func _resolve_nodes() -> void:
	menu_button = get_node("MenuButton") as Button
	turn_label = get_node("TurnLabel") as Label
	task_hint_label = get_node("TaskHint") as Label


func _ensure_connections() -> void:
	if _connected:
		return
	_connected = true
	menu_button.pressed.connect(menu_requested.emit)


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
	if not state.pending_promotions.is_empty():
		var promotion_actor := int(state.pending_promotions[0])
		return (
			"选择备战宝可梦晋升到战斗区"
			if promotion_actor == view_player
			else "等待对手选择新的战斗宝可梦"
		)
	if ai_thinking:
		return "等待对手行动"
	if state.phase == "SETUP":
		if (
			view_player in [0, 1]
			and state.setup_actor_idx in [0, 1]
			and state.setup_actor_idx != view_player
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
	task_hint_label.accessibility_name = "当前任务：%s" % value


func _apply_responsive_layout() -> void:
	# The fixed space at each edge is balanced (12 + 84 + 12 on the left,
	# 108 on the right). Equal expanding spacers therefore keep the continuous
	# turn/task group centered while the menu remains pinned to the left edge.
	if menu_button == null or turn_label == null or task_hint_label == null:
		return
	menu_button.custom_minimum_size = Vector2(84.0, 48.0)
	turn_label.custom_minimum_size = Vector2(
		252.0 if size.x < 1080.0 else 292.0,
		44.0,
	)
	task_hint_label.custom_minimum_size = Vector2(
		clampf(size.x * 0.22, 250.0, 340.0),
		44.0,
	)
