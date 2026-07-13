class_name BattlePhaseHud
extends VBoxContainer

signal phase_action_requested(action: GameAction)

@onready var phase_advance_button: Button = %PhaseAdvanceButton

var _connected := false


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()


func update_phase(
	state: GameState,
	view_player: int,
	ai_thinking: bool,
	game_mode: String,
	action_source: Variant,
) -> void:
	_resolve_nodes()
	_ensure_connections()
	var phase_action := _find_system_action(action_source)
	var label := "结算中"
	var tooltip := "当前效果正在结算"
	var enabled := false

	if state == null:
		tooltip = "正在载入对局状态"
	elif ai_thinking or _is_waiting_for_opponent(state, view_player, game_mode):
		label = "等待对手"
		tooltip = (
			"等待远端玩家行动"
			if game_mode == "network"
			else "对手正在行动"
		)
	elif state.phase == "SETUP":
		label = "完成准备"
		if phase_action and phase_action.action == "SETUP_DONE":
			enabled = true
			tooltip = "确认当前初始场面并完成准备"
		else:
			tooltip = "请先放置战斗宝可梦"
	elif phase_action and phase_action.action == "END_TURN":
		label = "结束回合"
		enabled = true
		tooltip = "结束当前玩家的回合"

	phase_advance_button.text = label
	phase_advance_button.disabled = not enabled
	phase_advance_button.tooltip_text = tooltip
	phase_advance_button.set_meta("action", phase_action if enabled else null)


func _find_system_action(action_source: Variant) -> GameAction:
	if action_source is GameAction:
		return _as_system_action(action_source as GameAction)
	if action_source is Dictionary:
		return _as_system_action(
			(action_source as Dictionary).get("action") as GameAction,
		)
	if action_source is Array:
		for row_value in action_source:
			var action: GameAction
			if row_value is GameAction:
				action = row_value as GameAction
			elif row_value is Dictionary:
				action = (row_value as Dictionary).get("action") as GameAction
			if action and action.action in ["SETUP_DONE", "END_TURN"]:
				return action
	return null


func _as_system_action(action: GameAction) -> GameAction:
	if action and action.action in ["SETUP_DONE", "END_TURN"]:
		return action
	return null


func _is_waiting_for_opponent(
	state: GameState,
	view_player: int,
	game_mode: String,
) -> bool:
	if view_player not in [0, 1]:
		return false
	if state.phase == "SETUP":
		return (
			view_player < state.setup_ready.size()
			and state.setup_ready[view_player]
		)
	if game_mode == "local":
		return false
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0]) != view_player
	return state.active_player_idx != view_player


func _resolve_nodes() -> void:
	phase_advance_button = get_node(
		"PhasePanel/Content/PhaseAdvanceButton"
	) as Button


func _ensure_connections() -> void:
	if _connected:
		return
	_connected = true
	phase_advance_button.pressed.connect(func() -> void:
		var action := phase_advance_button.get_meta("action") as GameAction
		if action:
			phase_action_requested.emit(action)
	)
