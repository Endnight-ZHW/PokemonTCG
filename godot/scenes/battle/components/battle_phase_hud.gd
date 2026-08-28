class_name BattlePhaseHud
extends Control

signal phase_action_requested(action: GameAction)
signal log_drawer_toggled(is_open: bool)

@onready var phase_advance_button: Button = %PhaseAdvanceButton
@onready var log_toggle_button: Button = %LogToggleButton

const RAIL_WIDTH := 132.0
const RAIL_HEIGHT := 196.0
const DRAWER_WIDTH := 360.0
const DRAWER_MAX_HEIGHT := 560.0
const DRAWER_GAP := 10.0
const PHASE_PANEL_OFFSET_Y := 112.0
const DOCK_EDGE_MARGIN := 16.0
const DOCK_RIGHT_MARGIN := 8.0
const RAIL_VISUAL_HALO := 14.0
const RESERVED_BOARD_WIDTH := RAIL_WIDTH + DOCK_RIGHT_MARGIN + RAIL_VISUAL_HALO

var _connected := false
var _log_drawer_open := false
var _layout_connected := false
var _phase_panel: PanelContainer
var _log_drawer_tween: Tween


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()
	if not _layout_connected:
		_layout_connected = true
		resized.connect(_layout_dock)
	set_log_drawer_open(false, false)
	call_deferred("_layout_dock")


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
		if phase_action and phase_action.kind == "SETUP_DONE":
			enabled = true
			tooltip = "确认当前初始场面并完成准备"
		else:
			tooltip = "请先放置战斗宝可梦"
	elif phase_action and phase_action.kind == "END_TURN":
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
			if action and action.kind in ["SETUP_DONE", "END_TURN"]:
				return action
	return null


func _as_system_action(action: GameAction) -> GameAction:
	if action and action.kind in ["SETUP_DONE", "END_TURN"]:
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
			state.setup_actor_idx in [0, 1]
			and state.setup_actor_idx != view_player
		)
	if game_mode == "local":
		return false
	if not state.pending_promotions.is_empty():
		return int(state.pending_promotions[0]) != view_player
	return state.active_player_idx != view_player


func _resolve_nodes() -> void:
	_phase_panel = get_node("PhasePanel") as PanelContainer
	phase_advance_button = get_node(
		"PhasePanel/Content/PhaseAdvanceButton"
	) as Button
	log_toggle_button = get_node(
		"PhasePanel/Content/LogToggleButton"
	) as Button


func _ensure_connections() -> void:
	if not _connected:
		_connected = true
		phase_advance_button.pressed.connect(func() -> void:
			var action := phase_advance_button.get_meta("action") as GameAction
			if action:
				phase_action_requested.emit(action)
		)
		log_toggle_button.toggled.connect(func(is_open: bool) -> void:
			set_log_drawer_open(is_open)
		)
	# LogPanel is composed by BattleTable rather than owned by the standalone HUD
	# scene. Re-check this optional child idempotently so a dynamically attached
	# drawer still gets a working close button after _ready().
	var log_panel := get_node_or_null("LogPanel") as BattleLogPanel
	if log_panel and not log_panel.close_requested.is_connected(close_log_drawer):
		log_panel.close_requested.connect(close_log_drawer)


func set_log_drawer_open(is_open: bool, emit_change: bool = true) -> void:
	_resolve_nodes()
	var changed := _log_drawer_open != is_open
	_log_drawer_open = is_open
	var log_panel := get_node_or_null("LogPanel") as Control
	_kill_log_drawer_tween()
	if log_panel:
		log_panel.visible = is_open
	log_toggle_button.set_pressed_no_signal(is_open)
	log_toggle_button.text = "收起日志" if is_open else "行动日志"
	log_toggle_button.tooltip_text = (
		"收起行动日志抽屉" if is_open else "展开行动日志抽屉"
	)
	if changed and emit_change:
		log_drawer_toggled.emit(is_open)
	_layout_dock()
	if log_panel:
		if is_open and changed:
			_play_log_drawer_motion(log_panel)
		else:
			log_panel.modulate.a = 1.0


func toggle_log_drawer() -> void:
	set_log_drawer_open(not _log_drawer_open)


func close_log_drawer() -> void:
	set_log_drawer_open(false)


func is_log_drawer_open() -> bool:
	return _log_drawer_open


func _play_log_drawer_motion(log_panel: Control) -> void:
	var duration := MotionPolicy.duration("panel")
	if duration <= 0.0 or MotionPolicy.reduced():
		log_panel.modulate.a = 1.0
		return
	var target_position := log_panel.position
	log_panel.position = target_position + Vector2(18.0, 0.0)
	log_panel.modulate.a = 0.0
	_log_drawer_tween = create_tween().set_parallel(true)
	_log_drawer_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	_log_drawer_tween.tween_property(
		log_panel, "position", target_position, duration
	)
	_log_drawer_tween.tween_property(log_panel, "modulate:a", 1.0, duration)
	_log_drawer_tween.finished.connect(func() -> void:
		_log_drawer_tween = null
	)


func _kill_log_drawer_tween() -> void:
	if _log_drawer_tween and _log_drawer_tween.is_valid():
		_log_drawer_tween.kill()
	_log_drawer_tween = null


func _layout_dock() -> void:
	if _phase_panel == null:
		return
	var rail_x := maxf(0.0, size.x - RAIL_WIDTH)
	var usable_height := maxf(size.y, RAIL_HEIGHT)
	var drawer_height := minf(
		DRAWER_MAX_HEIGHT,
		maxf(260.0, usable_height - 96.0),
	)
	var drawer_y := maxf(DOCK_EDGE_MARGIN, (usable_height - drawer_height) * 0.5)
	# Keep the log drawer vertically centered while placing the compact turn
	# controls slightly below the visual midpoint. This leaves the upper-right
	# deck/discard row unobstructed and makes the primary action easier to reach.
	var maximum_phase_y := maxf(
		DOCK_EDGE_MARGIN,
		usable_height - RAIL_HEIGHT - DOCK_EDGE_MARGIN,
	)
	var phase_panel_y := minf(
		drawer_y + PHASE_PANEL_OFFSET_Y,
		maximum_phase_y,
	)
	_phase_panel.position = Vector2(rail_x, phase_panel_y)
	_phase_panel.size = Vector2(RAIL_WIDTH, RAIL_HEIGHT)

	var log_panel := get_node_or_null("LogPanel") as Control
	if log_panel == null:
		return
	log_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	log_panel.position = Vector2(
		maxf(0.0, rail_x - DRAWER_GAP - DRAWER_WIDTH),
		drawer_y,
	)
	log_panel.size = Vector2(DRAWER_WIDTH, drawer_height)
