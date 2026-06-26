class_name BattlePhaseHud
extends VBoxContainer

signal phase_action_requested(action: GameAction)

@onready var phase_advance_button: Button = %PhaseAdvanceButton
var phase_labels: Dictionary = {}
var _connected := false


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()


func update_phase(
	state: GameState,
	_view_player: int,
	ai_thinking: bool,
	game_mode: String,
	phase_action_row: Dictionary,
) -> void:
	_resolve_nodes()
	if state == null:
		return
	for phase in phase_labels:
		var active := str(phase) == state.phase
		var label: Label = phase_labels[phase]
		label.add_theme_color_override(
			"font_color",
			DesignTokens.BG_DEEP if active else DesignTokens.TEXT_MUTED,
		)
		label.add_theme_stylebox_override(
			"normal",
			DesignTokens.panel_style(
				DesignTokens.GOLD if active else Color("#1b293c"),
				8,
				DesignTokens.GOLD if active else DesignTokens.BORDER_SOFT,
				1,
				0,
			),
		)
	var phase_action: GameAction = phase_action_row.get("action") as GameAction
	phase_advance_button.set_meta("action", phase_action)
	phase_advance_button.disabled = phase_action == null or ai_thinking
	phase_advance_button.text = (
		"完成准备"
		if phase_action and phase_action.action == "SETUP_DONE"
		else "进入下一阶段"
	)
	phase_advance_button.tooltip_text = (
		""
		if phase_action
		else "等待对手行动"
		if game_mode == "network"
		else "请先完成当前卡牌操作"
	)


func _resolve_nodes() -> void:
	phase_advance_button = get_node(
		"PhasePanel/Content/PhaseAdvanceButton"
	) as Button
	phase_labels = {
		"DRAW": get_node("PhasePanel/Content/PhaseRow/DrawPhase"),
		"MAIN": get_node("PhasePanel/Content/PhaseRow/MainPhase"),
		"ATTACK": get_node("PhasePanel/Content/PhaseRow/AttackPhase"),
		"POKEMON_CHECKUP": get_node("PhasePanel/Content/PhaseRow/CheckupPhase"),
	}


func _ensure_connections() -> void:
	if _connected:
		return
	_connected = true
	phase_advance_button.pressed.connect(func() -> void:
		var action := phase_advance_button.get_meta("action") as GameAction
		if action:
			phase_action_requested.emit(action)
	)
