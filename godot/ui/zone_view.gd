class_name ZoneView
extends Control

signal activated(card_id: String)
signal inspected(context: Dictionary)
signal action_requested(action: GameAction)

var title := ""
var card_id := ""
var count := 0
var is_hidden_zone := false
var target_player := -1
var target_slot := ""
var inspect_context: Dictionary = {}
var catalog := CardCatalog.new()

@onready var frame: Panel = %Frame
@onready var image: TextureRect = %Image
@onready var title_label: Label = %TitleLabel
@onready var count_label: Label = %CountLabel
@onready var empty_label: Label = %EmptyLabel
@onready var action_button: Button = %ActionButton
var _pending_action_row: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	gui_input.connect(_on_gui_input)
	action_button.pressed.connect(_on_action_pressed)
	_refresh()
	set_action(_pending_action_row)


func configure(
	p_title: String,
	p_card_id: String,
	p_count: int,
	p_hidden: bool = false,
	p_context: Dictionary = {},
) -> void:
	title = p_title
	card_id = p_card_id
	count = p_count
	is_hidden_zone = p_hidden
	inspect_context = p_context.duplicate(true)
	inspect_context["title"] = title
	inspect_context["count"] = count
	inspect_context["card_id"] = card_id
	inspect_context["hidden"] = is_hidden_zone
	_refresh()


func set_action(row: Dictionary = {}) -> void:
	_pending_action_row = row.duplicate()
	if not is_node_ready() or action_button == null:
		return
	var action: GameAction = row.get("action")
	action_button.visible = action != null
	if action == null:
		action_button.set_meta("action", null)
		return
	action_button.text = str(row.get("label", action.action))
	action_button.set_meta("action", action)


func _refresh() -> void:
	if not is_node_ready():
		return
	title_label.text = title
	count_label.text = str(count)
	count_label.visible = count > 0
	var texture_path := ""
	if is_hidden_zone and count > 0:
		texture_path = "res://assets/cards/card_back.webp"
	elif not card_id.is_empty():
		texture_path = str(catalog.get_card(card_id).get("image_path", ""))
	image.texture = (
		load(texture_path) as Texture2D
		if not texture_path.is_empty() and ResourceLoader.exists(texture_path)
		else null
	)
	empty_label.visible = image.texture == null
	empty_label.text = "空%s" % title


func _on_gui_input(event: InputEvent) -> void:
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and not event.pressed
	):
		if not inspect_context.is_empty():
			inspected.emit(inspect_context.duplicate(true))
		elif not card_id.is_empty():
			activated.emit(card_id)


func _on_action_pressed() -> void:
	var action: GameAction = action_button.get_meta("action") as GameAction
	if action:
		action_requested.emit(action)
