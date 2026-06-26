class_name BattleActionPanel
extends PanelContainer

signal action_requested(action: GameAction)

@export var primary_action_button_height := 48.0
@export var secondary_action_button_height := 43.0

@onready var quick_actions: VBoxContainer = %QuickActions
@onready var action_list: VBoxContainer = %ActionList
@onready var all_actions_scroll: ScrollContainer = %AllActionsScroll
@onready var all_actions_toggle: Button = %AllActionsToggle

var _expanded := false
var _rows: Array[Dictionary] = []
var _connected := false


func _ready() -> void:
	_resolve_nodes()
	_ensure_connections()


func update_actions(
	action_rows: Array[Dictionary],
	_selected_entity_key: String,
	ai_thinking: bool,
	_game_mode: String,
) -> void:
	_resolve_nodes()
	_rows = action_rows.duplicate()
	visible = not _rows.is_empty()
	_clear_children(quick_actions)
	_clear_children(action_list)
	for index in range(_rows.size()):
		var row := _rows[index]
		var action: GameAction = row.get("action")
		if action == null:
			continue
		var button := _action_button(row, index < 3)
		button.disabled = ai_thinking
		if index < 3:
			quick_actions.add_child(button)
		action_list.add_child(_action_button(row, false))
	all_actions_scroll.visible = _expanded
	quick_actions.visible = not _expanded


func _resolve_nodes() -> void:
	quick_actions = get_node("Margin/Content/QuickActions") as VBoxContainer
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
		_expanded = not _expanded
		update_actions(_rows, "", false, "")
	)


func _action_button(row: Dictionary, prominent: bool) -> Button:
	var action: GameAction = row.get("action")
	var button := Button.new()
	button.text = str(row.get("label", action.action if action else "动作"))
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.custom_minimum_size.y = (
		primary_action_button_height
		if prominent
		else secondary_action_button_height
	)
	button.add_theme_font_size_override("font_size", 15 if prominent else 13)
	button.pressed.connect(func() -> void:
		if action:
			action_requested.emit(action)
	)
	return button


func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()
