class_name BattleHeader
extends Control

signal menu_requested
signal cancel_requested
signal detail_requested
signal back_requested

@onready var menu_button: Button = %MenuButton
@onready var turn_label: Label = %TurnLabel
@onready var task_hint_label: Label = %TaskHint

var _connected := false
var _task_hint_override := ""
var _turn_full_text := ""
var _guidance: Dictionary = {}
var _selection_active := false


func _ready() -> void:
	initialize_ui()
	resized.connect(_apply_responsive_layout)
	_apply_responsive_layout()


func initialize_ui() -> void:
	menu_button = get_node("MenuButton") as Button
	turn_label = get_node("TurnLabel") as Label
	task_hint_label = get_node("TaskHint") as Label
	if not _connected:
		_connected = true
		menu_button.pressed.connect(menu_requested.emit)
		get_node("RightInset/CancelSelectionButton").pressed.connect(cancel_requested.emit)
		get_node("RightInset/DetailButton").pressed.connect(detail_requested.emit)
		get_node("RightInset/BackActionButton").pressed.connect(back_requested.emit)
		task_hint_label.add_theme_color_override("font_color", DesignTokens.TEXT)
		for button in [menu_button, get_node("RightInset/BackActionButton"), get_node("RightInset/DetailButton"), get_node("RightInset/CancelSelectionButton")]:
			for font_state in ["font_color", "font_hover_color", "font_pressed_color"]:
				button.add_theme_color_override(font_state, DesignTokens.TEXT)
			button.add_theme_stylebox_override("normal", DesignTokens.panel_style(DesignTokens.PANEL, 10, DesignTokens.BORDER, 1, 6))
			button.add_theme_stylebox_override("hover", DesignTokens.panel_style(DesignTokens.PANEL_HOVER, 10, DesignTokens.GOLD, 2, 6))
			button.add_theme_stylebox_override("pressed", DesignTokens.panel_style(DesignTokens.PANEL_PRESSED, 10, DesignTokens.GOLD, 2, 6))


func update_header(state: GameState, view_player: int, ai_thinking: bool, task_hint: String = "") -> void:
	initialize_ui()
	if state == null:
		turn_label.text = "等待对局"
		apply_guidance({"text": "正在载入对局"})
		return
	var actor := state.setup_actor_idx if state.phase == "SETUP" else state.active_player_idx
	_turn_full_text = "第 %d 回合 · %s · %s" % [state.turn_number, "我方行动" if actor == view_player else "对手行动", _phase_name(state.phase)]
	turn_label.text = _turn_full_text
	turn_label.tooltip_text = _turn_full_text
	turn_label.accessibility_name = _turn_full_text
	turn_label.add_theme_color_override("font_color", DesignTokens.GOLD if actor == view_player else DesignTokens.TEXT_MUTED)
	var value := BattleGuidanceModel.resolve(state, view_player, "", [], "", null, 0, "", "", ai_thinking)
	if not task_hint.is_empty():
		value.text = task_hint
	apply_guidance(value)


func apply_guidance(value: Dictionary) -> void:
	_guidance = value
	get_node("RightInset/CancelSelectionButton").visible = bool(value.get("can_cancel", false))
	get_node("RightInset/CancelSelectionButton").text = "取消操作"
	get_node("RightInset/BackActionButton").visible = bool(value.get("can_back", false))
	get_node("RightInset/DetailButton").visible = _selection_active and str(value.get("tone", "")) != "waiting"
	_render_guidance()
	_apply_responsive_layout()


func set_selection_active(active: bool) -> void:
	_selection_active = active


func set_task_hint(task_hint: String) -> void:
	_task_hint_override = task_hint.strip_edges()
	_render_guidance()


func clear_task_hint() -> void:
	_task_hint_override = ""
	_render_guidance()


func set_ai_thinking(_active: bool, _ai_name: String = "AI", _started_msec: int = 0, _animate: bool = true) -> void:
	pass


func _render_guidance() -> void:
	if task_hint_label == null:
		return
	var text := str(_guidance.get("text", "选择卡牌进行操作"))
	var tone := str(_guidance.get("tone", "normal"))
	if not _task_hint_override.is_empty():
		text = text + " · " + _task_hint_override if tone in ["required", "target"] else _task_hint_override
	task_hint_label.text = text
	task_hint_label.tooltip_text = text
	task_hint_label.accessibility_name = "当前任务：%s" % text
	var accent := DesignTokens.STATE_TARGET if tone == "target" else DesignTokens.GOLD if tone == "required" else DesignTokens.BORDER
	var style := DesignTokens.panel_style(DesignTokens.SUCCESS_SURFACE if tone == "target" else DesignTokens.PANEL, 12, accent, 2, 0)
	style.shadow_color = Color(accent, 0.16)
	style.shadow_size = 4
	get_node("TaskPanel").add_theme_stylebox_override("panel", style)
	var icon := get_node("TaskIcon") as Label
	icon.text = "!" if tone == "required" else "→" if tone == "target" else "…" if tone == "waiting" else "◆"
	icon.add_theme_color_override("font_color", accent)


func _apply_responsive_layout() -> void:
	if task_hint_label == null or size.x <= 0.0:
		return
	var narrow := size.x < 900.0
	var row_height := 70.0 if narrow else 58.0
	custom_minimum_size.y = 12.0 + row_height
	offset_bottom = offset_top + custom_minimum_size.y
	menu_button.position = Vector2(12, 6 + (row_height - 48.0) * 0.5)
	menu_button.size = Vector2(72, 48)
	turn_label.position = Vector2(12, row_height + 16)
	turn_label.custom_minimum_size = Vector2.ZERO
	turn_label.size = Vector2(minf(size.x * 0.25, 300.0), 30)
	turn_label.text = _turn_full_text.replace("我方行动", "我方").replace("对手行动", "对手")
	if size.x < 1180.0:
		var parts := turn_label.text.split(" · ")
		if parts.size() == 3:
			turn_label.text = "%s · %s" % [parts[0], parts[1]]
	turn_label.add_theme_font_size_override("font_size", 12 if narrow else 14)
	var panel := get_node("TaskPanel") as Control
	panel.position = Vector2(94, 6)
	panel.size = Vector2(maxf(1.0, size.x - 106), row_height)
	var actions := get_node("RightInset") as Control
	var width := 0.0
	for name in ["BackActionButton", "DetailButton", "CancelSelectionButton"]:
		var button := actions.get_node(name) as Button
		if not button.visible:
			continue
		button.position = Vector2(width, (row_height - 48.0) * 0.5)
		button.size = Vector2(96 if name == "CancelSelectionButton" else 88 if name == "BackActionButton" else 52, 48)
		width += button.size.x + 6.0
	actions.position = Vector2(size.x - 20.0 - width, 6)
	actions.size = Vector2(width, row_height)
	var icon := get_node("TaskIcon") as Control
	icon.position = Vector2(106, 6)
	icon.size = Vector2(24, row_height)
	task_hint_label.custom_minimum_size = Vector2.ZERO
	task_hint_label.position = Vector2(138, 10)
	task_hint_label.size = Vector2(maxf(48, actions.position.x - 150), row_height - 8)
	task_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	task_hint_label.max_lines_visible = 3 if narrow else 2
	task_hint_label.add_theme_font_size_override("font_size", 16 if narrow else 18)


func _phase_name(phase: String) -> String:
	return str({"SETUP": "准备阶段", "DRAW": "抽牌阶段", "MAIN": "主要阶段", "ATTACK": "攻击结算", "POKEMON_CHECKUP": "宝可梦检查", "GAME_OVER": "对局结束"}.get(phase, phase))
