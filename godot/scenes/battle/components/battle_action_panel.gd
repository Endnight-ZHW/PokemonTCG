class_name BattleActionPanel
extends PanelContainer

signal action_requested(action: GameAction)
signal collapse_requested

@export var action_button_height := 48.0

@onready var action_list: VBoxContainer = %ActionList
@onready var all_actions_scroll: ScrollContainer = %AllActionsScroll
@onready var all_actions_toggle: Button = %AllActionsToggle

var _rows: Array[Dictionary] = []
var _ai_thinking := false
var _connected := false


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()


func update_actions(
	action_rows: Array[Dictionary],
	_selected_entity_key: String,
	ai_thinking: bool,
	_game_mode: String,
	expanded := false,
) -> void:
	_resolve_nodes()
	_rows = action_rows.duplicate()
	_ai_thinking = ai_thinking
	var should_show := expanded and not _rows.is_empty()
	visible = should_show
	_clear_children(action_list)
	all_actions_scroll.visible = true
	all_actions_toggle.disabled = _rows.is_empty()
	if not should_show:
		return
	for row in _rows:
		var action: GameAction = row.get("action")
		if action == null:
			continue
		var button := _action_button(row)
		button.disabled = ai_thinking
		action_list.add_child(button)


func _resolve_nodes() -> void:
	action_list = get_node(
		"Margin/Content/AllActionsScroll/ActionList"
	) as VBoxContainer
	all_actions_scroll = get_node(
		"Margin/Content/AllActionsScroll"
	) as ScrollContainer
	all_actions_toggle = get_node(
		"Margin/Content/Heading/AllActionsToggle"
	) as Button


func _ensure_connections() -> void:
	if _connected:
		return
	_connected = true
	all_actions_toggle.pressed.connect(func() -> void:
		collapse_requested.emit()
	)


func _action_button(row: Dictionary) -> Button:
	var action: GameAction = row.get("action")
	var button := Button.new()
	button.text = str(row.get("label", action.action if action else "动作"))
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.custom_minimum_size.y = action_button_height
	button.add_theme_font_size_override("font_size", 13)
	button.pressed.connect(func() -> void:
		if action and not _ai_thinking:
			action_requested.emit(action)
	)
	return button


func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()
